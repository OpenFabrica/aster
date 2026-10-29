// Files 预览槽的失效与固定：关闭、拖走、解锁和 pinPreviewSlot 之后槽身份都要放手。
import AsterCore
import Combine
import Foundation
import Testing

@testable import Aster

@Test("关闭或拖走预览槽后，下一次预览新建槽")
@MainActor
func closingOrDetachingSlotForgetsIt() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  guard case .created(let first) = try fixture.show("a.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  #expect(tab.closePane(id: first))
  #expect(tab.previewSlotPaneID == nil)
  guard case .created(let second) = try fixture.show("b.md") else {
    Issue.record("关闭后应重新建槽")
    return
  }
  #expect(second != first)
  let payload = try #require(tab.detachPaneForTransfer(second))
  payload.runtimes.values.forEach { $0.stop(immediately: true) }
  #expect(tab.previewSlotPaneID == nil)
  #expect(tab.validPreviewSlotPaneID() == nil)
  #expect(tab.layout.allPanes.count == 1)
}

@Test("解锁预览槽即视为固定，Files 不再覆盖它")
@MainActor
func unlockingSlotPinsIt() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  guard case .created(let slotID) = try fixture.show("a.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  tab.runtime(for: slotID)?.setReadOnly(false)
  #expect(tab.previewSlotPaneID == nil)
  #expect(tab.validPreviewSlotPaneID() == nil)
  guard case .created(let next) = try fixture.show("b.md") else {
    Issue.record("原槽固定后应新建槽")
    return
  }
  #expect(next != slotID)
  #expect(tab.layout.descriptor(forPane: slotID)?.resourcePath == fixture.url("a.swift").path)
  #expect(tab.layout.allPanes.count == 3)
}

@Test("pinPreviewSlot 解锁可编辑类型，预览类型保持只读")
@MainActor
func pinningSlotUnlocksEditorKindsOnly() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  guard case .created(let editorSlot) = try fixture.show("a.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  #expect(tab.runtime(for: editorSlot)?.descriptor.kind == .editor)
  #expect(tab.pinPreviewSlot() == editorSlot)
  #expect(tab.runtime(for: editorSlot)?.isReadOnly == false)
  #expect(tab.previewSlotPaneID == nil)
  #expect(tab.pinPreviewSlot() == nil)
  guard case .created(let imageSlot) = try fixture.show("d.png") else {
    Issue.record("固定后应新建槽")
    return
  }
  #expect(tab.runtime(for: imageSlot)?.descriptor.kind == .preview)
  #expect(tab.pinPreviewSlot() == imageSlot)
  #expect(tab.runtime(for: imageSlot)?.isReadOnly == true)
}

@Test("解锁预览槽时立即清空槽身份并发出 nil，不等懒校验")
@MainActor
func unlockingSlotClearsIdentityEagerly() throws {
  let fixture = try FilesPreviewSlotFixture()
  defer { fixture.tearDown() }
  let tab = fixture.tab
  guard case .created(let slotID) = try fixture.show("a.swift") else {
    Issue.record("第一次预览应新建槽")
    return
  }
  var changes: [UUID?] = []
  let subscription = tab.previewSlotChanged.sink { changes.append($0) }
  defer { subscription.cancel() }
  tab.runtime(for: slotID)?.setReadOnly(false)
  // 直接读存储属性而不是 validPreviewSlotPaneID()，证明是订阅立即清空的。
  #expect(tab.previewSlotPaneID == nil)
  #expect(changes == [nil])
}
