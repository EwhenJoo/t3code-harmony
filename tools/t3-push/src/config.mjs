// Where the helper keeps its state, and how it reads and writes it.
//
// config.json holds the computers' access tokens, the phones' push tokens and the bind key, so it
// is written with owner-only permissions (POSIX) and replaced atomically.
import NodeCrypto from "node:crypto";
import NodeFS from "node:fs/promises";
import NodeOS from "node:os";
import NodePath from "node:path";

export const DEFAULT_PORT = 8790;

export function configDir() {
  if (process.env.T3_PUSH_HOME) return process.env.T3_PUSH_HOME;
  const home = NodeOS.homedir();
  if (process.platform === "win32") {
    return NodePath.join(process.env.APPDATA || NodePath.join(home, "AppData", "Roaming"), "t3-push");
  }
  if (process.platform === "darwin") {
    return NodePath.join(home, "Library", "Application Support", "t3-push");
  }
  return NodePath.join(process.env.XDG_CONFIG_HOME || NodePath.join(home, ".config"), "t3-push");
}

export function configPath() {
  return NodePath.join(configDir(), "config.json");
}

export function newKey() {
  return NodeCrypto.randomBytes(16).toString("hex");
}

function defaults() {
  return {
    version: 1,
    listen: { host: "0.0.0.0", port: DEFAULT_PORT },
    bindKey: newKey(),
    push: null,
    computers: [],
    devices: [],
    // Other helpers that should receive this helper's phones: [{ name, url, key }].
    peers: [],
  };
}

export async function loadConfig() {
  let raw;
  try {
    raw = await NodeFS.readFile(configPath(), "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return defaults();
    throw error;
  }
  const value = JSON.parse(raw);
  const base = defaults();
  return {
    ...base,
    ...value,
    listen: { ...base.listen, ...(value.listen ?? {}) },
    computers: Array.isArray(value.computers) ? value.computers : [],
    devices: Array.isArray(value.devices) ? value.devices : [],
    peers: Array.isArray(value.peers) ? value.peers : [],
  };
}

export async function saveConfig(config) {
  const dir = configDir();
  await NodeFS.mkdir(dir, { recursive: true, mode: 0o700 });
  const target = configPath();
  const temp = `${target}.${process.pid}.tmp`;
  await NodeFS.writeFile(temp, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  await NodeFS.rename(temp, target);
}

/** Copies a file into the config folder (owner-only) and returns its new path. */
export async function importPrivateFile(source, name) {
  const dir = configDir();
  await NodeFS.mkdir(dir, { recursive: true, mode: 0o700 });
  const target = NodePath.join(dir, name);
  await NodeFS.copyFile(source, target);
  await NodeFS.chmod(target, 0o600).catch(() => {});
  return target;
}
