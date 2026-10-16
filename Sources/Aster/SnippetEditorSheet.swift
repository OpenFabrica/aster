import AppKit
import AsterCore
import Foundation

// 命令片段编辑表单：名称、多行命令（一行一条）、标签。新建与编辑共用。
// 风格与 `SaveSSHHostSheet` 一致：NSAlert + accessoryView，有窗口时作为 sheet 展示。
// 片段保存为 `.commands` scope 的 Recipe；字段规则在 `WorkflowSnippet`，这里只负责收集与提示。

/// 命令片段的新建 / 编辑表单。
@MainActor
enum SnippetEditorSheet {
  /// 表单字段的文本值。
  struct Values: Equatable {
    var name: String
    var commandsText: String
    var tagsText: String

    /// 从已有片段预填：命令按行展开，标签用逗号连接。
    init(recipe: WorkflowRecipe) {
      name = recipe.name
      commandsText = recipe.commands.joined(separator: "\n")
      tagsText = recipe.tags.joined(separator: ", ")
    }

    init(name: String = "", commandsText: String = "", tagsText: String = "") {
      self.name = name
      self.commandsText = commandsText
      self.tagsText = tagsText
    }
  }

  /// 展示表单直到得到合法片段或用户取消。内容不合法时带着原输入重新弹出并说明原因。
  static func prompt(title: String, initial: Values, in window: NSWindow?) -> WorkflowRecipe? {
    var values = initial
    var problem: String?
    while true {
      guard let submitted = present(title: title, values: values, problem: problem, in: window) else { return nil }
      values = submitted
      do {
        return try WorkflowSnippet.make(
          name: values.name, commandsText: values.commandsText, tagsText: values.tagsText)
      } catch {
        problem = describe(error)
      }
    }
  }

  /// 把校验错误转成给用户看的一句话。
  static func describe(_ error: any Error) -> String {
    switch error {
    case WorkflowRecipeTOMLError.missingValue(let field) where field == "recipe.name":
      return L("片段名称不能为空")
    case WorkflowRecipeTOMLError.invalidStructure:
      return L("至少要有一条命令")
    case WorkflowRecipeTOMLError.valueTooLong(let field) where field == "recipe.tags",
      WorkflowRecipeTOMLError.invalidValue(let field, _) where field == "recipe.tags":
      return L("标签最多 16 个，每个不超过 32 字节，不能包含逗号或控制字符")
    case WorkflowRecipeTOMLError.valueTooLong, WorkflowRecipeTOMLError.tooManyCommands:
      return L("名称或命令过长，或命令超过 128 条")
    case WorkflowRecipeTOMLError.invalidValue:
      return L("名称和命令不能包含控制字符")
    default:
      return L("片段无效：\(error.localizedDescription)")
    }
  }

  /// 弹出一次表单；取消返回 nil。
  private static func present(title: String, values: Values, problem: String?, in window: NSWindow?) -> Values? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText =
      problem ?? L("一行一条命令。粘贴到 Pane 时不会自动回车；「运行」会先按 Recipe 规则让你检查全部命令。")
    if problem != nil { alert.alertStyle = .warning }
    alert.addButton(withTitle: L("保存"))
    alert.addButton(withTitle: L("取消"))

    let width: CGFloat = 420
    let nameField = NSTextField()
    configure(nameField, placeholder: L("名称"), identifier: "snippet-name-field")
    nameField.stringValue = values.name

    let commandsView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 140))
    commandsView.identifier = NSUserInterfaceItemIdentifier("snippet-commands-text")
    commandsView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    commandsView.isRichText = false
    // 命令里的引号与连字符必须原样保存，关掉系统的智能替换。
    commandsView.isAutomaticQuoteSubstitutionEnabled = false
    commandsView.isAutomaticDashSubstitutionEnabled = false
    commandsView.isAutomaticTextReplacementEnabled = false
    commandsView.isAutomaticSpellingCorrectionEnabled = false
    commandsView.isVerticallyResizable = true
    commandsView.autoresizingMask = [.width]
    commandsView.textContainerInset = NSSize(width: 4, height: 4)
    commandsView.string = values.commandsText
    commandsView.setAccessibilityLabel(L("命令"))
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.documentView = commandsView
    scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

    let tagsField = NSTextField()
    configure(tagsField, placeholder: L("标签，用逗号分隔（可选）"), identifier: "snippet-tags-field")
    tagsField.stringValue = values.tagsText

    let form = NSStackView(views: [nameField, scroll, tagsField])
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 6
    form.frame = NSRect(x: 0, y: 0, width: width, height: 210)
    for view in [nameField, scroll, tagsField] as [NSView] {
      view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    alert.accessoryView = form
    alert.window.initialFirstResponder = values.name.isEmpty ? nameField : commandsView

    guard run(alert, in: window) == .alertFirstButtonReturn else { return nil }
    return Values(name: nameField.stringValue, commandsText: commandsView.string, tagsText: tagsField.stringValue)
  }

  private static func configure(_ field: NSTextField, placeholder: String, identifier: String) {
    field.placeholderString = placeholder
    field.identifier = NSUserInterfaceItemIdentifier(identifier)
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityLabel(placeholder)
  }

  /// 有窗口用 sheet，无窗口退化为模态；与 `SaveSSHHostSheet` 相同。
  private static func run(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
    guard let window else { return alert.runModal() }
    alert.beginSheetModal(for: window) { response in NSApp.stopModal(withCode: response) }
    return NSApp.runModal(for: alert.window)
  }
}

/// 片段文件的定位与读写：只在 Recipes 目录里操作，只接受 `.commands` scope。
enum SnippetRecipeFiles {
  /// 片段文件读取或定位失败。
  enum FileError: Error, Equatable {
    /// 路径不在 Recipes 目录内，或不是 `.asterrecipe` 文件。
    case outsideDirectory
    /// 文件不是命令片段（布局 Recipe 不能在片段表单里编辑）。
    case notSnippet
  }

  /// 为新片段选一个不覆盖已有文件的路径：`<名称>.asterrecipe`，重名时追加 `-2`、`-3`…
  static func newURL(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
    let stem = WorkflowSnippet.fileStem(for: name)
    var candidate = directory.appendingPathComponent(stem).appendingPathExtension(WorkflowRecipeTOML.fileExtension)
    var index = 2
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(stem)-\(index)")
        .appendingPathExtension(WorkflowRecipeTOML.fileExtension)
      index += 1
    }
    return candidate
  }

  /// 校验路径位于 Recipes 目录（直接子项）且扩展名正确，返回规范化后的 URL。
  static func validatedURL(_ path: String, in directory: URL) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path,
      url.pathExtension.lowercased() == WorkflowRecipeTOML.fileExtension
    else { throw FileError.outsideDirectory }
    return url
  }

  /// 读取一个片段；不是 `.commands` scope 时抛 `.notSnippet`。
  static func loadSnippet(at url: URL) throws -> WorkflowRecipe {
    let recipe = try WorkflowRecipeTOML.load(from: url).recipe
    guard recipe.scope == .commands else { throw FileError.notSnippet }
    return recipe
  }
}
