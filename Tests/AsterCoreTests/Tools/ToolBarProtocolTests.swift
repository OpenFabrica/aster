// bar 脚本协议：stdout 项目列表的逐项校验与限额、onClick 白名单、iconFile 越界、stdin / 环境变量。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolBarProtocol")
struct ToolBarProtocolTests {
  /// 解析一段 JSON 文本。
  private func parse(
    _ json: String, pluginDirectory: URL? = nil, itemLimit: Int = ToolBarProtocol.itemLimit
  ) throws -> ToolBarOutput {
    try ToolBarProtocol.parse(Data(json.utf8), pluginDirectory: pluginDirectory, itemLimit: itemLimit)
  }

  /// 解析只含一个项目的输出，返回该项（被丢弃时为 nil）。
  private func parseItem(_ item: String, pluginDirectory: URL? = nil) throws -> ToolBarItem? {
    try parse(#"{"items": [\#(item)]}"#, pluginDirectory: pluginDirectory).items.first
  }

  /// 解析 `{"text": "x", "onClick": <click>}` 的动作；项目被丢弃时为 nil。
  private func parseAction(_ click: String) throws -> ToolBarAction? {
    try parseItem(#"{"text": "x", "onClick": \#(click)}"#)?.action
  }

  /// 临时插件目录，含 `icons/ok.svg`；结束时整体删除。
  private struct PluginSandbox {
    let root: URL
    let plugin: URL
    let outside: URL

    /// 建好 plugin 与 outside 两个目录并放入测试图标。
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("aster-bar-\(UUID().uuidString)")
      plugin = root.appendingPathComponent("plugin", isDirectory: true)
      outside = root.appendingPathComponent("outside", isDirectory: true)
      let icons = plugin.appendingPathComponent("icons", isDirectory: true)
      try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
      try Data("<svg/>".utf8).write(to: icons.appendingPathComponent("ok.svg"))
      try Data("<svg/>".utf8).write(to: outside.appendingPathComponent("evil.svg"))
    }

    /// 删除整个临时目录。
    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  // MARK: 限额

  /// 项目数、文字长度、tooltip 长度的上限；不合格的项目被丢弃、不占名额。
  @Test func parseAppliesItemCountAndTextLimits() throws {
    let many = (0..<20).map { #"{"text": "i\#($0)"}"# }.joined(separator: ",")
    let capped = try parse(#"{"items": [\#(many)]}"#)
    #expect(capped.items.count == ToolBarProtocol.itemLimit)
    #expect(capped.items.first?.text == "i0" && capped.items.last?.text == "i11")
    let listCapped = try parse(#"{"items": [\#(many)]}"#, itemLimit: ToolBarProtocol.listItemLimit)
    #expect(listCapped.items.count == 20)

    // 坏项目不占名额：前面两个坏项目被丢弃，后面仍取满 limit 个。
    let mixed = try parse(
      #"{"items": [{"nope": 1}, {"text": ""}, {"text": "a"}, {"text": "b"}, {"text": "c"}]}"#, itemLimit: 2)
    #expect(mixed.items.map(\.text) == ["a", "b"])

    // 文字：64 个字符合格，65 个丢弃，多字节字符按字符计；换行等控制字符丢弃。
    #expect(try parseItem(#"{"text": "\#(String(repeating: "长", count: 64))"}"#)?.text?.count == 64)
    #expect(try parseItem(#"{"text": "\#(String(repeating: "长", count: 65))"}"#) == nil)
    #expect(try parseItem(#"{"text": "a\nb"}"#) == nil)
    #expect(try parseItem(#"{"text": 5}"#) == nil)

    // 文字和图标至少要有一个；全空白的文字不算文字。
    #expect(try parseItem(#"{"tooltip": "只有提示"}"#) == nil)
    #expect(try parseItem(#"{"text": "   "}"#) == nil)
    #expect(try parseItem(#"{"text": "   ", "icon": "gear"}"#)?.symbol == "gear")

    // tooltip：256 个字符原样，超出截断为 256 个字符并以 … 结尾，换行保留。
    #expect(try parseItem(#"{"text": "a", "tooltip": "\#(String(repeating: "x", count: 256))"}"#)?.tooltip?.count == 256)
    let clipped = try #require(try parseItem(#"{"text": "a", "tooltip": "\#(String(repeating: "x", count: 300))"}"#)?.tooltip)
    #expect(clipped.count == 256 && clipped.hasSuffix("…"))
    #expect(try parseItem(#"{"text": "a", "tooltip": "第一行\n第二行"}"#)?.tooltip == "第一行\n第二行")
  }

  /// 项目里有不认识的键就丢弃整项；id 类型不对也丢弃。
  @Test func unknownItemKeysDropTheItem() throws {
    #expect(try parseItem(#"{"text": "a", "onclick": {"type": "refresh"}}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "extra": 1}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "id": 3}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "id": "branch"}"#)?.id == "branch")
    #expect(try parseItem(#"{"text": "a", "id": null, "tooltip": null}"#)?.text == "a")
  }

  /// icon 只接受 `^[a-z0-9.]{1,64}$`；不合格只丢图标，文字保留。
  @Test func symbolNamesAreValidated() throws {
    #expect(try parseItem(#"{"text": "a", "icon": "arrow.triangle.branch"}"#)?.symbol == "arrow.triangle.branch")
    #expect(try parseItem(#"{"text": "a", "icon": "Arrow Branch"}"#)?.symbol == nil)
    #expect(try parseItem(#"{"text": "a", "icon": "Arrow Branch"}"#)?.text == "a")
    #expect(try parseItem(#"{"text": "a", "icon": "\#(String(repeating: "a", count: 65))"}"#)?.symbol == nil)
    // 图标无效且没有文字：没有可画的内容，整项丢弃。
    #expect(try parseItem(#"{"icon": "Bad Icon"}"#) == nil)
  }

  // MARK: 动作

  /// 未知动作类型、onClick 不是对象、动作带多余的键，都丢弃整个项目。
  @Test func unknownActionTypeDropsItem() throws {
    #expect(try parseAction(#"{"type": "shell", "text": "rm -rf /"}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "onClick": {"type": "shell"}}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "onClick": "refresh"}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "onClick": {"text": "x"}}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "onClick": {"type": 3}}"#) == nil)
    #expect(try parseItem(#"{"text": "a", "onClick": {"type": "refresh", "force": true}}"#) == nil)
    // 没有 onClick 的项目是纯展示。
    #expect(try parseItem(#"{"text": "a"}"#)?.action == nil)
  }

  /// copy：text 必填、非空、≤ 64 KiB；concealed 必须是布尔。
  @Test func copyActionRules() throws {
    #expect(try parseAction(#"{"type": "copy", "text": "main"}"#) == .copy(text: "main", concealed: false))
    #expect(try parseAction(#"{"type": "copy", "text": "s", "concealed": true}"#) == .copy(text: "s", concealed: true))
    #expect(try parseAction(#"{"type": "copy"}"#) == nil)
    #expect(try parseAction(#"{"type": "copy", "text": ""}"#) == nil)
    #expect(try parseAction(#"{"type": "copy", "text": "s", "concealed": 1}"#) == nil)
    #expect(try parseAction(#"{"type": "copy", "text": "s", "mode": "insert"}"#) == nil)
    // 动作文本的 64 KiB 上限与整份 stdout 的上限相同，单项文本再长也会先触发 outputTooLarge；这里只确认长文本能过。
    #expect(try parseAction(#"{"type": "copy", "text": "\#(String(repeating: "长", count: 20_000))"}"#) != nil)
  }

  /// terminal：mode 缺省 insert，只认 insert / submit；text 规则同 copy。
  @Test func terminalActionRules() throws {
    #expect(try parseAction(#"{"type": "terminal", "text": "git pull"}"#) == .terminal(text: "git pull", mode: .insert))
    #expect(
      try parseAction(#"{"type": "terminal", "text": "ls", "mode": "submit"}"#) == .terminal(text: "ls", mode: .submit))
    #expect(try parseAction(#"{"type": "terminal", "text": "ls", "mode": "run"}"#) == nil)
    #expect(try parseAction(#"{"type": "terminal", "text": "ls", "mode": 1}"#) == nil)
    #expect(try parseAction(#"{"type": "terminal"}"#) == nil)
    #expect(try parseAction(#"{"type": "terminal", "text": ""}"#) == nil)
    #expect(try parseAction(#"{"type": "terminal", "text": "ls", "concealed": true}"#) == nil)
  }

  /// openURL：只允许带主机的 http / https。
  @Test func openURLActionRules() throws {
    #expect(
      try parseAction(#"{"type": "openURL", "url": "https://example.com/a?b=1"}"#)
        == .openURL(URL(string: "https://example.com/a?b=1")!))
    #expect(try parseAction(#"{"type": "openURL", "url": "http://localhost:8080"}"#) != nil)
    for url in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "https://", "example.com", "", "https://a b.com"] {
      #expect(try parseAction(#"{"type": "openURL", "url": "\#(url)"}"#) == nil, "\(url)")
    }
    #expect(try parseAction(#"{"type": "openURL"}"#) == nil)
    #expect(try parseAction(#"{"type": "openURL", "url": 3}"#) == nil)
  }

  /// openPanel / feature：目标必须是合法的 code；refresh 不带参数。
  @Test func panelFeatureAndRefreshActionRules() throws {
    #expect(try parseAction(#"{"type": "openPanel", "view": "status"}"#) == .openPanel(viewID: "status"))
    #expect(try parseAction(#"{"type": "openPanel", "view": "Status"}"#) == nil)
    #expect(try parseAction(#"{"type": "openPanel", "view": "../x"}"#) == nil)
    #expect(try parseAction(#"{"type": "openPanel"}"#) == nil)
    #expect(try parseAction(#"{"type": "refresh"}"#) == .refresh)
    #expect(try parseAction(#"{"type": "feature", "code": "decode"}"#) == .feature(code: "decode", text: nil))
    #expect(
      try parseAction(#"{"type": "feature", "code": "decode", "text": "abc"}"#) == .feature(code: "decode", text: "abc"))
    #expect(try parseAction(#"{"type": "feature", "code": "BAD"}"#) == nil)
    #expect(try parseAction(#"{"type": "feature", "code": "decode", "text": 1}"#) == nil)
    #expect(try parseAction(#"{"type": "feature"}"#) == nil)
  }

  // MARK: iconFile

  /// iconFile 必须解析到插件目录内的普通文件；越界、符号链接逃逸、绝对路径、`..`、扩展名不对都只丢图标。
  @Test func iconFileMustStayInsidePlugin() throws {
    let sandbox = try PluginSandbox()
    defer { sandbox.remove() }
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.plugin.appendingPathComponent("icons/link.svg").path,
      withDestinationPath: sandbox.outside.appendingPathComponent("evil.svg").path)
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.plugin.appendingPathComponent("outdir").path, withDestinationPath: sandbox.outside.path)
    try FileManager.default.createDirectory(
      at: sandbox.plugin.appendingPathComponent("dir.svg"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: sandbox.plugin.appendingPathComponent("icons/note.txt"))

    func iconFile(_ path: String, text: String = #""text": "a","#) throws -> String? {
      try parseItem(#"{\#(text) "iconFile": "\#(path)"}"#, pluginDirectory: sandbox.plugin)?.iconFile
    }
    let resolved = try #require(try iconFile("icons/ok.svg"))
    #expect(resolved.hasSuffix("/plugin/icons/ok.svg") && resolved.hasPrefix("/"))
    #expect(FileManager.default.fileExists(atPath: resolved))

    for path in [
      "icons/missing.svg", "/etc/hosts", sandbox.outside.appendingPathComponent("evil.svg").path,
      "../outside/evil.svg", "icons/../../outside/evil.svg", "icons/link.svg", "outdir/evil.svg",
      "icons/note.txt", "dir.svg", "",
    ] {
      #expect(try iconFile(path) == nil, "\(path)")
      // 文字还在，项目没有被丢弃。
      #expect(try iconFile(path) == nil && parseItem(#"{"text": "a", "iconFile": "\#(path)"}"#, pluginDirectory: sandbox.plugin)?.text == "a")
    }
    // 没有文字、iconFile 又无效：整项丢弃。
    #expect(try parseItem(#"{"iconFile": "../outside/evil.svg"}"#, pluginDirectory: sandbox.plugin) == nil)
    // 没有插件目录时一律不接受 iconFile。
    #expect(try parseItem(#"{"text": "a", "iconFile": "icons/ok.svg"}"#, pluginDirectory: nil)?.iconFile == nil)
    // 只有 iconFile 也能成项。
    #expect(try parseItem(#"{"iconFile": "icons/ok.svg"}"#, pluginDirectory: sandbox.plugin)?.iconFile != nil)
  }

  // MARK: 颜色

  /// color 只接受 `#RRGGBB` / `#RRGGBBAA` 与五个令牌；其它写法忽略颜色、保留项目。
  @Test func colorAcceptsHexAndTokensOnly() throws {
    func color(_ text: String) throws -> ToolBarColor? {
      try parseItem(#"{"text": "a", "color": "\#(text)"}"#)?.color
    }
    #expect(try color("#FF8000") == .rgba(red: 1, green: 128.0 / 255, blue: 0, alpha: 1))
    #expect(try color("#00ff0080") == .rgba(red: 0, green: 1, blue: 0, alpha: 128.0 / 255))
    for token in ToolBarColorToken.allCases {
      #expect(try color(token.rawValue) == .token(token))
    }
    for bad in ["red", "#FFF", "#GG0000", "FF0000", "#FF00000", "#FF0000FF00", "ACCENT", ""] {
      #expect(try color(bad) == nil, "\(bad)")
    }
    #expect(try parseItem(#"{"text": "a", "color": "red"}"#)?.text == "a")
    #expect(try parseItem(#"{"text": "a", "color": 5}"#)?.color == nil)
  }

  // MARK: 外层结构

  /// 空项目表示隐藏；空 / 全空白 stdout 同样视为没有项目。
  @Test func emptyItemsMeansHidden() throws {
    #expect(try parse(#"{"items": []}"#).isEmpty)
    #expect(try parse("{}").isEmpty)
    #expect(try parse(#"{"items": null}"#).isEmpty)
    #expect(try parse("").isEmpty)
    #expect(try parse(" \n\t ").isEmpty)
    let hidden = try parse(#"{"items": [], "ttl": 600}"#)
    #expect(hidden.isEmpty && hidden.ttl == 600)
  }

  /// 外层不是对象、items 不是数组、不是 JSON，都是格式错误。
  @Test func malformedOutputIsRejected() {
    for text in ["[]", "3", "\"x\"", "not json", #"{"items": "a"}"#, #"{"items": {"text": "a"}}"#, "{"] {
      #expect(throws: ToolBarError.self, "\(text)") { try parse(text) }
    }
  }

  /// ttl 只接受 5–3600 的整数；越界、小数、布尔、字符串当作没给。
  @Test func ttlIsBounded() throws {
    func ttl(_ literal: String) throws -> Int? { try parse(#"{"items": [], "ttl": \#(literal)}"#).ttl }
    #expect(try ttl("5") == 5 && ttl("30") == 30 && ttl("3600") == 3600)
    for literal in ["4", "0", "-1", "3601", "30.5", "true", "\"30\"", "null"] {
      #expect(try ttl(literal) == nil, "\(literal)")
    }
  }

  /// stdout 超过 64 KiB 整份作废；恰好 64 KiB 可以解析。
  @Test func oversizedOutputIsRejected() throws {
    let limit = ToolBarProtocol.stdoutLimit
    let prefix = #"{"items": [{"text": "a"}], "pad": ""#
    let suffix = #""}"#
    func output(bytes: Int) -> Data {
      Data((prefix + String(repeating: "x", count: bytes - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
    }
    #expect(throws: ToolBarError.outputTooLarge) {
      try ToolBarProtocol.parse(output(bytes: limit + 1), pluginDirectory: nil)
    }
    #expect(throws: ToolBarError.outputTooLarge) {
      try ToolBarProtocol.parse(Data(repeating: 0x20, count: limit + 1), pluginDirectory: nil)
    }
    let exact = try ToolBarProtocol.parse(output(bytes: limit), pluginDirectory: nil)
    #expect(exact.items.count == 1)
  }

  // MARK: stdin 与环境变量

  /// stdin 是键按字母序的 JSON：顶层 context / trigger / view，缺省值写 null，斜杠不转义。
  @Test func stdinPayloadHasViewTriggerAndContext() throws {
    let empty = ToolBarProtocol.stdinData(viewID: "branch", trigger: .initial, context: ToolBarContext())
    #expect(
      String(decoding: empty, as: UTF8.self)
        == #"{"context":{"agent":null,"appearance":"dark","branch":null,"isRemote":false,"locale":"zh-Hans","paneID":null,"tabID":null,"workingDirectory":null},"trigger":"initial","view":"branch"}"#)

    let context = ToolBarContext(
      workingDirectory: "/tmp/a b", isRemote: false, locale: "en", appearance: "light", branch: "feat/x",
      tabID: "T1", paneID: "P1", agent: ToolBarAgentContext(provider: "claude", state: "running"))
    let full = ToolBarProtocol.stdinData(viewID: "v", trigger: .activePane, context: context)
    #expect(
      String(decoding: full, as: UTF8.self)
        == #"{"context":{"agent":{"provider":"claude","state":"running"},"appearance":"light","branch":"feat/x","isRemote":false,"locale":"en","paneID":"P1","tabID":"T1","workingDirectory":"/tmp/a b"},"trigger":"activePane","view":"v"}"#)
    let object = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
    #expect(Set(object.keys) == ["context", "trigger", "view"])
  }

  /// 环境变量：ASTER_VIEW、ASTER_TRIGGER 必有，ASTER_BRANCH 只在有分支时出现；值里的 NUL 去掉。
  @Test func environmentCarriesViewTriggerAndBranch() {
    let plain = ToolBarProtocol.environment(viewID: "branch", trigger: .interval, context: ToolBarContext())
    #expect(plain == ["ASTER_VIEW": "branch", "ASTER_TRIGGER": "interval"])
    let withBranch = ToolBarProtocol.environment(
      viewID: "branch", trigger: .manual, context: ToolBarContext(branch: "ma\0in"))
    #expect(withBranch["ASTER_BRANCH"] == "main" && withBranch["ASTER_TRIGGER"] == "manual")
    let emptyBranch = ToolBarProtocol.environment(viewID: "v", trigger: .cwd, context: ToolBarContext(branch: ""))
    #expect(emptyBranch["ASTER_BRANCH"] == nil)
  }
}
