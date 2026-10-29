// `aster mcp` 的工具目录：tools/list 的真值表（名称、说明、参数 schema、annotations）。
// 说明文字写给编程 agent 看，决定它何时调用、如何避开交互式陷阱，因此用英文且写得具体。
import Foundation

/// `aster mcp` 暴露的工具定义。顺序即 tools/list 的展示顺序。
public enum AgentHostMCPToolCatalog {
  /// 工具名常量，分发与测试共用。
  public enum Name {
    public static let listHosts = "list_hosts"
    public static let hostExec = "host_exec"
    public static let hostWait = "host_wait"
    public static let hostRead = "host_read"
    public static let hostInterrupt = "host_interrupt"
    public static let hostClose = "host_close"
    public static let listTabs = "list_tabs"
    public static let listPanes = "list_panes"
    public static let listPluginTools = "list_plugin_tools"
    public static let runPluginTool = "run_plugin_tool"
  }

  /// 单次等待的秒数区间。上限 50 s：Codex 默认 tool_timeout_sec 是 60 s，留 10 s 余量给连接与渲染。
  public static let timeoutSecondsRange = 1...50
  public static let defaultTimeoutSeconds = 40

  /// 合法工具名集合，分发前做白名单校验。
  public static let names: Set<String> = [
    Name.listHosts, Name.hostExec, Name.hostWait, Name.hostRead, Name.hostInterrupt, Name.hostClose,
    Name.listTabs, Name.listPanes, Name.listPluginTools, Name.runPluginTool,
  ]

  /// `initialize` 结果里的 `instructions`：一段总览，帮客户端决定何时启用这组工具。
  public static let instructions =
    "Aster lets you run shell commands on the user's saved SSH hosts through a persistent terminal "
    + "that the user can watch and control. Call list_hosts first, then host_exec. Each host access "
    + "is approved by the user in Aster; never ask the user for passwords or keys. "
    + "You can also list the terminal tabs and panes open in Aster (list_tabs, list_panes), and run "
    + "the user's Aster plugin commands without opening their UI (list_plugin_tools, then run_plugin_tool)."

  private static let hostProperty: JSONValue = .object([
    "type": "string",
    "description": "Exact host name or id, as returned by list_hosts.",
  ])

  private static let timeoutProperty: JSONValue = .object([
    "type": "integer",
    "minimum": .number(Double(timeoutSecondsRange.lowerBound)),
    "maximum": .number(Double(timeoutSecondsRange.upperBound)),
    "default": .number(Double(defaultTimeoutSeconds)),
    "description": .string(
      "Seconds to wait for the command to finish before returning status running "
      + "(1-\(timeoutSecondsRange.upperBound), default \(defaultTimeoutSeconds)). The command keeps "
      + "running after a timeout; continue with host_wait."),
  ])

  /// tools/list 的 JSON 载荷。
  public static var listPayload: [JSONValue] {
    [
      tool(
        name: Name.listHosts, title: "List Aster SSH hosts",
        description:
          "List the SSH hosts saved in the Aster terminal app (name, user@host:port target, group, "
          + "id, and the agent access policy when set). Call this before host_exec to find the exact "
          + "host name, and whenever a host tool reports not_found or ambiguous_target.",
        properties: [:], required: [],
        annotations: ["readOnlyHint": true, "openWorldHint": false]),
      tool(
        name: Name.hostExec, title: "Run a command on an SSH host",
        description: hostExecDescription,
        properties: [
          "host": hostProperty,
          "command": .object([
            "type": "string",
            "description": .string(
              "Shell command to run (max 16 KiB, max 4000 bytes per line). Multi-line scripts are "
              + "allowed. Use non-interactive flags."),
          ]),
          "reason": .object([
            "type": "string",
            "description": .string(
              "One short sentence telling the user why you run this; shown in the approval prompt "
              + "and the Aster window."),
          ]),
          "timeout_seconds": timeoutProperty,
        ],
        required: ["host", "command"],
        annotations: ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": true]),
      tool(
        name: Name.hostWait, title: "Wait for a running host command",
        description:
          "Keep waiting for a command that host_exec returned as running or needs_input. Returns the "
          + "same shape as host_exec, with all output since the command started. Only the session "
          + "that started the command can wait for it.",
        properties: [
          "command_id": .object([
            "type": "string",
            "description": "The command_id returned by host_exec (format c-xxxxxxxxxxxx).",
          ]),
          "timeout_seconds": timeoutProperty,
        ],
        required: ["command_id"],
        annotations: ["readOnlyHint": true, "openWorldHint": true]),
      tool(
        name: Name.hostRead, title: "Read the host terminal screen",
        description:
          "Read the last lines of your agent terminal on a host, exactly as the user sees them. Use "
          + "it to inspect a prompt or a full-screen program after needs_input, or to recover output "
          + "after a disconnect.",
        properties: [
          "host": hostProperty,
          "lines": .object([
            "type": "integer", "minimum": 1, "maximum": .number(Double(AgentHostLimits.maximumReadLines)),
            "description": .string("Number of lines to read (1-\(AgentHostLimits.maximumReadLines), default 100)."),
          ]),
        ],
        required: ["host"],
        annotations: ["readOnlyHint": true, "openWorldHint": true]),
      tool(
        name: Name.hostInterrupt, title: "Interrupt the running host command",
        description:
          "Send Ctrl-C to the command currently running in your agent terminal on a host. Use it "
          + "when a command hangs, waits for input you cannot give, or runs longer than intended.",
        properties: ["host": hostProperty],
        required: ["host"],
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]),
      tool(
        name: Name.hostClose, title: "Close the host terminal",
        description:
          "Close your agent terminal on a host when you are done with it. Shell state (cwd, "
          + "exported variables) is lost; the next host_exec opens a new terminal and may need "
          + "approval again.",
        properties: ["host": hostProperty],
        required: ["host"],
        annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": true]),
      tool(
        name: Name.listTabs, title: "List Aster tabs",
        description:
          "List the terminal tabs open in the Aster app: tab id (w1:t2), window id, pane count and title. "
          + "* marks the selected tab of each window; window_focused marks the focused window. Use the "
          + "tab id with list_panes, or with the aster CLI (aster tab focus <tab>).",
        properties: [
          "window": .object([
            "type": "string",
            "description": .string(
              "Only list tabs of this window: a window id (w1), or any tab or pane id inside it, or "
              + "current for your own window. Omit to list every window."),
          ])
        ],
        required: [],
        annotations: ["readOnlyHint": true, "openWorldHint": false]),
      tool(
        name: Name.listPanes, title: "List Aster panes",
        description:
          "List the panes open in the Aster app: pane id (w1:p3), tab id, kind, the agent or foreground "
          + "command running in it, and its working directory. * marks the focused pane of each tab. "
          + "Use the pane id with the aster CLI (aster pane read <pane>).",
        properties: [
          "tab": .object([
            "type": "string",
            "description": .string(
              "Only list panes of this tab: a tab id (w1:t2), any pane id or agent name inside it, or "
              + "current for your own tab. Omit to list every pane."),
          ])
        ],
        required: [],
        annotations: ["readOnlyHint": true, "openWorldHint": false]),
      tool(
        name: Name.listPluginTools, title: "List Aster plugin commands",
        description:
          "List the commands of the plugins installed in Aster (built-in and user plugins): id, title, "
          + "plugin, kind, and whether run_plugin_tool can run it. Commands with a web UI or that open "
          + "a terminal tab can only be used inside Aster; plugins that are disabled or need approval "
          + "cannot run until the user handles them in Aster.",
        properties: [
          "query": .object([
            "type": "string",
            "description": "Optional search words matched against titles, keywords and plugin names.",
          ])
        ],
        required: [],
        annotations: ["readOnlyHint": true, "openWorldHint": false]),
      tool(
        name: Name.runPluginTool, title: "Run an Aster plugin command",
        description:
          "Run a plugin command from list_plugin_tools without opening its UI and return its output "
          + "(text, a list of items, or just done). Script commands are the user's approved plugin "
          + "programs; they get the input on stdin and run for at most 60 seconds.",
        properties: [
          "id": .object([
            "type": "string",
            "description": "Command id as returned by list_plugin_tools (<plugin id>/<command code>).",
          ]),
          "input": .object([
            "type": "string",
            "description": "Text to process (for example a timestamp, a JWT, or a URL). Optional.",
          ]),
          "cwd": .object([
            "type": "string",
            "description": "Absolute working directory for script commands. Defaults to your own working directory.",
          ]),
        ],
        required: ["id"],
        annotations: ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": true]),
    ]
  }

  /// host_exec 的说明：写清持久 Shell、审批与交互式陷阱，这是 agent 用好这个工具的关键。
  private static let hostExecDescription =
    "Run a shell command on a saved SSH host in a persistent, stateful shell: cd, export and other "
    + "shell state persist between calls on the same host. The user approves access per host and "
    + "watches every command live in an Aster terminal. Never ask the user for passwords, "
    + "passphrases or private keys; authentication is handled by Aster. Prefer non-interactive "
    + "forms: -y / --yes, sudo -n, --no-pager, DEBIAN_FRONTEND=noninteractive, and avoid TUIs and "
    + "full-screen programs (vim, top, less, htop). Result status: completed (with exit_code), "
    + "running (call host_wait with the command_id), needs_input (the command is waiting for input; "
    + "tell the user to answer it in the Aster window, then call host_wait), interrupted, or ended. "
    + "Output is capped; long output keeps its head and tail."

  /// 组装单个工具的 JSON 定义。
  private static func tool(
    name: String, title: String, description: String, properties: [String: JSONValue],
    required: [String], annotations: [String: JSONValue]
  ) -> JSONValue {
    var annotationObject = annotations
    annotationObject["title"] = .string(title)
    return .object([
      "name": .string(name),
      "title": .string(title),
      "description": .string(description),
      "inputSchema": .object([
        "type": "object",
        "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)),
        "additionalProperties": false,
      ]),
      "annotations": .object(annotationObject),
    ])
  }
}
