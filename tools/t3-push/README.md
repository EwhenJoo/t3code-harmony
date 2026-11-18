# T3 推送小助手（t3-push）

让鸿蒙手机在 App 关闭时也能收到 T3 Code 的通知：需要你批准、等你回答、任务完成、任务失败。

T3 官方中继只发苹果和安卓推送，所以由这个小程序代劳。它对 T3 来说就是一个普通客户端：

1. 用配对链接连上各台电脑的 T3 Code（局域网或 Tailscale 直连，不经过 T3 Connect，不占它的名额），订阅对话状态；
2. 发现有对话需要你、完成或失败时，经华为 Push Kit 推到绑定的手机；
3. 点通知直接打开那条对话（`t3code://thread?id=…&env=…`）。

不修改 T3 服务端。推送内容只有对话标题、项目名和电脑名，不含消息正文。

## 运行环境

- Node.js 22+（Windows、Linux、macOS 都可以）
- 一台基本常开的机器装一份即可，它能盯所有电脑；手机要能访问它（同一局域网或 Tailscale）

## 安装

```sh
cd tools/t3-push
npm install
node bin/t3-push.mjs setup --project-id <AGC 项目 ID> --service-account <推送服务账号 JSON>
```

服务账号 JSON 在 AppGallery Connect → 项目设置 → 服务账号密钥 下载（需要 Push Kit 权限）。`setup` 会把它复制到配置目录，
仓库里不保存任何密钥。默认以**测试消息**发送：不需要“自分类权益”，但每天有条数上限；权益批下来后加 `--production`。

## 接入电脑

在每台电脑上生成一个配对链接（T3 Code「Settings → Sharing & access」，或与服务端同版本的命令行
`t3 auth pairing create --ttl 10m --base-url http://<这台电脑的 Tailscale/局域网地址>:3773`），然后：

```sh
node bin/t3-push.mjs add 'http://100.x.y.z:3773/pair#token=…' --label 实验室
node bin/t3-push.mjs list
```

注意：`~/.local/bin/t3` 如果是旧版（如 0.0.45），它和正在运行的服务端用的不是同一个数据库，生成的配对码服务端不认。
Windows 上可以用桌面版自带的同版本命令行：

```powershell
$env:ELECTRON_RUN_AS_NODE = '1'
& "$env:LOCALAPPDATA\Programs\t3code\T3 Code (Nightly).exe" "$env:LOCALAPPDATA\Programs\t3code\resources\server.asar\apps\server\dist\bin.mjs" auth pairing create --ttl 10m --base-url http://127.0.0.1:3773 --json
```

## 绑定手机

```sh
node bin/t3-push.mjs bind            # 终端里显示二维码（自动选 Tailscale 地址，没有则用局域网地址）
node bin/t3-push.mjs bind --host <电脑的局域网 IP>
```

用手机相机或 App「设置 → 通知 → 推送小助手 → 扫码绑定」扫码即可。之后可以在 App 里发测试通知或解除绑定，
也可以在电脑上 `node bin/t3-push.mjs test`。

## 开机自动运行

```sh
node bin/t3-push.mjs install     # Linux：systemd 用户服务；macOS：launchd；Windows：「启动」文件夹（无需管理员）
node bin/t3-push.mjs uninstall
```

运行中修改配置（`add`、`remove`、`setup`）会在几秒内自动生效，不用重启。日志：配置目录下的 `t3-push.log`。

| 系统 | 配置目录 |
| --- | --- |
| Windows | `%APPDATA%\t3-push` |
| macOS | `~/Library/Application Support/t3-push` |
| Linux | `~/.config/t3-push` |

`config.json` 里有各台电脑的访问令牌、手机的推送令牌和绑定密钥，只应本人可读。撤销一台电脑：`t3-push remove <名称>`，
并在那台电脑的 T3 Code 里撤销这个客户端（名为配对时的标签，类型 bot）。

## 多台电脑：每台各装一份 + 同伴同步

隔着 Tailscale 中继（DERP）去连别的电脑的 T3 时，几 MB 的状态快照会让连接时断时续。更稳的做法是每台电脑各装一份、
只盯本机的 T3（连 `127.0.0.1`，T3 的数据不出本机），手机只在其中一份上绑定一次，再由它把手机转交给其它几份：

```sh
# 在新机器上：用这台已配置好的机器打包（含预置配置、手机令牌、推送服务账号，注意保管），传过去后运行 install.sh
node scripts/pack-for-linux.mjs ./t3-push-linux.tar.gz <新机器的 tailnet 地址> <名称>   # 最后一行打印它的绑定链接
# 在新机器上（只监听 127.0.0.1，用 tailnet 内转发给同伴访问）：
bash t3-push-bundle/install.sh                  # Node 22+、接入本机 T3、开机自启、tailscale serve 8790、测试推送
# 回到绑定手机的那台：
node bin/t3-push.mjs peer add 't3code://push?url=http://<新机器>:8790&key=…'
```

之后手机在这台重新绑定（比如重装 App 换了令牌）时会自动同步给所有同伴；同伴每 10 分钟也会再收到一次完整列表。
没有 systemd 的机器上，`install.sh` 会改用 cron `@reboot` + nohup 开机自启。

## 网络

- 电脑上的 T3 只监听 `127.0.0.1` 时（常见于 Linux 服务器），在那台电脑上用 Tailscale 把端口只转发给自己的 tailnet，
  不用改 T3：`tailscale serve --bg --tcp=3773 tcp://127.0.0.1:3773`（用户态 tailscaled 要加 `--socket=…`）。
  不要用 funnel，那会暴露到公网。经 DERP 中继时首个请求可能要几秒，小助手的超时是 30 秒，断线会自动重连。
- 小助手监听 `0.0.0.0:8790`（`config.json` 的 `listen` 可改）。手机只在绑定、测试和刷新令牌时访问它，平时不需要连着。
- Windows 防火墙按网络类型放行：如果手机走 Tailscale（Windows 把 Tailscale 网卡记为“专用”网络）而 node.exe 只在“公用”网络放行，
  需要为 node.exe 加一条专用网络的入站规则，或改用局域网地址绑定。

## 测试

```sh
npm test    # 事件判定、配对链接解析、Push Kit JWT 签名，以及对着 tools/mock-t3 的真实配对 + 订阅 + 完成事件
```
