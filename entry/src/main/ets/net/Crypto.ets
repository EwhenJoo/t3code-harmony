import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export function utf8(text: string): Uint8Array {
  return new util.TextEncoder().encodeInto(text);
}

export function utf8Decode(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

export function base64(bytes: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(bytes);
}

export function base64Decode(text: string): Uint8Array {
  return new util.Base64Helper().decodeSync(text);
}

/** RFC 4648 §5 without padding, as JOSE requires. */
export function base64Url(bytes: Uint8Array): string {
  return base64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

export function base64UrlDecode(text: string): Uint8Array {
  let normalized = text.replace(/-/g, '+').replace(/_/g, '/');
  while (normalized.length % 4 !== 0) {
    normalized += '=';
  }
  return base64Decode(normalized);
}

export function sha256(bytes: Uint8Array): Uint8Array {
  const md = cryptoFramework.createMd('SHA256');
  md.updateSync({ data: bytes });
  return md.digestSync().data;
}

export function sha256Base64Url(text: string): string {
  return base64Url(sha256(utf8(text)));
}

export function randomUuid(): string {
  return util.generateRandomUUID(false);
}

/** Decodes the payload of a compact JWT without verifying it (for reading `exp` and `sub`). */
export function jwtPayload(jwt: string): Record<string, Object> | null {
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    return null;
  }
  try {
    return JSON.parse(utf8Decode(base64UrlDecode(parts[1]))) as Record<string, Object>;
  } catch (e) {
    return null;
  }
}
