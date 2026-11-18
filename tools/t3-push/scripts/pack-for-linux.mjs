// Packs the helper for another machine: app files, a seed config (fresh bind key, listen on
// 127.0.0.1, the phones bound here), the Push Kit service account and install-linux.sh.
// Usage: node scripts/pack-for-linux.mjs <out.tar.gz>
// Prints the new helper's bind link (for `t3-push peer add`) — keep it private.
import { execFileSync } from "node:child_process";
import NodeFS from "node:fs/promises";
import NodeOS from "node:os";
import NodePath from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig, newKey } from "../src/config.mjs";

const here = NodePath.dirname(fileURLToPath(import.meta.url));
const root = NodePath.resolve(here, "..");
const out = NodePath.resolve(process.argv[2] ?? "t3-push-linux.tar.gz");
const host = process.argv[3] ?? "";

const config = await loadConfig();
if (!config.push?.serviceAccountFile) throw new Error("先在这台机器上运行 t3-push setup");
const stage = await NodeFS.mkdtemp(NodePath.join(NodeOS.tmpdir(), "t3-push-pack-"));
const bundle = NodePath.join(stage, "t3-push-bundle");
try {
  await NodeFS.mkdir(NodePath.join(bundle, "app"), { recursive: true });
  for (const entry of ["bin", "src", "node_modules", "package.json", "README.md"]) {
    await NodeFS.cp(NodePath.join(root, entry), NodePath.join(bundle, "app", entry), { recursive: true });
  }
  await NodeFS.mkdir(NodePath.join(bundle, "seed"));
  const seed = {
    version: 1,
    listen: { host: "127.0.0.1", port: 8790 },
    bindKey: newKey(),
    push: null,
    computers: [],
    devices: config.devices,
    peers: [],
  };
  await NodeFS.writeFile(NodePath.join(bundle, "seed", "config.json"), `${JSON.stringify(seed, null, 2)}\n`);
  await NodeFS.copyFile(config.push.serviceAccountFile, NodePath.join(bundle, "seed", "service-account.json"));
  await NodeFS.copyFile(NodePath.join(here, "install-linux.sh"), NodePath.join(bundle, "install.sh"));
  // Windows: bsdtar from System32 (GNU tar from Git would read "C:" as a remote host).
  const tar = process.platform === "win32" ? NodePath.join(process.env.SystemRoot ?? "C:\\Windows", "System32", "tar.exe") : "tar";
  execFileSync(tar, ["-czf", out, "-C", stage, "t3-push-bundle"], { stdio: "inherit" });
  console.log(`已打包：${out}`);
  if (host) {
    console.log(`t3code://push?url=${encodeURIComponent(`http://${host}:8790`)}&key=${seed.bindKey}&name=${encodeURIComponent(process.argv[4] ?? "Linux")}`);
  }
} finally {
  await NodeFS.rm(stage, { recursive: true, force: true });
}
