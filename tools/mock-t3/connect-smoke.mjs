// End-to-end smoke test of the mock T3 Connect flow with a reference DPoP client in Node:
// Clerk email code → relay DPoP token → computer list → tunnel credential → approval → DPoP
// environment token → WebSocket ticket → DPoP-proved upgrade.
//   node tools/mock-t3/connect-smoke.mjs [http://127.0.0.1:3790]
import crypto from "node:crypto";
import http from "node:http";

const base = process.argv[2] ?? "http://127.0.0.1:3790";
const { publicKey, privateKey } = crypto.generateKeyPairSync("ec", { namedCurve: "P-256" });
const jwk = publicKey.export({ format: "jwk" });
const b64url = (b) => Buffer.from(b).toString("base64url");
const thumbprint = b64url(crypto.createHash("sha256").update(JSON.stringify({ crv: jwk.crv, kty: jwk.kty, x: jwk.x, y: jwk.y })).digest());

function proof(method, url, accessToken) {
  const header = b64url(JSON.stringify({ typ: "dpop+jwt", alg: "ES256", jwk: { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y } }));
  const payload = { htm: method, htu: url.split("?")[0], jti: crypto.randomUUID(), iat: Math.floor(Date.now() / 1000) };
  if (accessToken) payload.ath = b64url(crypto.createHash("sha256").update(accessToken).digest());
  const input = `${header}.${b64url(JSON.stringify(payload))}`;
  const sig = crypto.sign("sha256", Buffer.from(input), { key: privateKey, dsaEncoding: "ieee-p1363" });
  return `${input}.${b64url(sig)}`;
}

let clientJwt = "";
async function clerk(method, path, form) {
  const res = await fetch(`${base}/__clerk${path}?_is_native=1`, {
    method,
    headers: { "content-type": "application/x-www-form-urlencoded", ...(clientJwt ? { authorization: clientJwt } : {}) },
    body: form ? new URLSearchParams(form).toString() : undefined,
  });
  clientJwt = res.headers.get("authorization") ?? clientJwt;
  return { status: res.status, body: await res.json() };
}

function assert(cond, message) {
  if (!cond) {
    console.error("FAIL:", message);
    process.exit(1);
  }
  console.log("ok  ", message);
}

await fetch(`${base}/__test/reset`, { method: "POST" });
await clerk("POST", "/v1/client");
const unknown = await clerk("POST", "/v1/client/sign_ins", { identifier: "nobody@example.com" });
assert(unknown.body.errors?.[0]?.code === "form_identifier_not_found", "unknown email is rejected");
const signIn = await clerk("POST", "/v1/client/sign_ins", { identifier: "dev@t3.example" });
const factor = signIn.body.response.supported_first_factors.find((f) => f.strategy === "email_code");
await clerk("POST", `/v1/client/sign_ins/${signIn.body.response.id}/prepare_first_factor`, { strategy: "email_code", email_address_id: factor.email_address_id });
const wrong = await clerk("POST", `/v1/client/sign_ins/${signIn.body.response.id}/attempt_first_factor`, { strategy: "email_code", code: "000000" });
assert(wrong.body.errors?.[0]?.code === "form_code_incorrect", "wrong code is rejected");
const done = await clerk("POST", `/v1/client/sign_ins/${signIn.body.response.id}/attempt_first_factor`, { strategy: "email_code", code: "424242" });
const sessionId = done.body.response.created_session_id;
assert(done.body.response.status === "complete" && sessionId, "email code signs in");
const clerkJwt = (await clerk("POST", `/v1/client/sessions/${sessionId}/tokens/t3-relay`)).body.jwt;

const relay = `${base}/__relay`;
const tokenUrl = `${relay}/v1/client/dpop-token`;
const rt = await (await fetch(tokenUrl, {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded", dpop: proof("POST", tokenUrl) },
  body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:token-exchange", subject_token: clerkJwt, subject_token_type: "urn:ietf:params:oauth:token-type:jwt", requested_token_type: "urn:ietf:params:oauth:token-type:access_token", resource: relay, scope: "environment:connect", client_id: "t3-mobile" }).toString(),
})).json();
assert(rt.token_type === "DPoP", "relay issues a DPoP token");
const envs = await (await fetch(`${relay}/v1/environments`, { headers: { authorization: `Bearer ${clerkJwt}` } })).json();
assert(envs.environments.length === 2, "relay lists computers");
const connectUrl = `${relay}/v1/environments/mock-env/connect`;
const connect = async () => (await fetch(connectUrl, {
  method: "POST",
  headers: { authorization: `DPoP ${rt.access_token}`, dpop: proof("POST", connectUrl, rt.access_token), "content-type": "application/json" },
  body: JSON.stringify({ clientProofKeyThumbprint: thumbprint }),
})).json();
const exchange = async (credential) => fetch(`${base}/oauth/token`, {
  method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded", dpop: proof("POST", `${base}/oauth/token`) },
  body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:token-exchange", subject_token: credential, subject_token_type: "urn:t3:params:oauth:token-type:environment-bootstrap", requested_token_type: "urn:ietf:params:oauth:token-type:access_token", client_label: "smoke" }).toString(),
});
const first = await exchange((await connect()).credential);
assert(first.status === 403 && (await first.json()).code === "connect_approval_pending", "first connection waits for approval");
await fetch(`${base}/__test/connect/approve`, { method: "POST" });
const second = await exchange((await connect()).credential);
const envToken = await second.json();
assert(second.status === 200 && envToken.token_type === "DPoP", "approved device gets a DPoP environment token");

const ticketUrl = `${base}/api/auth/websocket-ticket/rpc`;
const bearerOnly = await fetch(ticketUrl, { method: "POST", headers: { authorization: `DPoP ${envToken.access_token}` } });
assert(bearerOnly.status === 401, "a DPoP token without a proof is refused");
const ticket = await (await fetch(ticketUrl, { method: "POST", headers: { authorization: `DPoP ${envToken.access_token}`, dpop: proof("POST", ticketUrl, envToken.access_token) } })).json();
assert(typeof ticket.ticket === "string", "DPoP request gets a WebSocket ticket");

const upgrade = (withProof) => new Promise((resolve) => {
  const wsProof = proof("GET", `${base}/ws`, ticket.ticket);
  const q = `wsTicket=${encodeURIComponent(ticket.ticket)}&orchestrationProtocol=2&connectionMethod=relay${withProof ? `&dpop=${encodeURIComponent(wsProof)}` : ""}`;
  const req = http.request(`${base}/ws?${q}`, { headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": crypto.randomBytes(16).toString("base64") } });
  req.on("upgrade", (res, socket) => { socket.destroy(); resolve(101); });
  req.on("response", (res) => resolve(res.statusCode));
  req.on("error", () => resolve(0));
  req.end();
});
assert((await upgrade(false)) !== 101, "upgrade without the DPoP query proof is refused");
// The refused upgrade did not consume the ticket, so the proved one can still use it.
assert((await upgrade(true)) === 101, "upgrade with the DPoP query proof is accepted");
console.log("connect smoke passed");
