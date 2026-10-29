# 应用身份与单实例

正式版与开发版各用一套数据；同一身份同时只跑一个进程。本页说明这两条规则的原因、范围与验证方式。

## 为什么要分开

启动恢复依赖 UserDefaults 里的工作区快照与「正在运行」标记 `aster.session.running.v1`。开发版曾与正式版共用 bundle ID，于是共用这两样东西：正式版在跑时打开开发版，开发版读到「正在运行」就当成上次崩溃，恢复同一份快照，并在每个 Pane 的首个 prompt 发送 `claude --resume <同一个会话>`，同一个 agent 会话被两个进程打开。之后两边抢着写快照；开发版的启动补收还会把正式版正在跑的 Memory 会话当成崩溃遗留关掉，并把 `~/.zshrc` 等文件里的受管区块改成指向开发版包里的脚本。

「正在运行」标记只能回答「上次有没有正常退出」，回答不了「另一个实例是否还活着」。所以有两层修复：身份不同的进程数据分开；身份相同的进程用实例锁互斥。

## 身份判定

`AsterAppIdentity`（`Sources/AsterCore/AsterAppIdentity.swift`）是唯一判定点。可执行文件解析符号链接后位于 `X.app/Contents/MacOS/` 时，读取 `X.app` 的 bundle ID：

- `io.local.aster-terminal` 等其他 ID：正式版。
- `io.local.aster-terminal.dev`：开发版。`scripts/build-app.sh` 不再写入这个 ID，本地 `-dev` 包与正式版同一身份；手动把包的 bundle ID 改成它，才会以开发版身份运行。
- 不在 App 包里（`swift run`、`.build/debug/aster-cli`、测试宿主）：开发版，碰不到正式版数据。

本地包默认用钥匙串里的 Developer ID 证书签名（不公证），指定要求是「bundle ID + 团队 ID」，所以重新打包、和正式版互换后，系统隐私权限与钥匙串授权都保留；ad-hoc 签名每次打包都变，需要重新授权。规则见 [软件更新](software-update.md)「打包与逐层签名」。

设置页安装的 `/usr/local/bin/aster` 是指向包内 `aster-cli` 的符号链接，同样按包认身份，连到对应的控制 socket。

## 按身份分开的数据

- UserDefaults：随 bundle ID 自动分开，包括工作区快照、运行标记、命名工作区注册表与偏好。
- Application Support：正式版 `~/Library/Application Support/Aster/`，开发版 `Aster-Dev/`。其中有 `hosts.json`、`ssh-keys.json`、`host-facts.json`、`machines.json`、`settings.json`、`Memory/`、`Sessions/`（本机后台会话服务）、`Autocomplete/`、`Recipes/`、`audit/`、`RemoteMigrations/`、`CrashReports/`、`Control/aster.sock` 与 `instance.lock`。
- 日志：`~/Library/Logs/Aster/` 与 `~/Library/Logs/Aster-Dev/`；缓存按 bundle ID 落在 `~/Library/Caches/<bundle id>/`。
- 钥匙串：全局只有一条的 agent 主机授权条目，开发版的 service 加 `.dev` 后缀（`AsterAppIdentity.keychainServiceSuffix`）。

新增持久化路径一律经 `AsterAppIdentity.applicationSupportDirectory()` 或 `dataDirectoryName` 推导，不要再写死 `Aster/...`。

仍然共用的有：`~/.config/aster/`（主题、agent 检测清单、自定义视图）；SSH 凭据的钥匙串条目按主机与密钥 ID 区分，两边的 `hosts.json` 不同，不会相撞；`~/.claude` 等 agent 配置只在用户点「安装」时写入。

## 开发版不改的东西

下面两条只对以 `.dev` 身份运行的进程生效；`build-app.sh` 打的本地包是正式版身份，不受影响。

- Shell 启动文件：受管区块写的是包内绝对路径，只由正式版维护（`AsterResourceLocations.managesShellStartupFiles`）。开发版的 Pane 沿用正式版装好的那一段；设置里切换 Shell 集成只改设置。
- 系统入口：手动改成 `.dev` 身份的包，应同时去掉 `CFBundleURLTypes`（`ssh://`、`aster://`）与 `NSServices`，并把 `.asterrecipe` 的 `LSHandlerRank` 降为 `Alternate`，让链接、Finder「在 Aster 中打开」与双击 Recipe 仍只交给正式版。

开发版首次启动是空的：设置、主机与 Recipe 要重新配置，也可以手动把 `Aster/` 下对应文件复制到 `Aster-Dev/`，但不要复制 `Memory/`、`Sessions/` 与 `instance.lock`。通知等系统权限按 bundle ID 记录，开发版第一次使用时要再授权。

## 单实例锁

`AsterSingleInstance.claim()` 在 `main()` 最早一步、诊断会话启动之前，对 `<数据目录>/instance.lock` 加 `flock` 独占锁（`AsterInstanceLock`）：

- 抢到：写入本进程 PID，持有到进程退出。
- 抢不到：把锁文件里 PID 对应的进程调到前台，在标准错误输出一行说明后退出，不启动诊断、不碰快照。
- 打不开锁文件（权限、磁盘满）：照常启动，只失去单实例保护，诊断记 `application.instance_lock_unavailable`。

内核在进程退出或崩溃时释放锁，不会留下脏锁。锁文件以 `O_CLOEXEC` 打开，Shell 等子进程继承不到描述符，否则 App 崩溃后子进程仍攥着锁，下次启动会被误判成已有实例。「重新启动」与 Sparkle 更新都先等旧进程退出再拉起新进程，不受影响。

## 验证

```sh
./scripts/test.sh --filter "AsterAppIdentityTests|AsterInstanceLockTests|AsterControlProtocolTests"
./scripts/build-app.sh
plutil -p dist/Aster.app/Contents/Info.plist | grep -E 'CFBundleIdentifier|CFBundleName|CFBundleURLTypes|NSServices'
```

`dist/Aster.app` 的 bundle ID 应是 `io.local.aster-terminal`，版本号形如 `0.6.27-dev-<git 短哈希>`，`CFBundleVersion` 比仓库值小 1（等于上一个已发布构建号，下一次正式发版仍会被 Sparkle 提示）。

真机验收：退出正在运行的 Aster，用 `dist/Aster.app` 替换 `/Applications/Aster.app` 后打开，应恢复原工作区与设置。正式版在跑时再打开 `dist/Aster.app`，应切回已在运行的实例，不出现第二个进程。
