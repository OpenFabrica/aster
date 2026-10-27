// 工具面板的全局快捷键（Carbon 热键，签名 'ASTL'）。不监听普通键盘输入，也不需要辅助功能授权；
// 注册失败时仍可经「窗口 → 工具面板」与命令面板打开。
import AppKit
import Carbon

/// 兼容设置键 `tools.launcherShortcut` 的取值。设置页负责禁用与 Quick Terminal 冲突的组合。
enum ToolLauncherShortcut: String, CaseIterable, Equatable {
  case none
  case optionSpace
  case controlOptionSpace

  /// 设置键与缺省值；缺省不占用任何组合键。
  static let settingKey = "tools.launcherShortcut"
  static let defaultValue = ToolLauncherShortcut.none

  /// 解析设置里的原始值；不认识的值返回 nil，由调用方按注册失败处理。
  init?(settingValue: String) {
    self.init(rawValue: settingValue)
  }

  /// Carbon 键码与修饰键；`none` 没有组合。
  var keyCombination: (keyCode: UInt32, modifiers: UInt32)? {
    switch self {
    case .none: nil
    case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
    case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
    }
  }
}

/// 热键身份。放在非隔离的命名空间里，C 回调才能直接引用（回调不能捕获上下文）。
private enum ToolLauncherHotKeyID {
  /// 'ASTL'。Quick Terminal 用 'ASTQ'，两者装在同一个应用事件目标上。
  static let signature: OSType = 0x4153_544C
  static let id: UInt32 = 1
}

/// 注册与释放工具面板热键。所有方法都在主线程调用。
@MainActor
final class ToolLauncherHotKey {
  private var reference: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var registeredShortcut: ToolLauncherShortcut?
  /// 用户按下热键。
  var onPress: (() -> Void)?

  /// 释放时注销热键与事件处理器。
  isolated deinit { stop() }

  /// 按设置值注册；与已注册的组合相同时不重复注册。返回 Carbon 状态码，非 `noErr` 表示失败。
  func configure(settingValue: String) -> OSStatus {
    guard let shortcut = ToolLauncherShortcut(settingValue: settingValue) else {
      stop()
      return OSStatus(paramErr)
    }
    if registeredShortcut == shortcut { return noErr }
    stop()
    guard let combination = shortcut.keyCombination else {
      registeredShortcut = shortcut
      return noErr
    }
    var event = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    // 同一个应用事件目标上还挂着 Quick Terminal 的 handler：签名不是自己的必须返回
    // eventNotHandledErr，事件才会继续传给下一个 handler，否则会吞掉对方的热键。
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        var identifier = EventHotKeyID()
        guard let event,
          GetEventParameter(
            event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
            &identifier) == noErr,
          identifier.signature == ToolLauncherHotKeyID.signature,
          identifier.id == ToolLauncherHotKeyID.id
        else { return OSStatus(eventNotHandledErr) }
        guard let context else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated {
          Unmanaged<ToolLauncherHotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
        }
        return noErr
      }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else {
      stop()
      return status
    }
    let result = RegisterEventHotKey(
      combination.keyCode, combination.modifiers,
      EventHotKeyID(signature: ToolLauncherHotKeyID.signature, id: ToolLauncherHotKeyID.id),
      GetApplicationEventTarget(), 0, &reference)
    if result == noErr { registeredShortcut = shortcut } else { stop() }
    return result
  }

  /// 应用结束或配置变化时释放系统注册，重复调用无副作用。
  func stop() {
    if let reference { UnregisterEventHotKey(reference) }
    if let handler { RemoveEventHandler(handler) }
    reference = nil
    handler = nil
    registeredShortcut = nil
  }
}
