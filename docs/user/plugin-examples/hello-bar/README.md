# Hello Bar：状态条示例

一个最小的状态条（`bar` 视图）：在终端标签底部显示当前时间和活动 Pane 所在的文件夹名，点击文件夹名复制完整路径。
脚本用 Python 写，演示 `command` 的裸名写法。

## 安装

1. 打开 Aster「设置 → 工具」。
2. 点「添加开发目录…」，选这个 `hello-bar` 文件夹（改了脚本会自动重跑）。
3. Aster 列出插件要的权限：`exec`（运行脚本）和 `clipboard.write`（点击复制路径）。点「允许」。
4. 回到终端窗口，标签底部出现状态条。在「设置 → 工具 → 视图」里可以把它改放到标签顶部或关掉。

## 文件

| 文件 | 作用 |
| --- | --- |
| `aster-plugin.json` | 清单：没有 `features`，只有 `contributes.views` 里的一个 bar 视图。 |
| `bin/bar.py` | 读 stdin 的上下文，输出 `{"items": [...]}`。 |

## 注意

- `"command": ["python3", "bin/bar.py"]` 里的 `python3` 是裸名：Aster 按固定 PATH
  （`/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`）查找，不读你的 shell 配置。
  用 nvm / pyenv 等装的解释器找不到；要么用 Homebrew 装，要么删掉 `python3`，只写 `["bin/bar.py"]`
  （脚本第一行的 `#!/usr/bin/env python3` 会生效），或者写解释器的绝对路径。
- 脚本需要可执行权限：`chmod +x bin/bar.py`。
- 在终端里先试：`echo '{"context":{"isRemote":false}}' | ASTER_CWD=$PWD ./bin/bar.py`。

完整规则见 [编写 Aster 工具插件](../../plugin-authoring.md) 的「把界面挂到窗口上」。
