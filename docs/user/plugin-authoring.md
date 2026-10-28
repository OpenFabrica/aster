# 编写 Aster 工具插件

Aster 的工具箱可以装你自己写的插件。一个插件就是一个文件夹，根目录放一份 `aster-plugin.json`。
插件里的每个「功能」会出现在 Open Quickly 的「工具」页和工具面板里。

功能有两种写法：

- **脚本工具**：运行插件自带的程序或脚本（任何语言），把输出显示出来。
- **网页工具**：一个本地网页（HTML + JS + CSS），在沙箱里运行，经 `window.aster` 与 Aster 通信。

两个可以直接照抄的例子在 [plugin-examples](plugin-examples/)：`hello-script`（脚本）和 `hello-web`（网页）。

## 五分钟上手

1. 把 `docs/user/plugin-examples/hello-script` 复制到任意位置，例如 `~/Code/hello-script`。
2. 打开「设置 → 工具」，点「添加开发目录…」，选这个文件夹。
3. Aster 列出插件要的权限，点「允许」。
4. 按 `⇧⌘O` 再按 `⌘U`，或打开工具面板，搜索 `hello`。

开发目录只登记路径、不复制文件。你改了文件，Aster 会自动重新扫描，已打开的网页工具会自动刷新。
写好以后可以用「从文件夹安装…」正式安装：Aster 把文件夹复制到插件目录
`~/Library/Application Support/Aster/Plugins/<id>/`。

## 清单 `aster-plugin.json`

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
  "permissions": ["clipboard.write", "terminal.insert"],
  "network": [],
  "features": [
    {
      "code": "decode",
      "title": "解析 JWT",
      "subtitle": "header / payload / 过期时间",
      "keywords": ["jwt", "token"],
      "match": [{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ[\\w-]+\\.[\\w-]+\\.[\\w-]*$" }],
      "action": { "type": "ui" }
    }
  ]
}
```

Aster 严格检查清单。任何一条不对，整个插件都不加载，并在「设置 → 工具 → 问题」里写出是哪个字段。

| 字段 | 规则 |
| --- | --- |
| `schemaVersion` | 必须是 `1`。 |
| `id` | 小写、点分，例如 `com.example.jwt`，≤ 128 字节。`aster.` 开头留给内置插件。 |
| `name` | 1–64 个字符。 |
| `version` | 语义版本，例如 `1.0.0`、`1.2.0-beta.1`。 |
| `description` / `author` | 可选，分别 ≤ 512 / ≤ 128 个字符。 |
| `homepage` | 可选，必须是 `https://` 地址。 |
| `icon` | 可选，插件内的相对路径，`svg` / `png` / `jpg` / `jpeg` / `pdf`。 |
| `ui` | 网页工具必填。`main` 是入口 HTML 的相对路径；`height` 是希望的高度，120–800，缺省 480。 |
| `permissions` | 要用的权限，见下文「权限」。 |
| `network` | 声明了 `network` 权限时必填：允许访问的主机名，例如 `api.github.com` 或 `*.example.com`，最多 16 个。 |
| `features` | 1–32 个功能。 |

其它规则：

- 不认识的字段一律拒绝，拼错字段名也会报错。
- 路径必须是插件内的相对路径：不以 `/` 开头，不含 `..`。
- 文本字段不能含控制字符。

### 功能（feature）

| 字段 | 规则 |
| --- | --- |
| `code` | 插件内唯一，小写字母、数字、`_`、`-`，≤ 32 个字符。 |
| `title` | 1–64 个字符；`subtitle` 可选，≤ 128。 |
| `keywords` | 搜索关键词，最多 8 个。中文标题会自动支持拼音和首字母搜索。 |
| `match` | 内容匹配规则，最多 8 条。用户粘贴的内容命中时，这个功能会出现在「识别到」里。 |
| `action` | 功能怎么运行：`ui`、`script`，或内置插件专用的 `builtin`。 |

每个功能至少要有一个关键词或一条 match 规则。

### 内容匹配（match）

```json
{ "type": "regex", "label": "解析这个 JWT", "pattern": "^eyJ…$", "minLength": 10, "maxLength": 8192 }
{ "type": "text", "label": "统计字数", "exclude": "^\\s*$", "maxLength": 100000 }
{ "type": "files", "label": "压缩图片", "fileType": "file", "extensions": ["png", "jpg"], "maxCount": 20 }
```

- `regex`：正则（`NSRegularExpression` 语法），≤ 512 个字符。**能匹配空字符串的正则会被拒绝**，
  例如 `.*`。`maxLength` 缺省 10,000，超长的内容直接跳过，不跑正则。
- `text`：任意文本都命中。可以用 `exclude` 排除一些内容。它只说明「能处理文字」，所以排在关键词搜索结果后面；
  想在用户粘贴特定内容时置顶，用 `regex`。
- `files`：拖进工具面板的文件。`fileType` 是 `file` 或 `directory`；`extensions`（小写、不带点）和
  `pattern` 最多选一个。
- `label`：显示在「识别到」行上的说明，≤ 64 个字符。

## 脚本工具

```json
{
  "code": "upper",
  "title": "转成大写",
  "keywords": ["upper"],
  "action": { "type": "script", "command": ["bin/upper.sh"], "output": "text", "stdin": "text", "timeout": 10 }
}
```

- 清单必须声明 `exec` 权限。
- `command` 是参数数组，**不经过 shell**。`command[0]` 写相对路径时相对插件目录，并且必须有可执行权限
  （`chmod +x bin/upper.sh`）。
- 工作目录：来源终端的目录；没有时用主目录。
- `timeout`：1–60 秒，缺省 10 秒（`list` 缺省 3 秒）。超时先发 `SIGTERM`，1 秒后 `SIGKILL`。

### 输入

`stdin` 为 `text`（缺省）时，标准输入是用户输入的原文。为 `json` 时是：

```json
{
  "code": "upper",
  "query": "hello",
  "input": { "text": "hello", "files": [], "source": "typed" },
  "context": { "workingDirectory": "/Users/me/project", "isRemote": false, "locale": "zh-Hans", "appearance": "dark" }
}
```

环境变量只给这些，不继承 Aster 自己的环境：

| 变量 | 含义 |
| --- | --- |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin` |
| `HOME`、`USER`、`LOGNAME`、`LANG`、`TMPDIR`、`SHELL` | 与登录环境一致 |
| `ASTER_FEATURE` | 功能的 `code` |
| `ASTER_QUERY` | 用户输入的文字 |
| `ASTER_CWD` | 来源终端的目录（可能为空） |
| `ASTER_PLUGIN_ID` / `ASTER_PLUGIN_DIR` | 插件 id 与插件目录 |
| `ASTER_PLUGIN_DATA` | 插件私有数据目录，可以放缓存 |
| `ASTER_LOCALE` | 界面语言，例如 `zh-Hans`、`en` |

### 输出（`output`）

| 值 | Aster 怎么处理 |
| --- | --- |
| `text` | 标准输出作为结果文本（UTF-8，去掉末尾一个换行）。可以复制，或预填到终端。 |
| `list` | 标准输出是 `{"items":[{"title":"…","subtitle":"…","value":"…"}]}`。用户继续输入时 300 ms 后重跑。 |
| `none` | 只看退出码：成功提示「已完成」，失败显示错误输出。 |
| `terminal` | 不在后台运行，而是在新终端标签里运行这条命令，你能看到全部输出。 |

`list` 每项：`title` 必填（≤ 256），`subtitle` ≤ 512，`value` 是选中后复制或预填的内容（缺省等于 `title`，
≤ 64 KiB）。超过 200 项只显示前 200 项；`title`、`subtitle` 太长会被截断；有一项 `value` 超长或 `title` 为空，
整份输出作废。

上限：标准输出 1 MiB、错误输出 64 KiB，超出即停止并报错。退出码不是 0 时显示错误输出的前 4 KiB。

## 网页工具

```
my-tool/
  aster-plugin.json   "ui": { "main": "index.html", "height": 420 }
  index.html
  app.js
  style.css
```

网页从 `aster-plugin://<插件 id>/` 加载，只能读插件文件夹里的普通文件。安全限制：

- **不执行内联脚本**。把 JS 放在独立文件里，用 `<script src="app.js"></script>` 引入；也不要写
  `onclick="…"` 这类属性，改用 `addEventListener`。不能用 `eval` 和 `new Function`。
- **不能直接联网**（`fetch`、`XMLHttpRequest`、外部图片、外部字体都会被挡）。要访问网络，声明 `network`
  权限和域名，再用 `aster.net.fetch`。
- 页面不能跳转到插件以外的地址。用户点击的 `http(s)` 链接会在默认浏览器里打开。
- 每个插件有自己独立的存储空间，互相看不到。
- 没有 `alert` / `confirm` / `prompt`，也没有 `<input type=file>`：选文件用 `aster.files.pick`。用户把文件拖到页面上时，页面可以用标准的 `drop` 事件和 File API 读取。
- WebRTC 已关闭。

### `window.aster`

```js
aster.onEnter(({ code, input, context, theme }) => {
  // 工具被打开时调用；input.text 是用户的输入，context.locale 是界面语言
});
aster.onQuery((text) => { /* 工具面板里用户继续输入 */ });
aster.onThemeChange(({ appearance }) => { /* "light" 或 "dark" */ });

await aster.getInput();                    // {code, input, context}
aster.setHeight(360);                      // 120–800
aster.close();

await aster.storage.set("history", [1, 2]); // 本插件私有，总量 ≤ 5 MiB
await aster.storage.get("history");
await aster.storage.remove("history");
await aster.storage.keys();

// 加密存储：用法和 storage 一样，内容用钥匙串里的密钥加密后存到本机，适合口令、令牌这类机密
await aster.secureStorage.set("tokens", ["…"]);
await aster.secureStorage.get("tokens");
await aster.secureStorage.remove("tokens");
await aster.secureStorage.keys();

await aster.clipboard.writeText("…");      // 需要 clipboard.write
await aster.clipboard.writeText(pw, { concealed: true }); // 标成机密内容，剪贴板管理器不记录
await aster.clipboard.readText();          // 需要 clipboard.read
await aster.terminal.insert("ls -la");     // 需要 terminal.insert：预填到来源终端，不回车
await aster.terminal.selection();          // 需要 terminal.read
await aster.files.pick({ extensions: ["json"], multiple: false }); // 需要 files.read
await aster.files.read(path, "utf8");      // 只能读选中过或作为输入传入的文件
await aster.net.fetch("https://api.github.com/zen", { method: "GET" }); // 需要 network
await aster.notify("完成", "已处理 3 个文件"); // 需要 notify
await aster.openURL("https://example.com"); // 先弹确认，返回用户是否同意
```

`onEnter`、`onQuery`、`onThemeChange` 返回一个函数，调用它就取消注册。

所有异步方法失败时抛出 `AsterError`（可以用 `err instanceof aster.AsterError` 判断），带 `code` 字段：

| code | 含义 |
| --- | --- |
| `permission_denied` | 清单没声明这个权限，或用户没授权。 |
| `invalid_params` | 参数类型或范围不对。 |
| `payload_too_large` | 超过上限（单条消息 2 MiB、文本 1 MiB、文件 10 MiB、网络响应 5 MiB）。 |
| `rate_limited` | 每秒调用超过 50 次。 |
| `unknown_method` / `unsupported_version` | 当前 Aster 不支持这个方法或协议版本。 |
| `unavailable` | 当前不可用，例如来源终端已经关闭。 |
| `failed` | 其它失败，`message` 里有原因。 |

页面可以不依赖 Aster 单独打开（方便调试）。写 `if (window.aster) { … }` 判断即可。

### 外观与语言

- `document.documentElement.dataset.asterAppearance` 是 `light` 或 `dark`，跟着 Aster 实时变化。
  `prefers-color-scheme` 也能用。
- `context.locale` 是 Aster 的界面语言：`zh-Hans`、`zh-Hant`、`en`、`ja`、`fr`、`de`。

### 调试

开发目录里的网页工具可以用 Safari 的 Web 检查器调试：打开 Safari「设置 → 高级 → 显示网页开发者功能」，
然后在 Safari「开发」菜单里找到 Aster 和你的插件页面。正式安装的插件不开放检查器。

## 权限

| 权限 | 能做什么 | 风险 |
| --- | --- | --- |
| `clipboard.write` | 写剪贴板 | 低 |
| `terminal.insert` | 把文字预填到来源终端，不回车 | 低 |
| `notify` | 发系统通知 | 低 |
| `clipboard.read` | 读剪贴板 | 中 |
| `terminal.read` | 读来源终端的选中文字 | 中 |
| `files.read` | 读用户选中或作为输入传入的文件 | 中 |
| `network` | 访问 `network` 列出的域名 | 中 |
| `exec` | 运行插件自带的程序或脚本 | 高 |

插件第一次运行前，Aster 列出它要的权限，由用户决定是否允许。以下情况会再问一次：

- 新版本多要了权限或网络域名。
- 已安装插件的文件变了（Aster 记录了文件摘要）。开发目录里的插件不比对文件，方便你边改边试。

授权只保存在 `~/Library/Application Support/Aster/tools-state.json`，不进 `settings.json`，导入设置不会带来插件授权。
只声明真正用到的权限：要的越少，用户越容易允许。

## 常见问题

**插件没出现。** 看「设置 → 工具 → 问题」，那里写着清单哪个字段不对。修好后点「重新扫描」。

**脚本提示没有权限运行。** 给脚本加可执行权限：`chmod +x bin/你的脚本`；第一行写上解释器，例如
`#!/bin/sh` 或 `#!/usr/bin/env python3`。注意 `PATH` 只有上面列出的几个目录。

**网页里的按钮没反应。** 多半是写了内联脚本或 `onclick=` 属性，被安全策略挡住了。改成独立 JS 文件和
`addEventListener`。

**`fetch` 失败。** 网页不能直接联网，改用 `aster.net.fetch`，并在清单里声明 `network` 权限和域名。
