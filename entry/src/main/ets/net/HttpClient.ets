import { http } from '@kit.NetworkKit';

export const ORCHESTRATION_PROTOCOL_VERSION: string = '2';

export class HttpError extends Error {
  status: number;
  body: string;

  constructor(status: number, body: string, message: string) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

export class HttpResult {
  status: number = 0;
  body: string = '';
  /** Response headers with lower-cased names. */
  headers: Map<string, string> = new Map();
}

/** Small promise wrapper over @kit.NetworkKit http with text bodies. */
export async function httpRequest(
  method: http.RequestMethod,
  url: string,
  headers: Record<string, string>,
  body?: string,
  timeoutMs?: number,
): Promise<HttpResult> {
  const client = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: timeoutMs ?? 10000,
      readTimeout: timeoutMs ?? 30000,
      maxLimit: 32 * 1024 * 1024,
      usingCache: false,
    };
    // NetworkKit rejects an empty-string body with error 401 (parameter error); omit it instead.
    if (body !== undefined && body.length > 0) {
      options.extraData = body;
    }
    const response = await client.request(url, options);
    const result = new HttpResult();
    result.status = response.responseCode as number;
    result.body = typeof response.result === 'string' ? response.result as string : JSON.stringify(response.result);
    const raw = response.header as Record<string, Object> | undefined;
    if (raw !== undefined && raw !== null) {
      Object.keys(raw).forEach((name: string) => {
        result.headers.set(name.toLowerCase(), String(raw[name]));
      });
    }
    return result;
  } finally {
    client.destroy();
  }
}

export class BinaryResult {
  status: number = 0;
  data: ArrayBuffer = new ArrayBuffer(0);
  contentType: string = '';
}

/** GET a binary resource (images); the body stays an ArrayBuffer. */
export async function httpDownload(url: string, headers: Record<string, string>, timeoutMs: number = 15000,
  maxBytes: number = 4 * 1024 * 1024): Promise<BinaryResult> {
  const client = http.createHttp();
  try {
    const response = await client.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      maxLimit: maxBytes,
      usingCache: false,
    });
    const result = new BinaryResult();
    result.status = response.responseCode as number;
    if (response.result instanceof ArrayBuffer) {
      result.data = response.result as ArrayBuffer;
    }
    const raw = response.header as Record<string, Object> | undefined;
    if (raw !== undefined && raw !== null) {
      Object.keys(raw).forEach((name: string) => {
        if (name.toLowerCase() === 'content-type') {
          result.contentType = String(raw[name]).toLowerCase();
        }
      });
    }
    return result;
  } finally {
    client.destroy();
  }
}

/** POST a binary body (attachment uploads); the server answers 204 with no body. */
export async function httpUpload(url: string, headers: Record<string, string>, data: ArrayBuffer,
  timeoutMs: number = 180000): Promise<HttpResult> {
  const client = http.createHttp();
  try {
    const response = await client.request(url, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: data,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: timeoutMs,
      usingCache: false,
    });
    const result = new HttpResult();
    result.status = response.responseCode as number;
    result.body = typeof response.result === 'string' ? response.result as string : '';
    return result;
  } finally {
    client.destroy();
  }
}

export function formEncode(fields: Record<string, string>): string {
  const parts: string[] = [];
  Object.keys(fields).forEach((key: string) => {
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(fields[key]));
  });
  return parts.join('&');
}

export function authHeaders(accessToken: string): Record<string, string> {
  const headers: Record<string, string> = {
    'authorization': 'Bearer ' + accessToken,
    'x-t3-orchestration-protocol': ORCHESTRATION_PROTOCOL_VERSION,
    'accept': 'application/json',
  };
  return headers;
}

export function describeHttpFailure(result: HttpResult): string {
  let detail = '';
  try {
    const parsed = JSON.parse(result.body) as Record<string, Object>;
    const message = parsed['message'];
    const code = parsed['code'] ?? parsed['error'];
    if (typeof message === 'string') {
      detail = message as string;
    } else if (typeof code === 'string') {
      detail = code as string;
    }
  } catch (e) {
    detail = result.body.substring(0, 160);
  }
  return `HTTP ${result.status}${detail.length > 0 ? ' · ' + detail : ''}`;
}
