/**
 * Pairing link parsing, matching apps/mobile/src/features/connection/pairing.ts:
 *  - `t3code://pair?pairingUrl=<url>` wrapper (what the desktop QR code encodes)
 *  - hosted links `https://app/pair?host=<server>#token=<code>`
 *  - direct links `http://192.168.1.5:3773/pair#token=<code>` or `?token=`
 */

export class PairingTarget {
  baseUrl: string = '';
  token: string = '';
  label: string = '';
}

function decode(value: string): string {
  try {
    return decodeURIComponent(value.replace(/\+/g, ' '));
  } catch (e) {
    return value;
  }
}

function readParam(params: string, name: string): string {
  const parts = params.split('&');
  for (const part of parts) {
    const eq = part.indexOf('=');
    const key = eq >= 0 ? part.substring(0, eq) : part;
    if (decode(key) === name) {
      return eq >= 0 ? decode(part.substring(eq + 1)).trim() : '';
    }
  }
  return '';
}

function isIpLiteral(host: string): boolean {
  const bare = host.split(':')[0];
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(bare) || host.startsWith('[') || bare === 'localhost';
}

/** Returns `scheme://host[:port]` for a URL-ish string, adding a scheme when missing. */
export function originOf(raw: string): string {
  let value = raw.trim();
  if (value.length === 0) {
    return '';
  }
  if (value.indexOf('://') < 0) {
    value = (isIpLiteral(value) ? 'http://' : 'https://') + value;
  }
  const schemeEnd = value.indexOf('://') + 3;
  let end = value.length;
  for (const sep of ['/', '?', '#']) {
    const idx = value.indexOf(sep, schemeEnd);
    if (idx >= 0 && idx < end) {
      end = idx;
    }
  }
  return value.substring(0, end);
}

export function parsePairingInput(input: string): PairingTarget {
  const result = new PairingTarget();
  let value = input.trim();
  if (value.length === 0) {
    return result;
  }
  // Unwrap the app link the desktop QR encodes.
  if (value.startsWith('t3code') && value.indexOf('://pair') > 0) {
    const q = value.indexOf('?');
    if (q >= 0) {
      const inner = readParam(value.substring(q + 1), 'pairingUrl');
      if (inner.length > 0) {
        value = inner;
      }
    }
  }
  const hashIdx = value.indexOf('#');
  const hash = hashIdx >= 0 ? value.substring(hashIdx + 1) : '';
  const beforeHash = hashIdx >= 0 ? value.substring(0, hashIdx) : value;
  const qIdx = beforeHash.indexOf('?');
  const query = qIdx >= 0 ? beforeHash.substring(qIdx + 1) : '';

  let token = readParam(hash, 'token');
  if (token.length === 0) {
    token = readParam(query, 'token');
  }
  const hostedHost = readParam(query, 'host');
  result.label = readParam(query, 'label');
  result.token = token;
  result.baseUrl = hostedHost.length > 0 ? originOf(hostedHost) : originOf(beforeHash);
  return result;
}

export function wsUrlFor(baseUrl: string): string {
  if (baseUrl.startsWith('https://')) {
    return 'wss://' + baseUrl.substring(8);
  }
  if (baseUrl.startsWith('http://')) {
    return 'ws://' + baseUrl.substring(7);
  }
  return baseUrl;
}
