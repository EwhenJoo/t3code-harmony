# T3 Code for HarmonyOS

[中文](#中文) · [English](#english)

## 中文

T3 Code 的鸿蒙原生客户端：在手机上查看和操作你电脑上运行的 T3 Code。

> 非官方社区项目，与 T3 Code 官方团队无关。

### 功能

- **连接电脑**：用 T3 账号登录（T3 Connect，任何网络都能连），或在局域网 / Tailscale 下扫码配对；可以同时连多台电脑
- **对话**：按项目分组的对话列表，实时查看输出；发消息、新建对话、批准命令、回答问题
- **输入**：选择模型、推理强度、计划模式和权限；添加图片和文件；语音输入
- **工作区**：Git（查看改动、提交、推送、创建 PR）、浏览文件、终端
- **PR 与用量**：查看、合并 PR；查看费用、Token 和额度
- **通知**：需要你处理、任务完成或失败时提醒，点开直达对话
- **鸿蒙特性**：折叠屏双栏、沉浸光感、新建按钮跟随握持手、深浅色

### 安装

需要 HarmonyOS 6.1 或更高版本。App 还没有上架应用市场，需要从电脑侧载：

1. 在 [Releases](https://github.com/EwhenJoo/t3code-harmony/releases/latest) 下载 `t3code-harmony-<版本>-unsigned.hap`。
2. 手机打开开发者模式：「设置 → 关于本机」连续点「软件版本」，再到「设置 → 系统 → 开发者选项」打开「USB 调试」或「无线调试」。
3. 在电脑上用侧载工具（例如小白调试助手）登录你自己的华为账号，给安装包自动签名并安装到手机。

这样安装的 App 在打开时照常提醒，但 App 关着时收不到推送：推送需要用你自己的 AGC 项目编译 App（见[开发说明](docs/DEVELOPMENT.md)）。

### 推送小助手

App 关着时的通知由推送小助手经华为 Push Kit 发送。把它装在一台常开的电脑上即可（Windows / macOS / Linux，需要 Node.js 22+）。

1. 安装，并填入 App 所属 AGC 项目的 Push Kit 服务账号：

   ```sh
   cd tools/t3-push
   npm install
   node bin/t3-push.mjs setup --project-id <AGC 项目 ID> --service-account <服务账号 JSON>
   ```

2. 接入电脑：在 T3 Code 的「Settings → Sharing & access」生成配对链接，然后：

   ```sh
   node bin/t3-push.mjs add '<配对链接>' --label 我的电脑
   ```

3. 绑定手机：运行下面的命令，在 App「设置 → 通知 → 推送小助手 → 扫码绑定」扫终端里的二维码，再点「发送测试通知」试一下。

   ```sh
   node bin/t3-push.mjs bind
   ```

4. 开机自动运行：

   ```sh
   node bin/t3-push.mjs install
   ```

更多选项见 [tools/t3-push/README.md](tools/t3-push/README.md)。

## English

A native HarmonyOS client for T3 Code: follow and drive the T3 Code running on your computer from your phone.

> Unofficial community project, not affiliated with the T3 Code team.

### Features

- **Connect**: sign in with your T3 account (T3 Connect, works on any network), or scan a pairing code on your LAN / Tailscale; connect several computers at once
- **Threads**: thread list grouped by project with live output; send messages, start new threads, approve commands, answer questions
- **Composer**: pick model, reasoning effort, plan mode and permissions; attach images and files; voice input
- **Workspace**: Git (view changes, commit, push, open a PR), file browser, terminal
- **PRs and usage**: review and merge pull requests; see cost, tokens and limits
- **Notifications**: when something needs you, finishes or fails; tap to open the thread
- **HarmonyOS**: two-pane layout on foldables, immersive light material, new-thread button follows your holding hand, light and dark themes

### Install

Requires HarmonyOS 6.1 or later. The app is not on AppGallery yet, so install it from a computer:

1. Download `t3code-harmony-<version>-unsigned.hap` from [Releases](https://github.com/EwhenJoo/t3code-harmony/releases/latest).
2. Turn on developer mode on the phone: in Settings → About phone, tap Software version repeatedly, then turn on USB debugging or Wireless debugging in Settings → System → Developer options.
3. On your computer, use a sideloading tool (for example 小白调试助手) to sign the package with your own Huawei account and install it on the phone.

Installed this way, the app notifies you while it is open, but cannot receive push notifications while it is closed: push needs the app built with your own AGC project (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).

### Push helper

When the app is closed, notifications are sent by the push helper through Huawei Push Kit. Install it on a computer that stays on (Windows / macOS / Linux, Node.js 22+).

1. Install it and give it the Push Kit service account of the app's AGC project:

   ```sh
   cd tools/t3-push
   npm install
   node bin/t3-push.mjs setup --project-id <AGC project ID> --service-account <service account JSON>
   ```

2. Add your computer: create a pairing link in T3 Code under Settings → Sharing & access, then:

   ```sh
   node bin/t3-push.mjs add '<pairing link>' --label my-computer
   ```

3. Bind your phone: run the command below and scan the QR code in the app under 设置 (Settings) → 通知 (Notifications) → 推送小助手 (Push helper) → 扫码绑定 (Scan to bind), then tap 发送测试通知 (Send test notification).

   ```sh
   node bin/t3-push.mjs bind
   ```

4. Start it automatically at login:

   ```sh
   node bin/t3-push.mjs install
   ```

See [tools/t3-push/README.md](tools/t3-push/README.md) for more options (in Chinese).

---

[MIT](LICENSE) · 开发说明 / Development: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
