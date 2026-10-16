# aster-ssh 协议

`aster-ssh` 是 Aster 的原生 SSH 运行时（Rust，基于 russh），移植自 tty7（Apache-2.0）。
本文是 Swift 侧（`Sources/AsterCore/SSHBrokerProtocol.swift`）与 Rust 侧共同遵守的契约：
任何一侧改字段都要同步改另一侧和本文。

## 1. 进程与角色

| 角色 | 命令 | 谁启动 | 说明 |
| --- | --- | --- | --- |
| broker | `aster-ssh broker --socket <path>` | App（`SSHBrokerSupervisor`），每个 App 实例一个 | 持有全部 russh 连接；stdin/stdout 是与 App 的控制通道；stdin EOF 即退出并断开全部连接 |
| client | `aster-ssh client …` | 替代原来 exec `/usr/bin/ssh` 的所有位置，包括 Ghostty Pane 子进程 | 连到 broker socket，打开一个 channel，转发 stdio、窗口大小与退出码 |
| config | `aster-ssh config list --json` / `aster-ssh config resolve <alias> --json` | App 按需调用 | 解析 `~/.ssh/config`，不依赖 broker |
| keys | `aster-ssh keys inspect` / `aster-ssh keys generate` | App 按需调用（`SSHRuntimeTool`） | 解析、规范化或生成保险库私钥；请求走 stdin、结果走 stdout，见 §6 |

broker 不读写钥匙串，不把任何秘密写入文件或日志。秘密只经控制通道（App 与 broker 之间的私有管道）传入内存。

## 2. client 命令行

```
aster-ssh client --broker <socket>
                 (--host-id <uuid> | --target <text>)
                 [--tty] [--no-prompt] [--connect-timeout <sec>]
                 [-- <remote command>]
```

- `--host-id`：已保存的主机，规格来自最近一次 `profiles.sync`。
- `--target`：alias、`user@host`、`user@host:port`、`ssh://user@host:port`、`[v6]:port`。
  broker 先按 `~/.ssh/config` 解析 alias（第一个匹配生效），再补默认端口 22 与当前用户名。
- `--tty`：请求远端 pty（大小取本地 tty；本地 stdin 是 tty 时进入 raw 模式，并转发 SIGWINCH）。
  对应 OpenSSH 的 `-tt`。
- `--no-prompt`：后台调用。缺少凭证或主机密钥需要确认时，broker 不向 App 发**交互**请求
  （`interactive:false`），App 只能用钥匙串里已有的凭证作答，否则按失败处理。对应 OpenSSH 的 `BatchMode=yes`。
- `<remote command>`：**单个字符串**，原样作为 SSH exec 请求发送（和 OpenSSH 一样由远端登录 Shell 解释），
  调用方负责 POSIX 转义（`RemoteSSHInvocation.shellQuoted`）。省略时请求交互 Shell（原生 SSH Pane）。

环境变量 `ASTER_SSH_TICKET`：App 为这一次启动签发的启动票据（见 §3）。**只走环境变量，不进 argv。**
client 启动后、起任何线程之前读出它，把 environ 里那段字节原地清零并 `unsetenv`，再放进 OPEN 的 `ticket`。
没有这个变量时 OPEN 不带票据，broker 会拒绝。

退出码：
- 远端命令正常结束：远端退出码；远端被信号结束：`128 + 信号值`。
- 传输层失败：`255`，并在 stderr **最后一行**输出一行结构化错误：

```
aster-ssh-error {"kind":"authenticationRequired","detail":"publickey,password rejected"}
```

`kind` 取值与 Swift `RemoteSSHFailureKind` 的 rawValue 完全一致：
`authenticationRequired`、`hostKeyUnknown`、`hostKeyChanged`、`hostUnreachable`、`timeout`、
`remoteCommandMissing`、`cancelled`、`transportFailure`。`detail` 已脱敏（不含口令、密钥内容、提示原文）。

**channel 生命周期（硬约束）**：client 进程退出或 socket 断开时，broker 必须立即对该 channel 发送 EOF
与 close。远端 pty 因此收到 SIGHUP，`aster-session terminal attach` 在 2 秒内退出并释放写租约。
禁止让 channel 挂在共享连接上等待超时（这是原来 ControlMaster 方案滞留 62 秒的问题）。

## 3. client ↔ broker 帧协议（Rust 内部）

unix socket，每帧 `type:u8 | len:u32 BE | payload`。

| type | 名称 | 方向 | payload |
| --- | --- | --- | --- |
| 1 | OPEN | c→b | JSON `{"hostID"?, "target"?, "tty":bool, "cols","rows", "term", "command"?, "interactive":bool, "connectTimeout"?, "ticket"?}` |
| 2 | OPENED | b→c | JSON `{}` |
| 3 | STDIN | c→b | 原始字节 |
| 4 | STDOUT | b→c | 原始字节 |
| 5 | STDERR | b→c | 原始字节 |
| 6 | STDIN_EOF | c→b | 空 |
| 7 | RESIZE | c→b | JSON `{"cols","rows"}` |
| 8 | EXIT | b→c | JSON `{"status":int?, "signal":string?}` |
| 9 | ERROR | b→c | JSON `{"kind","detail"}` |

**启动票据（`ticket`）**：broker 收到 OPEN 后，在解析 `hostID` / `target` 之前先验票，
没有有效票据就回 `ERROR {"kind":"authenticationRequired","detail":"invalid launch ticket"}` 并关闭连接，
连「主机 ID 是否存在」也不回答。

- 格式：`v1.<nonce>.<expiryMs>.<hmac>`。`nonce` 是 16 字节随机数的小写 hex（32 字符）；
  `expiryMs` 是 Unix 毫秒到期时间（App 签发时为当前时间加 120 秒）；
  `hmac = HMAC-SHA256(key, "v1|<nonce>|<expiryMs>")` 的小写 hex，`key` 来自 §4.2 的 `tickets.key`。
- 校验顺序：先常量时间比较 HMAC（伪造的票据不会占用 nonce），再查到期（已过期，或离现在超过 5 分钟，都拒绝），
  最后查 nonce 是否用过。通过即登记 nonce，到期后清掉。**每张票只能 OPEN 一次**。
- client 每个进程只 OPEN 一次，所以「一次启动一张票」就够：Pane 重新连接是新进程，App 会在创建 surface 时再签一张。
- 还没收到 `tickets.key` 时，OPEN 最多等 2 秒（broker 先 bind socket 再读 stdin）。
- 拒绝原因（缺失、伪造、过期、重放）只写 broker 日志，不回给 client。
- 仅调试：debug 构建（`debug_assertions`）的 broker 环境里有 `ASTER_SSH_TICKETS=off` 时不校验。发行版（`cargo build --release`）忽略这个变量，非 DEBUG 的 App 也会在拉起 broker 前把它从环境里删掉。

## 4. App ↔ broker 控制协议

broker 的 stdin（App→broker）与 stdout（broker→App），每行一个 JSON 对象（JSON Lines），UTF-8。
broker 的 stderr 只写脱敏日志。未知 `type` 必须忽略（向前兼容）。

### 4.1 broker → App

```jsonc
{"type":"ready","socket":"/…/broker.sock","version":"0.1.0"}

// 需要凭证。kind: password | passphrase | keyboardInteractive | privateKey
{"type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password",
 "hostID":"UUID"|null,"keyFile":null,"keyDigest":null,
 "name":"","instruction":"","prompts":[{"text":"Password:","echo":false}],
 "attempt":1,"interactive":true}
// passphrase 时 keyFile 为展开后的私钥路径，keyDigest 为私钥文件内容 SHA-512 的小写 hex。

// 要一把保险库私钥（vaultKeyID 来自 ResolvedSpec.vaultKeys[].id）。恒为 interactive:false，
// prompts 为空，attempt 恒为 1；其它 kind 不带 vaultKeyID 键。
{"type":"auth.request","id":"a3","endpoint":"deploy@10.0.0.5:22","kind":"privateKey",
 "hostID":"UUID"|null,"keyFile":null,"keyDigest":null,"vaultKeyID":"UUID",
 "name":"","instruction":"","prompts":[],"attempt":1,"interactive":false}

// 上一次 auth.answer 提供的秘密是否被服务器接受。App 只在 accepted=true 后才写钥匙串；
// accepted=false 且秘密来自钥匙串时，App 删除该条目。
// privateKey 的 auth.result 只是告知：服务器拒绝或公钥对不上时 accepted=false，App 不得因此删除保险库密钥。
{"type":"auth.result","id":"a1","accepted":true}

// 主机密钥需要确认。status: unknown | changed
{"type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519",
 "fingerprint":"SHA256:…","status":"unknown","interactive":true}

// 连接状态。state: connecting | connected | reconnecting | failed | closed
{"type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":"UUID"|null,"target":"orb"|null,
 "state":"failed","attempt":2,"errorKind":"hostUnreachable","detail":"connection refused"}

{"type":"log","level":"info","message":"…"}   // 已脱敏
```

### 4.2 App → broker

```jsonc
// 启动票据密钥（§3），32 字节的小写 hex。每个 broker 实例启动后的第一条消息；
// broker 重启时 App 换一把新密钥，旧实例签出的票随之作废。
{"type":"tickets.key","key":"<64 位 hex>"}

// 全量替换已保存主机的解析后规格（已合并「默认」项、已展开跳板链）。
{"type":"profiles.sync","profiles":{"UUID":{ /* ResolvedSpec */ }}}

// password / passphrase：secret 为 null 表示取消。
// keyboardInteractive：secret 恒为 null，按 responses 判断——数组（可为空）是回答，null 是取消。
// privateKey：secret 为未加密的 OpenSSH 私钥文本；null 表示取不到（不在保险库、钥匙串读取失败），
// broker 只跳过这一把，继续下一把密钥或下一种方式，不取消整个认证。broker 用完即清零。
{"type":"auth.answer","id":"a1","secret":"…"|null,"responses":["…"]|null}

// accept=true：unknown 追加到 ~/.ssh/known_hosts；changed 替换旧行。
{"type":"hostkey.answer","id":"h1","accept":true}

{"type":"disconnect","endpoint":"deploy@10.0.0.5:22"}
{"type":"shutdown"}
```

`interactive:false` 的请求，App 只能从钥匙串作答，不得弹窗；取不到就回 `secret:null`。
`privateKey` 请求总是 `interactive:false`：App 只为当前保险库目录里存在的 id 读钥匙串作答，未知 id 回 null。

### 4.3 ResolvedSpec

```jsonc
{
  "host":"10.0.0.5","port":22,"user":"deploy",
  "auth":"auto",                       // auto | password | publicKey | agent | keyboardInteractive
  "identityFiles":["/Users/me/.ssh/id_ed25519"],   // 已展开 ~ 与 %h/%r
  "identitiesOnly":false,              // 可省略，缺省 false。true：只用 identityFiles，见下
  "knownHostsFiles":[],                // 可省略，已展开的路径；见下
  "identityAgent":"~/agent.sock",      // 可省略，IdentityAgent 原文，由 broker 展开；见下
  "vaultKeys":[{"id":"UUID","publicKey":"ssh-ed25519 AAAA… me@mac"}],  // 可省略，为空时不编码；见下
  "agentForward":false,
  "proxyCommand":null,                 // 字符串，经 /bin/sh -c 执行，%h/%p/%r 由 broker 展开
  "socksProxy":null,"httpProxy":null,  // {"host","port"}
  "jump":null,                         // 另一个 ResolvedSpec（递归，最深 8 层）
  "forwards":[{"kind":"local","bind":{"host":"127.0.0.1","port":8080},
               "target":{"host":"localhost","port":80},"description":""}],
  "keepaliveInterval":15,"keepaliveCountMax":3,"connectTimeout":10,
  "verifyHostKeys":true
}
```

`knownHostsFiles`（对应 OpenSSH `UserKnownHostsFile`）：
- 空数组或缺省：用 `$HOME/.ssh/known_hosts`。
- 多个文件：依次查。优先级：`@revoked` > 任一文件有同一把密钥（匹配）> 任一文件有同算法不同密钥（changed）> unknown。
  用户接受新密钥时只写**第一个**文件（changed 时替换其中的旧行，没有旧行则追加）。
- `["none"]`：没有用户级文件（`UserKnownHostsFile none`）。与 OpenSSH 一致：主机仍按 unknown 处理，
  交互确认后**本次连接**照常进行但不写任何文件（下次新连接还会再问），非交互直接失败。
- 系统级文件 `/etc/ssh/ssh_known_hosts`、`/etc/ssh/ssh_known_hosts2` 始终只读参与校验；`--target`
  经 ssh_config 解析时改用其中的 `GlobalKnownHostsFile`。

`identitiesOnly`（对应 OpenSSH `IdentitiesOnly`）：agent 里只用与 identityFiles 同一把公钥的身份签名
（公钥取自旁边的 `.pub`，没有时从未加密私钥推出），不逐个尝试 agent 里的其它密钥。
与 OpenSSH 一样，identityFiles 为空时仍回落到默认密钥（`~/.ssh/id_ed25519` 等）。

`identityAgent`（对应 OpenSSH `IdentityAgent`）：这一跳认证与 agent 转发用的 ssh-agent。App 原文照传，
broker 在连接时解析；`jump` 里的每一跳各带各的，不互相继承。
- 缺省或 null：用 broker 继承到的 `SSH_AUTH_SOCK`。
- `"none"`：不用 agent。`"SSH_AUTH_SOCK"`：同缺省。两者区分大小写。
- `"$VAR"`：socket 路径取自 broker 进程的环境变量 VAR；没设或为空就不用 agent。
- 其它：socket 路径，broker 展开 `%h/%p/%r/%u/%d/%%`、`${VAR}`（没设就不用 agent）与开头的 `~`。

`vaultKeys`：这一跳可用的保险库密钥，只带 id 与 OpenSSH 公钥行（私钥只在 App 钥匙串里）。
`jump` 里的每一跳各带各的。认证顺序：
- `auto`：保险库密钥 → agent → identityFiles → 默认密钥 → password → keyboard-interactive。
- `publicKey`：保险库密钥 → identityFiles → 默认密钥。
- 轮到某把密钥时 broker 发 `auth.request kind=privateKey` 要私钥，先核对它与 `publicKey` 是同一把
  （只比密钥本身，不比注释），不一致就跳过，绝不拿去认证。
- `vaultKeys` 非空时不再尝试默认密钥（`~/.ssh/id_*`），保险库的意义就是不读明文私钥文件。
- `identitiesOnly:true` 时，agent 里与 `vaultKeys` 同一把公钥的身份也允许签名。

endpoint 身份（凭证共享、连接复用的键）：`user@host:port`；有跳板时连接复用键再拼上跳板链，
但凭证键仍是目标自身的 `user@host:port`。

## 5. config 子命令输出

```jsonc
// aster-ssh config list --json
{"hosts":[{"alias":"orb","hostName":"127.0.0.1","user":"root","port":32222,
           "identityFiles":["…"],"proxyJump":null,"proxyCommand":null,
           "forwards":[…],"keepaliveInterval":null,"keepaliveCountMax":null,
           "forwardAgent":null,"connectTimeout":null,"strictHostKeyChecking":null,
           "userKnownHostsFiles":["~/.orbstack/ssh/known_hosts"],"globalKnownHostsFiles":[],
           "identitiesOnly":true,"identityAgent":"~/.1password/agent.sock"}],
 "ignored":[{"file":"~/.ssh/config","line":12,"option":"Match","reason":"unsupported"}]}

// aster-ssh config resolve <alias> --json   → 单个上面的 host 对象；无匹配退出码 1
```

`ignored` 就是导入时展示给用户的 ImportReport。

字段都是 ssh_config 的原文（第一个出现的指令生效），`~` 与 `%` token 由使用方展开：
- `forwardAgent`、`identitiesOnly`：布尔，没写为 null。
- `connectTimeout`：秒，没写或 `none` 为 null。
- `strictHostKeyChecking`：归一化为 `yes | no | ask | accept-new`，没写为 null。
- `identityAgent`：`IdentityAgent` 原文（路径、`$VAR`、`SSH_AUTH_SOCK` 或 `none`），没写为 null。
  `$VAR` 名字不合法或 `${` 没闭合时记进 `ignored`（`invalidValue`）。
- `userKnownHostsFiles`、`globalKnownHostsFiles`：路径数组，可多个；`none` 写成 `["none"]`；没写为空数组。

新增字段一律可省略，旧版 JSON 仍能解码。

## 6. keys 子命令

App 导入、生成保险库私钥时调用。请求是 stdin 上的一个 JSON 对象，结果是 stdout 上的一个 JSON 对象；
私钥与 passphrase 从不进 argv（`ps` 可见），stderr 只写固定用法说明，不含任何密钥内容。stdin 上限 64 KiB。

```jsonc
// aster-ssh keys inspect   stdin：
{"privateKey":"-----BEGIN …","passphrase":null|"…","comment":null|"…"}
// aster-ssh keys generate  stdin（只支持 ed25519，algorithm 可省略）：
{"algorithm":"ed25519","comment":"…"}

// 成功：退出码 0
{"privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----\n…","publicKey":"ssh-ed25519 AAAA… me@mac",
 "algorithm":"ssh-ed25519","fingerprint":"SHA256:…","comment":"me@mac"}

// 可预期的失败：退出码 1
{"error":"encrypted"|"wrongPassphrase"|"invalid"|"unsupported"}
```

- `privateKey`：一律是**未加密**的 OpenSSH 格式、LF 换行。加密私钥在导入时用 passphrase 解开一次，
  之后只以明文形式存进钥匙串（钥匙串负责静态加密）。
- `publicKey`：OpenSSH 公钥行，注释非空时带注释。`fingerprint`：SHA-256，与 `ssh-keygen -l` 相同。
- `algorithm`：`ssh-ed25519`、`ecdsa-sha2-nistp256/384/521` 或 `ssh-rsa`。
- `comment`：请求里非空的 `comment` 覆盖密钥自带注释（去首尾空白，不能含换行等控制字符），否则沿用自带注释（可为空串）。
- 能识别的输入：OpenSSH（含 bcrypt 加密）、PKCS#1 `RSA PRIVATE KEY`（含 AES-128-CBC 旧式加密）、PKCS#8（含加密）、
  SEC1 `EC PRIVATE KEY`、PuTTY PPK。
- 错误码：
  - `encrypted`：私钥已加密而请求没给 passphrase（空串等同没给）。
  - `wrongPassphrase`：passphrase 解不开。
  - `invalid`：不是私钥、请求 JSON 不合法、注释含控制字符或超过 64 KiB。
  - `unsupported`：能识别但用不了——DSA、安全密钥（`sk-*`）、DES/AES-256 旧式 PEM 加密、generate 指定非 ed25519。
- 用法错误（未知子命令）：退出码 2，stdout 为空。

## 7. known-hosts 子命令

`aster-ssh known-hosts list` / `aster-ssh known-hosts remove` 给设置页的 known_hosts 管理界面用，不依赖 broker。
请求是 stdin 上的一个 JSON 对象（上限 64 KiB），结果是 stdout 上的一个 JSON 对象；参数不进 argv。
解析与匹配复用连接时校验用的同一个解析器（`known_hosts.rs`）。

```jsonc
// aster-ssh known-hosts list   （stdin，字段都可省略）
{"files":["~/.orbstack/ssh/known_hosts"],"includeDefault":true,"includeGlobal":true,
 "match":[{"host":"10.0.0.5","port":22}]}
// → stdout
{"files":[{"path":"/Users/me/.ssh/known_hosts","exists":true,"writable":true,"global":false,"error":null}],
 "entries":[{"file":"/Users/me/.ssh/known_hosts","line":3,"marker":null,
             "hosts":["10.0.0.5","[db]:2222"],"hashed":false,"algorithm":"ssh-ed25519",
             "fingerprint":"SHA256:…","comment":null,
             "matches":[{"host":"10.0.0.5","port":22}],"lineDigest":"<64 位十六进制>"}],
 "skipped":[{"file":"/Users/me/.ssh/known_hosts","line":9,"reason":"malformed"}]}

// aster-ssh known-hosts remove （stdin）
{"file":"/Users/me/.ssh/known_hosts","line":3,"lineDigest":"…","host":null}
// → stdout
{"removed":"line"}            // 或 "pattern"
```

`list`：
- 文件顺序：默认文件（`~/.ssh/known_hosts`，仅 debug 构建可用 `ASTER_SSH_KNOWN_HOSTS` 覆盖）→ `files`（展开 `~`，`none` 与空串忽略）→
  系统级文件（`/etc/ssh/ssh_known_hosts`、`/etc/ssh/ssh_known_hosts2`）。按解析符号链接后的真实路径去重；`path` 回显展开后的原路径。
- `exists:false` 的文件照样列出；读失败时 `error` 是错误文本。`writable` 要求文件存在、不是系统级、文件和它（解析链接后）所在目录都可写。
- `line` 从 1 开始；注释与空行不算记录。`marker` 为 `null | "revoked" | "certAuthority"`。
- `hosts` 是主机字段按逗号拆开的原文（含 `!` 取反模式），hashed 模式写成 `"(hashed)"`，`hashed` 表示行里至少有一个 hashed 模式。
- `matches` 是请求 `match` 里被这条记录覆盖的主机，判定与连接时一致（`[host]:port`、通配、取反、hashed 都算）；hashed 记录只能靠它显示主机名。
- `lineDigest` 是原行（不含 `\n`，含 `\r`）的 SHA-256 十六进制。
- `skipped.reason`：`malformed`（字段不全、未知 `@` 标记、非 UTF-8）或 `invalidKey`（公钥 base64 解析失败）。
- 只输出公钥指纹，不输出公钥原文。

`remove`：
- `file` 可含 `~`。`line` 处原行的摘要必须等于 `lineDigest`，否则（含行号越界）退出码 **3**，stdout `{"error":"stale"}`，文件不变。
- `host` 为 null 时删整行，返回 `"line"`。
- `host` 非空时只去掉这一行里命中该主机的模式（明文通配或 hashed，取反模式不动），行的其余字节原样保留，返回 `"pattern"`；
  去掉后不剩非取反模式时删整行，返回 `"line"`。没有模式命中时失败（`noMatch`）。
- 其它行逐字节保留（含 `\r\n` 与结尾换行的有无）。
- 写入时先顺着符号链接找到真实文件，在它的目录里写临时文件再 rename，保留原权限；链接本身不变。
- 失败时退出码 1，stdout `{"error":…}`：`global`（系统级文件，一律拒绝）、`notFound`、`notWritable`、`noMatch`、
  `malformed`（目标行解析不了，只在给了 `host` 时出现）、`invalidRequest`、`tooLarge`、`io`。
- 子命令名不对时退出码 2，只打 usage 到 stderr。
