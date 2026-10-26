// 主题 token、选区 Unicode 与行范围的纯行为回归。
import AppKit
import AsterCore
import Testing
import WebKit

@testable import Aster

@Test("未知语法回退当前主题纯文本，不遗留旧的高亮颜色")
func filePaneUnknownSyntaxFallsBackToThemeText() async throws {
  let theme = TerminalThemeCatalog.resolve(named: "Ayu Dark", customThemes: [], mode: .dark)
  let text = "plain content"
  let result = await FileRenderPipeline().renderSource(text, language: "aster-unknown-language", theme: theme)
  guard case .highlightedRTF(let data)? = result else { Issue.record("缺少纯文本回退"); return }
  let attributed = try NSAttributedString(data: data,
    options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
  #expect(attributed.string == text)
  let color = try #require(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
  #expect(HexColor(nsColor: color) == theme.palette.foreground)
}

@Test("源码正文和语法 token 使用当前主题色与 ANSI 色")
func filePaneHighlightUsesCurrentPalette() async throws {
  var theme = TerminalThemeCatalog.resolve(named: "Ayu Dark", customThemes: [], mode: .dark)
  theme.palette.foreground = HexColor(red: 130, green: 170, blue: 190)
  theme.palette.ansiColors[5] = HexColor(red: 200, green: 80, blue: 140)
  let text = "let plain = \"value\" + 42 // note"
  let result = await FileRenderPipeline().renderSource(text, language: "swift", theme: theme)
  guard case .highlightedRTF(let data)? = result else { Issue.record("高亮失败"); return }
  let attributed = try NSAttributedString(data: data,
    options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
  for (token, expected) in [("let", theme.palette.ansiColors[5]), ("plain", theme.palette.foreground),
    ("value", theme.palette.ansiColors[2]), ("42", theme.palette.ansiColors[3]), ("note", theme.palette.ansiColors[8])] {
    let range = (text as NSString).range(of: token)
    let color = try #require(attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
    #expect(HexColor(nsColor: color) == expected)
  }
}

@Test("文件选区按 UTF16 捕获并正确计算 CRLF 与末尾换行的行范围")
func fileChatContextCapturesUnicodeAndLineRange() {
  let text = "first\r\n😀 second\r\nthird\r\n"
  let selection = "😀 second\r\nthird\r\n"
  let context = FileChatContext.capture(path: "/tmp/current.txt", text: text,
    range: (text as NSString).range(of: selection))
  #expect(context.selection == selection)
  #expect(context.lines == 2...3)
  #expect(context.rendered(includeSelection: true).contains(selection))
  #expect(context.rendered(includeSelection: false) == "Path: /tmp/current.txt")
  #expect(FileChatContext.capture(path: "/tmp/current.txt", text: text,
    range: NSRange(location: NSNotFound, length: 1)).selection == nil)
}

@Test("会话预览的引用文字也跟随主题次要文字色")
@MainActor
func fileTranscriptQuoteUsesCurrentThemeColor() async throws {
  let theme = TerminalThemeCatalog.resolve(named: "Ayu Dark", customThemes: [], mode: .dark)
  let web = WKWebView()
  web.loadHTMLString(AgentTranscriptHTML.document(
    body: "<section class='claude'><div class='md'><blockquote>quoted text</blockquote></div></section>",
    style: FilePaneStyle(theme: theme)), baseURL: nil)
  var color = ""
  for _ in 0..<100 {
    color = (try? await web.evaluateJavaScript("(() => {const q = document.querySelector('blockquote'); return q ? getComputedStyle(q).color : '';})()") as? String) ?? ""
    if !color.isEmpty { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let expected = theme.palette.secondaryForeground
  #expect(color == "rgb(\(expected.red), \(expected.green), \(expected.blue))")
}
