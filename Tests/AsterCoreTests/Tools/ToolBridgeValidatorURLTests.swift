// 桥接的地址与调用频率：net.fetch 的 https 与域名检查、shell.openURL 的协议检查、域名通配匹配、滑动窗口限速。
import Foundation
import Testing

@testable import AsterCore

@Suite("ToolBridgeValidatorURL")
struct ToolBridgeValidatorURLTests {
  /// 执行并返回抛出的 `ToolBridgeError`；没有抛出时返回 nil。
  private func failure(_ body: () throws -> Void) -> ToolBridgeError? {
    do {
      try body()
      return nil
    } catch {
      return error as? ToolBridgeError
    }
  }

  /// 断言 `fetchURL` 以 `invalid_params` 失败（不比较提示文案）。
  private func expectFetchRejected(_ url: String, allowed: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    var isInvalidParams = false
    if case .invalidParams? = failure({ _ = try ToolBridgeValidator.fetchURL(url, allowedHosts: allowed) }) {
      isInvalidParams = true
    }
    #expect(isInvalidParams, "\(url)", sourceLocation: sourceLocation)
  }

  // MARK: net.fetch

  /// https 且主机匹配已授权域名（精确或通配、大小写无关）时返回 URL，路径与查询原样保留。
  @Test func fetchURLAcceptsAllowedHTTPSHosts() throws {
    let exact = try ToolBridgeValidator.fetchURL("https://api.example.com/v1/items?x=1&y=%20", allowedHosts: ["api.example.com"])
    #expect(exact.absoluteString == "https://api.example.com/v1/items?x=1&y=%20")
    let wildcard = try ToolBridgeValidator.fetchURL("HTTPS://Sub.Example.COM:8443/x", allowedHosts: ["other.org", "*.example.com"])
    #expect(wildcard.host(percentEncoded: false)?.lowercased() == "sub.example.com")
    #expect(wildcard.port == 8443)
  }

  /// 拒绝：非 https、缺协议或缺主机、主机不在授权列表里、授权列表为空。
  @Test(arguments: [
    "http://api.example.com/", "ftp://api.example.com/", "file:///etc/hosts", "api.example.com/path", "//api.example.com/",
    "https://", "https:///path", "", "https://other.org/", "https://example.com/",
  ])
  func fetchURLRejectsUnsuitableAddresses(url: String) {
    expectFetchRejected(url, allowed: ["api.example.com", "*.example.com.cn"])
    expectFetchRejected(url, allowed: [])
  }

  /// 主机里有百分号编码时拒绝（解码后的主机看起来在授权列表里，实际请求可能去别处）。
  @Test func fetchURLRejectsPercentEncodedHost() {
    expectFetchRejected("https://exa%6Dple.com/", allowed: ["example.com"])
    expectFetchRejected("https://%65xample.com/", allowed: ["*.com", "example.com"])
  }

  /// `net.fetch` 允许的 HTTP 方法是固定的七个（大写）。
  @Test func fetchMethodsAreTheSevenStandardVerbs() {
    #expect(ToolBridgeValidator.fetchMethods == ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
  }

  /// 用户信息不能骗过主机检查：检查和请求用的都是 `@` 之后真正的主机。
  @Test func fetchURLChecksTheRealHostBehindUserInfo() throws {
    expectFetchRejected("https://api.example.com@evil.com/", allowed: ["api.example.com"])
    let url = try ToolBridgeValidator.fetchURL("https://evil.com@api.example.com/x", allowedHosts: ["api.example.com"])
    #expect(url.host(percentEncoded: false) == "api.example.com")
  }

  /// 解析差异不能绕过授权列表：凡是通过检查的地址，实际请求去的主机必须就是被授权的那个。
  @Test(arguments: [
    "https://api.example.com@evil.com/", "https://evil.com@api.example.com/", "https://api.example.com\\@evil.com/",
    "https://evil.com\\@api.example.com/", "https://api.example.com%2F@evil.com/", "https://api.example.com%40evil.com/",
    "https://api.example.com#@evil.com/", "https://api.example.com?@evil.com/", "https://api.example.com:443@evil.com/",
    "https://api.example.com:@evil.com/", "https://evil.com:80@api.example.com/", "https://api.example.com%00.evil.com/",
    "https://[api.example.com]/x", "https://api.example.com.:443/x", "https://API.EXAMPLE.COM/x", "https:/api.example.com/x",
  ])
  func fetchURLNeverReachesAHostOutsideTheAllowList(input: String) throws {
    for pattern in ["api.example.com", "*.example.com"] {
      let url: URL
      do {
        url = try ToolBridgeValidator.fetchURL(input, allowedHosts: [pattern])
      } catch {
        continue
      }
      var host = try #require(url.host(percentEncoded: false)).lowercased()
      if host.hasSuffix(".") { host.removeLast() }
      #expect(ToolBridgeValidator.isHostAllowed(host, patterns: [pattern]), "\(input) -> \(host)")
    }
  }

  /// 未授权域名的报错里带出主机，方便插件作者定位。
  @Test func fetchURLNamesTheUnauthorizedHost() {
    let error = failure { _ = try ToolBridgeValidator.fetchURL("https://evil.example.org/", allowedHosts: ["api.example.com"]) }
    guard case .invalidParams(let reason)? = error else {
      Issue.record("应当以 invalidParams 失败")
      return
    }
    #expect(reason.contains("evil.example.org"))
  }

  // MARK: shell.openURL

  /// 只允许有主机的 http 与 https 地址（协议不分大小写），不看域名。
  @Test(arguments: [
    ("http://example.com", true), ("https://example.com/a?b=1#c", true), ("HTTP://EXAMPLE.COM", true),
    ("https://user@example.com:8443/", true), ("ftp://example.com", false), ("file:///etc/hosts", false),
    ("mailto:a@example.com", false), ("javascript:alert(1)", false), ("example.com", false), ("//example.com", false),
    ("https://", false), ("http:///x", false), ("", false),
  ])
  func openableURLAllowsOnlyHTTPAndHTTPS(text: String, allowed: Bool) throws {
    if allowed {
      let url = try ToolBridgeValidator.openableURL(text)
      #expect(["http", "https"].contains(url.scheme?.lowercased()), "\(text)")
    } else {
      var isInvalidParams = false
      if case .invalidParams? = failure({ _ = try ToolBridgeValidator.openableURL(text) }) { isInvalidParams = true }
      #expect(isInvalidParams, "\(text)")
    }
  }

  // MARK: 域名匹配

  /// 精确匹配与通配匹配的用例：(主机, 规则, 是否放行)。
  static let wildcardCases: [(String, [String], Bool)] = [
    ("example.com", ["example.com"], true),
    ("example.org", ["example.com"], false),
    ("a.example.com", ["example.com"], false),
    ("example.com", [], false),
    ("a.example.com", ["*.example.com"], true),
    ("a.b.example.com", ["*.example.com"], true),
    ("example.com", ["*.example.com"], false),
    ("badexample.com", ["*.example.com"], false),
    (".example.com", ["*.example.com"], false),
    ("a.example.com.evil.com", ["*.example.com"], false),
    ("a.example.com", ["other.org", "x.example.com", "*.example.com"], true),
    ("anything", ["*."], false),
    ("anything", ["*"], false),
  ]

  /// 大小写与末尾点的用例：(主机, 规则, 是否放行)。
  static let normalizationCases: [(String, [String], Bool)] = [
    ("EXAMPLE.com", ["Example.COM"], true),
    ("A.Example.Com", ["*.EXAMPLE.COM"], true),
    ("example.com.", ["example.com"], true),
    ("a.example.com.", ["*.example.com"], true),
    ("example.com..", ["example.com"], false),
    ("", ["example.com", ""], false),
    (".", ["example.com", ""], false),
  ]

  /// 精确匹配与通配匹配：`*.example.com` 匹配任意层子域名，不匹配 `example.com` 本身与 `badexample.com`。
  @Test(arguments: ToolBridgeValidatorURLTests.wildcardCases)
  func isHostAllowedMatchesExactAndWildcardPatterns(host: String, patterns: [String], expected: Bool) {
    #expect(ToolBridgeValidator.isHostAllowed(host, patterns: patterns) == expected)
  }

  /// 大小写无关（主机和规则两边），忽略主机末尾的一个点；空主机与只有一个点的主机不匹配。
  @Test(arguments: ToolBridgeValidatorURLTests.normalizationCases)
  func isHostAllowedIgnoresCaseAndOneTrailingDot(host: String, patterns: [String], expected: Bool) {
    #expect(ToolBridgeValidator.isHostAllowed(host, patterns: patterns) == expected)
  }

  // MARK: 限速

  /// 默认每秒 50 次：同一时刻第 51 次被拒绝，被拒绝的调用不计入。
  @Test func rateLimiterAllowsFiftyCallsPerSecondByDefault() {
    var limiter = ToolBridgeRateLimiter()
    #expect(limiter.limit == 50 && limiter.window == 1)
    let results = (0..<52).map { _ in limiter.allow(now: 100) }
    #expect(results == Array(repeating: true, count: 50) + [false, false])
    // 窗口滑过之后全部恢复，再次可以放行满 50 次。
    let later = (0..<51).map { _ in limiter.allow(now: 105) }
    #expect(later == Array(repeating: true, count: 50) + [false])
  }

  /// 窗口是滑动的（左开右闭）：每次放行后，恰好一个窗口之前的调用不再计数。
  @Test func rateLimiterWindowSlides() {
    var limiter = ToolBridgeRateLimiter(limit: 3, window: 1)
    // 用四分之一秒的整数倍，浮点数运算精确，边界比较不受舍入影响。
    let calls: [(time: TimeInterval, allowed: Bool)] = [
      (0, true), (0.25, true), (0.5, true), (0.75, false),
      (1.0, true), (1.0, false), (1.25, true), (1.25, false), (1.5, true),
    ]
    for call in calls {
      let allowed = limiter.allow(now: call.time)
      #expect(allowed == call.allowed, "t=\(call.time)")
    }
  }

  /// 被拒绝的调用不占名额：它不会让后面的窗口更晚恢复。
  @Test func rateLimiterIgnoresRejectedCalls() {
    var limiter = ToolBridgeRateLimiter(limit: 1, window: 1)
    let results = [0, 0.5, 1, 1.5, 2].map { limiter.allow(now: $0) }
    #expect(results == [true, false, true, false, true])
  }
}
