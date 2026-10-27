# Hello Web：网页工具示例

一个最小的网页工具，演示 `window.aster` 的常用接口：

- `aster.onEnter`：显示带进来的文字、来源和界面语言。
- `aster.storage`：记录打开次数，保存一段便签（插件私有存储，不需要声明权限）。
- `aster.clipboard.writeText`：「复制输入」按钮（清单声明了 `clipboard.write`）。
- `aster.setHeight`：「展开 / 收起」按钮改变工具区域的高度。
- 外观：样式同时支持 `[data-aster-appearance]` 和 `prefers-color-scheme`。

## 安装

1. 打开 Aster「设置 → 工具」。
2. 二选一：
   - 「添加开发目录…」：选这个 `hello-web` 文件夹。Aster 只登记路径，文件一变化，已打开的页面自动刷新。
   - 「从文件夹安装…」：Aster 把文件夹复制进插件目录。
3. 插件声明了 `clipboard.write`，第一次运行时 Aster 会弹出确认，同意后才会打开。

装好后在工具面板或 Open Quickly 的「工具」页搜 `hello web`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `aster-plugin.json` | 清单：`ui.main` 指向入口页面，`ui.height` 是默认高度，`permissions` 只写真正用到的权限。 |
| `index.html` | 页面结构。只引用插件目录里的 `style.css` 和 `app.js`。 |
| `app.js` | 页面逻辑：接收输入、读写存储、复制、调整高度。没有 `window.aster` 时（直接用浏览器打开）禁用相关按钮。 |
| `style.css` | 浅色与深色两套配色。 |

## 网页工具的限制

页面跑在沙箱 WebView 里，每个响应都带严格的内容安全策略（CSP）：

- 只执行插件目录里的独立脚本文件。内联 `<script>`、`onclick="…"` 这类内联事件属性、`eval` 和 `new Function` 都不能用。
- 不能加载外部资源（CDN、网络字体、远程图片）。需要联网时声明 `network` 权限和域名，再通过 `aster.net.fetch` 由 Aster 代发。
- 每个方法需要的权限见开发文档的桥接方法表；没声明的权限调用时拒绝为 `permission_denied`。
- 失败的调用会拒绝为 `AsterError`，`code` 字段区分原因（`permission_denied`、`rate_limited`、`invalid_params` 等）。

完整接口见开发文档 [工具箱与插件](../../../developer/tools-and-plugins.md) 的「网页工具」一节。

## 在浏览器里预览

直接用浏览器打开 `index.html` 可以检查布局和深浅色，但浏览器里没有 `window.aster`，依赖 App 的按钮会被禁用。
