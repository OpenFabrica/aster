// 侧栏「主机」页的外壳：标题带里的分段子标签（主机 | 密钥 | 已知主机）与当前子页。
// 主机管理集中在这里；「设置 → 主机」只保留 Agent 访问。各子页是独立的 NSViewController，
// 外壳只负责切换与转发 `pageDidAppear`，不持有主机、密钥或授权的任何数据。
import AppKit
import AsterCore

/// 主机页的子页。顺序即分段控件顺序。
enum HostsHubSection: String, CaseIterable, Sendable {
  case hosts
  case keys
  case knownHosts

  /// 分段控件上的标题。
  var title: String {
    switch self {
    case .hosts: L("主机")
    case .keys: L("密钥")
    case .knownHosts: L("已知主机")
    }
  }
}

/// 子页在挂到外壳上时收到的回调（刷新数据、交出键盘焦点）。
@MainActor
protocol HostsHubPage: AnyObject {
  /// 子页变为可见时调用。
  func pageDidAppear()
}

/// 主机页外壳控制器。工作区控制器跨刷新复用同一实例，当前子页与各子页状态都保留。
@MainActor
final class HostsHubViewController: NSViewController {
  let model: AppModel
  /// 「主机」子页（卡片网格），始终存在。
  let hostsPage: HostsPageViewController
  /// 其余子页的工厂；首次切到该子页时才创建。
  private let factories: [HostsHubSection: () -> NSViewController]
  private var pages: [HostsHubSection: NSViewController] = [:]
  private(set) var section: HostsHubSection = .hosts
  let segmentedControl = NSSegmentedControl()
  private let contentView = NSView()

  /// `factories` 缺某个子页时显示占位文字；测试可注入替身。
  init(
    model: AppModel, hostsPage: HostsPageViewController,
    factories: [HostsHubSection: () -> NSViewController] = HostsHubViewController.defaultFactories()
  ) {
    self.model = model
    self.hostsPage = hostsPage
    self.factories = factories
    super.init(nibName: nil, bundle: nil)
    pages[.hosts] = hostsPage
  }

  required init?(coder: NSCoder) { nil }

  /// 生产环境的子页工厂。各子页实现落地后在这里登记。
  static func defaultFactories() -> [HostsHubSection: () -> NSViewController] {
    [
      .keys: { HostsKeysViewController() },
      .knownHosts: { KnownHostsPageViewController() },
    ]
  }

  override func loadView() {
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("hosts-hub")
    view = root
    buildLayout(in: root)
    show(section, notify: false)
  }

  /// 外壳挂到内容区时调用：同步模型请求的子页，再通知当前子页。
  func pageDidAppear() {
    if model.hostsPageSection != section {
      show(model.hostsPageSection, notify: false)
    }
    (pages[section] as? HostsHubPage)?.pageDidAppear()
  }

  /// 切到指定子页（分段控件与 `AppModel.presentHostsPage(section:)` 共用）。
  func select(_ next: HostsHubSection) {
    if model.hostsPageSection != next { model.hostsPageSection = next }
    show(next, notify: true)
  }

  // MARK: - 布局

  /// 标题带（居中分段控件）+ 子页内容区。
  private func buildLayout(in root: NSView) {
    let titleBand = WorkspaceTitleBarBackgroundView()
    segmentedControl.segmentStyle = .rounded
    segmentedControl.trackingMode = .selectOne
    segmentedControl.segmentCount = HostsHubSection.allCases.count
    for (index, item) in HostsHubSection.allCases.enumerated() {
      segmentedControl.setLabel(item.title, forSegment: index)
      segmentedControl.setWidth(0, forSegment: index)
    }
    segmentedControl.controlSize = .small
    segmentedControl.identifier = NSUserInterfaceItemIdentifier("hosts-hub-sections")
    segmentedControl.target = self
    segmentedControl.action = #selector(segmentChanged(_:))
    titleBand.addSubview(segmentedControl)
    for subview in [titleBand, contentView, segmentedControl] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
    }
    root.addSubview(titleBand)
    root.addSubview(contentView)
    NSLayoutConstraint.activate([
      titleBand.topAnchor.constraint(equalTo: root.topAnchor),
      titleBand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      titleBand.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      titleBand.heightAnchor.constraint(equalToConstant: 36),
      segmentedControl.centerXAnchor.constraint(equalTo: titleBand.centerXAnchor),
      segmentedControl.centerYAnchor.constraint(equalTo: titleBand.centerYAnchor, constant: 2),

      contentView.topAnchor.constraint(equalTo: titleBand.bottomAnchor),
      contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
  }

  /// 分段控件点击：切换子页并记到模型（下次打开主机页回到同一子页）。
  @objc private func segmentChanged(_ sender: NSSegmentedControl) {
    guard HostsHubSection.allCases.indices.contains(sender.selectedSegment) else { return }
    select(HostsHubSection.allCases[sender.selectedSegment])
  }

  /// 换下旧子页、挂上新子页；`notify` 为真时通知新子页已可见。
  private func show(_ next: HostsHubSection, notify: Bool) {
    section = next
    if let index = HostsHubSection.allCases.firstIndex(of: next) {
      segmentedControl.selectedSegment = index
    }
    let page = page(for: next)
    guard isViewLoaded else { return }
    for child in children where child !== page {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
    if page.parent !== self { addChild(page) }
    if page.view.superview !== contentView {
      contentView.addSubview(page.view)
      page.view.translatesAutoresizingMaskIntoConstraints = false
      page.view.pinEdges(to: contentView)
    }
    if notify { (page as? HostsHubPage)?.pageDidAppear() }
  }

  /// 取（必要时创建）子页；没有工厂时用占位页。
  private func page(for section: HostsHubSection) -> NSViewController {
    if let existing = pages[section] { return existing }
    let created = factories[section]?() ?? HostsHubPlaceholderViewController(section: section)
    pages[section] = created
    return created
  }
}

extension HostsPageViewController: HostsHubPage {}

/// 尚未实现的子页占位。
@MainActor
final class HostsHubPlaceholderViewController: NSViewController {
  private let section: HostsHubSection

  /// 记住子页，用于显示标题。
  init(section: HostsHubSection) {
    self.section = section
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  /// 居中显示一行说明。
  override func loadView() {
    let root = NSView()
    let label = NSTextField(labelWithString: L("「\(section.title)」页正在建设中。"))
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    view = root
  }
}
