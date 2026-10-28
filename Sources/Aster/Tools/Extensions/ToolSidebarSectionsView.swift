// 垂直标签栏侧栏里的插件区块（`sidebar.section`）：每个视图一块，eyebrow 标题 + 内容（bar 的纵向列表或 panel 网页）。
// 由 WorkspaceExtensionHost 长期持有，工作区整树重建时只换父视图；视图增减只改这里的区块，
// bar 内容变化只重画列表，panel 高度变化只改约束。
import AppKit
import AsterCore

/// 侧栏插件区块的容器。只在主线程使用。
@MainActor
final class ToolSidebarSectionsView: NSStackView {
  private(set) var blocks: [ToolSidebarSectionBlock] = []
  /// eyebrow 颜色与左缘（随主题，由侧栏在每次整树重建时给）。
  private var eyebrowColor: NSColor = AsterTheme.secondaryInk
  private var eyebrowLeading: CGFloat = 10

  init() {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("tool-sidebar-sections")
    orientation = .vertical
    alignment = .width
    spacing = 0
    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.required, for: .vertical)
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 某个视图的区块。
  func block(for entryID: String) -> ToolSidebarSectionBlock? {
    blocks.first { $0.entry.id == entryID }
  }

  /// 对齐区块：声明没变的区块原样保留（只换条目），新增或声明变了的按 `make` 新建，没了的移除。
  func setEntries(_ entries: [ToolViewEntry], make: (ToolViewEntry) -> ToolSidebarSectionBlock) {
    var next: [ToolSidebarSectionBlock] = []
    for entry in entries {
      if let existing = blocks.first(where: { $0.entry.id == entry.id && $0.entry.contribution == entry.contribution }) {
        existing.entry = entry
        next.append(existing)
      } else {
        let block = make(entry)
        block.applyStyle(eyebrowColor: eyebrowColor, eyebrowLeading: eyebrowLeading)
        next.append(block)
      }
    }
    for block in blocks where !next.contains(where: { $0 === block }) { block.removeFromSuperview() }
    blocks = next
    for (index, block) in next.enumerated() {
      if index < arrangedSubviews.count, arrangedSubviews[index] === block { continue }
      block.removeFromSuperview()
      insertArrangedSubview(block, at: min(index, arrangedSubviews.count))
      block.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
  }

  /// 跟随侧栏的 eyebrow 样式。
  func applyStyle(eyebrowColor: NSColor, eyebrowLeading: CGFloat) {
    self.eyebrowColor = eyebrowColor
    self.eyebrowLeading = eyebrowLeading
    blocks.forEach { $0.applyStyle(eyebrowColor: eyebrowColor, eyebrowLeading: eyebrowLeading) }
  }

  /// 主题或外观变了：列表重新解析颜色。
  func refreshAppearance() {
    blocks.forEach { $0.listView?.refreshAppearance() }
  }

  /// 清空全部区块（窗口关闭）。
  func removeAllBlocks() {
    blocks.forEach { $0.removeFromSuperview() }
    blocks = []
  }
}

/// 侧栏里一个视图的区块：标题行 + bar 列表或 panel 容器。bar 没有项目时整块隐藏（栈不给它留位置）。
@MainActor
final class ToolSidebarSectionBlock: NSView {
  /// 标题行高度（点，未缩放），与侧栏其它 eyebrow 标题行一致。
  static let headerHeight: CGFloat = 38

  var entry: ToolViewEntry
  let titleLabel: NSTextField
  /// bar 视图的列表；panel 为 nil。
  let listView: ToolBarListView?
  /// panel 视图承载网页会话的容器；bar 为 nil。
  let panelContainer: NSView?
  private var panelHeightConstraint: NSLayoutConstraint?
  private var titleLeading: NSLayoutConstraint!
  private var contentLeading: NSLayoutConstraint?
  private var contentTrailing: NSLayoutConstraint?
  /// 当前挂在容器里的会话；会话归窗口的缓存所有，这里只弱引用。
  private(set) weak var mountedSession: ToolSessionViewController?

  /// panel 的 `panelHeight` 是点（夹取后）；bar 忽略它。
  init(entry: ToolViewEntry, panelHeight: CGFloat) {
    self.entry = entry
    titleLabel = makeLabel(entry.contribution.title, size: 10, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if entry.contribution.kind == .bar {
      listView = ToolBarListView()
      panelContainer = nil
    } else {
      listView = nil
      panelContainer = NSView()
    }
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("tool-sidebar-section-\(entry.id)")
    translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)
    let header = InterfaceScale.length(Self.headerHeight)
    titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor)
    var constraints = [
      titleLeading!,
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      titleLabel.bottomAnchor.constraint(equalTo: topAnchor, constant: header - 12),
    ]
    let content: NSView = listView ?? panelContainer!
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    let leading = content.leadingAnchor.constraint(equalTo: leadingAnchor)
    let trailing = content.trailingAnchor.constraint(equalTo: trailingAnchor)
    contentLeading = leading
    contentTrailing = trailing
    constraints += [
      leading, trailing,
      content.topAnchor.constraint(equalTo: topAnchor, constant: header),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    if let panelContainer {
      panelContainer.identifier = NSUserInterfaceItemIdentifier("tool-sidebar-panel-\(entry.id)")
      let height = panelContainer.heightAnchor.constraint(equalToConstant: panelHeight)
      panelHeightConstraint = height
      constraints.append(height)
    }
    NSLayoutConstraint.activate(constraints)
    isHidden = listView != nil
  }

  /// 不支持从 nib 解码。
  required init?(coder: NSCoder) { nil }

  /// 清单声明的侧栏面板高度：`height` 夹到 80–400，缺省 240。
  static func declaredPanelHeight(_ contribution: ToolViewContribution) -> CGFloat {
    ToolPanelSessionHost.clampedSidebarHeight(
      CGFloat(contribution.height ?? ToolViewContribution.defaultSidebarPanelHeight))
  }

  /// 当前 panel 高度（点）；bar 为 nil。
  var panelHeight: CGFloat? { panelHeightConstraint?.constant }

  /// eyebrow 与标签行文字左对齐；列表行按钮自带 5pt 内边距，往左让出这一段；panel 与标签行卡片同宽。
  func applyStyle(eyebrowColor: NSColor, eyebrowLeading: CGFloat) {
    titleLabel.textColor = eyebrowColor
    titleLeading.constant = eyebrowLeading
    if let listView {
      listView.horizontalInset = max(0, eyebrowLeading - InterfaceScale.length(5))
    } else {
      let inset = max(0, eyebrowLeading - 10)
      contentLeading?.constant = inset
      contentTrailing?.constant = -inset
    }
  }

  /// bar：换上这一段并按有无项目显隐整块。
  func render(_ segment: ToolBarSegment?) {
    guard let listView else { return }
    listView.apply(segment: segment)
    isHidden = listView.isHidden
  }

  /// panel：改高度（`ui.setHeight` 或清单变化）。只改约束，不重建视图树。
  func setPanelHeight(_ height: CGFloat) {
    guard let panelHeightConstraint, panelHeightConstraint.constant != height else { return }
    panelHeightConstraint.constant = height
  }

  /// panel：把会话视图挂进容器；已经挂着同一个会话时不动。换会话时摘下旧的（不 teardown）。
  func mount(_ session: ToolSessionViewController?) {
    guard let panelContainer else { return }
    if let mountedSession, mountedSession !== session, mountedSession.viewIfLoaded?.superview === panelContainer {
      mountedSession.view.removeFromSuperview()
    }
    mountedSession = session
    guard let session, session.view.superview !== panelContainer else { return }
    session.view.removeFromSuperview()
    panelContainer.addSubview(session.view)
    session.view.pinEdges(to: panelContainer)
  }
}
