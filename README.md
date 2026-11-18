# T3 Code for HarmonyOS

T3 Code 的鸿蒙原生客户端（ArkTS / ArkUI，Stage 模型，编译与目标 API 26，最低 API 23）。UI 参照 T3 Code iOS 版，
直接连接你电脑上运行的 T3 Code 服务端（与 iOS/Android 版使用同一套协议）。

> 这是社区做的非官方客户端，与 T3 Code 官方团队无关。T3 Code 的名称与标志归其所有者。

## 已实现

| 模块 | 说明 |
| --- | --- |
| T3 Connect | 用 T3 账号（邮箱验证码）登录，列出账号下开启了 T3 Connect 的电脑，经 `relay.t3.codes` 隧道连接；首次连接显示与电脑一致的核对码等待批准；设备绑定令牌（DPoP / ES256）到期自动续期 |
| 配对 | 扫码（Scan Kit）、粘贴配对链接、`t3code://pair?pairingUrl=` 深链；一次性配对码换取长期 access token（局域网 / Tailscale） |
| 多台电脑 | 可以同时连接多台电脑（局域网配对和 T3 Connect 可混用），所有电脑的线程合并在同一个列表里；顶部用「笔记本图标 + 每台电脑一个状态点」概括连接情况（不写名字，出问题时才补一句短文字），行内标出线程所在的电脑，筛选菜单可按电脑或项目筛选；每台电脑独立连接、断线重连和续期；同一台电脑换一种方式连接时替换旧的那条记录，不会重复出现 |
| 折叠屏 / 大屏 | 窗口 ≥ 600vp（Pura X Max 展开、平板）时左列表右对话的双栏布局（列表宽 32%，限制在 280–380vp；系统报告折痕时以折痕分栏、不在折痕上画内容），选中行高亮、未选线程时的占位页；折叠/展开时正在看的对话自动接续 |
| 实时连接 | `/ws` 上的 Effect RPC（JSON 帧、逐 Chunk Ack、5s Ping / 15s 静默断开、指数退避重连、回前台立即重连） |
| 底部页签 | 对话 / PR / 用量 / 设置四个页签，只显示图标（`HdsTabs` 浮动栏，固定 256vp 宽、在任何屏幕上居中）；有待处理时对话图标带琥珀色小点。「新建对话」是一个只有一个按钮的 `HdsTabs` 浮动栏，与页签栏是同一种系统组件、同一块材质（透明度、光感完全一致），比页签栏高一个身位：单屏时悬浮在握持手一侧，展开态固定在左侧列表栏的右下角。新建与电脑版一致：先弹出可搜索的项目列表（最近用过的在前，同名项目合成一项、副标题列出所在电脑），选好后打开空白的对话页——中间是项目图标、名称和路径，同名项目在多台电脑上时可点选在哪台电脑上做；模型、计划、权限、附件都在同一个输入框里，发出第一条消息后这个页面直接变成该对话（先显示刚发的消息，不跳页） |
| 对话列表 | 左上角是 T3 Code 标志（T3 字标 + Code + BETA），HDS 标题栏右侧是「分组与筛选」和搜索。默认和电脑侧边栏一样按项目分组：项目标题带与电脑同步的图标（电脑上设置的 Lucide 图标与颜色、Emoji、字母图标，或项目自带的 favicon（经 `assets.createUrl` 取签名地址），都没有时用与电脑相同的算法按项目名生成字母和颜色），多台电脑上同名的项目合成一组（组标题不标电脑，进对话可见）；点标题折叠/展开并记住，折叠时数量前一个状态色点（与电脑一致：琥珀等待批准、靛蓝等待回答、红色失败、天蓝运行中、绿色已完成未查看）；每组先列 5 个（待处理、运行中优先），其余「再显示」；组里已完成的对话默认隐藏（「分组与筛选」或设置里可打开），全部已完成的项目只在打开「显示已完成」或搜索时出现；每条对话右侧显示状态（审批 / 待回答、等待、运行计时、失败、草稿、完成未读，否则显示时间），两种分组方式相同；在手机上写了没发的内容按对话保存为草稿，再打开时填回；也可切回按状态分组（待处理 / 运行中 / 收件箱 / 稍后 / 可折叠的已完成）、每行显示项目 · 模型 · 分支与状态（审批 / 待回答 / 运行计时 / 失败）、左滑完成/归档、右滑置顶；长按菜单：打开、置顶、稍后提醒（1 小时后 / 今晚 / 明天上午 / 下周）、标记为完成或恢复、重命名（留空则重新生成标题）、归档、删除（先确认） |
| 对话详情 | HDS 标题栏右上角与 iOS 相同的三个按钮：文件、Git、终端；用户气泡、助手 Markdown、可折叠工作日志（命令/工具/修改/思考）、审批卡片、提问卡片、计划卡片，实时流式更新。代理一次问多个问题时一题一页（与电脑版一致）：顶部是进度条和「1 / 3」，左右滑动或「上一题 / 下一题」翻页，单选题选完自动翻到下一题，多选和自填答案用「下一题」，最后一页点「提交回答」；只有一个问题时仍是点一下就回答 |
| 输入 | 输入框下方一行是「模型 · 推理强度 · 快速」胶囊和「计划」开关。点胶囊打开与电脑版一致的三栏选择器：左栏是 harness（Claude / Codex / Cursor…，当前所用的带蓝点），中栏是该 harness 的模型，右栏是当前模型的推理强度、速度（标准 / 快速）和其它选项（来自服务端的 `optionDescriptors`）；底部一行是计划模式开关和权限（完全访问 / 自动 / 自动接受编辑 / 每步审批，点开是菜单）。窄屏三栏用紧凑宽度，展开屏自动加宽。运行中发送可设为「引导当前任务」或「排队到结束后」；新建对话用同一个输入框。左下角回形针可添加照片（系统图库）或文件（系统文件选择器），选好立即上传到对话所在的电脑（`attachments.createUploadUrl` 签名地址，图片 ≤10 MB 且为 png/jpeg/webp/gif，否则自动转 JPEG；文件 ≤50 MB），输入框上方显示缩略图/文件卡片，可单个移除或失败重试；发出的消息里图片按 `assets.createUrl` 取回显示，文件显示名称和大小。自动补全与电脑版一致：电脑上在「设置 → 实验室」打开提示建议后，Claude 每轮回复结束会给出下一句建议（`orchestration.subscribePromptSuggestion`，只对最近一轮已完成的运行有效）；输入框为空时建议显示在占位处，右侧发送键换成同样大小的 ⇥ 补全键，点一下填入（回车键设为发送时，空输入框回车也是补全），再点发送。发送键左边是麦克风：点一下开始录音，输入框下方换成「取消 · 音量条 · 计时 · 完成」，点完成后录音（16 kHz 单声道）发到设置里选的电脑转成文字，插到光标处（最长 5 分钟） |
| Git | 标题栏菜单显示分支与改动摘要、一键操作（与 iOS 相同的判定：提交 / 提交并推送 / 提交、推送并创建 PR / 推送 / 拉取 / 查看 PR，推送默认分支前确认）、查看改动（工作区 diff，带行号）、更多（分支列表与切换、提交、推送、拉取、创建 PR）；状态由 `subscribeVcsStatus` 实时推送 |
| 文件 | 浏览对话工作目录（`projects.listEntries`），查看文件（`projects.readFile`，代码带行号、Markdown 渲染并可切到源码） |
| 终端 | 标题栏菜单列出这个对话已有的终端会话（`subscribeTerminalMetadata`）并可新开；终端页用 ArkWeb + xterm.js（打包在 rawfile，离线可用）渲染，`terminal.attach / write / resize / close`，带 Esc / Tab / Ctrl / 方向键 / ^C 快捷键条，断线后自动续接 |
| PR | 所有电脑上仓库的拉取请求（`pullRequests.list`），全部 / 待我审查 / 我创建的，打开 / 已合并 / 已关闭 / 全部，搜索；详情页显示状态、检查、审查结论、标签、描述（Markdown），可合并（压缩 / 合并提交 / 变基）、标记为可审查、关闭、重新打开、在浏览器打开 |
| 用量 | 与 iOS 相同的「费用 / Token / 限额」：限额按服务商账号显示每个窗口剩余百分比、进度刻度、重置时间（`server.getConfig` / `server.refreshProviders` 的 `usageLimits`）；费用和 Token 支持 24 小时 / 7 / 30 / 90 天，按天（24 小时按小时）的堆叠柱状图和服务商占比（`server.getUsageSummary`）；多台电脑可筛选 |
| 通知 | 需要你审批/回答、任务完成、任务失败时提醒（可分别关闭），点通知直接打开对应对话；正在看的对话不打扰。App 打开时由实时连接发本地通知；App 关闭后由电脑上的**推送小助手**（`tools/t3-push`）经华为 Push Kit 送达——T3 中继只发 APNs / FCM，所以不改服务端、由小助手代劳。设置 → 通知 → 推送小助手：扫码/粘贴绑定、发测试通知、解除绑定；绑定后后台的本地通知自动让位，避免重复 |
| 语音输入 | 与电脑版「设置 → 语音」一致，设置存在手机上：转写位置可选关闭、某台电脑的本机模型，或某台电脑上已保存密钥的云服务（OpenAI / xAI / OpenRouter，只列出有密钥的）；选本机模型时列出那台电脑上已下载的模型（点选即切换，`/api/voice/models/select`），「下载其他模型」按推荐和所选语言排序，下载前确认，进度实时显示，下好后自动用它；选 OpenRouter 时可选具体模型；另有语言（自动或模型支持的语言）、去掉语气词、过滤静音（仅本机）、整理文字（用电脑上的文本模型整理标点、列表和口误更正，只发文字不发录音）。录音格式与电脑版相同：4 字节小端长度 + 选项 JSON + Float32 PCM，发到 `/api/voice/transcribe` 或 `/api/voice/cloud/<服务>/transcribe` |
| 设置 | 电脑与连接状态（点开菜单重新连接 / 重新配对 / 移除，移除前确认）、T3 账号、运行中发送方式（引导 / 排队）、回车键（换行 / 发送）、语音输入、通知开关、握持手、触感反馈开关、外观（跟随系统 / 浅色 / 深色）、列表选项 |

### 鸿蒙特性

- **沉浸光感（默认开启，不可关）**：所有页面的标题栏都是 `HdsNavigation` / `HdsNavDestination` 的 HDS 标题栏（返回键和右上角按钮是系统的光感玻璃圆钮，
  `systemMaterialEffect` 同样走 `IMMERSIVE`），分段控件用系统 `TabSegmentButtonV2`；菜单（含长按菜单）、确认/输入对话框、底部面板、
  在 API 26 设备上使用系统沉浸材质（`uiMaterial.ImmersiveMaterial` + `systemMaterial`，`module.json5` 声明
  `ohos.arkui.UIMaterial.state`），低版本系统（如 API 24 模拟器）自动回退为磨砂玻璃 + 点光边缘。
  按官方约束，普通组件上的沉浸材质只在标题栏和底部页签栏里生效，所以悬浮的新建按钮不自己套材质，而是用单按钮的 `HdsTabs` 浮动栏来画。
  底部 `HdsTabs` 浮动页签栏使用 `systemMaterialEffect`（设备支持时为 `hdsMaterial.MaterialType.IMMERSIVE`），
  `lightColor` 随代理状态变化（等待你处理时琥珀色、运行中蓝色）；新建/发送按钮通过 `hdsEffect.pointLight` 作为点光源，
  待审批卡片边缘可被照亮。
- **智能识别左右手握持**：`motion.on('holdingHandChanged')`（API 20 握持感知），不支持时回退到
  `operatingHandChanged`（触控识别）；单屏时新建对话按钮随握持手移到拇指一侧（展开态固定在左侧列表栏右下角）。输入框的发送/停止按钮始终在右侧。
  设置里可改为固定左手/右手；模拟器没有握持传感器时可用"模拟左手/右手"验证布局。
  真机上握持传感器会在"双手/单手"之间频繁跳变，布局只跟随稳定 0.7 秒的单手握持，双手或放下时保持原位。
- **折叠屏**：以 HarmonyOS 中断点（600vp）切换单栏/双栏；`Navigation` 嵌套一个详情栈承载右栏，
  宽度跨过断点时把当前对话连同从它打开的文件 / Git / 终端 / PR 页面一起在两个栈之间搬移。
- **宽屏**：展开态/三折叠下所有页签都在左侧列表栏，右侧详情栏保持不动，切换对话、PR、用量、设置时布局不跳。
- **动效**（`common/Motion.ets`）：全 App 一套规则。会移动的用不回弹的弹簧曲线（`interpolatingSpring`），只出现/消失的淡入淡出；
  转场自带动画，无论状态是点击、电脑推送还是定时器改的都会播放。页签之间淡入并轻微上移，不再横滑经过中间的页签；
  发送 / 停止 / 补全在同一个位置缩放交替，录音时工具栏和录音条原地交接；新到的消息、审批和提问从下方升起
  （流式输出的回答本身在长，不再另加动画）；折叠项目、展开工作记录、切换语音转写位置等改变布局的操作，其余内容滑到新位置；
  分段切换和加载完成时，旧内容立即让位，新内容淡入，不会两份叠在一起。
  测试里输入的文字只用英文和数字：UiTest 遇到中文会改走剪贴板粘贴，而模拟器和电脑共用剪贴板，会覆盖电脑上复制的内容。
- 其它：Scan Kit 扫码配对、触感反馈（vibrator，可在设置里关闭）、深浅色资源自动切换、键盘 `RESIZE` 避让。

### T3 Connect 协议（与官方移动端一致）

1. Clerk 原生模式（`https://clerk.t3.codes`，`_is_native=1`，客户端令牌放在 `authorization` 头）：
   `sign_ins` → `prepare_first_factor`（email_code）→ `attempt_first_factor` → `sessions/:id/tokens/t3-relay`
2. 设备 DPoP 密钥：P-256（cryptoFramework），证明为 ES256 JWS（DER 签名转 r‖s），`jti`/`iat`/`htm`/`htu`，带令牌时加 `ath`
3. 中继：`POST /v1/client/dpop-token`（Clerk JWT + DPoP，`client_id=t3-mobile`）→ `GET /v1/environments` →
   `POST /v1/environments/:id/connect`（DPoP + `clientProofKeyThumbprint`）→ 隧道地址与一次性凭据
4. 电脑：`POST <隧道>/oauth/token`（凭据 + DPoP）→ DPoP 访问令牌；`403 connect_approval_pending` 时显示核对码并轮询
5. 之后每个 HTTP 请求都带 `Authorization: DPoP` 与新的证明；WebSocket 票据同理，升级请求把证明放在 `dpop` 查询参数里

调试包可用 `t3code://dev-connect?fapi=…&relay=…` 把 T3 Connect 指向 Mock（正式包忽略）。

## 目录

```
entry/src/main/ets/
  net/        Pairing（配对链接解析）、HttpClient、RpcSocket（Effect RPC over WebSocket）
  model/      Types（协议数据结构）、AppState（线程/项目仓库与分组）、ThreadDetail（事件归并与消息流分组）
  services/   Connection（鉴权、订阅、命令、通用 RPC）、Workspace（对话的 Git 状态与终端列表）、Notifier（本地通知）、
              UserSettings、GripService、LightEffects
  views/      HomeView、ThreadPage、FeedCards、Composer、NewTaskPage、PairPage、SettingsView、
              PullRequestsView / PullRequestPage、UsageView、GitPage / DiffPage、FilesPage、TerminalPage
  components/ 通用组件（状态点、项目徽标、T3 Code 标志、Markdown）、TitleBars（HDS 标题栏）、ActionMenu、Dialogs、
              RunSettings（模型 / 推理强度 / 速度 / 模式 / 权限面板）
  common/     Material（API 26 沉浸材质与回退）、Motion（曲线与转场）、Nav、Prefs、Format、Typography
entry/src/main/resources/rawfile/terminal/  终端页（xterm.js 5.5 与 fit 插件，MIT）
entry/src/main/resources/rawfile/lucide/   Lucide 0.564 图标表（与电脑版同版本，ISC），用来显示项目图标
tools/t3-push/   推送小助手（Node 22+，Windows / Linux / macOS），见 tools/t3-push/README.md
tools/mock-t3/   Mock T3 服务端（测试用）
  pages/Index 根页面：Navigation + HdsTabs 浮动页签
```

## 协议要点（与 T3 Code 0.1.10 nightly 对齐）

1. `POST /oauth/token`（form）：`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`，
   `subject_token=<配对码>`，`subject_token_type=urn:t3:params:oauth:token-type:environment-bootstrap` → Bearer token
2. `POST /api/auth/websocket-ticket/rpc` → 一次性 ticket
3. `GET /ws?wsTicket=…&orchestrationProtocol=2&clientSurface=mobile`
4. 帧：`{_tag:"Request",id,tag,payload,headers:[]}` → `Chunk` / `Exit`；每个 `Chunk` 都要回 `{_tag:"Ack",requestId}`
5. 用到的 RPC：`orchestration.subscribeShell`、`orchestration.subscribeThread`、`orchestration.dispatchCommand`
   （`message.dispatch`（`start_immediately` + `deliveryIntent` 或 `queue_after_active`）/ `runtime-request.respond` / `thread.stop|settle|unsettle|archive|pin|unpin|snooze|unsnooze|delete` / `thread.metadata.update` / `thread.model-selection.set|runtime-mode.set|interaction-mode.set`）、`orchestration.launchThread`、`server.getConfig`；
   iOS 对齐的部分：`subscribeVcsStatus`、`vcs.pull|listRefs|switchRef`、`git.runStackedAction`、`review.getDiffPreview`、
   `projects.listEntries|readFile`、`subscribeTerminalMetadata`、`terminal.attach|write|resize|close`、`server.getUsageSummary|refreshProviders`、
   `pullRequests.list|detail|runAction`
6. 线程首屏用 HTTP `GET /api/orchestration/threads/:id`（带 `x-t3-orchestration-protocol: 2`），之后由流事件增量更新

## 构建与运行

需要 DevEco Studio 26.0.0（含 API 26 SDK；默认路径 `~/.t3/tools/DevEcoStudio-26.0.0`，可用 `DEVECO_STUDIO_HOME` 覆盖）。

```powershell
pwsh ./scripts/build.ps1            # 生成 entry/build/default/outputs/default/entry-default-unsigned.hap
pwsh ./scripts/deploy.ps1 -Shot shot.jpeg   # 编译 + 安装到 hdc 设备 + 启动 + 截图
```

也可以直接用 DevEco Studio 打开本目录。模拟器访问宿主机用 `10.0.2.2`，例如：

```powershell
t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 1h --label "HarmonyOS"
# 在 App 里粘贴 http://10.0.2.2:3773/pair#token=<credential>，或：
hdc shell "aa start -a EntryAbility -b com.ewhen.t3code -U 't3code://pair?pairingUrl=<URL 编码后的配对链接>'"
```

真机：最省事的是 T3 Connect（App 首屏"使用 T3 账号登录"，任何网络都能连）；也可以在同一局域网（或 Tailscale）下扫码配对。

真机安装需要签名。包名是 `com.ewhen.t3code`（AGC 不允许包名含 “harmony”，旧包名 `com.ewhen.t3code.harmony` 无法开通推送）。
AGC 项目 T3CodePushProbe 里的 APP ID「T3 Code 鸿蒙版」已开通 Push Kit，调试 Profile「T3Code-debug-push」用小白调试助手的调试证书，
列入手机和模拟器，放在仓库外的 `~/.t3/signing/t3code/`；`deploy.ps1` 调用 `scripts/sign.ps1`，就地读取小白调试助手的私钥签名
（不往仓库里拷贝任何密钥）。新设备要先在 AGC「设备」里登记，再编辑 Profile 加上它并重新下载。
自己签名安装时，把 `AppScope/app.json5` 的包名和 `entry/src/main/module.json5` 的 `client_id` 换成你在 AGC 创建的应用：

```powershell
pwsh ./scripts/deploy.ps1 -Target <手机IP>:<端口>   # 真机：编译 + 签名 + 覆盖安装（保留数据）
pwsh ./scripts/deploy.ps1 -Target 127.0.0.1:5555        # 模拟器：直接装未签名包（推送需要签名包：scripts/sign.ps1 后 hdc install）
```

## 测试

```powershell
# 折叠屏模拟器可以不点工具栏，直接切换折叠状态：
hdc shell "hidumper -s DisplayManagerService -a -p"   # 折叠（单屏 1264×1848）
hdc shell "hidumper -s DisplayManagerService -a -y"   # 展开（双屏 2584×1828）
pwsh ./scripts/test-e2e.ps1          # 启动 Mock → 编译 App 与测试包 → 清空 App 数据 → 在模拟器/真机上运行
pwsh ./scripts/test-e2e.ps1 -NoBuild # 只重跑
node ./tools/mock-t3/smoke.mjs       # 单独校验 Mock 服务端协议
node ./tools/mock-t3/connect-smoke.mjs  # 用 Node 参考实现跑一遍 Mock 的 T3 Connect 全链路
```

- `tools/mock-t3/connect.mjs`：Mock 的 Clerk（`dev@t3.example` / 验证码 `424242`）、中继和电脑端批准流程；
  App 发出的每个 DPoP 证明都会被真实校验（ES256 签名、方法、URL、`ath`、密钥指纹、防重放）。
- `entry/src/ohosTest/ets/test/ConnectJourney.test.ets`：3 个 T3 Connect 旅程（登录 → 选电脑 → 等批准 → 连接；
  令牌过期后静默续期；退出账号回到首屏）。

- `tools/mock-t3/server.mjs --profile lab`（端口 3791）扮演第二台电脑「实验室服务器」，`test-e2e.ps1` 会同时启动两台。
- `tools/mock-t3/server.mjs`：零依赖的 Mock T3 服务端（同一套协议：token 交换、ticket、`/ws` Effect RPC、
  Chunk/Ack、shell/thread 流），内置运行中、待审批、待回答、失败、收件箱和 30 条历史线程，模拟流式输出、审批回执、
  新建任务、停止、归档、置顶和断线；`tools/mock-t3/workspace.mjs` 提供 Git 状态与操作、diff、分支、文件树、一个脚本化的 shell、
  用量与限额、PR 列表/详情/操作；`/__test/state` 让测试核对"服务端实际收到了什么"。不会触碰真实 T3 数据。
- `entry/src/ohosTest/ets/test/Logic.test.ets`：31 个逻辑单测（配对链接、Markdown、消息流分组、首页分组、多台电脑合并与筛选、格式化、DPoP 签名转换与核对码、Git 一键操作判定、diff 解析、用量剩余百分比、语音请求编码）。
- `entry/src/ohosTest/ets/test/UserJourney.test.ets`：25 个用户旅程（Hypium + UiTest，像用户一样点、滑、长按、输入）：
  首次启动引导 → 错误链接提示 → 扫码深链配对 → 搜索 → 项目筛选 → 看流式输出完成 → 发消息 → 批准命令 → 一键回答问题 → 多个问题逐页回答（多选、滑动翻页、单选自动翻页、最后提交）→
  停止长任务 → 新建对话（选项目 → 空白对话页选模型/权限 → 发出即成对话）→ 从系统文件选择器添加文件和图片并发送 → 左滑归档 → 长按菜单置顶 → 电脑断开后自动重连 → 发送键固定在右、新建按钮单屏跟随握持手 → 展开屏双栏 → 深浅色切换 → 添加第二台电脑后两台的线程出现在同一列表、按电脑筛选 → 语音输入（选电脑本机模型、切换和下载模型、选语言，录音转写插入输入框、取消不发送；再改用 OpenRouter 云端模型并整理文字）→ 消息只发到所属电脑、移除电脑。
- `entry/src/ohosTest/ets/test/WorkspaceJourney.test.ets`：9 个与 iOS 对齐功能的旅程：Git 菜单看分支并打开 diff → 一键提交、推送并创建 PR
  （填写提交说明，核对服务端收到的参数）→ Git 页切换分支 → 文件浏览与查看（含 Markdown 预览/源码切换）→ 终端开 shell、
  快捷键发送、运行项目脚本 → PR 页签筛选、详情、压缩合并 → 用量页签的限额、费用图表和时间范围 → 长按菜单稍后提醒 / 取消、重命名、删除（核对服务端收到的命令）。
- 共 68 个用例，在折叠屏模拟器的折叠态（单栏）和展开态（双栏）上运行。展开态下模拟器的键盘窗口会按竖屏尺寸报告
  （覆盖整屏，UiTest 因此看不到 App 控件），`typeInto` 遇到时会先收起键盘再按坐标输入。
- 失败时测试会把截图存到应用沙箱 `files/fail-*.png`（设备路径 `/data/app/el2/100/base/com.ewhen.t3code/files/`）。

## 交互与视觉细节

- 设计取向：参照官方移动端（iPhone / Android 版）的信息结构与 zinc 灰阶配色，同时遵循鸿蒙设计规范——
  sm/md 断点、16vp 页边距、系统字号层级（标题 24 / 正文 16·14 / 辅助 12）、≥ 40vp 触控热区、折痕避让。
  界面以中性灰为主，颜色只用于状态（琥珀＝审批、靛蓝＝待回答、蓝＝运行中、红＝失败），卡片用细边框而非色块。
- 首页：下拉刷新、首屏骨架屏、行按压态、左滑完成/归档、右滑置顶、长按菜单、标题栏项目筛选菜单（带"项目：xxx"可一键清除的标签）、
  分组标题带细线、运行中线程实时计时、"5 分钟前 / 昨天"式相对时间。
- 线程页：标题下一行显示项目 · 模型与状态，阅读宽度上限 680vp；打开即标记已读、离开底部时出现"回到最新"、断线时顶部提示条、
  隐藏"准备工作区"等例行噪音；停止键只在输入框里（拇指一侧），等你审批/回答时给出明确提示。
- 新建对话：照电脑版，先选项目，再在对话页本身的空白状态里输入，第一条消息发出即成为对话。
- 对话页标题用小号（16vp 标题 + 12vp 位置/模型），给内容留出空间。
- 列表与电脑侧边栏一致地隐藏子代理、侧聊（`lineage.sideChat`），以及从另一台已连接电脑委派过来且父对话仍在的线程（`delegatedFrom`，它们归在父对话下）。
- 配对：扫码、系统安全粘贴控件（无需剪贴板权限）、手动输入、`t3code://pair` 深链自动配对。

## 尚未完成 / 下一步

- 推送目前以 Push Kit「测试消息」发送（每日条数有上限，锁屏归在“更多通知”）；要正常横幅提醒需在 AGC 申请“工作事项提醒”自分类权益后 `t3-push setup … --production`。实况窗（Live View Kit）尚未接入。
- T3 Connect 目前只支持邮箱验证码登录（不支持 GitHub/Google 等第三方登录和两步验证账号）。
- 同一台电脑记住多条路线（局域网 / Tailscale / T3 Connect）并自动选择可达的那条（目前同一台电脑只保留最近一次的连接方式）。
- 服务卡片（运行中 / 待处理数量）。
- 语音输入目前是录完再转写；电脑版的边说边出字（`/ws/voice` 流式）和自定义词典尚未接入。
- 与 iOS 仍有差距的细节：PR 的文件 diff、评论与审查提交、时间线；终端字号设置；
  用量页的会话明细和重置额度兑换；文件里的全文搜索；已归档对话列表。
- access token、Clerk 客户端令牌和 DPoP 私钥目前存在应用沙箱的 preferences 中，后续改用 HUKS / Asset Store Kit。
- 线程历史只加载服务端返回的首个窗口（长线程更早的消息需要分页接口）。

## 许可

[MIT](LICENSE)。内置的第三方资源保留各自的许可：xterm.js（MIT，`entry/src/main/resources/rawfile/terminal/LICENSE-xterm.txt`）、
Lucide 图标（ISC，`entry/src/main/resources/rawfile/lucide/LICENSE-lucide.txt`）。
