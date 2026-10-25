import Foundation

/// Values retained by the tab naming editor, including the inactive Name/Prefix value.
/// Switching editor modes does not change the effective title until the field is submitted.
public struct TabTitleEditorState: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Sendable { case name, prefix }
  public private(set) var mode: Mode = .name
  public private(set) var name = ""
  public private(set) var prefix = ""

  public init(override: TerminalTitleOverride = .automatic) { apply(override) }

  public func text(for mode: Mode) -> String { mode == .name ? name : prefix }

  /// Name submission trims surrounding whitespace and clears Prefix. Prefix preserves spaces
  /// and the previous Name; reset clears both and returns the editor to Name.
  public mutating func apply(_ override: TerminalTitleOverride) {
    switch override {
    case .automatic:
      mode = .name
      name = ""
      prefix = ""
    case .name(let value):
      mode = .name
      if case .name(let text) = TerminalTitleOverride.name(
        value.trimmingCharacters(in: .whitespaces)).normalized() { name = text }
      else { name = "" }
      prefix = ""
    case .prefix(let value):
      mode = .prefix
      if case .prefix(let text) = TerminalTitleOverride.prefix(value).normalized() { prefix = text }
      else { prefix = "" }
    }
  }

  public var effectiveOverride: TerminalTitleOverride {
    (mode == .name ? TerminalTitleOverride.name(name) : .prefix(prefix)).normalized()
  }
}
