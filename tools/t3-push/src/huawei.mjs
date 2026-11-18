// Huawei Push Kit (HarmonyOS, REST v3) with a project-level service account: a PS256 JWT signed
// with the service account key is the bearer token; no OAuth round trip is needed.
// https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-jwt-token
import NodeCrypto from "node:crypto";
import NodeFS from "node:fs/promises";

export class PushError extends Error {
  constructor(code, message) {
    super(message ?? `Push Kit 返回 ${code}`);
    this.code = code;
  }
}

/** Codes meaning "this token will never work again": forget the device. */
export const DEAD_TOKEN_CODES = new Set(["80300007"]);

export async function loadServiceAccount(path) {
  const value = JSON.parse(await NodeFS.readFile(path, "utf8"));
  for (const field of ["key_id", "sub_account", "private_key"]) {
    if (typeof value[field] !== "string" || !value[field].trim()) {
      throw new Error(`服务账号文件缺少 ${field}`);
    }
  }
  return { keyId: value.key_id, subAccount: value.sub_account, privateKey: value.private_key, projectId: value.project_id ?? "" };
}

export function signJwt(account, now = Date.now()) {
  const iat = Math.floor(now / 1000);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const unsigned = `${encode({ alg: "PS256", typ: "JWT", kid: account.keyId })}.${encode({
    iss: account.subAccount,
    aud: "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
    iat,
    exp: iat + 3600,
  })}`;
  const signature = NodeCrypto.sign("sha256", Buffer.from(unsigned), {
    key: NodeCrypto.createPrivateKey(account.privateKey),
    padding: NodeCrypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: 32,
  });
  return `${unsigned}.${signature.toString("base64url")}`;
}

/** Stable per conversation, so a newer notice replaces the older one for the same thread. */
export function notifyIdFor(key) {
  const digest = NodeCrypto.createHash("sha256").update(key).digest();
  return digest.readUInt32BE(0) & 0x7fffffff;
}

export function makePushClient({ projectId, account, category = "WORK", testMessage = true }, fetcher = fetch) {
  let cached = null;
  return {
    /** message: { title, body, uri?, notifyId? } */
    async send(token, message) {
      if (!cached || cached.expiresAt < Date.now()) {
        cached = { jwt: signJwt(account), expiresAt: Date.now() + 50 * 60_000 };
      }
      const notification = {
        category,
        title: [...message.title].slice(0, 40).join(""),
        body: [...message.body].slice(0, 160).join(""),
        clickAction: message.uri ? { actionType: 1, uri: message.uri } : { actionType: 0 },
        // While the app is open it shows its own in-app notice; the push would only duplicate it.
        foregroundShow: false,
      };
      if (message.notifyId !== undefined) notification.notifyId = message.notifyId;
      let response;
      try {
        response = await fetcher(`https://push-api.cloud.huawei.com/v3/${projectId}/messages:send`, {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(10_000),
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${cached.jwt}`,
            "push-type": "0",
          },
          body: JSON.stringify({
            payload: { notification },
            target: { token: [token] },
            pushOptions: { testMessage, ttl: 86_400 },
          }),
        });
      } catch (error) {
        throw new PushError("transport", `连不上 Push Kit：${error.cause?.code ?? error.message}`);
      }
      let result = null;
      try {
        result = await response.json();
      } catch {
        // fall through with the HTTP status
      }
      if (response.status === 401) cached = null;
      if (!response.ok || result?.code !== "80000000") {
        const code = typeof result?.code === "string" ? result.code : `http-${response.status}`;
        throw new PushError(code, `Push Kit 拒绝了推送（${code}${result?.msg ? `：${result.msg}` : ""}）`);
      }
      return result.requestId ?? "";
    },
  };
}
