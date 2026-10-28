# 控制 → 自动补全：Otty 1.6.2 恢复与重建

> 归档说明：Hopper 原库、关键反编译输出、SHA-256 清单和重开步骤已整理到 [Otty 1.6.2 分析存档](otty-analysis/1.6.2-0fa10277/README.md)。本文中的 `.build/rea/`、任务 worktree 路径与 PID 为历史记录；续查时使用存档中的同名文件，不能当成当前运行状态。

## 范围与结论

目标是 `/Applications/Otty.app` 的 1.6.2 版本中“控制 → 自动补全”，包括设置、输入触发、候选计算、学习、更新和清除。
Aster 的新运行期不再调用旧 `AutocompleteEngine` 或旧排序表；保留通用 Ghostty、文件、CLI 和 Shell 集成适配器。
按本任务约定，旧学习先备份，新库从空开始。本报告记录已识别的差异，不把尚未恢复的分支声称为完全相同。

## 证据和故障处理

| 证据 | 标识或位置 | 支持范围 |
| --- | --- | --- |
| 发布二进制 | SHA-256 `0fa1027714a601402cc7df42bf05d5c9fab6434f21e01701e7ce8c4bd8d0942e` | arm64，Otty 1.6.2 |
| 设置资源 | SHA-256 `c8a76c5ab2d7fa8f90552e2067ea141ddb07fe064382b9b63de971c15ba7342c` | 控件、文案、桥接 payload、状态渲染、清除弹窗 |
| REA JavaScript | `ev_acf41dd3e385d79718e3b40e20ee3043009c97d63cf94e7330912eeee0dfd56b` | 8 个文件、3 个解析文件、0 个解析失败；调用图达到 100000 节点限制，非全图证明 |
| REA 摘要 | `ev_44af302422b0b266ef1dab8cccd7ad2b9a611563f4ecad19cd69df60fe860ce3` | 资源调查摘要 |
| Ghost policy | `ev_eda6dd6a25abd0bf6178a38923661a1642b17f7979079d5b6782b8b1ffc65be9` | 接受键、面板和 inline 的原生配置位 |
| 引擎 | `ev_86926f0436e9f24aa29f94229d5ece3d927c4bde1d2386fafd28724a8af63a73` | 记录、结束、清除、历史与其他来源合并 |
| 历史 | `ev_cf581ebaa5166e484e69c0b7fccdb51cf5be0f68d77ec90e45bd12bf38d96833` | frecency、完整行排序及学习 |
| 配置 | `ev_b33ee9dfd268988e487d4a3db37474e9f34ba78f5dda4cf22eab97c691042266` | 枚举别名及 fallback |
| 后续定点恢复 | `ev_96a649374255ac759491fbc8ff9ee762258981712dbd2a0f6ba0a7d996c3444f` | boost、失败清理、上下文；汇编用于核对数值和布局 |

原生完整输出已迁移至主工作区文档的 `local/rea/` 归档；地址、推导和限制见 [原生证据笔记](otty-native-findings.md)。
初次从原始二进制启动的 REA 桥接超过等待时限，取消后 Hopper Python 在 `server.accept()` 中报告
`SystemError` / `KeyboardInterrupt`。这不表示已经完成的二进制分析被破坏。
后续复用了已保存的 `.build/rea/otty-1.6.2-0fa10277.hop`，完成多轮定点反编译。最后一轮 close_binary 未收到清理确认，返回 cleanup_incomplete；随后现场确认 Hopper 已退出，并结束该轮遗留的独立 driver 子进程。已导出证据保留，不能将这个返回称为正常关闭确认。
保存库 SHA-256 为 `155cb11ed6e0d4729688cf637e44fbf5bf0d608c469220e5a7dd4a44571d3603`。
原 MCP 连接后来仍未响应状态查询，因此这些成功结果来自独立 REA CLI/MCP driver 会话，不能称原连接已恢复。

## 恢复的行为合同

| 场景 | 触发与输入 | 处理和输出 | 副作用及失败 |
| --- | --- | --- | --- |
| 打开设置 | 控制分类、现有配置与 capabilities | 建议/学习分组，5 种接受键、4 种面板模式及 3 个开关 | 打开本身不学习、不更新网络数据库 |
| 缺省配置 | 未设置或无效枚举 | Tab、Esc 面板、inline/learning 开、skipSecrets 关 | 截图里的自动面板是当前配置，不是缺省值证据 |
| 配置变化 | 新 key/value | 先更新网页状态，再发 `config_changed` | Shell Integration 关闭时提示但仍保存；不自动开启，网页未等待持久化确认 |
| 补全查询 | 当前行、目录、规格、别名/PATH、学习 | 空行/无 token 返回空；其他输入按命令上下文形成候选 | 查询不执行候选命令或项目脚本；Git 动态源运行固定只读 argv，见动态报告 |
| 完整行历史 | 同目录、当前前缀 | LIKE前缀仅折叠ASCII且%/_/反斜杠为字面；最近500条按衰减分和整秒时间排序取20，再移除exact而不重算领先 | 与其他来源重复的完整结果以历史为准 |
| 普通候选 | 候选集、context/token 词频 | 分数每小时乘 0.95，年龄最多 720 小时；当前引擎对象 seen 加 10 | +10 不写盘，不加到完整行 |
| 已知规格 | 当前命令和子命令的静态选项/参数 | 历史分优先；同分子命令/别名→参数→选项→路径/目录，稳定排序 | 静态子命令、选项、参数和路径构造的 clearLeader 为 false；固定动态分派详见动态报告 |
| 根命令前缀 | 未结束的第一个词 | 对已有候选按全局词频 boost | 不因 command_history 中的 token 额外创建程序名，也不设置 clearLeader |
| 未知命令参数 | 无规格的参数候选和频率 | 仅比较有词频证据的候选，第一项 ≥第二项1.5倍才明确领先；仅一个有分项则领先 | 不使用 Aster 旧的类型基础分、命令转移或共享前缀 |
| 接受与预览 | 配置、面板选择、ghost及Shell接管状态 | Tab不隐式选择多项；未选单项Aster直接接受（原版仅清理），多项回退；已选项按scalar DEL替换原始token并按kind加空格 | Return仅接受已选项；Ctrl-Space重新查询；无结果Tab有120ms回退，详见Tab证据 |
| 提交学习 | 原始命令、目录、会话 | 首词和参数分别记录；已识别子命令路径作为参数 context；再次记录为衰减旧分+1 | ASCII 前导空格跳过；完整行还要求非空目录及 ≤2048 Unicode scalar；词频不受此长度条件限制 |
| 敏感值 | token、完整行、skipSecrets | 词频始终跳过敏感参数值；开关另外过滤完整行 | 默认关闭时完整行可能含敏感值；开启只影响未来记录；精确边界在 `CompletionPrivacy` 测试 |
| 执行完成 | 会话与真实退出码 | 127 删精确完整行及非 flag token；其他非零仅删未知长选项；known flags 为根规格整棵树的选项 | 不将126或输出文案改写成127；清理会影响该上下文已有词频，不只是本次增量 |
| 更新数据库 | `update_completions_db`，空对象 | running 显示消息/进度，idle 显示版本/数量/最后检查时间，failure 显示错误及重试按钮 | 网络协议尚未恢复；网页进度夹到0…1，未来时间夹成 just now，非法日期保留原字符串 |
| 打开清除框 | 点击清除行 | 五项每次全false，至少一项才能确认 | `capabilities.dataSync===true` 隐藏清除行；取消/遮罩无请求 |
| 确认清除 | 五个布尔键 | 发 `clear_autocomplete_data` 后关闭；native 按位1、2、4、8、16分别处理 | 失败项不计成功，继续其他项；不是五类共同回滚的事务；内置库保留 |

## 实现位置与验证映射

- `Sources/AsterCore/command-completion.swift`、`completion-presentation.swift`：来源合并、排序、领先；`CompletionRulesTests` 验证输入边界、同分顺序、20条上限、去重、+10、空输入和配置别名。
- `CompletionHistoryContext.swift`、`CompletionPrivacy.swift`：上下文及词频/整行各自的敏感过滤；`CompletionHistoryTests` 和隐私测试覆盖边界。
- `Sources/Aster/CompletionStore.swift`、`AutocompleteService.swift`：新库、备份、两阶段学习、部分成功、更新；`CompletionStoreTests` / `CompletionServiceStorageTests` 覆盖重启、失败写入、清理分类和单次更新。
- `TerminalAutocomplete.swift`：OSC、按键与渲染；控制器测试验证删除/插入字节、120ms回退、回显等待、IME、选择与单项面板。
- `Resources/settings-ui/autocomplete.js`、`SettingsView.swift`：桥接、帮助、状态与对话框；真实 WKWebView 测试验证 DOM、消息及截图。
- `scripts/export-fig-upstream.py`、`scripts/build-fig-specs.mjs`：从只读包内数据库导出 public upstream 数据，再转为 Aster 数据模型；Node/Python 和 Swift 测试验证 711 条、日期、来源约束及 scoped command 名称。

原版真实窗口核对过 `git chec` 的单候选面板和 `kout` ghost；清除框初始五项不选、取消后重开重置。
原版的合成 Tab 事件没有改变 `git chec`。用户随后纠正“直接补全”的早期反馈，并提供 `kout` 仍为浅色的截图；第二次 Tab 的反馈也没有确认插入。不能将浅色预览当作输入。
进一步恢复的 [宿主按键路径](otty-tab-findings.md) 证明：panel show将index设为-1；未选单项Tab只清理，未选普通多项交Shell，Tab没有先选择再接受的计数器。这个可达分支解释了为何不能根据候选外观推定已插入，但截图当时的精确内部状态仍未知。没有在原版执行数据清除或数据库更新。

## 已识别的可观察差异与未验证边界

以下是本轮识别出的完整清单，区分确定差异和仍未恢复的行为。未覆盖的输入不能由本表证明相同。

| 编号 | 差异或边界 | 用户可观察到的结果 |
| --- | --- | --- |
| D01 | 应用身份、CLI 和桥接归 Aster；学习从空开始 | UI 的显式学习命令是 `aster learn`；没有导入 Otty 或旧 Aster 的个人权重，最初排序可能不同 |
| D02 | Otty SQLite/缓存文件布局与 Aster 五分类 JSON/备份布局不同 | 外部工具看到的文件、锁、容量、损坏恢复及 I/O 失败行为不同；新学习文件上限32MiB |
| D03 | 更新仍使用 Aster GitHub 的 JSON 数据和60秒超时；未恢复原版地址、下载格式、校验、重试或后台策略 | 两个应用检查到的版本/错误可能不同；实测Aster地址HTTP200但仍为2025-05-05的714条，新增防降级保持2026-10-05的711条；该保护是本次Aster设计选择，未证明原版也如此 |
| D04 | Aster 更新进度目前只显示开始状态，最后检查时间属于设置窗口状态 | 传输过程没有原版可能提供的连续进度；关闭重开窗口后时间可能消失 |
| D05 | Fig静态数据与消费字段已补齐，保留Aster导入预算 | 当前快照四类节点零丢失；未知Fig扩展字段原版也跳过。Aster仍限制32MiB文件、16KiB描述、512字节名字、每参数10000建议，未来超限快照失败语义可能不同 |
| D06 | 固定动态分支已实现；部分来源和运行边界未齐 | 已支持Git/npm系列/Make/Compose/Cargo/SSH/which；jump、应用私有SSH配置和recent、alias/wrapper未接；Include glob全集、1MiB限制、总预算裁剪和进程会话与原版有差异。详见动态报告ND01–ND08 |
| D07 | 文件枚举仍用Aster适配器，未实现argument_paths学习表 | 模板并集已按原版；仍有500项枚举限制、目录排序及失败后的路径习惯差异 |
| D08 | 查询长度、预览与特殊Shell边界有限制 | 已实现scalar删除、普通字面替换、大小写候选及路径转义。4096 UTF-8输入上限、Unicode控制字符候选拒绝、复杂编辑/展开/跨行，以及预览的只追加前缀校验仍可能不同；Shell接管后无法重建输入时需新prompt |
| D09 | README、显式目录学习、help 使用保留的 Aster 适配器 | README只读指定文件且限2MiB；help有2.5秒/128KiB/禁网禁写约束，合并、触发、顺序及错误文案不保证等同原版；原版brew/npm/pip/cargo等安装命令的额外学习分支未移植 |
| D10 | 原版 `fix`/执行后建议分支存在但未恢复完整条件 | 新引擎没有接入旧 Aster 猜测式纠错、clone后cd、项目resume、剪贴板及共享前缀注入；原版相关建议不能声称已覆盖 |
| D11 | Ghostty/AppKit渲染、调度与部分状态保留Aster实现 | 已还原Tab/Right/Return分支和120ms回退；150ms防抖、8行面板、字体图标位置、窄Pane、Shell建议共存、异步重排保留选中身份仍不保证同原版show/reset行为 |
| D12 | Shell/远端协议仍为 Aster | alias/PATH经OSC6973；远端跳过本机文件及help，Otty token/helper回退的完整语义未移植 |
| D13 | 清除的宿主反馈与参数校验是Aster实现 | 原版help缓存清理调用后直接计成功；Aster写盘失败会报部分失败；Aster桥接拒绝缺项/额外键并显示本地toast，原版宿主同类反馈未恢复 |
| D14 | 设置页宿主导航、缩放和布局不是Otty整个设置窗口 | 本区域标签和选项对应，外围导航、页面宽度、焦点/键盘导航与tooltip像素存在差别；不声称截图逐像素一致 |
| D15 | 初始化失败后重试只恢复共享服务 | 已打开且原先未绑定服务的Pane需要重新打开，CLI消费者也需重启应用才能重建；学习写入错误保留在服务状态，未增加与原版等同的通知通道 |
| D16 | 静态和限定真实窗口验证的边界 | Tab内部条件已恢复，但没有动态读取Otty截图当时的index/ghost/shell接管状态；原版引擎跨Pane作用域未定。更新、删除、数据库损坏、全部Shell/远端/并发和异常外部表现未全量差分 |

## 本轮执行结果（2026-10-25）

此节替代前阶段的 Tab 验收结论。旧阶段的“第一次 Tab 选择、第二次接受”和 `checkoutx` 只证明当时的 Aster 实现，已被本轮原生证据与实现覆盖，不能作为 Otty 规则。旧日志/截图保留为调查过程。

- `./scripts/test.sh --no-parallel --filter 'Autocomplete|autocomplete|completion|recoveredCompletion|figDatabase|figContext|figRules|figStore|figSnapshot|figScoped'`：255 项 Swift 测试通过，1 个 suite，42.243 秒；封装脚本的 8 项 Python 宿主检查通过。日志：`.build/rea/remaining-regression-final.log`。
- 真实窗口发现 Compose 两种命令的差别后，新增 `autocompleteNativeDynamicComposeRequiresParsedSubcommand`：当前快照的空链、独立命令及完整嵌套规格三个分支通过。该独立运行的 1 项测试见 `.build/rea/remaining-compose-regression.log`。两次合计 256 个不同 Swift 测试。
- Fig 转换器 4 项 Node、导出器 2 项 Python 测试通过；711 根命令与 17,517 command / 67,994 option / 40,173 arg / 40,435 suggestion 节点计数由 Swift 回归验证。
- `python3 scripts/check-localizations.py check`：五种翻译的原生/网页键均 `missing=0`；`git diff --check` 通过。
- `./scripts/build-app.sh` 成功，包内资源、运行组件自检、签名验证通过。构建日志：`.build/rea/remaining-build-app.log`。其后只增加测试与证据文档，生产源码和资源未再变更。
- 新包的实际窗口按下表执行。候选测试使用独立合成项目，Git 始终保持 main 和原有一个修改/一个未跟踪文件；没有执行 checkout/switch、项目脚本、Make 或 Compose 操作。一次在面板尚未打开时按 Return，使无效的 `git chec` 进入 Shell 并报未知子命令，随后分步确认面板选择再验证 Return；这条记录留在开发版测试历史中，没有清除整个用户学习库。
- 旧阶段已完成设置控件、清除框取消/重开重置、WKWebView 截图和更新 running→idle 的验收；本阶段重新确认数据库为 2026-10-05 / 711 条，未重新触发清除或更新。
- 验收专用标签已关闭，面板模式已恢复为测试前的 Escape；原有开发版标签和正式版 Aster 进程均保留。原版 Otty 的专用测试标签也已关闭。

| 真实窗口输入和动作 | 观察结果 | 截图（均在 `.build/rea/ui-evidence/`） |
| --- | --- | --- |
| 自动模式 `git chec` → Tab → `x` | `git checx`，单项未选择不插入灰字 | `remaining-single-unselected-tab-x.png` |
| 自动模式 `git chec` → Down → Tab → `x` | `git checkout x`，替换 token 并补尾空格 | `remaining-selected-tab-x.png` |
| 自动模式 `git ch` → Tab | Aster 面板关闭；随后 Shell 自己补为 checkout，Ctrl-C 返回新提示符 | `remaining-multiple-shell-tab.png`、后续 `remaining-npm-scripts.png` 的上一行 |
| `git checkout feature-rea-` | 两个动态分支；Down×2、Tab、`x` 得到 `git checkout feature-rea-b x` | `remaining-git-branches.png`、`remaining-git-selected-tab-x.png` |
| `git add rea-` → Down | `rea-untracked.txt`，描述为 untracked，来自 Git 状态源 | `remaining-git-status-detail.png` |
| `npm run rea-` → Down → Tab → `x` | 两个脚本候选，实际输入 `npm run rea-build x` | `remaining-npm-scripts.png`、`remaining-npm-selected-tab-x.png` |
| `git --no-pager status --no-pa` → Down | 仍有根级且已使用过的 `--no-pager` | `remaining-fig-inherited-used-option.png` |
| `make rea-`、`docker-compose up rea-`、`cargo run --bin rea-` | 分别出现 Make targets、Compose services、Cargo bin 及各自描述 | `remaining-make-targets.png`、`remaining-compose-standalone-services.png`、`remaining-cargo-bin.png` |
| `docker compose up rea-` | 当前快照无服务候选；原版数据库和原生链门控证明同样限制 | `remaining-compose-services.png`；解释见动态报告 |
| Escape 模式，`git chec`，面板隐藏 → Tab → `x` | `git checkout x`；隐藏 ghost 与可见未选面板走不同分支 | `remaining-hidden-ghost.png`、`remaining-hidden-tab-x.png` |
| Escape 模式，`git sw` → Escape×2 → Down → Return → `x` | 第一次 Escape 清 ghost，第二次打开面板；选择后 Return 只写入，最终 `git switch x` 未执行 | `remaining-manual-selected.png`、`remaining-manual-selected-return-x.png` |

SSH/which、超时、取消、动态迟到、Unicode 和引号等分支完成定向自动测试，未声称每个分支都在两个应用窗口逐项差分。尤其原版截图当时的 selectedIndex/ghost/Shell 接管状态仍未动态读取。

交付应用为 `/Users/mike/.codex/worktrees/otty-autocomplete-rebuild/aster/dist/Aster.app`，版本 `0.6.26-dev-6c7b4fa+`，bundle ID `io.local.aster-terminal.dev`。当前验收进程 PID 22687，路径与该产物一致。主可执行文件修改时间 `2026-10-25T19:00:51.916638+08:00`，SHA-256 `0265d7ed60061b7740f5cef8142a77c18ca7b7fdf7def20bba629e5f02325a4f`。完整交付信息在 `.build/rea/artifact-manifest.json`。

以上为初轮交付的历史验证：当时未运行全仓测试，尚未提交、合并或发布，主工作区保持干净且已有 ahead 2。后续定向回归、提交整合及归档入口见本页顶部的续查手册。
