// 由宿主绑定的运行期覆盖；共享范围由终端会话归属决定。
import AsterCore
import Combine
import Foundation

@MainActor
final class PanePrivilegesState {
  enum CaffeinateMode: Equatable { case off, forThisTask, forAllTasks }

  private(set) var privileges = PanePrivileges()
  private(set) var caffeinateMode = CaffeinateMode.off
  private var caffeinatedSessionIDs: Set<UUID> = []
  /// 在赋值完成后发布，Session 可同步应用鼠标/Bell策略而不读到旧值。
  let didChange = PassthroughSubject<Void, Never>()

  var userOverrides: [PanePrivileges.Field: Bool] { privileges.userOverrides }

  func set(_ field: PanePrivileges.Field, to value: Bool) {
    update { $0.set(field, to: value) }
  }

  func toggle(_ field: PanePrivileges.Field, inheriting configuration: AsterConfiguration) {
    set(field, to: !privileges.value(field, inheriting: configuration))
  }

  func muteSound() { update { $0.muteSound() } }
  func muteNotifications() { update { $0.muteNotifications() } }

  /// 普通任务防休眠作用于调用方给出的会话集合；完成或关闭逐个释放。
  /// 未运行时可传当前会话 ID，让下一条任务完成时撤销一次性请求。
  func setCaffeinateMode(_ mode: CaffeinateMode, sessionIDs: Set<UUID> = []) {
    caffeinateMode = mode
    caffeinatedSessionIDs = mode == .forThisTask ? sessionIDs : []
    didChange.send()
  }

  func caffeinates(sessionID: UUID) -> Bool {
    caffeinateMode == .forAllTasks
      || (caffeinateMode == .forThisTask && caffeinatedSessionIDs.contains(sessionID))
  }

  func taskFinished(sessionID: UUID) {
    guard caffeinateMode == .forThisTask, caffeinatedSessionIDs.contains(sessionID) else { return }
    caffeinatedSessionIDs.remove(sessionID)
    if caffeinatedSessionIDs.isEmpty { caffeinateMode = .off }
    didChange.send()
  }

  private func update(_ mutation: (inout PanePrivileges) -> Void) {
    mutation(&privileges)
    didChange.send()
  }
}
