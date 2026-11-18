// Mock T3 Connect deployment for the HarmonyOS client tests: Clerk's native Frontend API
// (email-code sign-in), the relay (DPoP token exchange, computer list, tunnel credentials) and
// the computer-side checks (DPoP-bound tokens, first-connection approval).
//
// Every DPoP proof is verified for real (ES256 signature, htm/htu, iat, jti replay, ath and the
// key thumbprint), so the tests prove the client's crypto, not just its control flow.
//
//   Clerk  : http://<host>/__clerk/v1/...      user dev@t3.example, email code 424242
//   Relay  : http://<host>/__relay/v1/...
//   Tunnel : http://<host> (the mock environment itself)

import crypto from "node:crypto";

export const MOCK_EMAIL = "dev@t3.example";
export const MOCK_CODE = "424242";
const TEMPLATE = "t3-relay";
const CLIENT_ID = "t3-mobile";

const b64url = (buf) => Buffer.from(buf).toString("base64url");
const sha256b64url = (text) => b64url(crypto.createHash("sha256").update(text).digest());

export function freshConnectState() {
  return {
    clients: new Map(), // client jwt -> { signIns: Map, sessions: Map }
    clerkTokens: new Map(), // session jwt -> { sub, exp }
    relayTokens: new Map(), // relay access token -> { thumbprint, scope, exp }
    credentials: new Map(), // tunnel credential -> { environmentId, thumbprint, exp }
    envTokens: new Map(), // environment access token -> { thumbprint, exp }
    approved: new Set(), // thumbprints approved on the "computer"
    pending: new Set(),
    requireApproval: true,
    seenJti: new Set(),
    log: [],
  };
}

export let cs = freshConnectState();
export function resetConnect() {
  cs = freshConnectState();
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", ...headers });
  res.end(JSON.stringify(body));
}

function clerkError(res, status, code, message) {
  send(res, status, { errors: [{ code, message, long_message: message }] });
}

function fakeJwt(claims) {
  return `${b64url(JSON.stringify({ alg: "none", typ: "JWT" }))}.${b64url(JSON.stringify(claims))}.${b64url(crypto.randomBytes(16))}`;
}

/** Verifies an RFC 9449 proof; returns { thumbprint } or { error }. */
export function verifyDpop(proof, method, url, accessToken) {
  if (!proof) return { error: "missing_proof" };
  const parts = proof.split(".");
  if (parts.length !== 3) return { error: "malformed_proof" };
  let header, payload;
  try {
    header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"));
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
  } catch {
    return { error: "malformed_proof" };
  }
  if (header.typ !== "dpop+jwt" || header.alg !== "ES256" || header.jwk?.kty !== "EC" || header.jwk?.crv !== "P-256") {
    return { error: "bad_header" };
  }
  if ("d" in header.jwk) return { error: "private_key_leaked" };
  const key = crypto.createPublicKey({ key: { kty: "EC", crv: "P-256", x: header.jwk.x, y: header.jwk.y }, format: "jwk" });
  const signature = Buffer.from(parts[2], "base64url");
  if (signature.length !== 64) return { error: "signature_not_jose" };
  const ok = crypto.verify("sha256", Buffer.from(`${parts[0]}.${parts[1]}`), { key, dsaEncoding: "ieee-p1363" }, signature);
  if (!ok) return { error: "invalid_signature" };
  const htu = url.split("?")[0].split("#")[0];
  if (payload.htm !== method.toUpperCase()) return { error: `method_mismatch:${payload.htm}` };
  if (payload.htu !== htu) return { error: `url_mismatch:${payload.htu} != ${htu}` };
  if (Math.abs(Date.now() / 1000 - payload.iat) > 300) return { error: "time_window" };
  if (!payload.jti || cs.seenJti.has(payload.jti)) return { error: "replayed" };
  cs.seenJti.add(payload.jti);
  if (accessToken !== undefined && payload.ath !== sha256b64url(accessToken)) return { error: "ath_mismatch" };
  const thumbprint = sha256b64url(JSON.stringify({ crv: header.jwk.crv, kty: header.jwk.kty, x: header.jwk.x, y: header.jwk.y }));
  return { thumbprint };
}

// ---------------------------------------------------------------------------------------------
// Clerk Frontend API (native mode)

function clientFor(req) {
  return cs.clients.get(req.headers.authorization ?? "");
}

function clientJson(client) {
  return {
    object: "client",
    id: client.id,
    last_active_session_id: [...client.sessions.keys()].at(-1) ?? null,
    sessions: [...client.sessions.values()].map((s) => ({
      id: s.id,
      status: "active",
      user: { id: "user_mock", primary_email_address_id: "idn_mock", email_addresses: [{ id: "idn_mock", email_address: MOCK_EMAIL }] },
    })),
  };
}

function handleClerk(req, res, url, form) {
  if (url.searchParams.get("_is_native") !== "1") return clerkError(res, 400, "native_required", "Missing _is_native");
  const path = url.pathname.replace(/^\/__clerk/, "");
  if (path === "/v1/client" && req.method === "POST") {
    const jwt = fakeJwt({ client: crypto.randomUUID() });
    const client = { id: `client_${crypto.randomUUID().slice(0, 8)}`, signIns: new Map(), sessions: new Map() };
    cs.clients.set(jwt, client);
    return send(res, 200, { response: clientJson(client), client: null }, { authorization: jwt });
  }
  const client = clientFor(req);
  if (!client) return clerkError(res, 401, "authentication_invalid", "Unknown client");
  if (path === "/v1/client" && req.method === "GET") {
    return send(res, 200, { response: clientJson(client), client: null });
  }
  if (path === "/v1/client/sign_ins" && req.method === "POST") {
    const identifier = (form.get("identifier") ?? "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(identifier)) return clerkError(res, 422, "form_param_format_invalid", "Identifier is invalid.");
    if (identifier !== MOCK_EMAIL) return clerkError(res, 422, "form_identifier_not_found", "Couldn't find your account.");
    const signIn = { id: `sia_${crypto.randomUUID().slice(0, 8)}`, status: "needs_first_factor", prepared: false };
    client.signIns.set(signIn.id, signIn);
    cs.log.push({ tag: "clerk.signIn", payload: { identifier } });
    return send(res, 200, {
      response: {
        object: "sign_in_attempt",
        id: signIn.id,
        status: signIn.status,
        supported_first_factors: [
          { strategy: "email_code", email_address_id: "idn_mock", safe_identifier: "d**@t3.example" },
          { strategy: "password" },
        ],
      },
      client: clientJson(client),
    });
  }
  const signInMatch = /^\/v1\/client\/sign_ins\/([^/]+)\/(prepare_first_factor|attempt_first_factor)$/.exec(path);
  if (signInMatch && req.method === "POST") {
    const signIn = client.signIns.get(signInMatch[1]);
    if (!signIn) return clerkError(res, 404, "resource_not_found", "Sign in not found");
    if (signInMatch[2] === "prepare_first_factor") {
      if (form.get("strategy") !== "email_code" || form.get("email_address_id") !== "idn_mock") {
        return clerkError(res, 422, "strategy_for_user_invalid", "Bad strategy");
      }
      signIn.prepared = true;
      cs.log.push({ tag: "clerk.codeSent", payload: {} });
      return send(res, 200, { response: { object: "sign_in_attempt", id: signIn.id, status: "needs_first_factor" }, client: clientJson(client) });
    }
    if (!signIn.prepared) return clerkError(res, 422, "verification_missing", "Prepare first");
    if (form.get("code") !== MOCK_CODE) return clerkError(res, 422, "form_code_incorrect", "Incorrect code");
    const session = { id: `sess_${crypto.randomUUID().slice(0, 8)}` };
    client.sessions.set(session.id, session);
    signIn.status = "complete";
    cs.log.push({ tag: "clerk.signedIn", payload: { session: session.id } });
    return send(res, 200, {
      response: { object: "sign_in_attempt", id: signIn.id, status: "complete", created_session_id: session.id },
      client: clientJson(client),
    });
  }
  const tokenMatch = /^\/v1\/client\/sessions\/([^/]+)\/tokens\/([^/]+)$/.exec(path);
  if (tokenMatch && req.method === "POST") {
    if (!client.sessions.has(tokenMatch[1])) return clerkError(res, 404, "session_not_found", "No session");
    if (tokenMatch[2] !== TEMPLATE) return clerkError(res, 404, "template_not_found", "No template");
    const jwt = fakeJwt({ sub: "user_mock", aud: "t3-relay", exp: Math.floor(Date.now() / 1000) + 60 });
    cs.clerkTokens.set(jwt, { sub: "user_mock", exp: Date.now() + 60000 });
    return send(res, 200, { object: "token", jwt });
  }
  const removeMatch = /^\/v1\/client\/sessions\/([^/]+)\/remove$/.exec(path);
  if (removeMatch && req.method === "POST") {
    client.sessions.delete(removeMatch[1]);
    cs.log.push({ tag: "clerk.signedOut", payload: {} });
    return send(res, 200, { response: { object: "session", id: removeMatch[1], status: "removed" }, client: clientJson(client) });
  }
  return clerkError(res, 404, "not_found", path);
}

// ---------------------------------------------------------------------------------------------
// Relay

function validClerk(token) {
  const entry = cs.clerkTokens.get(token);
  return entry && entry.exp > Date.now();
}

function computers(host) {
  return [
    { environmentId: "mock-env", label: "Mock 工作站", endpoint: { httpBaseUrl: `http://${host}`, wsBaseUrl: `ws://${host}`, providerKind: "cloudflare" }, linkedAt: new Date(Date.now() - 86400000).toISOString() },
    { environmentId: "env-offline", label: "家里的 Mac mini", endpoint: { httpBaseUrl: "http://10.255.255.1:9", wsBaseUrl: "ws://10.255.255.1:9", providerKind: "cloudflare" }, linkedAt: new Date(Date.now() - 7 * 86400000).toISOString() },
  ];
}

function handleRelay(req, res, url, body) {
  const host = req.headers.host;
  const path = url.pathname.replace(/^\/__relay/, "");
  const fullUrl = `http://${host}${url.pathname}`;
  if (path === "/v1/client/dpop-token" && req.method === "POST") {
    const form = new URLSearchParams(body);
    if (form.get("client_id") !== CLIENT_ID || form.get("resource") !== `http://${host}/__relay`) return send(res, 401, { code: "invalid_request" });
    if (form.get("grant_type") !== "urn:ietf:params:oauth:grant-type:token-exchange" || form.get("subject_token_type") !== "urn:ietf:params:oauth:token-type:jwt") return send(res, 400, { code: "unsupported_grant_type" });
    if (!validClerk(form.get("subject_token"))) return send(res, 401, { code: "invalid_bearer" });
    const proof = verifyDpop(req.headers.dpop, "POST", fullUrl);
    if (proof.error) return send(res, 401, { code: "invalid_dpop", detail: proof.error });
    const token = `rat_${crypto.randomUUID()}`;
    const scope = form.get("scope");
    cs.relayTokens.set(token, { thumbprint: proof.thumbprint, scope, exp: Date.now() + 600000 });
    cs.log.push({ tag: "relay.token", payload: { scope } });
    return send(res, 200, { access_token: token, issued_token_type: "urn:ietf:params:oauth:token-type:access_token", token_type: "DPoP", expires_in: 600, scope });
  }
  if (path === "/v1/environments" && req.method === "GET") {
    const bearer = (req.headers.authorization ?? "").replace(/^Bearer /, "");
    if (!validClerk(bearer)) return send(res, 401, { code: "invalid_bearer" });
    return send(res, 200, { environments: computers(host) });
  }
  const connectMatch = /^\/v1\/environments\/([^/]+)\/connect$/.exec(path);
  if (connectMatch && req.method === "POST") {
    const token = (req.headers.authorization ?? "").replace(/^DPoP /, "");
    const entry = cs.relayTokens.get(token);
    if (!entry || entry.exp < Date.now() || !entry.scope.split(" ").includes("environment:connect")) return send(res, 401, { code: "invalid_token" });
    const proof = verifyDpop(req.headers.dpop, "POST", fullUrl, token);
    if (proof.error || proof.thumbprint !== entry.thumbprint) return send(res, 401, { code: "invalid_dpop", detail: proof.error ?? "key_mismatch" });
    let payload = {};
    try { payload = JSON.parse(body || "{}"); } catch { return send(res, 400, { code: "bad_json" }); }
    if (payload.clientProofKeyThumbprint !== entry.thumbprint) return send(res, 401, { code: "thumbprint_mismatch" });
    const computer = computers(host).find((c) => c.environmentId === decodeURIComponent(connectMatch[1]));
    if (!computer) return send(res, 404, { code: "environment_not_found" });
    if (computer.environmentId === "env-offline") return send(res, 503, { code: "environment_offline" });
    const credential = `cred_${crypto.randomUUID()}`;
    cs.credentials.set(credential, { environmentId: computer.environmentId, thumbprint: entry.thumbprint, exp: Date.now() + 120000 });
    cs.log.push({ tag: "relay.connect", payload: { environmentId: computer.environmentId } });
    return send(res, 200, { environmentId: computer.environmentId, endpoint: computer.endpoint, credential, expiresAt: new Date(Date.now() + 120000).toISOString() });
  }
  return send(res, 404, { code: "not_found", path });
}

/** Handles /__clerk and /__relay; returns false for everything else. */
export function handleConnectRoutes(req, res, url, body) {
  if (url.pathname.startsWith("/__clerk/")) {
    handleClerk(req, res, url, new URLSearchParams(body));
    return true;
  }
  if (url.pathname.startsWith("/__relay/")) {
    handleRelay(req, res, url, body);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// Computer side

/** `/oauth/token` with a relay credential. Returns true when it handled the request. */
export function handleTunnelTokenExchange(req, res, form) {
  const credential = form.get("subject_token") ?? "";
  if (!credential.startsWith("cred_")) return false;
  const entry = cs.credentials.get(credential);
  if (!entry || entry.exp < Date.now()) {
    send(res, 401, { code: "invalid_credential", message: "Credential expired" });
    return true;
  }
  const proof = verifyDpop(req.headers.dpop, "POST", `http://${req.headers.host}/oauth/token`);
  if (proof.error || proof.thumbprint !== entry.thumbprint) {
    send(res, 401, { code: "invalid_credential", detail: proof.error ?? "key_mismatch" });
    return true;
  }
  if (cs.requireApproval && !cs.approved.has(proof.thumbprint)) {
    cs.pending.add(proof.thumbprint);
    cs.log.push({ tag: "connect.pending", payload: { client_label: form.get("client_label") } });
    send(res, 403, { _tag: "EnvironmentConnectApprovalPendingError", code: "connect_approval_pending", traceId: crypto.randomUUID() });
    return true;
  }
  cs.credentials.delete(credential);
  const token = `eat_${crypto.randomUUID()}`;
  cs.envTokens.set(token, { thumbprint: proof.thumbprint, exp: Date.now() + 3600000 });
  cs.log.push({ tag: "connect.token", payload: { client_label: form.get("client_label"), client_os: form.get("client_os") } });
  send(res, 200, { access_token: token, issued_token_type: "urn:ietf:params:oauth:token-type:access_token", token_type: "DPoP", expires_in: 3600, scope: "orchestration:read orchestration:operate" });
  return true;
}

/** Validates `Authorization: DPoP <token>` + proof. Returns the thumbprint, or null. */
export function dpopPrincipal(req, url) {
  const auth = req.headers.authorization ?? "";
  if (!auth.startsWith("DPoP ")) return null;
  const token = auth.slice(5);
  const entry = cs.envTokens.get(token);
  if (!entry || entry.exp < Date.now()) return null;
  const proof = verifyDpop(req.headers.dpop, req.method, `http://${req.headers.host}${url.pathname}`, token);
  if (proof.error || proof.thumbprint !== entry.thumbprint) {
    cs.log.push({ tag: "connect.rejected", payload: { error: proof.error ?? "key_mismatch", path: url.pathname } });
    return null;
  }
  return proof.thumbprint;
}

/** Test controls: approve waiting devices, toggle approval, expire tokens. */
export function handleConnectTestRoutes(req, res, url) {
  if (url.pathname === "/__test/connect/approve" && req.method === "POST") {
    for (const t of cs.pending) cs.approved.add(t);
    const count = cs.pending.size;
    cs.pending.clear();
    send(res, 200, { approved: count });
    return true;
  }
  if (url.pathname === "/__test/connect/expire" && req.method === "POST") {
    for (const entry of cs.envTokens.values()) entry.exp = 0;
    send(res, 200, { ok: true });
    return true;
  }
  if (url.pathname === "/__test/connect/state") {
    send(res, 200, { pending: cs.pending.size, approved: cs.approved.size, envTokens: cs.envTokens.size, log: cs.log });
    return true;
  }
  return false;
}
