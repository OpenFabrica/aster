import Testing

@testable import AsterCore

@Test("Path= 上报解码百分号、去重并保序；非法项整条拒收")
func shellSearchPathReportParsesAndValidates() {
  #expect(
    ShellSearchPathReport(payload: "Path=/opt/homebrew/bin:/usr/bin:/Users/me/my%20tools:/usr/bin")?.directories
      == ["/opt/homebrew/bin", "/usr/bin", "/Users/me/my tools"])
  #expect(ShellSearchPathReport(payload: "Path=")?.directories == [])
  #expect(ShellSearchPathReport(payload: "Path=/usr/bin:relative/bin") == nil)
  #expect(ShellSearchPathReport(payload: "Path=/usr/bin:/evil%07bin") == nil)
  #expect(ShellSearchPathReport(payload: "Path=/usr/bin\u{7}") == nil)
  #expect(ShellSearchPathReport(payload: "Aliases=gs") == nil)
  let tooMany = "Path=" + (0...64).map { "/d\($0)" }.joined(separator: ":")
  #expect(ShellSearchPathReport(payload: tooMany) == nil)
  #expect(ShellSearchPathReport(payload: "Path=/" + String(repeating: "a", count: 8_200)) == nil)
}
