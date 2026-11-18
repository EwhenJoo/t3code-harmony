import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { base64, base64Decode, base64Url, randomUuid, sha256Base64Url, utf8 } from './Crypto';
import { Prefs } from '../common/Prefs';

const PREF_DPOP_KEY = 'dpop.key.v1';

export interface PublicJwk {
  kty: string;
  crv: string;
  x: string;
  y: string;
}

interface StoredKey {
  pub: string;
  pri: string;
}

interface ProofHeader {
  typ: string;
  alg: string;
  jwk: PublicJwk;
}

interface ProofPayload {
  htm: string;
  htu: string;
  jti: string;
  iat: number;
  ath?: string;
}

interface ThumbprintInput {
  crv: string;
  kty: string;
  x: string;
  y: string;
}

/** RFC 9449: the proof's `htu` is the request URL without query or fragment. */
export function dpopHtu(url: string): string {
  let end = url.length;
  const query = url.indexOf('?');
  const hash = url.indexOf('#');
  if (query >= 0) {
    end = Math.min(end, query);
  }
  if (hash >= 0) {
    end = Math.min(end, hash);
  }
  return url.substring(0, end);
}

/**
 * ECDSA signatures come out of cryptoFramework as DER (SEQUENCE of two INTEGERs);
 * JWS ES256 wants the fixed 64-byte r‖s form.
 */
export function derToJoseSignature(der: Uint8Array): Uint8Array {
  if (der.length < 8 || der[0] !== 0x30) {
    throw new Error('Unexpected ECDSA signature encoding');
  }
  let offset = der[1] & 0x80 ? 2 + (der[1] & 0x7f) : 2;
  const out = new Uint8Array(64);
  for (let part = 0; part < 2; part++) {
    if (der[offset] !== 0x02) {
      throw new Error('Unexpected ECDSA signature integer');
    }
    const length = der[offset + 1];
    let start = offset + 2;
    let size = length;
    while (size > 32 && der[start] === 0) {
      start++;
      size--;
    }
    if (size > 32) {
      throw new Error('ECDSA integer too long');
    }
    out.set(der.subarray(start, start + size), part * 32 + (32 - size));
    offset += 2 + length;
  }
  return out;
}

/** P-256 X.509 SubjectPublicKeyInfo ends with the uncompressed point 04‖X‖Y. */
function jwkFromSpki(spki: Uint8Array): PublicJwk {
  const point = spki.subarray(spki.length - 65);
  if (point[0] !== 0x04) {
    throw new Error('Unexpected P-256 public key encoding');
  }
  return {
    kty: 'EC',
    crv: 'P-256',
    x: base64Url(point.subarray(1, 33)),
    y: base64Url(point.subarray(33, 65)),
  };
}

/**
 * The device's proof-of-possession key for T3 Connect. Relay and environment access tokens are
 * bound to its thumbprint, so it must stay stable for the life of the install.
 */
export class DpopKey {
  readonly jwk: PublicJwk;
  readonly thumbprint: string;
  private readonly keyPair: cryptoFramework.KeyPair;

  private constructor(keyPair: cryptoFramework.KeyPair) {
    this.keyPair = keyPair;
    this.jwk = jwkFromSpki(keyPair.pubKey.getEncoded().data);
    const input: ThumbprintInput = { crv: this.jwk.crv, kty: this.jwk.kty, x: this.jwk.x, y: this.jwk.y };
    this.thumbprint = sha256Base64Url(JSON.stringify(input));
  }

  private static cached: DpopKey | null = null;

  static async load(): Promise<DpopKey> {
    if (DpopKey.cached !== null) {
      return DpopKey.cached;
    }
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    const raw = Prefs.getString(PREF_DPOP_KEY, '');
    let keyPair: cryptoFramework.KeyPair | null = null;
    if (raw.length > 0) {
      try {
        const stored = JSON.parse(raw) as StoredKey;
        keyPair = await generator.convertKey({ data: base64Decode(stored.pub) }, { data: base64Decode(stored.pri) });
      } catch (e) {
        keyPair = null;
      }
    }
    if (keyPair === null) {
      keyPair = await generator.generateKeyPair();
      const stored: StoredKey = {
        pub: base64(keyPair.pubKey.getEncoded().data),
        pri: base64(keyPair.priKey.getEncoded().data),
      };
      Prefs.put(PREF_DPOP_KEY, JSON.stringify(stored));
    }
    DpopKey.cached = new DpopKey(keyPair);
    return DpopKey.cached;
  }

  /** Forgets the key (sign-out). The next load creates a fresh one, unlinking old tokens. */
  static reset(): void {
    DpopKey.cached = null;
    Prefs.remove(PREF_DPOP_KEY);
  }

  /** A one-time DPoP proof JWT for `method url`, bound to `accessToken` via `ath` when given. */
  async proof(method: string, url: string, accessToken?: string): Promise<string> {
    const header: ProofHeader = { typ: 'dpop+jwt', alg: 'ES256', jwk: this.jwk };
    const payload: ProofPayload = {
      htm: method.toUpperCase(),
      htu: dpopHtu(url),
      jti: randomUuid(),
      iat: Math.floor(Date.now() / 1000),
    };
    if (accessToken !== undefined && accessToken.length > 0) {
      payload.ath = sha256Base64Url(accessToken);
    }
    const signingInput = `${base64Url(utf8(JSON.stringify(header)))}.${base64Url(utf8(JSON.stringify(payload)))}`;
    const signer = cryptoFramework.createSign('ECC256|SHA256');
    await signer.init(this.keyPair.priKey);
    const der = await signer.sign({ data: utf8(signingInput) });
    return `${signingInput}.${base64Url(derToJoseSignature(der.data))}`;
  }
}

const CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
const B64URL_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/** The code the host shows next to an approval request, derived exactly like T3 Code does. */
export function deviceVerificationCode(thumbprint: string): string {
  let code = '';
  const head = thumbprint.substring(0, 8);
  for (let i = 0; i < head.length; i++) {
    const value = Math.max(0, B64URL_ALPHABET.indexOf(head.charAt(i)));
    code += CODE_ALPHABET.charAt(value % CODE_ALPHABET.length);
  }
  return `${code.substring(0, 4)}-${code.substring(4)}`;
}
