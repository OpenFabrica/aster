# Otty 1.6.2 原生 Tab / 接受候选规则

> 归档说明：Hopper 原库、关键反编译输出、SHA-256 清单和重开步骤已整理到 [Otty 1.6.2 分析存档](otty-analysis/1.6.2-0fa10277/README.md)。本文中的 `.build/rea/`、任务 worktree 路径与 PID 为历史记录；续查时使用存档中的同名文件，不能当成当前运行状态。

本页记录已保存 REA Evidence 和当前 arm64 Mach-O 的有界 LLVM 反汇编规则。实现与真实窗口验证在恢复报告中单独记录。REA keyDown Evidence：`ev_ab3ac8ae06372e00bb1a44e1006a790df14038e6f458b5613eae4d13694c0022`，文件 `remaining-keybody.json` / `tab-keybody.txt`；新增本地反汇编不冒充 REA Evidence，其 SHA-256 和来源见 `fig-rules-tab-provenance.json`。

## 调用与状态

`tab-keybody.txt` 的 `loc_10077adb4` 先调用 `0x100172bc0(event)`；返回 true 时直接到 keyDown 退出点 `0x10077c488`。只有 false 才可能走后面的 Tab fast path / PTY 转发。因此看到 keyDown 内 `10077b270` 的转发分支，不能推论所有 Tab 都直达 shell。

`AutoCompleteState` 的 ivar 名字和偏移来自 `otty-objc.txt:12970` 后：panel +16、ghostText +24、ghostIsLine +40、lastInput +56、items +72、dismissedInput +80、completionGeneration +96、panelActivated +104、fallbackTabWatchdog +168、fallbackTabResolvedGen +176、shellCompletionActive +184。`AutoCompletePanel.selectedIndex` 为 +48，items 为 +40。

`0x100172bc0` 是实际补全按键处理器。下表的 true = 已消耗按键；false = 交还 keyDown 继续处理。所有分支还受函数前部的输入法 marked text、终端状态等前置门控；本页不把尚未命名的门控推断成具体 shell 状态。

## 面板可见时

| 输入与条件 | 行为 | 地址 |
|---|---|---|
| Tab 配置允许；selectedIndex >= 0 | 调用 selected-item 接受函数，返回 true | `17331c–173350 → 173624 → 17387c` |
| Tab 配置允许；selectedIndex < 0；state.items.count == 1 | 同样调用 selected-item 接受函数；但该函数拿到 nil，dismiss 后直接返回，**没有插入**；外层仍返回 true | `173354–173374 → 173624`；`1742cc–174304 → 17457c → 1745b8` |
| Tab 配置允许；未选中且非单项；ghost 非空且首项 kind 是 fix/historyline | 接受首项 ghost，返回 true | `173378–1733a0 → 173a68` |
| Tab 配置允许；未选中且非单项；上述 ghost 条件不满足 | dismiss；shellCompletionActive = true；返回 false | `17338c/390/39c → 1730bc–1730d0 → 172d90–172d98` |
| Right 配置允许；已选中或单项 | 调用 selected-item 接受函数，返回 true；未选中单项同样只 dismiss | `1735d0–173624` |
| Right 配置允许；未选中、多项、ghost 非空 | 接受首项 ghost，返回 true，**不要求 fix/historyline** | `173618 → 173a48–173a70` |
| Return / 小键盘 Enter；selectedIndex >= 0 | 接受所选项，返回 true | `173314/17349c → 1734f0–173514 → 173624` |
| Return / 小键盘 Enter；未选中 | dismiss，返回 false，让 shell 收到原按键 | `173518 → 1738c8–1738d4` |
| Down / Up | 选择下一项 / 上一项，更新或清除对应 ghost，返回 true | `173630` / `17312c`，调用 `1992d4(+1/-1)` |

返回值证明：accept 调用后 `17362c → 17387c → 173884` 把 w22 设为 1，`172d98` 作为 w0 返回；fallback 的 `1730d0 → 172d90 → 172d94` 把 w22 设为 0 后返回。Tab 分支没有“第一次 Tab 把选中项设为 0”或 Tab 计数器。

## 面板初始选择和循环

面板构造器 `19984c` 在 `199868–19986c` 写 `selectedIndex=-1`。面板 show/update `196920` 在 `196a24` 调用 hide，然后 `196a54–196a58` **无条件**写 `selectedIndex=-1`；没有单项特例。主 UI show 调用位于 `175618`，其紧随的代码是释放和返回，没有补选首项。

`1992d4` 对空列表不做操作；已有选择时用 `(index + delta + count) % count`；未选中时 delta > 0 选 0，否则选 count-1 (`199318–199344`)。`19934c` 调用选择更新；这是真正改变 index 的键盘路径。

`196830` selectedItem getter 在 index < 0 或 >= count 时返回 nil，不回退首项。`17428c` 只有面板**不可见**时才改取 state.items.first；面板可见时拿到 nil 就直接 dismiss。鼠标 row-click 回调 `17e940` 会先将 index 移到点击行，再调用接受函数 (`17e9c8–17e9f0`)。

这证明了未选中单项 Tab 的可达行为；仅凭截图高亮不能判定它运行时 selectedIndex，hover、异步更新和 shell 状态仍需交互证据区分。

## 面板隐藏时

ghost 非空且 Tab 允许：state.items.count == 1、或首项 +0x58 布尔值为 true、或首项 kind 为 fix/historyline，进入 `174600` 接受首项并返回 true (`1732ac–173308` / `17377c–173798`)。这里 +0x58 与候选 clearLeader 的对应属于结构映射；机器指令直接证明的是该布尔分支。

多项、首项 +0x58 为 false 且不是 fix/historyline 时：仅清 ghost，shellCompletionActive=true，返回 false (`1738d8–1738fc`)。此分支没有完整 dismiss，因此不会直接清空 items 或 panelActivated。

ghost 非空且 Right 配置允许：直接接受首项，不受上述 Tab 的领先门槛限制 (`173428–17343c`，由非 Tab 路径也可到达)。

面板不可见且 ghost 为空、Tab 允许：清 dismissedInput；通过原生 `100a7d678` 门控后调用 `173bc0(forcePanel=false, fallbackTab=true)`，返回其布尔值 (`1739d8–173a3c`)。它启动异步查询，没有立即接受候选。

Ctrl-Space 只在 shortcut 枚举值 2 时成立：`173018` 将配置值和常量 `16e714 → rodata 101ae7772 = 2` 比较；Control 修饰位 18 且 charactersIgnoringModifiers 等于空格后，清 dismissedInput、调用相同查询函数 `173bc0(false,false)`，然后返回 true (`1731a4–1731fc`)。它与 Tab 共用查询函数，但没有 fallback Tab 标志，并非无条件全局快捷键。

## Shell 接管、清理和异步 fallback

shellCompletionActive 已为 true 时，Tab、Left、Right、Down、Up 全部立即返回 false，保持 true；**任何其他进入此函数的按键**先写 false，再继续补全处理 (`172dd0–172e18`)。普通文字输入可由这条路径解除；本轮没有证明 prompt 事件会主动解除，不能把它写成已恢复规则。前置门控先于这里，因此被输入法等门控提前返回的按键不保证重置。

`1729d0` dismiss 取消 debounceTimer、fallbackTabWatchdog、sshExitHintTimer，generation+1，panelActivated=false，隐藏面板，清 ghost，清 items；**不写 shellCompletionActive** (`172b04–172ba8`)。`175218` 只清 ghostText / ghostIsLine 并清原生 ghost 渲染，不清 items / panelActivated / shellCompletionActive。

`173bc0` 的 fallbackTab=true 安排 0.12 秒 watchdog (`173f4c–174034`，Double bits `0x3fbeb851eb851eb8`)。watchdog `17da00` 只有 generation 匹配、fallbackTabResolvedGen 尚未等于此 generation、ghost 为空且 panel 不可见才执行：标记 generation 已 resolved，取消 timer，调用 `178348` fallback 发送，shellCompletionActive=true，再 dismiss。已有 ghost / panel 或过期 generation 都直接返回 (`17da4c–17db1c`)。这不是第二次 Tab 接受机制。

Swift kind 原生字符串表 `17181c` / 跳转表 `101ae78b0`：0 subcommand、1 option、2 argument、3 filepath、4 folder、5 alias、6 fix、7 snippet、8 recipe_alias、9 readme、10 learned、11 historyline。`171aa4` 精确返回 kind == 6 || kind == 11。

## 可直接派生的回归用例

1. 可见单项、index=-1、Tab允许：不插字，清面板和 ghost，消耗 Tab。
2. 可见普通多项、index=-1：Tab 清理并交给 shell；下一次 Tab 及方向键仍交给 shell；输入字母后解除接管。
3. 可见多项、index>=0：Tab / Return 接受选中项；无选择 Return 不接受。
4. hidden ghost 普通多项无 leader：Tab fallback；Right 允许时接受首项。
5. 可见或 hidden 的 fix/historyline ghost：覆盖其 Tab 特例；不要将 learned/token 历史自动视作 historyline。
6. show/update 后 index=-1；Down 选首，Up 选末，已有选中循环；Tab 不替代选择动作。
7. 无 ghost 的 Tab 查询：120ms 内已有 ghost 或 panel则不发 fallback；generation过期不发；仍为空则仅发一次并标记 shell 接管。

未完成：原版 UI 真实按键验证；prompt 重置 shell 接管的完整外部调用图；所有输入法/终端前置门控的命名。现有用户观察可能同时涉及 shell 接管和异步 panel 更新，不能仅凭这些静态分支反推截图中的具体状态。

## 接受时发送的字节

`177848` 普通接受路径可表达为：

```text
rawToken = lastRawToken(lastInput)
deleteTarget = kind ∈ {fix, historyline} ? lastInput : rawToken
erase = [0x7f] * deleteTarget.unicodeScalars.count
insertText = kind ∈ {filepath, folder} ? escapePath(item.text, rawToken) : item.text
suffix = kind ∈ {folder, fix, historyline} ? "" : " "
sendBytes(erase + UTF8(insertText + suffix))
```

删除计数 helper `17be38` 是 **Unicode scalar distance**：UTF-8 原生字符串循环按 lead-byte 长度前进，每个 scalar 加 1（`17beb8–17bf20`）；foreign 路径调用 `String.UnicodeScalarView._foreignIndex(after:)` / `before:`，由 `otool -Iv` 的 `101ac6388` / `101ac6394` 导入符号直接证明。不是 UTF-8 字节数、Swift Character 数或屏幕列数。`177990–1779a8` 为每个 scalar 填入一个 `0x7f`。组合字符 `e + U+0301` 发两个 DEL，`中` 发一个 DEL。

`1614d0` 的 lastRawToken 按 Swift Character 遍历，但只把未转义、未处于单/双引号中的 **ASCII 空格 U+0020** 当分界；记录最后分界后的 String.Index，最后返回原始 suffix (`1616c0–161700`)。引号和反斜杠不从 suffix 中去除。因此替换目标包含原有引号：例如 `git "chec` 的原始 token 是 `"chec`，接受普通 subcommand `checkout` 发送 5 个 DEL，再发送 `checkout `。输入尾部已有未引号空格时 rawToken 为空，不删除那些已有空格。

普通路径的尾空格是无条件拼接：`177bc0–177c24` 仅排除 folder / fix / historyline，没有检查候选是否本已以空白结尾；候选已有尾空格也再加一个空格。它没有针对当前光标右侧的空白检查，此函数只拿保存的 lastInput。

filepath/folder 经 `06ad84` 逐 Character 转义，集合在 `101dc1900`，精确字节为 `[32,40,41,38,124,59,36,33,62,60,96,92,34,39,42,63,91,93,123,125,126,35,94,10,9]`，即空格、括号、`&|;$!><`、反引号、反斜杠、单双引号、`*?[]{}~#^`、换行与 Tab；集合中的每个 Character 前加一个反斜杠。没有保留用户原来的引号包裹。`17c21c` 另有 tilde 特例：把 rawToken 交给已有 tokenizer，取 first；若 first 以 `~` 开头且转义结果以 `\\~` 开头，移除结果的第一个反斜杠。因此用户键入 `~` 的路径可保留 tilde 展开。

上述算法只描述普通插入路径。snippet (7) 且带对应动作字段时、readme (9) / learned (10) 且带 body 字段时，在 `1779b8–177b8c` 进入各自分支，不走普通尾空格拼接；本轮没有继续恢复这些动作字段的具体业务。

证据：`fig-rules-tab-accept.s`、`fig-rules-tab-shell-escape.s`、`fig-rules-tab-swift-imports.txt`。这轮没有原版运行时验证；scalar DEL 对 shell 编辑器的实际删除效果可能取决于其自身 Unicode 行编辑行为，静态事实是发出的字节计数。
