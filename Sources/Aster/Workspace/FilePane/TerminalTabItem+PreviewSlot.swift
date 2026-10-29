// Files 预览槽策略：右侧 Files 选中文件时，在中间区域只复用一个 Pane 原地换内容，
// 不再每次新拆分屏。槽身份只存在于运行态；关闭、拖走、解锁或编辑后自动视为已固定。
import AsterCore
import Foundation

/// 一次预览请求的结果，供调用方与测试判断是否真的换了内容。
enum PreviewSlotOutcome: Equatable {
  /// 新拆出了预览槽 Pane。
  case created(UUID)
  /// 原地替换了已有预览槽的内容。
  case retargeted(UUID)
  /// 不需要改动：预览槽已经显示该文件，或别的 Pane 已打开同一文件。
  case unchanged
  /// 当前标签不能使用预览槽（远端投影标签）。
  case rejected
}

extension TerminalTabItem {
  /// 返回仍然有效的预览槽 Pane ID；失效时顺带清空。
  /// 有效条件：Pane 仍在本标签布局中、是文件 Pane、只读且没有未保存内容。
  /// 用户解锁或编辑过的槽视为已固定，Files 不能再覆盖它。
  func validPreviewSlotPaneID() -> UUID? {
    guard let paneID = previewSlotPaneID else { return nil }
    guard let runtime = runtime(for: paneID),
      layout.descriptor(forPane: paneID) != nil,
      [.editor, .preview].contains(runtime.descriptor.kind),
      runtime.isReadOnly, !runtime.isDirty
    else {
      previewSlotPaneID = nil
      return nil
    }
    return paneID
  }

  /// 在预览槽中显示一个已预读的文件。没有有效槽时在活动 Pane 右侧新拆一个，但不改变
  /// 活动 Pane；已有槽时原地替换，不重建工作区视图。
  /// - Parameter browsingRoot: Files 当前浏览根目录，写入描述符的工作目录。若用文件
  ///   父目录，用户点进预览 Pane 后 Files 根目录会跟着跳走。
  @discardableResult
  func showInPreviewSlot(_ preload: FileDocumentPreload, browsingRoot: String) -> PreviewSlotOutcome {
    // 远端投影标签的布局真值在服务端，本地不能私自增删 Pane。
    guard remoteTabID == nil else { return .rejected }
    let target = preload.url.standardizedFileURL
    let slotID = validPreviewSlotPaneID()
    // 别的 Pane 已打开同一文件（可能有未保存内容）时不再另开一份只读副本，避免两份内容不一致。
    let openedElsewhere = layout.allPanes.contains { pane in
      pane.id != slotID && [.editor, .preview].contains(pane.kind)
        && pane.resourcePath.map { URL(fileURLWithPath: $0).standardizedFileURL } == target
    }
    if openedElsewhere { return .unchanged }
    // 类型规则与 `.automatic` 打开一致；可编辑类型以只读 Source 展示，固定时原地解锁即可。
    let kind: PaneKind = preload.presentationKind.supportsEditing ? .editor : .preview
    if let slotID {
      if runtime(for: slotID)?.descriptor.resourcePath.map({
        URL(fileURLWithPath: $0).standardizedFileURL
      }) == target {
        return .unchanged
      }
      let descriptor = PaneDescriptor(
        id: slotID, kind: kind, workingDirectory: browsingRoot, resourcePath: target.path)
      if replacePaneContentInPlace(slotID, with: descriptor, preload: preload, readOnly: true) {
        return .retargeted(slotID)
      }
      previewSlotPaneID = nil
    }
    let paneID = UUID()
    split(
      direction: .right,
      kind: kind,
      resourcePath: target.path,
      workingDirectory: browsingRoot,
      paneID: paneID,
      activate: false,
      preload: preload
    )
    guard let runtime = runtime(for: paneID) else { return .rejected }
    runtime.setReadOnly(true)
    previewSlotPaneID = paneID
    return .created(paneID)
  }

  /// 固定当前预览槽：它变成普通 Pane，可编辑类型解锁；下一次 Files 预览会新开槽。
  /// - Returns: 被固定的 Pane ID；没有有效槽时返回 nil。
  @discardableResult
  func pinPreviewSlot() -> UUID? {
    guard let paneID = validPreviewSlotPaneID(), let runtime = runtime(for: paneID) else {
      return nil
    }
    if runtime.descriptor.kind == .editor { runtime.setReadOnly(false) }
    previewSlotPaneID = nil
    return paneID
  }

  /// 预览槽当前显示的文件；没有有效槽时为 nil。
  var previewSlotFileURL: URL? {
    guard let paneID = validPreviewSlotPaneID() else { return nil }
    return runtime(for: paneID)?.descriptor.resourcePath.map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
  }
}
