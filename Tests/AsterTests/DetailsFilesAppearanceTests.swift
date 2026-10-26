// 用真实 Files 行核对主题颜色，并可导出明暗主题渲染证据。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("Files 图标和名称跟随当前主题的强调色与前景色")
@MainActor
func filesRowsRenderCurrentThemeColors() async throws {
  let defaults = UserDefaults(suiteName: "DetailsFilesAppearanceTests.\(UUID().uuidString)")!
  let preferences = AppPreferences(defaults: defaults)
  defer { preferences.cancelThemePreview() }
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.stop(immediately: true) }
  let client = WorkspaceInspectionClient(
    information: { _ in .init(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { directory, _ in
      [WorkspaceFileNode(path: directory + "/Sources", name: "Sources", depth: 0, isDirectory: true),
       WorkspaceFileNode(path: directory + "/README.md", name: "README.md", depth: 0, isDirectory: false)]
    })
  let controller = DetailsPanelViewController(model: model, preferences: preferences, inspectionClient: client)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.setContentSize(NSSize(width: 320, height: 400))
  controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
  window.orderFront(nil)
  defer { window.orderOut(nil); controller.setPresentationActive(false) }
  for _ in 0..<5 { await Task.yield() }
  func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
  let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" })
  for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let appearance = try #require(NSAppearance(named: appearanceName))
    let mode: TerminalThemeMode = name == "dark" ? .dark : .light
    preferences.previewTheme(TerminalThemeCatalog.resolve(
      named: name == "dark" ? "Ayu Dark" : "Ayu Light", customThemes: [], mode: mode))
    controller.synchronizeAppearanceIfNeeded()
    window.appearance = appearance
    window.setContentSize(NSSize(width: 320, height: 400))
    controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
    controller.view.needsLayout = true
    window.contentView?.layoutSubtreeIfNeeded()
    for row in 0..<2 {
      let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
      let icon = try #require(descendants(cell).compactMap { $0 as? NSImageView }.first)
      let label = try #require(descendants(cell).compactMap { $0 as? PointingHandButton }.first)
      #expect(["Sources", "README.md"].contains(label.title))
      let foreground = try #require(label.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
      appearance.performAsCurrentDrawingAppearance {
        #expect(icon.contentTintColor?.usingColorSpace(.sRGB) == AsterTheme.accent.usingColorSpace(.sRGB))
        #expect(foreground.usingColorSpace(.sRGB) == AsterTheme.ink.usingColorSpace(.sRGB))
      }
    }
    if let path = ProcessInfo.processInfo.environment["ASTER_FILES_UI_EVIDENCE_DIR"] {
      let destination = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      controller.view.displayIfNeeded()
      let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
      controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: destination.appendingPathComponent("files-\(name).png"))
    }
  }
}
