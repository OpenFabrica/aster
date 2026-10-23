// agent 远程执行测试的替身：模拟 POSIX Shell 的终端、记录型批准面板与终端面板、内存审计。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 模拟远端 Shell 的终端：识别注入的探针与命令行，按 `behavior` 产出标记符与输出。
@MainActor
final class FakeShellSurface: AgentHostTerminalSurface {
  /// 一条命令在假 Shell 里的结局。
  enum Outcome {
    case complete(output: String, exitCode: Int)
    /// 打印提示后等输入；收到任意一行输入后以 0 结束。
    case prompt(String)
    /// 一直跑，直到 Ctrl-C。
    case hang(String)
  }

  var screen = "Welcome to fake\n$ "
  var isProcessRunning = true
  var acceptsInput = true
  var isAlternateScreenActive = false
  var isNativeSSHClient: Bool? = true
  var behavior: (String) -> Outcome = { _ in .complete(output: "", exitCode: 0) }
  private(set) var commands: [String] = []
  private(set) var terminated = false
  private var pendingNonce: String?

  func send(_ text: String) -> Bool {
    guard acceptsInput, isProcessRunning else { return false }
    if text == "\u{03}" {
      if pendingNonce != nil { screen += "^C\n$ " }
      pendingNonce = nil
      return true
    }
    if let nonce = Self.capture(text, #"printf '\\074aster:%s:ready\\076\\n' ([0-9a-f]{12})"#) {
      screen += "\n<aster:\(nonce):ready>\n$ "
      return true
    }
    if let nonce = Self.capture(text, #"printf '\\074aster:%s\\076\\n' ([0-9a-f]{12})b; eval"#),
      let quoted = Self.capture(text, #"eval '((?:[^']|'\\''|'"\$\(printf '(?:\\[0-7]{3})+'\)"')*)'; printf"#)
    {
      let command = Self.unquote(quoted)
      commands.append(command)
      screen += "\n<aster:\(nonce)b>\n"
      switch behavior(command) {
      case .complete(let output, let code):
        screen += (output.isEmpty ? "" : output + "\n") + "<aster:\(nonce)e:\(code)>\n$ "
      case .prompt(let prompt):
        screen += prompt
        pendingNonce = nonce
      case .hang(let output):
        screen += output
        pendingNonce = nonce
      }
      return true
    }
    // 其它输入当作用户在提示处回答。
    if let nonce = pendingNonce, screen.hasSuffix(":") {
      screen += "\n<aster:\(nonce)e:0>\n$ "
      pendingNonce = nil
    }
    return true
  }

  func readActiveScreen() -> String? { screen }
  func readScrollback(maximumLines: Int) -> String? { screen }

  func terminate() {
    terminated = true
    isProcessRunning = false
  }

  /// 还原 `AgentHostCommandFraming.quoted` 的引号内文本：`'\''` 回到 `'`，
  /// `'"$(printf '\ooo…')"'` 组按八进制解回原始字节。
  private static func unquote(_ quoted: String) -> String {
    let pattern = #"'\\''|'"\$\(printf '((?:\\[0-7]{3})+)'\)"'"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return quoted }
    var bytes: [UInt8] = []
    var cursor = quoted.startIndex
    for match in regex.matches(in: quoted, range: NSRange(quoted.startIndex..., in: quoted)) {
      guard let range = Range(match.range, in: quoted) else { continue }
      bytes += Array(quoted[cursor..<range.lowerBound].utf8)
      if let octal = Range(match.range(at: 1), in: quoted) {
        bytes += quoted[octal].split(separator: "\\").compactMap { UInt8($0, radix: 8) }
      } else {
        bytes.append(UInt8(ascii: "'"))
      }
      cursor = range.upperBound
    }
    bytes += Array(quoted[cursor...].utf8)
    return String(decoding: bytes, as: UTF8.self)
  }

  /// 正则第一个捕获组。
  private static func capture(_ text: String, _ pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}

/// 不建窗口的终端面板。
@MainActor
final class FakeTerminalPresenter: AgentHostTerminalPresenting {
  private(set) var shown = 0
  private(set) var attentions = 0
  private(set) var closed = false
  /// 当作这个终端浮窗的窗口；测试用它模拟「浮窗是 key」。
  weak var ownedWindow: NSWindow?
  /// 被关闭快捷键收起的次数。
  private(set) var hiddenByShortcut = 0
  func show(attention: Bool) {
    shown += 1
    if attention { attentions += 1 }
  }
  func refresh() {}
  func close() { closed = true }
  func ownsKeyWindow(_ keyWindow: NSWindow) -> Bool { keyWindow === ownedWindow }
  func hideForCloseShortcut() { hiddenByShortcut += 1 }
}

/// 记录型批准：按预设回答，或挂起直到测试调用 `answer`。
@MainActor
final class FakeApprovals: AgentHostApprovalPresenting {
  var onAnswer: ((AgentHostApprovalRequest, AgentHostApprovalAnswer, Bool) -> Void)?
  /// 预设回答；nil 表示不回答（等超时）。
  var nextAnswer: AgentHostApprovalAnswer?
  /// 回答前执行（模拟用户在面板挂着时改了主机等）。
  var beforeAnswer: () -> Void = {}
  private(set) var requests: [AgentHostApprovalRequest] = []
  /// 被 `dismiss` 撤掉的请求。
  private(set) var dismissed: [AgentHostApprovalRequest] = []

  func requestApproval(_ request: AgentHostApprovalRequest, timeout: Duration) async throws -> AgentHostApprovalAnswer? {
    requests.append(request)
    beforeAnswer()
    guard let answer = nextAnswer else {
      do { try await Task.sleep(for: timeout) } catch {}
      return nil
    }
    onAnswer?(request, answer, true)
    return answer
  }

  /// 模拟等待方都已超时后用户才回答。
  func answerLate(_ request: AgentHostApprovalRequest, _ answer: AgentHostApprovalAnswer) {
    onAnswer?(request, answer, false)
  }

  /// 记录被撤掉的请求（只看已登记过的）。
  func dismiss(where shouldDismiss: (AgentHostApprovalRequest) -> Bool) {
    dismissed += requests.filter(shouldDismiss)
  }
}

/// 内存审计。
@MainActor
final class MemoryAuditLog: AgentHostAuditWriting {
  private(set) var records: [AgentHostAuditRecord] = []
  func append(_ record: AgentHostAuditRecord) { records.append(record) }
  var actions: [AgentHostAuditRecord.Action] { records.map(\.action) }
}

/// 装好替身的服务与 dispatcher。
@MainActor
struct AgentHostFixture {
  var hosts: [SSHHostProfile]
  let audit = MemoryAuditLog()
  let approvals = FakeApprovals()
  let service: AgentHostService
  let dispatcher: AsterControlDispatcher
  let client = ControlFakeClient()
  /// 按主机 ID 取到的假 Shell（终端建立后才有）。
  let surfaces: SurfaceBox

  /// 可变的引用盒子：工厂闭包往里登记新建的替身。
  @MainActor
  final class SurfaceBox {
    var byHost: [UUID: FakeShellSurface] = [:]
    var presenters: [UUID: FakeTerminalPresenter] = [:]
    var configure: (FakeShellSurface) -> Void = { _ in }
    var enabled = true
    /// 当前主机列表；测试可改地址或删主机。
    var hosts: [SSHHostProfile] = []
  }

  init(hostNames: [String] = ["prod-db"], configure: @escaping (FakeShellSurface) -> Void = { _ in }) {
    hosts = [SSHHostProfile.emptyDefaults()] + hostNames.map { SSHHostProfile(name: $0, host: "\($0).example.com", user: "deploy") }
    let box = SurfaceBox()
    box.configure = configure
    surfaces = box
    let timing = AgentHostTerminal.Timing(
      poll: .milliseconds(10), connectQuiet: 0.02, probeTimeout: 0.3, probeAttempts: 2, resyncTimeout: 0.3,
      needsInputQuiet: 0.1, interruptGrace: 0.1)
    let registry = AgentHostTerminalRegistry { spec, _ in
      let surface = FakeShellSurface()
      box.configure(surface)
      box.byHost[spec.hostID] = surface
      let presenter = FakeTerminalPresenter()
      box.presenters[spec.hostID] = presenter
      let terminal = AgentHostTerminal(
        terminalID: spec.terminalID, hostID: spec.hostID, hostName: spec.hostName, target: spec.target,
        sessionKey: spec.caller.key, caller: spec.caller, surface: surface, timing: timing)
      return (terminal, presenter)
    }
    box.hosts = hosts
    let grants = AgentHostGrantStore(
      persistence: InMemoryAgentHostGrantPersistence(), audit: audit,
      hostLookup: { id in box.hosts.first { $0.id == id }.map { .init(id: id.uuidString, name: $0.name, target: $0.host) } })
    service = AgentHostService(
      dependencies: .init(
        hosts: { box.hosts }, isEnabled: { box.enabled }, grants: grants, approvals: approvals, registry: registry,
        audit: audit, user: AgentHostLocalUser(account: "tester", name: "Tester"), approvalTimeout: .milliseconds(200)))
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") {
      AsterControlDispatcher.Policy(allowSendKeys: false, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
    }
    dispatcher.agentHostService = service
  }

  /// 调一个控制方法。
  func call(_ method: String, _ params: JSONValue) async -> AsterControlResponse {
    await dispatcher.handle(controlRequest(method, params), client: client)
  }

  /// `host.exec` 的参数。
  static func exec(
    _ command: String, host: String = "prod-db", session: String = "s1", timeoutMs: Int = 3_000
  ) -> JSONValue {
    ["host": .string(host), "command": .string(command), "agent": ["session": .string(session), "client": "test"],
     "timeout_ms": .number(Double(timeoutMs))]
  }
}

/// 每次新建的独立 UserDefaults，偏好测试不碰真实设置。
func makeAgentHostTestDefaults() -> UserDefaults {
  let suite = "AgentHostTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 轮询等条件成立（最多 `timeout`）。测试并行时主线程可能很忙，固定时长的睡眠不可靠。
@MainActor
func pollUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
  }
}
