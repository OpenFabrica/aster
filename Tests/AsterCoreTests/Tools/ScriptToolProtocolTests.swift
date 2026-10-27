// 脚本工具协议的输入侧：stdin 内容、ASTER_* 环境变量、基础环境、工作目录、上限常量与错误说明。
import Foundation
import Testing

@testable import AsterCore

@Suite("ScriptToolProtocol")
struct ScriptToolProtocolTests {
  /// 带齐所有字段的输入，用来核对 json 模式写出的每个键。
  private let fullInput = ToolInput(
    text: "a/b\n你好",
    files: ["/a/b.txt", "/c d"],
    source: .file,
    context: ToolContext(workingDirectory: "/tmp/work", isRemote: true, locale: "en", appearance: "light"))

  // MARK: stdin

  /// text 模式写入输入文本原文：不改换行、不看 query；没有文本时为空。
  @Test func textModeWritesRawTextOnly() throws {
    // text 模式下的 stdin；query 故意给一个值，验证它不会混进去。
    func stdin(_ input: ToolInput) throws -> Data {
      try ScriptToolProtocol.stdinData(code: "run", query: "ignored", input: input, mode: .text)
    }
    #expect(try stdin(ToolInput(text: "line\r\n你好\n")) == Data("line\r\n你好\n".utf8))
    #expect(try stdin(ToolInput(text: "")) == Data())
    #expect(try stdin(ToolInput(text: nil)) == Data())
    #expect(try stdin(ToolInput(files: ["/a"], source: .file)) == Data())
  }

  /// json 模式：键按字母序、缺省值写 null、斜杠与非 ASCII 不转义，`context` 在顶层。
  @Test func jsonModeWritesSortedKeysWithExplicitNulls() throws {
    let empty = try ScriptToolProtocol.stdinData(code: "hash", query: nil, input: ToolInput(), mode: .json)
    #expect(
      String(decoding: empty, as: UTF8.self)
        == #"{"code":"hash","context":{"appearance":"dark","isRemote":false,"locale":"zh-Hans","workingDirectory":null},"#
        + #""input":{"files":[],"source":"none","text":null},"query":null}"#)

    let full = try ScriptToolProtocol.stdinData(code: "x", query: "q", input: fullInput, mode: .json)
    #expect(
      String(decoding: full, as: UTF8.self)
        == #"{"code":"x","context":{"appearance":"light","isRemote":true,"locale":"en","workingDirectory":"/tmp/work"},"#
        + #""input":{"files":["/a/b.txt","/c d"],"source":"file","text":"a/b\n你好"},"query":"q"}"#)
  }

  /// json 模式的结构：`input` 只有 text/files/source，`context` 的四个字段在顶层而不在 `input` 里。
  @Test func jsonModeKeepsContextOutsideInput() throws {
    let data = try ScriptToolProtocol.stdinData(code: "x", query: nil, input: fullInput, mode: .json)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(root.keys) == ["code", "query", "input", "context"])
    #expect(root["query"] is NSNull)
    let input = try #require(root["input"] as? [String: Any])
    #expect(Set(input.keys) == ["text", "files", "source"])
    #expect(input["source"] as? String == "file")
    let context = try #require(root["context"] as? [String: Any])
    #expect(Set(context.keys) == ["workingDirectory", "isRemote", "locale", "appearance"])
    #expect(context["isRemote"] as? Bool == true)
  }

  // MARK: 环境变量

  /// 注入的变量齐全；`ASTER_QUERY` 与 `ASTER_CWD` 有值时才出现。
  @Test func environmentContainsAsterVariables() {
    // 固定插件与目录，只变 query 与工作目录。
    func environment(query: String?, cwd: String?) -> [String: String] {
      ScriptToolProtocol.environment(
        pluginID: "com.example.p", code: "run", query: query,
        input: ToolInput(context: ToolContext(workingDirectory: cwd, locale: "en")),
        pluginDirectory: "/plugins/p", dataDirectory: "/data/p")
    }
    let base = [
      "ASTER_FEATURE": "run", "ASTER_PLUGIN_ID": "com.example.p", "ASTER_PLUGIN_DIR": "/plugins/p",
      "ASTER_PLUGIN_DATA": "/data/p", "ASTER_LOCALE": "en",
    ]
    #expect(environment(query: nil, cwd: nil) == base)
    #expect(environment(query: "hello", cwd: nil) == base.merging(["ASTER_QUERY": "hello"]) { $1 })
    #expect(environment(query: nil, cwd: "/tmp/w") == base.merging(["ASTER_CWD": "/tmp/w"]) { $1 })
    #expect(environment(query: "hello", cwd: "/tmp/w").count == 7)
  }

  /// 值里的 NUL 被去掉，并且先去 NUL 再按 64 KiB 截断。
  @Test func environmentStripsNulBeforeTruncating() {
    // 只取 ASTER_QUERY，方便比较。
    func query(_ text: String) -> String? {
      ScriptToolProtocol.environment(
        pluginID: "p", code: "c", query: text, input: ToolInput(), pluginDirectory: "/p", dataDirectory: "/d")["ASTER_QUERY"]
    }
    let limit = ScriptToolProtocol.environmentValueLimit
    #expect(query("a\0b\0") == "ab")
    #expect(query(String(repeating: "\0", count: 100) + String(repeating: "a", count: limit)) == String(repeating: "a", count: limit))
  }

  /// 超过 64 KiB（UTF-8 字节）就截断，恰好等于上限不动，多字节字符不会被切成两半。
  @Test func environmentTruncatesAtByteLimitOnCharacterBoundary() throws {
    // 取 ASTER_QUERY，缺失视为失败。
    func query(_ text: String) throws -> String {
      try #require(
        ScriptToolProtocol.environment(
          pluginID: "p", code: "c", query: text, input: ToolInput(), pluginDirectory: "/p", dataDirectory: "/d")["ASTER_QUERY"])
    }
    let limit = ScriptToolProtocol.environmentValueLimit
    #expect(limit == 65_536)
    #expect(try query(String(repeating: "a", count: limit - 1)).utf8.count == limit - 1)
    #expect(try query(String(repeating: "a", count: limit)).utf8.count == limit)
    #expect(try query(String(repeating: "a", count: limit + 1)).utf8.count == limit)
    // 65536 = 3 × 21845 + 1，所以三字节字符只能放 21845 个（65535 字节）。
    let cjk = try query(String(repeating: "你", count: 30_000))
    #expect(cjk.count == 21_845)
    #expect(cjk.utf8.count == limit - 1)
    #expect(cjk.allSatisfy { $0 == "你" })
  }

  /// 每一个注入的值都经过清洗：NUL 被去掉、超长被截断，不只是查询串。
  @Test func environmentSanitizesEveryValue() {
    let long = String(repeating: "d", count: ScriptToolProtocol.environmentValueLimit + 10)
    let environment = ScriptToolProtocol.environment(
      pluginID: "p\0q", code: "c\0d", query: nil,
      input: ToolInput(context: ToolContext(workingDirectory: "/tmp/\0w", locale: "e\0n")),
      pluginDirectory: "/plugins/\0p", dataDirectory: long)
    #expect(environment["ASTER_PLUGIN_ID"] == "pq")
    #expect(environment["ASTER_FEATURE"] == "cd")
    #expect(environment["ASTER_CWD"] == "/tmp/w")
    #expect(environment["ASTER_LOCALE"] == "en")
    #expect(environment["ASTER_PLUGIN_DIR"] == "/plugins/p")
    #expect(environment["ASTER_PLUGIN_DATA"]?.utf8.count == ScriptToolProtocol.environmentValueLimit)
  }

  /// 基础环境：固定 PATH，只透传 6 个键，缺 LANG 时给 UTF-8，空值当作没有，其余变量一律不带。
  @Test func baseEnvironmentPassesOnlyAllowedKeys() {
    #expect(ScriptToolProtocol.inheritedEnvironmentKeys == ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"])
    #expect(ScriptToolProtocol.defaultPath == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    let process = [
      "PATH": "/evil/bin", "HOME": "/Users/a", "USER": "a", "LOGNAME": "a", "LANG": "zh_CN.UTF-8",
      "TMPDIR": "/tmp/", "SHELL": "/bin/zsh", "AWS_SECRET_ACCESS_KEY": "secret", "FOO": "bar",
    ]
    #expect(
      ScriptToolProtocol.baseEnvironment(from: process) == [
        "PATH": ScriptToolProtocol.defaultPath, "HOME": "/Users/a", "USER": "a", "LOGNAME": "a",
        "LANG": "zh_CN.UTF-8", "TMPDIR": "/tmp/", "SHELL": "/bin/zsh",
      ])
  }

  /// 缺 LANG（或为空）时补 `en_US.UTF-8`；空的其它变量不带；没有任何环境时只剩 PATH 与 LANG。
  @Test func baseEnvironmentFillsLanguageAndSkipsEmptyValues() {
    let expectedEmpty = ["PATH": ScriptToolProtocol.defaultPath, "LANG": "en_US.UTF-8"]
    #expect(ScriptToolProtocol.baseEnvironment(from: [:]) == expectedEmpty)
    #expect(ScriptToolProtocol.baseEnvironment(from: ["LANG": "", "HOME": ""]) == expectedEmpty)
    #expect(ScriptToolProtocol.fallbackLanguage == "en_US.UTF-8")
    #expect(ScriptToolProtocol.baseEnvironment(from: ["LANG": "C"])["LANG"] == "C")
    #expect(ScriptToolProtocol.baseEnvironment(from: ["HOME": "/Users/a\0b"])["HOME"] == "/Users/ab")
  }

  /// 工作目录：本地 Pane 用它的目录；远端、缺省或空串回到用户主目录。
  @Test(arguments: [
    ("/tmp/work", false, "/tmp/work"),
    ("/tmp/work", true, "/home/me"),
    (nil, false, "/home/me"),
    (nil, true, "/home/me"),
    ("", false, "/home/me"),
  ] as [(String?, Bool, String)])
  func workingDirectoryFallsBackToHome(directory: String?, isRemote: Bool, expected: String) {
    let input = ToolInput(context: ToolContext(workingDirectory: directory, isRemote: isRemote))
    #expect(ScriptToolProtocol.workingDirectory(for: input, homeDirectory: "/home/me") == expected)
  }

  // MARK: 常量与错误说明

  /// 上限与超时和开发文档「脚本工具协议」一节一致。
  @Test func limitsMatchDocumentedValues() {
    #expect(ScriptToolProtocol.defaultTimeout == 10)
    #expect(ScriptToolProtocol.listTimeout == 3)
    #expect(ScriptToolProtocol.maximumTimeout == 60)
    #expect(ScriptToolProtocol.terminationGrace == 1)
    #expect(ScriptToolProtocol.stdoutLimit == 1_048_576)
    #expect(ScriptToolProtocol.stderrLimit == 65_536)
    #expect(ScriptToolProtocol.stderrDisplayLimit == 4_096)
    #expect(ScriptToolProtocol.listItemLimit == 200)
    #expect(ScriptToolProtocol.listTitleLimit == 256)
    #expect(ScriptToolProtocol.listSubtitleLimit == 512)
    #expect(ScriptToolProtocol.listValueLimit == 65_536)
    #expect(ScriptToolProtocol.listDebounce == 0.3)
  }

  /// 错误说明带上原因；退出码不带千分位；各无参数的错误说明互不相同。
  @Test func localizedMessageIncludesReasonAndStatus() {
    #expect(ScriptToolError.invalidCommand("reason-a").localizedMessage.contains("reason-a"))
    #expect(ScriptToolError.invalidListOutput("reason-b").localizedMessage.contains("reason-b"))
    #expect(ScriptToolError.launchFailed("reason-c").localizedMessage.contains("reason-c"))
    let withStderr = ScriptToolError.exitStatus(3, stderr: "bad thing").localizedMessage
    #expect(withStderr.contains("3") && withStderr.contains("bad thing"))
    let withoutStderr = ScriptToolError.exitStatus(3, stderr: "").localizedMessage
    #expect(withoutStderr.contains("3") && !withoutStderr.contains("bad thing") && withoutStderr != withStderr)
    #expect(ScriptToolError.exitStatus(1_234_567, stderr: "").localizedMessage.contains("1234567"))
    #expect(ScriptToolError.exitStatus(-1, stderr: "").localizedMessage.contains("-1"))
    let plain = [ScriptToolError.outputTooLarge, .timedOut, .cancelled].map(\.localizedMessage)
    #expect(plain.allSatisfy { !$0.isEmpty } && Set(plain).count == 3)
  }
}
