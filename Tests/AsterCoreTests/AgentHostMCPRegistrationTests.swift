// AgentHostMCPRegistration：从客户端配置取已登记的 aster 命令，并判断是否会失效。
import AsterCore
import Foundation
import Testing

@Test func claudeCommandReadsUserScopedServer() {
  let json = #"{"mcpServers":{"aster":{"type":"stdio","command":"/usr/local/bin/aster","args":["mcp"]}},"projects":{}}"#
  #expect(AgentHostMCPRegistration.claudeCommand(fromJSON: Data(json.utf8)) == "/usr/local/bin/aster")
  #expect(AgentHostMCPRegistration.claudeCommand(fromJSON: Data(#"{"mcpServers":{}}"#.utf8)) == nil)
  #expect(AgentHostMCPRegistration.claudeCommand(fromJSON: Data("not json".utf8)) == nil)
}

@Test func codexCommandReadsOnlyAsterSection() {
  let toml = """
    [mcp_servers.other]
    command = "/bin/other"

    [mcp_servers.aster]
    command = "/Users/me/dist/Aster.app/Contents/MacOS/aster-cli"
    args = ["mcp"]

    [projects."/tmp"]
    trust_level = "trusted"
    """
  #expect(AgentHostMCPRegistration.codexCommand(fromTOML: toml) == "/Users/me/dist/Aster.app/Contents/MacOS/aster-cli")
  #expect(AgentHostMCPRegistration.codexCommand(fromTOML: "[mcp_servers.aster]\ncommand = '/opt/a b'\n") == "/opt/a b")
  #expect(AgentHostMCPRegistration.codexCommand(fromTOML: "[mcp_servers.aster]\ncommand = \"/x/\\\"q\\\"\"\n") == "/x/\"q\"")
  #expect(AgentHostMCPRegistration.codexCommand(fromTOML: "[mcp_servers.other]\ncommand = \"/a\"\n") == nil)
}

@Test func statusFlagsBundlePathsAndMissingFiles() {
  let exists: (String) -> Bool = { $0 != "/gone/aster-cli" }
  let bundle = "/Users/me/aster-agent-hosts/dist/Aster.app/Contents/MacOS/aster-cli"
  // 已装稳定命令：只有完全等于稳定路径才算正常。
  #expect(AgentHostMCPRegistration.status(command: "/usr/local/bin/aster", stablePath: "/usr/local/bin/aster", isExecutable: exists) == .ok)
  #expect(AgentHostMCPRegistration.status(command: bundle, stablePath: "/usr/local/bin/aster", isExecutable: exists) == .needsRepair)
  // 没装稳定命令：包内路径或已不存在的路径都要修复。
  #expect(AgentHostMCPRegistration.status(command: bundle, stablePath: nil, isExecutable: exists) == .needsRepair)
  #expect(AgentHostMCPRegistration.status(command: "/gone/aster-cli", stablePath: nil, isExecutable: exists) == .needsRepair)
  #expect(AgentHostMCPRegistration.status(command: nil, stablePath: "/usr/local/bin/aster", isExecutable: exists) == .notRegistered)
}
