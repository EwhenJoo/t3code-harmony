#!/usr/bin/env node
// T3 推送小助手：盯着各台电脑上的 T3 Code，有对话需要你、完成或失败时，经华为 Push Kit 推到鸿蒙手机。
import NodeOS from "node:os";
import { configDir, configPath, importPrivateFile, loadConfig, saveConfig } from "../src/config.mjs";
import { Daemon } from "../src/daemon.mjs";
import { loadServiceAccount, makePushClient } from "../src/huawei.mjs";
import { install, uninstall } from "../src/service.mjs";
import { pairComputer } from "../src/t3.mjs";

const HELP = `T3 推送小助手

用法：
  t3-push setup --project-id <AGC 项目 ID> --service-account <服务账号 JSON> [--category WORK] [--production]
      配置华为 Push Kit。默认以测试消息发送（无需自分类权益，有每日条数上限）；拿到权益后加 --production。
  t3-push add <配对链接> [--label 名称]
      接入一台电脑。在那台电脑的 T3 Code「Settings → Sharing & access」里生成配对链接，或运行与服务端同版本的
      t3 auth pairing create --ttl 10m --base-url http://<它的地址>:3773，把 /pair#token=… 链接交给这里。
      支持 Tailscale / 局域网地址，不经过 T3 Connect。
  t3-push list                      列出电脑和已绑定的手机
  t3-push remove <ID 或名称>         移除一台电脑或一部手机
  t3-push bind [--host <地址>]       显示二维码；在手机 App「设置 → 通知 → 推送小助手」扫码绑定
  t3-push run                       前台运行（install 后由系统自动运行）
  t3-push test                      给所有已绑定的手机发一条测试通知
  t3-push peer add <另一台小助手的绑定链接>   把在这里绑定的手机同步给它（例如 Linux 服务器上只盯本机的那份）
  t3-push peer list | peer remove <名称>
  t3-push install | uninstall       开机/登录时自动运行（Linux systemd、macOS launchd、Windows「启动」文件夹）

配置目录：${configDir()}
`;

function option(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const value = args[i + 1];
  args.splice(i, 2);
  return value;
}

function flag(args, name) {
  const i = args.indexOf(name);
  if (i < 0) return false;
  args.splice(i, 1);
  return true;
}

/** Tailscale (100.64.0.0/10) first, then a private LAN address. */
function guessHost() {
  const addrs = Object.values(NodeOS.networkInterfaces()).flat().filter((a) => a && a.family === "IPv4" && !a.internal);
  const tailscale = addrs.find((a) => {
    const [x, y] = a.address.split(".").map(Number);
    return x === 100 && y >= 64 && y <= 127;
  });
  if (tailscale) return tailscale.address;
  const lan = addrs.find((a) => /^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address));
  return (lan ?? addrs[0])?.address ?? "127.0.0.1";
}

async function main() {
  const args = process.argv.slice(2);
  const command = args.shift();
  switch (command) {
    case "setup": {
      const projectId = option(args, "--project-id");
      const serviceAccount = option(args, "--service-account");
      const category = option(args, "--category") ?? "WORK";
      const production = flag(args, "--production");
      if (!projectId || !/^\d+$/.test(projectId) || !serviceAccount) throw new Error("需要 --project-id 和 --service-account");
      const target = await importPrivateFile(serviceAccount, "service-account.json");
      await loadServiceAccount(target);
      const config = await loadConfig();
      config.push = { projectId, serviceAccountFile: target, category, testMessage: !production };
      await saveConfig(config);
      console.log(`已配置 Push Kit（项目 ${projectId}，分类 ${category}，${production ? "正式消息" : "测试消息"}）`);
      return;
    }
    case "add": {
      const label = option(args, "--label");
      const link = args[0];
      if (!link) throw new Error("用法：t3-push add <配对链接> [--label 名称]");
      const computer = await pairComputer(link, { label });
      const config = await loadConfig();
      config.computers = [...config.computers.filter((c) => c.id !== computer.id), computer];
      await saveConfig(config);
      console.log(`已接入：${computer.label}（${computer.baseUrl}）`);
      return;
    }
    case "list": {
      const config = await loadConfig();
      console.log(`配置：${configPath()}`);
      console.log(`Push Kit：${config.push ? `项目 ${config.push.projectId}${config.push.testMessage ? "（测试消息）" : ""}` : "未配置"}`);
      console.log("电脑：");
      for (const c of config.computers) console.log(`  ${c.label}  ${c.baseUrl}  [${c.id}]`);
      if (!config.computers.length) console.log("  （无）");
      console.log("手机：");
      for (const d of config.devices) console.log(`  ${d.label}  绑定于 ${d.updatedAt}`);
      if (!config.devices.length) console.log("  （无）");
      return;
    }
    case "remove": {
      const key = args[0];
      const config = await loadConfig();
      const computers = config.computers.length;
      const devices = config.devices.length;
      config.computers = config.computers.filter((c) => c.id !== key && c.label !== key);
      config.devices = config.devices.filter((d) => d.id !== key && d.label !== key);
      if (config.computers.length === computers && config.devices.length === devices) throw new Error(`没有找到 ${key}`);
      await saveConfig(config);
      console.log(config.computers.length < computers
        ? "已移除电脑；别忘了在那台电脑的 T3 Code 设置里撤销这个客户端"
        : "已移除手机");
      return;
    }
    case "bind": {
      const config = await loadConfig();
      await saveConfig(config);
      const host = option(args, "--host") ?? guessHost();
      const base = `http://${host}:${config.listen.port}`;
      const link = `t3code://push?url=${encodeURIComponent(base)}&key=${config.bindKey}&name=${encodeURIComponent(NodeOS.hostname())}`;
      const { renderUnicodeCompact } = await import("uqr");
      console.log(renderUnicodeCompact(link, { border: 2 }));
      console.log(`用手机相机或 App「设置 → 通知 → 推送小助手 → 扫码绑定」扫描上面的二维码，或复制这个链接：\n${link}`);
      console.log(`\n手机需要能访问 ${base}（同一局域网或 Tailscale）。`);
      return;
    }
    case "run": {
      const daemon = new Daemon();
      await daemon.start();
      const stop = () => {
        daemon.stop();
        process.exit(0);
      };
      process.on("SIGINT", stop);
      process.on("SIGTERM", stop);
      return;
    }
    case "test": {
      const config = await loadConfig();
      if (!config.push) throw new Error("还没有配置 Push Kit，先运行 t3-push setup");
      if (!config.devices.length) throw new Error("还没有绑定手机，先运行 t3-push bind");
      const client = makePushClient({
        projectId: config.push.projectId,
        account: await loadServiceAccount(config.push.serviceAccountFile),
        category: config.push.category,
        testMessage: config.push.testMessage !== false,
      });
      for (const device of config.devices) {
        try {
          await client.send(device.token, { title: "T3 推送小助手", body: `来自 ${NodeOS.hostname()} 的测试通知`, notifyId: 1 });
          console.log(`已发送到 ${device.label}`);
        } catch (error) {
          console.log(`发送到 ${device.label} 失败：${error.message}`);
        }
      }
      return;
    }
    case "peer": {
      const sub = args.shift();
      const config = await loadConfig();
      if (sub === "add") {
        const link = String(args[0] ?? "");
        const q = link.indexOf("?");
        const params = new URLSearchParams(q >= 0 ? link.slice(q + 1) : "");
        const url = (params.get("url") ?? "").replace(/\/+$/, "");
        const key = params.get("key") ?? "";
        if (!link.startsWith("t3code://push") || !/^https?:\/\/[^/]+$/.test(url) || key.length < 16) {
          throw new Error("用法：t3-push peer add 't3code://push?url=…&key=…'（在另一台运行 t3-push bind 得到）");
        }
        const name = params.get("name") || url;
        config.peers = [...config.peers.filter((p) => p.url !== url), { name, url, key }];
        await saveConfig(config);
        console.log(`已添加同伴 ${name}（${url}）；运行中的小助手几秒内会把已绑定的手机同步过去`);
        return;
      }
      if (sub === "remove") {
        const before = config.peers.length;
        config.peers = config.peers.filter((p) => p.name !== args[0] && p.url !== args[0]);
        if (config.peers.length === before) throw new Error(`没有找到同伴 ${args[0]}`);
        await saveConfig(config);
        console.log("已移除同伴");
        return;
      }
      for (const p of config.peers) console.log(`${p.name}  ${p.url}`);
      if (!config.peers.length) console.log("（没有同伴）");
      return;
    }
    case "install":
      console.log(await install());
      return;
    case "uninstall":
      console.log(await uninstall());
      return;
    case undefined:
    case "help":
    case "--help":
    case "-h":
      console.log(HELP);
      return;
    default:
      throw new Error(`未知命令 ${command}\n\n${HELP}`);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
