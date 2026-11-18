// Start-at-login for `t3-push run` on each desktop OS:
//   Linux    systemd user unit        ~/.config/systemd/user/t3-push.service
//   macOS    launchd agent            ~/Library/LaunchAgents/codes.t3.push.plist
//   Windows  Startup folder           "T3 Push Helper.vbs" starts node hidden through wscript
//            (a logon scheduled task would need administrator rights)
import { execFileSync, spawn } from "node:child_process";
import NodeFS from "node:fs/promises";
import NodeOS from "node:os";
import NodePath from "node:path";
import { fileURLToPath } from "node:url";
import { configDir } from "./config.mjs";

const BIN = NodePath.resolve(NodePath.dirname(fileURLToPath(import.meta.url)), "..", "bin", "t3-push.mjs");
const NAME = "T3 Push Helper";
const LAUNCHD_LABEL = "codes.t3.push";

function run(cmd, args, { allowFail = false } = {}) {
  try {
    return execFileSync(cmd, args, { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
  } catch (error) {
    if (allowFail) return "";
    throw new Error(`${cmd} ${args.join(" ")} 失败：${(error.stderr || error.message).trim()}`);
  }
}

function systemdUnitPath() {
  return NodePath.join(process.env.XDG_CONFIG_HOME || NodePath.join(NodeOS.homedir(), ".config"), "systemd", "user", "t3-push.service");
}

function launchdPlistPath() {
  return NodePath.join(NodeOS.homedir(), "Library", "LaunchAgents", `${LAUNCHD_LABEL}.plist`);
}

function windowsLauncherPath() {
  const appData = process.env.APPDATA || NodePath.join(NodeOS.homedir(), "AppData", "Roaming");
  return NodePath.join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup", `${NAME}.vbs`);
}

/** The launcher only starts node; a running helper is found by its command line. */
function stopWindowsHelper() {
  const script = "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | "
    + "Where-Object { $_.CommandLine -like '*t3-push.mjs*' -and $_.CommandLine -like '* run*' } | "
    + "ForEach-Object { Stop-Process -Id $_.ProcessId -Force }";
  run("powershell", ["-NoProfile", "-Command", script], { allowFail: true });
}

export async function install() {
  const node = process.execPath;
  if (process.platform === "linux") {
    const unit = systemdUnitPath();
    await NodeFS.mkdir(NodePath.dirname(unit), { recursive: true });
    await NodeFS.writeFile(unit, [
      "[Unit]",
      "Description=T3 Code push helper (HarmonyOS notifications)",
      "After=network-online.target",
      "Wants=network-online.target",
      "",
      "[Service]",
      `ExecStart=${node} ${BIN} run`,
      "Restart=always",
      "RestartSec=5",
      "",
      "[Install]",
      "WantedBy=default.target",
      "",
    ].join("\n"));
    run("systemctl", ["--user", "daemon-reload"]);
    run("systemctl", ["--user", "enable", "--now", "t3-push.service"]);
    run("systemctl", ["--user", "restart", "t3-push.service"]);
    // Without lingering, user services stop at logout; best effort (may need polkit).
    run("loginctl", ["enable-linger", NodeOS.userInfo().username], { allowFail: true });
    return `已安装 systemd 用户服务：${unit}\n查看日志：journalctl --user -u t3-push -f`;
  }
  if (process.platform === "darwin") {
    const plist = launchdPlistPath();
    await NodeFS.mkdir(NodePath.dirname(plist), { recursive: true });
    await NodeFS.mkdir(configDir(), { recursive: true });
    const log = NodePath.join(configDir(), "t3-push.out.log");
    await NodeFS.writeFile(plist, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${node}</string><string>${BIN}</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${log}</string>
  <key>StandardErrorPath</key><string>${log}</string>
</dict>
</plist>
`);
    const domain = `gui/${process.getuid()}`;
    run("launchctl", ["bootout", domain, plist], { allowFail: true });
    run("launchctl", ["bootstrap", domain, plist]);
    return `已安装 launchd 代理：${plist}`;
  }
  if (process.platform === "win32") {
    const launcher = windowsLauncherPath();
    await NodeFS.mkdir(NodePath.dirname(launcher), { recursive: true });
    // VBScript string: double quotes inside are doubled. 0 = hidden window, False = don't wait.
    const quoted = (s) => `""${s}""`;
    await NodeFS.writeFile(launcher, `CreateObject("WScript.Shell").Run "${quoted(node)} ${quoted(BIN)} run", 0, False\r\n`);
    stopWindowsHelper();
    spawn("wscript.exe", [launcher], { detached: true, stdio: "ignore", windowsHide: true }).unref();
    return `已加入开机启动（${launcher}）并已在后台启动\n日志：${NodePath.join(configDir(), "t3-push.log")}`;
  }
  throw new Error(`暂不支持 ${process.platform}`);
}

export async function uninstall() {
  if (process.platform === "linux") {
    run("systemctl", ["--user", "disable", "--now", "t3-push.service"], { allowFail: true });
    await NodeFS.rm(systemdUnitPath(), { force: true });
    run("systemctl", ["--user", "daemon-reload"], { allowFail: true });
    return "已移除 systemd 用户服务";
  }
  if (process.platform === "darwin") {
    run("launchctl", ["bootout", `gui/${process.getuid()}`, launchdPlistPath()], { allowFail: true });
    await NodeFS.rm(launchdPlistPath(), { force: true });
    return "已移除 launchd 代理";
  }
  if (process.platform === "win32") {
    await NodeFS.rm(windowsLauncherPath(), { force: true });
    stopWindowsHelper();
    return "已从开机启动中移除，并停止了后台的小助手";
  }
  throw new Error(`暂不支持 ${process.platform}`);
}
