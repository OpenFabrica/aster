# 工具箱与插件

## 业务背景

Aster 提供类似 uTools 的「常用工具」：一个入口搜索工具，或直接粘贴内容让 Aster 推荐能处理它的工具。
用户可以把自己写的插件放进插件目录，或登记一个开发目录，Aster 负责发现、授权、运行和展示。

v1 范围：

- 入口 A：Open Quickly 新增「工具」页（`⇧⌘O` 后 `⌘U`）。
- 入口 B：独立的工具面板（全局快捷键呼出，默认不占用；也可从「窗口」菜单与命令面板打开）。
- 三种运行方式：原生内置工具（Swift）、脚本工具（任意可执行程序）、网页工具（WKWebView 沙箱）。
- 权限声明 + 安装确认 + 文件摘要校验；设置页「工具」分类管理插件。
- 工具 Pane：工具可开成工作区分屏。v1 **不持久化**工具 Pane（见「工具 Pane」）。

不在 v1：终端/文件右键「用工具处理」、系统服务菜单、`aster tool` CLI、复制后推荐、Inspector 固定、
读取最后一条命令输出、`.asterplugin` 打包、插件 backend 进程、MCP 暴露、插件索引。

## 模块与归属

| 层 | 位置 | 职责 |
| --- | --- | --- |
| 领域规则 | `Sources/AsterCore/Tools/` | 清单模型与校验、权限、信任状态、文件摘要、匹配排序、脚本协议、桥接协议校验、内置转换纯函数、状态文件模型。不依赖 AppKit。 |
| 运行时 | `Sources/Aster/Tools/` | `ToolCenter`（协调者）、插件扫描与安装、脚本运行、原生工具视图、工具会话视图、安装确认。 |
| 网页运行时 | `Sources/Aster/Tools/Web/` | `WebToolViewController`、`aster-plugin://` scheme handler、桥接、`Resources/tool-runtime/aster-bridge.js`。 |
| 入口 | `Sources/Aster/Tools/Launcher/`、Open Quickly、`AppModel+Tools.swift` | 工具面板、全局快捷键、Open Quickly「工具」页、工具 Pane、命令面板与菜单入口。 |
| 设置 | `SettingsToolsBridge.swift`、`Resources/settings-ui/tools.js` | 设置页「工具」分类。 |
| 内置网页工具 | `Resources/tools-builtin/<id>/` | JWT、正则、Diff、颜色、密码生成，按普通插件格式编写。 |

应用层只通过 `Sources/Aster/Tools/ToolContracts.swift` 里的类型交互：入口与设置页不直接读插件目录、
不直接创建 WebView 或进程。

## 插件包与清单 v1

一个插件 = 一个目录 + 根目录下的 `aster-plugin.json`（UTF-8，≤ 64 KiB）。

```json
{
  "schemaVersion": 1,
  "id": "com.example.jwt",
  "name": "JWT 解析",
  "version": "1.2.0",
  "description": "解析 JWT 的 header 与 payload",
  "author": "Example",
  "homepage": "https://example.com",
  "icon": "icon.svg",
  "ui": { "main": "index.html", "height": 420 },
  "permissions": ["clipboard.write", "terminal.insert", "exec"],
  "network": [],
  "features": [
    {
      "code": "decode",
      "title": "解析 JWT",
      "subtitle": "header / payload / 过期时间",
      "keywords": ["jwt", "token"],
      "match": [{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]*$", "maxLength": 8192 }],
      "action": { "type": "ui" }
    },
    {
      "code": "now",
      "title": "当前时间戳",
      "keywords": ["now"],
      "action": { "type": "script", "command": ["bin/now.sh"], "output": "text" }
    }
  ]
}
```

校验规则（`ToolManifest.decode(_:source:)`，任何一条不满足都整份拒绝，错误指出字段，例如
`features[0].match[0].maxLength`）。长度没写「字节」的都按字符算；必填文本全是空白也算空；「控制字符」
包括 U+2028/U+2029 与双向控制符：

- 未知字段一律拒绝（每一层都是）。`schemaVersion` 必须是 1。
- `id`：`^[a-z0-9]+(\.[a-z0-9][a-z0-9-]*)+$`，≤ 128 字节；`aster.` 前缀保留给内置插件。
- `name` 1–64 字符；`version` 匹配 `^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$`，≤ 32；`description` ≤ 512；
  `author` ≤ 128；`homepage` 必须是 `https://` URL，≤ 512。文本字段不得含控制字符。
- 路径字段（`icon`、`ui.main`、`feature.icon`、相对的 `command[0]`）：相对路径、不以 `/` 开头、不含 `..`
  段、不含控制字符，≤ 256；`ui.main` 以 `.html` 结尾；图标扩展名限 `svg`/`png`/`jpg`/`jpeg`/`pdf`。
- `ui.height` 120–800，缺省 480。
- `permissions` 不重复；`network` 仅在声明 `network` 权限时必填且非空，≤ 16 项，每项是主机名或 `*.主机名`
  （小写，不含协议、端口、路径）。没声明 `network` 权限时 `network` 必须缺省或为空。
- `features` 1–32 项，`code` 匹配 `^[a-z0-9][a-z0-9_-]{0,31}$` 且不重复；`title` 1–64；`subtitle` ≤ 128。
- `keywords` ≤ 8 项，每项 1–32 字符；`match` ≤ 8 条；每个功能至少有一个关键词或一条 match 规则。
- match 规则：
  - `regex`：`pattern` ≤ 512 且能编译（NSRegularExpression 语法），**能匹配空串的正则拒绝**；
    `minLength` ≥ 1，`maxLength` ≤ 1,048,576，缺省 10,000。
  - `text`：任意文本；可选 `exclude`（同 regex 约束，但允许匹配空串）、`minLength`、`maxLength`（缺省同样是 10,000）。
  - `files`：`fileType` 为 `file`/`directory`（缺省都可）；`extensions`（小写、无点、≤ 16 项）与 `pattern`
    最多二选一，都只看文件名；每个文件都要满足；`minCount` ≥ 1，`maxCount` ≤ 100。
  - 可空正则用一组探针文本检测零长度匹配（能抓到 `a*`、`\b`、`(?=.)`）；只在特定内容前才产生空匹配的写法
    （如 `(?=foo)`）不会被拒，它们不会命中任意输入，影响不大。
  - 每条规则可带 `label`（≤ 64），在启动器的「识别到」行显示。
- `action`：
  - `{"type":"ui"}`：清单必须有 `ui`。
  - `{"type":"script","command":[…],"output":"text|list|none|terminal","stdin":"text|json","timeout":秒}`：
    `command` 1–32 项、每项 ≤ 4096 字节且不含控制字符；清单必须声明 `exec` 权限；`timeout` 1–60，
    缺省 10（`list` 缺省 3）。
  - `{"type":"builtin","handler":"…"}`：只允许内置来源（`source == .builtin`）。

## 权限与信任

| 权限 | 能做什么 | 风险 |
| --- | --- | --- |
| （隐式）storage / secureStorage | 本插件私有数据，各 ≤ 5 MiB；secureStorage 加密落盘 | — |
| `clipboard.write` | 写剪贴板 | 低 |
| `terminal.insert` | 把文字预填到来源 Pane，不回车 | 低 |
| `notify` | 系统通知 | 低 |
| `clipboard.read` | 读剪贴板 | 中 |
| `terminal.read` | 读来源 Pane 的选区 | 中 |
| `files.read` | 读用户选中或作为输入传入的文件 | 中 |
| `network` | 经原生代发访问 `network` 列出的域名 | 中 |
| `exec` | 运行插件自带程序 / 脚本 | 高 |

信任状态（`ToolPluginTrust.status`）：

- 内置来源：启用即 `ready`，不需要确认。
- 没声明任何权限的插件：启用即 `ready`（页面只能在沙箱里自娱自乐）。
- 用户来源 / 开发来源：没有授权记录 → `needsApproval(.firstRun)`；声明的权限或域名多于已授权 →
  `needsApproval(.permissionsAdded / .networkDomainsAdded)`；用户来源的文件摘要与授权时不同 →
  `needsApproval(.filesChanged)`（开发来源不比对摘要，方便热重载）；用户停用 → `disabled`。
- 运行需要确认的插件时先弹安装确认；用户拒绝则不运行。授权只记在 `tools-state.json`，
  **不写入 `settings.json`**，导入设置不会带来插件授权。
- 确认框（`ToolInstallSheet`）：有可见窗口挂成 sheet，否则单独弹面板；「允许」在弹出 0.6 s 后才可点，防止连按回车
  误授权。用户同意后再核对一次：清单与摘要必须仍是用户看到的那份，才写入授权；同一插件同时多次请求只弹一个确认框。
  工具会话里的授权提示要点「允许并运行…」才弹确认框。
- 运行用户插件前在后台重算一次摘要（`prepareToRun`）：目录监听只看一层，原地改写的文件靠这一步拦住。
- 安装：先复制到 `Plugins/.install-<uuid>`，复制后的摘要必须等于确认时的摘要，再用 `renamex_np(RENAME_EXCL)`
  原子改名；`start()` 清掉中途留下的临时目录。卸载：先关闭该插件的会话，再删 WebKit 存储、`PluginData/<id>/` 与加密存储密钥；
  用户插件目录移到废纸篓，开发插件只取消登记，不动用户的源码目录。

文件摘要（`ToolPluginDigest.compute`）：按相对路径（UTF-8 字节序）排序遍历插件目录所有普通文件（跳过 `.DS_Store`
与管道等特殊文件），用 `O_NOFOLLOW` 流式读取，对「相对路径 + 0x00 + 长度 + 0x00 + 内容」做 SHA-256。符号链接、
读不了的子目录、超过 2,000 个文件或 50 MiB 直接报错，不静默跳过。用户来源算不出摘要时也要求重新确认。

状态文件解码是容错的：坏字段用默认值，坏记录逐条丢弃，不认识的权限丢掉；`lastUsed` 固定写 Unix 秒；只切过启用
开关、没确认过的记录仍算首次运行（`ToolPluginState.hasApproval`）。

## 匹配与排序

- 关键词搜索（`ToolMatcher.search`）：对标题、关键词、插件名做大小写、变音与全半角无关的模糊子序列匹配；中文
  同时比对拼音全拼与首字母（`CFStringTransform` 汉字转拉丁）。档位：标题完全命中 > 标题前缀 > 关键词完全命中
  > 其余；同档按最优子序列打分，再加 frecency（最多 40 分）；同分保持目录顺序（所以目录顺序要稳定）。空查询
  按 frecency 返回最近常用。归一化结果缓存在有锁的全局表里；`ToolCenter` 每次重建目录后在后台先搜一次预热，
  避免第一次打字时在主线程做拼音转换。300 个条目预热后单次中位约 3 ms（调试构建）。
- 内容匹配（`ToolMatcher.contentMatches`）：把输入当成待处理内容，逐条执行 match 规则；文本超过规则
  `maxLength`（或全局 1 MiB）直接跳过，不跑正则。每个功能取等级最高的规则：regex > files > text。每次正则
  匹配限 50 ms（`.reportProgress` 中止灾难性回溯），超时按没命中算。内置工具在正则命中后还要过
  `BuiltinTextTools.acceptsContent` 二次确认（例如 `password` 不算 Base64，`2023-02-29` 不算日期）。
- 使用记录按功能 id（`<pluginID>/<code>`）记次数与最近时间，存在 `tools-state.json`。

## 内置工具

内置原生工具由 `BuiltinToolCatalog.manifest`（id `aster.builtin`）声明，`action` 都是 `builtin`：

| handler | 功能 | 内容匹配 |
| --- | --- | --- |
| `timestamp` | 秒 / 毫秒时间戳 ↔ 日期 | `^\d{10}(\d{3})?$`、常见日期格式 |
| `base64` | 编码 / 解码 | 看起来像 Base64 的文本 |
| `url` | 编码 / 解码 / 拆参数 | 含 `%XX` 或 `http(s)://` |
| `hash` | MD5 / SHA-1 / SHA-256 / SHA-512 | 任意文本（排序靠后） |
| `uuid` | UUID v4 / v7、随机串 | — |
| `ports` | 本机监听端口、结束进程（先确认） | `^:?\d{2,5}$` |
| `json` | 格式化 / 压缩 / 树视图 | `^\s*[\[{]` |
| `stickies` | 便笺列表：新建、全部显示 / 收起、删除；便笺本身是桌面窗口（见「便笺」） | — |

`BuiltinTextTools.inlineResult` 给出可立即计算的结果（启动器行内显示，`↩` 复制）。内置网页工具
（JWT、正则、Diff、颜色）放在 `Resources/tools-builtin/<id>/`，id 以 `aster.` 开头，来源为内置：

| id | 功能 | 内容匹配 | 权限 |
| --- | --- | --- | --- |
| `aster.jwt` | 解码 header / payload、`exp`/`iat`/`nbf` 本地时间与状态；不验证签名；5 段按 JWE 只解 header | 纯 token、带 `Authorization`/`Bearer` 前缀 | `clipboard.write`、`terminal.insert` |
| `aster.regex` | 六个标志、高亮、编号与命名分组；匹配在 Web Worker 里跑，1 s 超时 terminate | —（只靠关键词） | `clipboard.write` |
| `aster.diff` | Myers 行级 diff（线性空间）、折叠相同行、行内高亮、忽略空白/大小写、复制 unified diff；> 5000 行截断 | — | `clipboard.write` |
| `aster.color` | HEX 3/4/6/8、rgb(a)/hsl(a)（含 CSS4 空格写法）、裸 `r, g, b`、颜色名；WCAG 对比度 | `#` + 3/4/6/8 位、不带 `#` 且含字母的 6 位、`rgb(`/`hsl(` 开头 | `clipboard.write` |
| `aster.password` | 随机密码：`crypto.getRandomValues` 拒绝采样；默认规则 + 自定义规则；用途属性（默认几项 + 自定义，全部选填）；复制即记历史 | —（只靠关键词） | `clipboard.write` |

- 输入分配：JWT 与颜色的 `enter`/`query` 都填输入框；正则的 `enter` 填测试文本（单行 `/…/flags` 填进正则），
  `query` 填正则；Diff 的 `enter` 填左栏、`query` 填右栏。
- 每个工具自带六种语言字典，按 `context.locale` 选择；`getInput()` 先取语言，最多等 400 ms 再显示，避免先闪英文。
- 每个内置网页工具目录各放一份相同的 `kit.js` 与 `base.css`（插件只能读自己目录里的文件），改动时所有副本一起改。
- 密码生成（`aster.password`）：规则与属性定义是普通数据，存 `storage`（`rules`、`attributes` 等）；历史存
  `secureStorage` 的 `history`（新的在前，上限 500 条，同一密码重复复制只更新该条）。复制一律带 `concealed`。
  生成页记住本次打开后最近一次复制写入的条目 id；再次复制时，若该条仍在且用途属性（整理后的非空值）
  与这次完全相同，就把它换成新密码并移到最前，不新增条目（`PasswordCore.recordCopy` 的 `replaceId`）。
  空用途同样适用，但只在同一次打开内，重新打开工具后第一次复制总是新增。历史页可修改条目的密码与属性
  （`PasswordCore.editEntry`）：属性整份替换、清空即删除，时间、规则与位置不变，密码不能为空。
  历史条目保存属性名快照，属性定义删掉后旧条目照样能显示。
- 清单里的 `name`、`description`、`title`、`subtitle`、match `label` 只写简体中文原文。运行时只对内置来源用
  `L(String.LocalizationValue(原文))` 查 `Localizable.strings`（与原生内置工具同一张表），译文由
  `l10n-work` 合并进各语言表，并有测试检查每条都有译文；用户插件原样显示。

## 脚本工具协议

- 执行：`posix_spawn`，独立进程组，不经过 shell；`command[0]` 为相对路径时相对插件目录解析，
  解析后（含符号链接）必须仍在插件目录内；绝对路径原样使用。必须可执行。
- 工作目录：来源 Pane 的本地 cwd，否则用户主目录。
- 环境：`PATH`（`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`）、`HOME`、`USER`、`LOGNAME`、
  `LANG`、`TMPDIR`、`SHELL`，加上 `ASTER_FEATURE`、`ASTER_QUERY`、`ASTER_CWD`、`ASTER_PLUGIN_ID`、
  `ASTER_PLUGIN_DIR`、`ASTER_PLUGIN_DATA`、`ASTER_LOCALE`。不继承 Aster 进程的其它环境变量。
- stdin：`text` 模式写入输入文本原文（无输入写空）；`json` 模式写入
  `{"code":…, "query":…, "input":{"text":…, "files":[…], "source":…}, "context":{…}}`（缺的值写 `null`）。
  写完关闭 stdin。`ASTER_*` 的值去掉 NUL 并截到 64 KiB，避免 `posix_spawn` 报 `E2BIG`。`command[0]` 用 realpath
  解析（URL 的解析会去掉 `/private` 前缀），目录不算可执行。
- 输出：
  - `text`：stdout 按 UTF-8 解码（非法字节替换），去掉末尾一个换行，作为结果文本。
  - `list`：stdout 必须是 `{"items":[{"title":…, "subtitle":…, "value":…}]}`；`title` 必填 ≤ 256，
    `subtitle` ≤ 512（超长截断加 `…`），`value` ≤ 64 KiB（缺省等于 title）；超过 200 项只取前 200；
    `value` 超限或 `title` 为空则整份作废。输入变化时 300 ms 去抖重跑，旧进程直接取消。
  - `none`：只看退出码，成功提示「已完成」，失败显示 stderr。
  - `terminal`：不由运行器执行，而是在新终端标签里运行（命令按 POSIX 单引号转义）。
- 上限：超时（缺省 10 s，list 3 s，最大 60 s）先 `SIGTERM` 进程组，1 s 后 `SIGKILL`；stdout 1 MiB、
  stderr 64 KiB 超出即终止并报错；退出码非 0 时显示 stderr 前 4 KiB。
- 实现（`ScriptToolRunner`）：`posix_spawn` 带 `SETPGROUP`、`CLOEXEC_DEFAULT`（子进程不继承 Aster 的 PTY 与 socket）、
  `SETSIGDEF`/`SETSIGMASK`；只给父进程一端设非阻塞，stdin 写端设 `NOSIGPIPE`。poll 循环放在 GCD 线程，不占协作线程池。
  超时、取消、输出超限走同一流程。用 `waitid(WNOWAIT)` 先看不收：主进程退出 200 ms 后，仍握着输出管道的后代进程
  一起结束，避免后台子进程让工具一直「运行中」。

## 网页工具

- 加载：`WKURLSchemeHandler` 处理 `aster-plugin://<pluginID>/<path>`，只返回插件目录内的普通文件
  （拒绝 `..`、符号链接越界、目录、隐藏文件），按扩展名给 MIME。每个响应带 CSP：
  `default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:;
  font-src 'self' data:; media-src 'self' data: blob:; connect-src 'none'; object-src 'none';
  frame-src 'none'; base-uri 'none'; form-action 'none'`。内联脚本不执行，插件必须用独立 JS 文件。
  路径先按 `/` 切段再逐段解码，拒绝 `..`、`%2e%2e`、`%2F`、隐藏段、空段与控制字符；host 必须逐字等于插件 id
  （不带端口与用户信息）；解析符号链接后仍须在插件目录内。禁止访问回 403、找不到回 404、读失败回 500。
  每个响应另带 `X-Content-Type-Options: nosniff`、`Cache-Control: no-store`、`X-DNS-Prefetch-Control: off`。
  文件在后台读取，被 `webView(_:stop:)` 停止的任务不再回调（`PluginResourceResolver` 是可单测的纯函数）。
- 隔离：每个插件一个 `WKWebsiteDataStore(forIdentifier:)`，标识由 `ToolPluginIdentity.dataStoreIdentifier`
  从插件 id 推导；卸载时先关闭该插件的所有会话，再 `WKWebsiteDataStore.remove(forIdentifier:)` 并删除
  `PluginData/<id>/`。禁止 JS 自动开新窗口；关闭链接预览；拒绝摄像头与麦克风；取消下载；只有开发来源
  `isInspectable`。不提供 `alert`/`confirm`/`prompt` 与 `<input type=file>`（选文件用 `files.pick`）。
- WebRTC：STUN/TURN 连接不受 CSP `connect-src` 约束，脚本创建的 `about:blank` iframe 也绕得过 `frame-src`，
  所以分两层关闭（`WebToolSandbox`）：私有偏好 `_setPeerConnectionEnabled:`（先 `responds(to:)` 判断，与设置页给
  WKWebView 设 `drawsBackground` 同类做法），加上注入所有 frame 的文档开始脚本把 `RTCPeerConnection` 置为只读的
  `undefined`。
- 导航（`WebToolNavigationPolicy`）：只允许本插件 `aster-plugin://<id>/` 下的地址。`http(s)` 链接要同时满足
  导航类型为 `.linkActivated` **且** 1 秒内有真实的鼠标或按键输入（`ToolWebView` 记录），才交给默认浏览器——
  脚本里的 `a.click()` 也会报告成 `.linkActivated`，单看导航类型挡不住静默外发。其它外部跳转一律拦截。
  `createWebViewWith` 返回 nil；指向本插件的 `target=_blank` 就地打开。
- 桥接：`window.webkit.messageHandlers.aster`（`WKScriptMessageHandlerWithReply`，`.page` 内容世界），只收
  主 frame 且地址属于本插件的消息，经弱引用代理接入。`Resources/tool-runtime/aster-bridge.js` 在文档开始时
  只注入主 frame，暴露 `window.aster`；读不到这个文件时显示错误、不创建 WebView。
- 处理顺序：限流 → 解析 → 授权 → 分派。格式不对的消息也计入限流。可用权限取「已授予 ∩ 清单声明」，网络域名同样
  取交集。桥接失效（`teardown()`）后迟到的结果直接丢弃；`ui.close` 先回复再请求关闭。
- 请求格式：`{ v: 1, method: "storage.get", params: { … } }`。成功时 Promise 解析为结果；失败时拒绝，
  错误字符串格式 `"<code>: <message>"`，JS 侧转成 `AsterError { code, message }`。
- 事件（Swift → JS）：`callAsyncJavaScript("window.__asterReceive(event)", arguments: ["event": …])`，
  `event.type` 为 `enter`（`{code, input, context, theme}`）、`query`（`{text}`，工具面板搜索框在工具打开后
  继续输入）或 `theme`（`{theme}`）。`theme` 为 `{appearance: "light"|"dark"}`。shim 收到后同步设置
  `document.documentElement.dataset.asterAppearance` 与 `style.colorScheme`；WKWebView 的外观也跟随 App，
  所以插件既可以用 `prefers-color-scheme`，也可以用 `[data-aster-appearance]`。

`window.aster`（由 `aster-bridge.js` 提供，网页工具只用这些名字）：

```js
aster.version                       // 1
aster.onEnter(cb)                   // cb({code, input, context, theme})；已进入过则立即用最近一次调用
aster.onQuery(cb)                   // cb(text)
aster.onThemeChange(cb)             // cb(theme)
aster.getInput()                    // → Promise<{code, input, context}>（tool.input）
aster.setHeight(px)                 // ui.setHeight
aster.close()                       // ui.close
aster.storage.get(key) / set(key, value) / remove(key) / keys()
aster.secureStorage.get(key) / set(key, value) / remove(key) / keys()   // 加密落盘
aster.clipboard.readText() / writeText(text, {concealed})
aster.terminal.insert(text) / selection()
aster.files.pick({extensions, multiple}) / read(path, encoding)
aster.net.fetch(url, {method, headers, body})
aster.notify(title, body)
aster.openURL(url)
aster.AsterError                    // 错误类型，便于 instanceof 判断
// 失败时 Promise 拒绝为 AsterError（继承 Error，带 code 字段）
// onEnter / onQuery / onThemeChange 返回取消注册的函数
```

`input` 结构与 Swift 的 `ToolInput` 编码一致：`{text, files, source, context}`；`context` 为
`{workingDirectory, isRemote, locale, appearance}`。

桥接方法 v1：

| 方法 | 参数 | 结果 | 权限 |
| --- | --- | --- | --- |
| `tool.input` | — | `{code, input, context}` | — |
| `ui.setHeight` | `{height}` 120–800 | `null` | — |
| `ui.close` | — | `null` | — |
| `storage.get` | `{key}` | 值或 `null` | — |
| `storage.set` | `{key, value}` | `null` | — |
| `storage.remove` | `{key}` | `null` | — |
| `storage.keys` | — | `[key]` | — |
| `secureStorage.get` / `set` / `remove` / `keys` | 同 `storage.*` | 同 `storage.*` | — |
| `clipboard.readText` | — | 文本 | `clipboard.read` |
| `clipboard.writeText` | `{text, concealed?}` | `null` | `clipboard.write` |
| `terminal.insert` | `{text}` | `null` | `terminal.insert` |
| `terminal.selection` | — | 文本或 `null` | `terminal.read` |
| `files.pick` | `{extensions?, multiple?}` | `[path]` | `files.read` |
| `files.read` | `{path, encoding: "utf8"\|"base64"}` | 文本 | `files.read` |
| `net.fetch` | `{url, method?, headers?, body?}` | `{status, headers, body}` | `network` |
| `notify` | `{title, body?}` | `null` | `notify` |
| `shell.openURL` | `{url}` | `Bool`（用户是否同意） | — |

参数上限：单条消息 ≤ 2 MiB；`key` ≤ 128 字节，存储总量 ≤ 5 MiB（JSON 值）；`text` ≤ 1 MiB；
`files.read` 只认本次会话里经 `files.pick` 选中或作为输入传入的路径，单文件 ≤ 10 MiB；`net.fetch` 只允许
`https`，主机必须匹配已授权域名，响应 ≤ 5 MiB，超时 15 s，结果 `body` 为文本（UTF-8）；`shell.openURL`
只允许 `http(s)`，先弹确认。每个页面每秒最多 50 次调用，超出返回 `rate_limited`。

实现细节：

- `storage`：同一数据目录在进程内共用一个 actor，原子写入；缓存比对文件大小与修改时间（脚本工具也可能写同一个
  `storage.json`）。写入后超过 5 MiB 即拒绝，原内容不变。
- `secureStorage`：`PluginData/<id>/secure-storage.bin`，整份 JSON 用 AES-GCM（CryptoKit）加密，文件是 4 字节魔数
  `AST1` + 合并密文（nonce + 密文 + tag），附加数据是插件 id。密钥是每个插件一把 256 位对称密钥，存钥匙串
  generic password（service `io.aster.tool-secure-storage` + 身份后缀，account 是插件 id），第一次写入时创建，
  只读不建。读条目前先按引用核对 ACL（与 Agent 主机「一直允许」授权同一套 `AgentHostKeychainAccessCheck`）：
  「任何 App 都能解密」的预埋条目不用，删掉重建。解不开（密钥丢失、条目不可信、文件损坏或被换）时把文件改名为
  `secure-storage.bin.bad` 留底并记诊断，按空存储继续；钥匙串本身访问失败（被拒、未解锁）直接报错、不动文件。
  只有 Aster 写这个文件，读一次后用内存缓存；上限与 `storage` 相同（明文 JSON ≤ 5 MiB，key ≤ 128 字节）。
  脚本工具拿不到密钥，不能读写加密存储。卸载插件时随 `PluginData/<id>/` 一起删除密钥，删不掉只记诊断。
- `clipboard.writeText` 的 `concealed`：只认布尔值；为真时同时写入 `org.nspasteboard.ConcealedType`，
  遵守 nspasteboard.org 约定的剪贴板管理器不会记录这条内容。
- `files.read`：允许列表与当前 `input.files` 按规范化路径比对，只读普通文件；经句柄多读 1 字节判断是否超限。
- `net.fetch`：方法限 GET/POST/PUT/PATCH/DELETE/HEAD，GET 与 HEAD 不能带 body；请求头 ≤ 32 个、值不能含 CR/LF，
  禁止 `Host`、`Cookie`、分帧与连接类头及 `proxy-*`。ephemeral `URLSession`（无 cookie、缓存与凭据存储），
  流式读取超过 5 MiB 即中止。重定向只跟到已授权的 https 主机，否则原样返回 3xx；HTTP 认证与客户端证书质询一律拒绝。
- 错误码：读未选中的文件 → `invalid_params`；访问未授权主机 → `permission_denied`；`key` 超过 128 字节 →
  `payload_too_large`。
- 协议细则（`ToolBridgeValidator`）：`v` 必须恰好是数字 1；`ui.setHeight` 四舍五入并收进 120–800，不报错；
  `net.fetch` 的主机里不能有 `%` 编码；域名匹配忽略主机末尾的一个点。限流器是 AsterCore 的 `ToolBridgeRateLimiter`。
- `notify`：直接用 `UNUserNotificationCenter`（授权方式与终端通知相同，副标题为插件名，清理控制字符）。App 没有
  通知代理，Aster 在前台时系统不弹横幅，通知只进通知中心——与终端通知一致。

已知缺口（v1 接受）：

- `<link rel=preconnect>` 可借主机名把少量数据带出（CSP 管不到，WebKit 无公开开关）。
- 用户手势下的原生复制（`⌘C`、`execCommand('copy')`）不受 `clipboard.write` 约束。
- 拖到网页工具区域的文件由 WebKit 交给页面（File API），不经过 `files.read`：视为用户主动给出文件，与浏览器一致；
  工具面板只在搜索框与结果区接收「拖文件作为输入」。

## 启动器

**A · Open Quickly「工具」页**：新增 `OpenQuicklyKind.tool` 与 `OpenQuicklyFilter.tool`（chip「工具」，`⌘U`）。

- 静态行：每个可用功能一行（标题、插件名 · 副标题、来源徽章）。随 App 发布的工具副标题不写插件名（原生工具的插件名都是
  「Aster 内置工具」，内置网页工具的插件名就是标题）。内置原生工具按处理器各用一个符号（`ToolEntryPresentation.symbol`）。
- 「识别到」行：查询文本命中 match 规则时显示（`ToolCenter.contentMatches`）；内置转换在行内直接显示结果。
  regex / files 规则命中置顶；text 规则接受任意文字（如「计算 Hash」），命中排在关键词搜索结果后面，
  否则输入工具名「json」时默认选中的是 Hash。同一功能既被 text 规则命中、又被关键词搜到时只留搜索行
  （`ToolMatch.isTextRuleMatch`、`ToolLauncherResults.rows`，两个启动器共用）。
- 主动作 `↩`：有行内结果 → 复制结果；否则在工具面板里打开该工具（命中内容时把查询文本当输入）。
- 右键 / 操作菜单：复制结果、预填到终端、在工具面板打开、在新窗口打开、开成 Pane。

**B · 工具面板**（`ToolLauncherController`）：

- 非激活浮动面板（参照 Quick Terminal 的 `NSPanel` 配置），宽 720，顶边在鼠标所在屏幕上方 1/6 处，向下展开。
  失去 key 自动隐藏，但挂着 sheet 或模态框时例外（网页工具的选文件、打开链接确认与权限确认都是 sheet）。
- 钉住（搜索行右侧图钉，`ToolLauncherController.isPinned`）：失去 key 不收起；`collectionBehavior` 从
  `.moveToActiveSpace` 换成 `.canJoinAllSpaces`；预填、开成 Pane、在终端运行时不收起面板（开成 Pane 时退出面板里的
  工具，避免同一工具开两份）。钉住的面板在背后时，全局快捷键与「窗口 → 工具面板」先把它设为 key，拿着键盘时快捷键才收起。
  用户点回钉住的面板（`windowDidBecomeKey`）时重新记下前台应用，没开工具时来源换成当前活动 Pane；控制器自己设 key
  （呼出、请求、sheet 结束）时不改来源，以免覆盖请求里的来源。
- 移动：无边框面板没有标题栏，`ToolLauncherPanel.sendEvent` 在左键按下时询问内容区 `isDragHandle`，命中就调
  `performDrag(with:)`（系统窗口拖动，松开才返回）。把手只有搜索行里搜索框与按钮以外的部分，以及底栏；结果行与工具
  界面照常接收点击。拖完记下左上角，之后内容变高从这里往下长，下次呼出也放在这里（所在屏幕已不在时忘掉）。
  钉住状态与位置只存在内存里，不写偏好。
- 顶部搜索框，下方结果列表（「识别到」+ 搜索结果），选中工具后下方展开工具界面（高度取工具请求的高度）。
- 键盘：`↑`/`↓` 选择，`↩` 打开，`⌘↩` 把结果预填到终端，`⌥↩` 开成 Pane，`⇧↩` 在新窗口打开（只在焦点位于搜索框时：
  工具自己的多行输入里 `⇧↩` 是换行），`Esc` 先退出工具、再关闭面板，
  `⌘1`–`⌘9` 快速选择。失去焦点自动隐藏，并把焦点还给之前的应用。键盘路由是纯函数（`ToolLauncherKeyRouter`）。
  面板拿着键盘时 `⌘W` 只收起面板，分屏类菜单置灰；`⌘D`/`⌘T`/`⌘N` 仍作用于背后的工作区（与 Quick Terminal 一致）。
- `↩` 的语义两边不同：Open Quickly 里「识别到」行有行内结果时 `↩` 复制；工具面板里 `↩` 一律打开工具，`⌘↩` 才把
  行内结果或工具结果预填到终端。
- 支持把文件拖到面板上作为输入（`files` 匹配）。
- 结果行（`ToolLauncherRowView`，与 Open Quickly 的通用行分开）：行高 48，左侧 28pt 图标块——插件自带图标优先
  （`iconPath`，按路径缓存），否则用与内置网页工具图标同族的固定深色底 + 符号，原生工具每个一种色相。右侧徽章只在
  有信息量时出现：「识别到」用强调色，用户 / 开发插件写「网页」「脚本」，内置工具不挂「内置」。按住 `⌘` 时快选键帽
  显示在徽章位，图标与标题不动。颜色都在 `updateLayer` 里按外观解析，切换明暗与主题后自动跟上。
- 对齐：放大镜对准行图标块中线、输入文字对准行标题、底栏左边对准图标块。底栏每条提示的按键加粗、说明常规，都用次色。
- 全局快捷键：兼容设置键 `tools.launcherShortcut`，取值 `none`（默认）/ `optionSpace` / `controlOptionSpace`；
  不能与 Quick Terminal 选同一组合（设置页禁用冲突选项，注册失败时提示一次）。Carbon 热键签名 `'ASTL'`。
- 其它入口：「窗口 → 工具面板」菜单项、命令面板「工具面板」（发 `.asterShowToolLauncher` 通知）。
- Open Quickly 的工具行不进内存索引，每次刷新向 `ToolCenter` 现取，与工具面板排序一致；「全部」页只有输入了查询
  才出工具行（最多 3 条识别到 + 5 条搜索结果），空查询不列工具，避免淹没其它类型。
- chip 条（`OpenQuicklyFilterStrip`）：加了第 11 个 chip 后，en/ja/de/fr 下超出可用宽度。先收紧内边距与间距，
  仍放不下时裁掉末尾，不撑破整列。

来源 Pane：从工作区窗口打开时取该窗口的活动 Pane；全局快捷键打开时取最前工作区窗口的活动 Pane。
`terminal.insert` / `⌘↩` 只写这个 Pane，Pane 已关闭或不是终端时失败并提示，走 `pastePromptText`
（bracketed paste + 粘贴保护，永不回车）。

## 工具 Pane

- 新增 `PaneKind.tool`，`resourcePath` 保存功能 id（`<pluginID>/<code>`）。工具会话按 Pane id 缓存，
  工作区重建时复用同一个控制器，不重载 WebView。
- `PaneDescriptor` 解码 `kind` 改为容错：不认识的值降级成同目录的终端 Pane（保留 cwd、丢掉 `resourcePath`），
  不再让整份工作区快照失败；缺字段仍然报错。
- 会话缓存（`ToolPaneSessionCache`）：Pane 从所有标签里消失后，下一轮主队列再 `teardown()`——延后一轮是为了跨标签
  搬运时不被误拆。`openToolPane` 先按预定的 Pane id 建好会话再分屏；远端窗口拒绝并提示。跨窗口拖走的工具 Pane
  在新窗口里重建一个空输入的会话。
- 显示名：`PaneDescriptor.toolDisplayTitle` 取功能标题，功能不存在时显示「工具」。控制接口的 `PaneInfo.title`、
  标签标题回退与新标签标题都走它；标签标题规则的 `${file}` 不取工具 Pane 的功能 id。
- v1 **不持久化**工具 Pane：保存工作区快照、最近关闭与关闭历史、导出 Recipe 时都剔除工具 Pane（其所在分屏由
  兄弟节点顶替，只剩工具 Pane 的标签不保存）；导入 Recipe 遇到 `tool` 报 `unsupportedPaneKind`。
  等容错解码随正式版发布之后，再考虑持久化。
- 在新标签里运行脚本命令（`output == terminal`）：拼成 `env 'K=V' 'cmd' 'arg'`；含 Unicode `Cc` 控制字符就整条
  拒绝，emoji 里的零宽连接符可以通过。

## 设置页「工具」

分类 id `tools`，排在「Recipes」之后。快照键 `tools`：

```json
{
  "launcherShortcut": "none",
  "quickTerminalShortcut": "none",
  "pluginsDirectory": "/Users/…/Library/Application Support/Aster/Plugins",
  "plugins": [{ "id": "…", "name": "…", "version": "…", "description": "…", "source": "builtin|user|development",
                "directory": "…", "status": "ready|disabled|needsApproval", "statusReason": "firstRun|filesChanged|permissionsAdded|networkDomainsAdded|null",
                "enabled": true, "permissions": [{ "id": "exec", "risk": "high", "title": "…", "granted": true }],
                "networkDomains": ["…"], "featureCount": 2, "removable": true }],
  "issues": [{ "path": "…", "message": "…" }],
  "developmentFolders": ["…"]
}
```

动作（`tools.` 前缀）：`setEnabled {id, enabled}`、`approve {id}`、`uninstall {id}`、`reveal {id}`、
`openPluginsFolder`、`reload`、`installFromFolder`（原生选择文件夹）、`addDevelopmentFolder`、
`removeDevelopmentFolder {path}`、`openLauncher`。`tools.launcherShortcut` 走普通 `set` 管线。

实现（`SettingsToolsBridge`，注入 `ToolManaging`，测试可替换）：

- 插件排序：用户安装 → 开发中 → 内置，同组按名称；权限按风险从高到低，同级保持清单顺序；不需要确认时
  `statusReason` 为 `null`。
- 参数严格校验：`id` 必须在当前插件列表里，`enabled` 只认 JSON 布尔值，`path` 必须是已登记的开发目录；
  失败用 toast 提示并以失败回执，用户取消（`ToolCenterError.declined`）不提示。
- 卸载只对用户安装的插件，设置页先弹原生确认，`ToolCenter` 不再重复确认；开发中的插件只能在「开发」里移除登记，
  不会把用户的源码目录移到废纸篓。卡片上的「移除开发目录」只在 `summary.directory` 与 `developmentFolders`
  某项完全相等时出现，两边用同一种路径规范化。
- 确认框与选择框都用 sheet，同一时间只开一个；设置窗口关闭后，异步动作完成时不再推快照、提示或回执。
- `changes` 连发时合并到下一轮主队列只推一次快照；动作自己推了快照就取消已排队的那次。
- 快捷键冲突：网页下拉的 `conflictKey` 让两个下拉互相禁用对方占用的组合；Swift 侧写入前双向拒绝
  （`SettingsShortcutConflict.usedByQuickTerminal` / `.usedByToolLauncher`）。导入或重新加载配置不检查冲突，
  这时由热键注册失败的一次性提示兜底。

## 存储布局

路径都经 `AsterAppIdentity.applicationSupportDirectory()` 推导：

```
<AppSupport>/Plugins/<id>/            用户安装的插件
<AppSupport>/PluginData/<id>/         插件私有数据（storage.json、加密的 secure-storage.bin）与脚本的 ASTER_PLUGIN_DATA
<AppSupport>/tools-state.json         启用、授权、摘要、开发目录、使用记录
<App>/Contents/Resources/tools-builtin/   内置网页工具（只读）
<App>/Contents/Resources/tool-runtime/    aster-bridge.js
```

开发目录：只登记路径不复制；目录监听（`FileSystemDirectoryWatcher`）加 1 s 修改时间轮询兜底，变化后重新扫描，
已打开的网页工具自动刷新（`reloadFromDisk()`）；清单或授权变化时重建网页工具控制器；外观变化时调 `applyAppearance`。

扫描（`ToolPluginScanner`）在后台进行，结果按代次应用，迟到的旧结果丢弃；`reloadAndWait()` 等到不早于本次发起的
扫描生效才返回。来源优先级：内置 > 用户 > 开发，id 冲突与无效清单记入 `pluginIssues`；用户插件扫描时算摘要，失败就
跳过并记一条问题。`runtimeInfo(pluginID:)` 只在状态为 `ready` 时返回；原生内置插件 `aster.builtin` 没有目录，返回 nil。

`tools-state.json`：启动时同步读一次（上限 4 MiB）；写入走串行队列、原子写；使用记录去抖 2 s，App 退出前 flush。
文件损坏时改名为 `.bad` 留底并记一条问题，再按空状态启动。

## 本地化

Swift 的 `L("…")` 新文案写入 `l10n-work/*.json`（`key → {en, ja, fr, de, zh-Hant}`），由
`python3 scripts/check-localizations.py merge` 合并；网页设置页文案写入 `Resources/settings-ui/i18n.js` 五种语言。
内置网页工具自带六种语言字典（`zh-Hans`、`zh-Hant`、`en`、`ja`、`fr`、`de`），按 `context.locale` 选择。

## 测试

只跑定向用例：`./scripts/test.sh --filter <name>`。覆盖：清单校验（每条拒绝规则）、匹配与拼音、信任状态机、
摘要、脚本协议解析与上限、桥接参数与授权、内置转换；scheme handler 路径越界、桥接未授权拒绝、脚本超时与
输出上限、插件扫描与无效清单、容错解码与快照剔除工具 Pane、设置桥快照与动作；加密存储的密文格式、密钥丢失与预埋条目、
剪贴板机密标记（`ToolSecureStorageTests`）。

## 独立工具窗口

- `ToolWindowController`：工具面板、工具 Pane 之外的第三种 `ToolSessionHost`。入口是工具面板的 `⇧↩` 与右键菜单、
  Open Quickly 工具行的操作菜单。每个窗口一份独立会话，同一工具可以开多个；窗口由类型上的登记表保活，
  `windowWillClose` 时 `teardown()`，下一轮再移出登记表（不在自己的回调里释放自己）。
- 窗口类型 `ToolStandaloneWindow`（便笺窗口是它的子类）。它不是工作区窗口：AppDelegate 的 `⌘W` / 关闭标签
  在它拿着键盘时只关这个窗口，分屏与活动 Pane 类菜单置灰，免得落到背后工作区的活动 Pane。`followsAppAppearance`
  为真时随 App 明暗切换（便笺为假，纸面固定浅色）。
- 尺寸：初始宽 720、高取工具希望的高度（200–800）加底栏；之后忽略工具的高度请求，由用户拖动。每个功能 id 一个
  `setFrameAutosaveName`（`AsterToolWindow.<entryID>`），只有第一个窗口能占用，其余从最后一个工具窗口错开 24pt。
- 宿主语义：`⌘↩`（窗口拦截 `performKeyEquivalent`）把 `primaryResultText` 预填到终端并把用户带到那个 Pane；
  预填目标有来源只认来源（来源已关闭则失败，不改写别处），没有来源时取目标工作区当前的活动终端。开成 Pane 成功后
  关掉窗口；`terminal` 脚本在目标工作区的新标签里运行。提示显示在窗口底栏。

## 便笺

- 内置原生工具 `stickies`（`StickiesToolContent`）只是目录：列表按修改时间倒序，启动器继续输入的文字筛选列表
  （忽略大小写、变音与全半角），也是「新建便笺」的初始内容；`⌘↩` 预填选中便笺的全文。
- `StickyNoteCenter`（主线程单例）持有全部便笺与窗口。启动时 `restoreOpenNotes()` 重新打开 `isOpen` 的便笺
  （不抢焦点），退出时 `flush()`。关窗口只是收起（`isOpen = false`），删除才移除；新便笺沿用最近改过的那张的颜色，
  位置从最近一张开着的便笺错开，没有时放在鼠标所在屏幕右上角。改字更新 `modifiedAt`，移动、换开关不算修改。
- 窗口（`StickyNoteWindowController`）：`.titled + .fullSizeContentView`，隐藏标题文字与缩放 / 最小化按钮，
  顶部 24pt 略深的色带可拖动。纸面取 macOS「便笺」六色，固定 `.aqua` 外观。右键菜单在系统编辑菜单前加：新建、
  字体、颜色、浮在最前面（`.floating` 层级）、半透明（`alphaValue` 0.75）、折叠、删除（有内容先确认）。
- 快捷键对齐 macOS「便笺」，由 `StickyNoteWindow.performKeyEquivalent` 先于菜单处理（否则 `⌘N`/`⌘T`/`⌘1` 会落到
  新建窗口、新建标签、切换标签）：`⌘N` 新建、`⌘T` 字体面板、`⌘B`/`⌘I` 切换粗斜体、`⌘U` 下划线、`⌘+`/`⌘=` 与 `⌘-`
  字号 ±1（8–96）、`⌘1`–`⌘6` 颜色、`⌥⌘F` 浮在最前面、`⌥⌘T` 半透明、`⌘↩` 发送到当前 Pane（Aster 自加）。
  映射是纯函数 `StickyNoteCommand.command`。
  粗斜体按选区开头的字体决定加或去，整段一致；没有选区时改输入属性。格式操作经 `shouldChangeText`/`didChangeText`，
  可撤销，也会触发保存。
- 发送到当前 Pane：`⌘↩`、标题栏右侧纸飞机按钮或右键菜单第一项。有选区发选区，没有发全文，去掉首尾空白
  （`StickyNoteCommand.textToSend`）。目标是 `StickyNoteCenter.workspaceProvider`：AppDelegate 注入，按
  `NSApp.orderedWindows` 取最前面的工作区窗口（便笺拿着键盘时 key window 不是工作区），再取它选中标签的活动终端
  （`AppModel.toolTerminalOrigin()`）。写入走 `ToolTerminalOrigin.submit` → `TerminalSession.submitComposerText`，
  与 Composer 相同：bracketed paste 一次写入多行，再单独发 Return；粘贴保护、只读与 Vi 模式门禁照常生效。不切走焦点，
  便于连续发送；结果（已发送 / 失败原因）在便笺标题栏显示几秒，失败时响一声。
- 折叠：双击标题栏由系统调到 `zoom`/`performZoom`（偏好为最小化时是 `performMiniaturize`，`⌘M` 同），窗口改为折叠 /
  展开，高度收成实际标题栏高度，标题栏里显示第一行；折叠时不可改大小，记位置按展开高度记。
- 正文是富文本（`isRichText`、`usesFontPanel`，不收图片）：保存纯文本 `text`（标题、搜索、预填用）与整篇 RTF
  `richText`；RTF 超过 4 MiB 只存纯文本。没有 `richText` 的旧便笺按默认字体显示纯文本。
- 列表的选中行用浅色圆角底（`NSTableRowView.drawSelection`），不用系统强调蓝；表格 `acceptsFirstMouse`，
  便笺窗口拿着键盘时第一下点击工具面板里的列表也能选中。
- 存储：`<AppSupport>/sticky-notes.json`（`StickyNoteStore`），`{version: 1, notes: [...]}`，时间写 Unix 秒。
  读取上限 32 MiB；坏文件改名 `.bad` 留底后从空开始。解码容错（AsterCore `StickyNote`）：`id` 无效的记录丢弃、
  重复 `id` 留第一条、坏字段用默认值、无效位置按没有位置处理；单张便笺正文上限 200,000 个 UTF-16 单元（不切开
  字素簇）。写盘去抖 600 ms，在串行队列上原子写入。存储位置经 `AsterAppIdentity` 推导，开发版与测试宿主隔离。
- 显示前核对存下来的位置仍落在某块屏幕上，显示器拔掉后改为居中。
