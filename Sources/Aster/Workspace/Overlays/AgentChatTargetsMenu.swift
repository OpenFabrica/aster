// Send to 原生菜单：按项目及目标类型分组，选项使用稳定值而不是菜单位置。
import AppKit
import AsterCore

/// Otty Send to 的启动目录，仅声明可启动命令，不额外宣称 hook 或历史集成能力。
enum AgentChatNewTarget: String, CaseIterable {
  case claudeCode, codex, openCode, cursorCLI, kimiCode, pi, omp, grokBuild
  case reasonix, codeBuddy, antigravity, githubCopilot

  var provider: AgentProvider? {
    switch self {
    case .antigravity: .antigravity
    case .githubCopilot: .githubCopilot
    default: AgentProvider(rawValue: rawValue)
    }
  }

  var name: String {
    switch self {
    case .reasonix: "Reasonix"
    case .codeBuddy: "CodeBuddy CLI"
    case .antigravity: "Google Antigravity CLI"
    default: provider?.displayName ?? rawValue
    }
  }

  var command: String {
    switch self {
    case .cursorCLI: "cursor-agent"
    case .reasonix: "reasonix"
    case .codeBuddy: "codebuddy"
    default: provider?.commandName ?? rawValue
    }
  }

  func launchComponents(overrides: [String: [String]]) -> [String] {
    guard let configured = overrides[provider?.rawValue ?? rawValue], let executable = configured.first,
      (try? AgentLaunchPrefix(executable: executable, arguments: Array(configured.dropFirst()))) != nil
    else { return [command] }
    return configured
  }
}

enum AgentChatTargetChoice: Equatable {
  case existing(AgentChatDestination)
  case create(AgentChatNewTarget)

  func matches(_ other: AgentChatTargetChoice) -> Bool {
    switch (self, other) {
    case (.existing(let lhs), .existing(let rhs)): lhs.paneID == rhs.paneID
    case (.create(let lhs), .create(let rhs)): lhs == rhs
    default: false
    }
  }
}

@MainActor
enum AgentChatTargetsMenu {
  /// projectPaths 由已有异步项目解析器提供；初次布局时按目录归属，解析后更新到仓库根。
  static func populate(_ popup: NSPopUpButton, presentation: AgentChatPresentation,
    projectPaths: [String: String] = [:], preservingSelection: Bool = true) {
    let selection = preservingSelection ? popup.selectedItem?.representedObject as? AgentChatTargetChoice : nil
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.minimumWidth = 420
    let headings = [L("当前项目的 Agents"), L("当前项目的终端"), L("其他 Agents"), L("其他终端")]
    let source = projectKey(presentation.workingDirectory, projectPaths: projectPaths)
    for group in headings.indices {
      let destinations = presentation.destinations.filter { destination in
        let sameProject = source != nil && projectKey(destination.workingDirectory, projectPaths: projectPaths) == source
        return (sameProject ? 0 : 2) + (destination.providerName == nil ? 1 : 0) == group
      }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
      guard !destinations.isEmpty else { continue }
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      menu.addItem(.sectionHeader(title: headings[group]))
      for destination in destinations {
        menu.addItem(item(title: destination.title, detail: destination.providerName,
          choice: .existing(destination)))
      }
    }
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    menu.addItem(.sectionHeader(title: L("创建新会话")))
    for target in AgentChatNewTarget.allCases {
      menu.addItem(item(title: L("新建 \(target.name)"), detail: target.name, choice: .create(target)))
    }
    popup.menu = menu
    let selected = selection.flatMap { selected in
      menu.items.first { ($0.representedObject as? AgentChatTargetChoice)?.matches(selected) == true }
    }
      ?? menu.items.first { $0.representedObject is AgentChatTargetChoice }
    if let selected { popup.select(selected) }
  }

  static func resolveProjects(for presentation: AgentChatPresentation) async -> [String: String] {
    let directories = Set(presentation.destinations.compactMap(\.workingDirectory)
      + [presentation.workingDirectory].compactMap { $0 })
    var result: [String: String] = [:]
    for directory in directories {
      if let project = await ProjectResolutionService.shared.project(for: directory) {
        result[directory] = project.path
      }
    }
    return result
  }

  private static func projectKey(_ directory: String?, projectPaths: [String: String]) -> String? {
    directory.map { URL(fileURLWithPath: projectPaths[$0] ?? $0).standardizedFileURL.path }
  }

  private static func item(title: String, detail: String?, choice: AgentChatTargetChoice) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.representedObject = choice
    item.indentationLevel = 1
    let label = NSMutableAttributedString(string: title,
      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    if let detail {
      label.append(NSAttributedString(string: "  " + detail,
        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    item.attributedTitle = label
    return item
  }
}
