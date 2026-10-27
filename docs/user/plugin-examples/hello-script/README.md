# Hello Script：脚本工具示例

两个最小的脚本工具：「转成大写」演示 `output: "text"`，「文本变体」演示 `output: "list"`。

## 安装

1. 打开 Aster「设置 → 工具」。
2. 二选一：
   - 「添加开发目录…」：选这个 `hello-script` 文件夹。Aster 只登记路径、不复制，改了脚本立即生效，适合边写边试。
   - 「从文件夹安装…」：Aster 把文件夹复制进插件目录，之后改原文件夹不影响已安装的副本。
3. 第一次运行时 Aster 会弹出确认，列出插件申请的权限（这里只有 `exec`：运行插件自带的程序）。同意后才会运行。

装好后在工具面板或 Open Quickly 的「工具」页搜 `hello`。输入以 hello 开头的文字时，「转成大写」还会出现在「识别到」一栏。

## 文件

| 文件 | 作用 |
| --- | --- |
| `aster-plugin.json` | 清单：id、名称、权限和两个功能。脚本功能必须声明 `exec` 权限。 |
| `bin/upper.sh` | `output: "text"`：读 stdin（为空时读 `ASTER_QUERY`），把文字转成大写输出。 |
| `bin/variants.sh` | `output: "list"`：输出 `{"items": [...]}`，每项有 `title`、`subtitle`，可选 `value`（选中后复制或预填的内容）。 |

## 脚本约定（摘要）

- Aster 不经过 shell，直接运行 `command`。脚本要有 shebang 和可执行位：`chmod +x bin/*.sh`。
- `command[0]` 写相对路径时相对插件目录解析，解析后必须仍在插件目录里。
- 工作目录是来源终端的当前目录，没有时是主目录。
- 环境变量只有 `PATH`、`HOME`、`USER`、`LOGNAME`、`LANG`、`TMPDIR`、`SHELL`，再加上 `ASTER_FEATURE`、`ASTER_QUERY`、
  `ASTER_CWD`、`ASTER_PLUGIN_ID`、`ASTER_PLUGIN_DIR`、`ASTER_PLUGIN_DATA`、`ASTER_LOCALE`，不继承 Aster 的其它环境变量。
- `"stdin": "text"` 写入输入文本原文；`"stdin": "json"` 写入 `{"code", "query", "input", "context"}`。写完即关闭 stdin。
- 超时缺省 10 秒（`list` 缺省 3 秒，最长 60 秒），到时先结束整个进程组。stdout 上限 1 MiB；退出码非 0 时显示 stderr。
- `list` 模式在输入变化时去抖 300 ms 重跑，旧进程直接取消，所以脚本要快。

完整规则见开发文档 [工具箱与插件](../../../developer/tools-and-plugins.md) 的「脚本工具协议」一节。

## 在终端里先试一下

```sh
echo 'hello world' | ./bin/upper.sh
ASTER_QUERY='Hello, Aster' ASTER_LOCALE=zh-Hans ./bin/variants.sh < /dev/null | python3 -m json.tool
```
