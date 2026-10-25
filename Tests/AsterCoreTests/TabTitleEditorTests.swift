import AsterCore
import Foundation
import Testing

@Test func paneTitleEditorNameTrimsAndClearsPrefix() {
  var editor = TabTitleEditorState(override: .prefix("dev: "))
  editor.apply(.name("  Build  "))
  #expect(editor.name == "Build")
  #expect(editor.prefix.isEmpty)
  #expect(editor.effectiveOverride == .name("Build"))
  editor.apply(.name(" \t "))
  #expect(editor.effectiveOverride == .automatic)
}

@Test func paneTitleEditorPrefixRetainsNameAndWhitespace() throws {
  var editor = TabTitleEditorState(override: .name("Build"))
  editor.apply(.prefix("dev: "))
  #expect(editor.name == "Build")
  #expect(editor.prefix == "dev: ")
  #expect(editor.effectiveOverride == .prefix("dev: "))
  let restored = try JSONDecoder().decode(TabTitleEditorState.self,
    from: JSONEncoder().encode(editor))
  #expect(restored == editor)
  editor.apply(.prefix(""))
  #expect(editor.mode == .prefix)
  #expect(editor.name == "Build")
  #expect(editor.effectiveOverride == .automatic)
  editor.apply(.automatic)
  #expect(editor.mode == .name)
  #expect(editor.name.isEmpty && editor.prefix.isEmpty)
}

@Test func paneTitleEditorBoundsUntrustedText() {
  let editor = TabTitleEditorState(override: .name(String(repeating: "名", count: 1_000) + "\u{1b}"))
  #expect(editor.name.utf8.count <= TerminalTitleState.maximumTitleBytes)
  #expect(!editor.name.contains("\u{1b}"))
}
