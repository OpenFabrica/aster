// 将当前终端主题映射到源码高亮与自有文字预览。
import AsterCore

struct FilePaneStyle: Equatable, Sendable {
  let theme: TerminalTheme
  var foreground: HexColor { theme.palette.foreground }
  var background: HexColor { theme.palette.renderedTerminalBackground }

  private func ansi(_ index: Int) -> String {
    (theme.palette.ansiColors.indices.contains(index)
      ? theme.palette.ansiColors[index] : foreground).displayString
  }

  /// highlight.js 的语义类别映射到当前 ANSI 色；普通字符和标点始终使用正文色。
  var sourceCSS: String {
    """
    .hljs{color:\(foreground.displayString);background:\(background.displayString)}
    .hljs-keyword,.hljs-selector-tag,.hljs-meta{color:\(ansi(5))}
    .hljs-string,.hljs-regexp,.hljs-symbol,.hljs-addition{color:\(ansi(2))}
    .hljs-number,.hljs-literal,.hljs-built_in{color:\(ansi(3))}
    .hljs-comment,.hljs-quote{color:\(ansi(8));font-style:italic}
    .hljs-type,.hljs-title.class_,.hljs-attribute,.hljs-attr{color:\(ansi(6))}
    .hljs-title,.hljs-title.function_,.hljs-section{color:\(ansi(4))}
    .hljs-deletion{color:\(ansi(1))}
    .hljs-operator,.hljs-params,.hljs-punctuation,.hljs-subst,.hljs-property,.hljs-name,.hljs-variable,.hljs-tag,.hljs-code,.hljs-formula,.hljs-bullet,.hljs-link,.hljs-template-tag,.hljs-template-variable,.hljs-doctag,.hljs-selector-id,.hljs-selector-class,.hljs-selector-pseudo,.hljs-selector-attr{color:\(foreground.displayString)}
    .hljs-emphasis{font-style:italic}.hljs-strong{font-weight:bold}.hljs-link{text-decoration:underline}
    """
  }

  /// 预览只接收经过类型校验的颜色值；不把文件内容插入 CSS。
  var previewCSS: String {
    """
    :root{color-scheme:\(theme.mode == .dark ? "dark" : "light");--file-fg:\(foreground.displayString);--file-bg:\(background.displayString)}
    html,body{color:var(--file-fg);background:var(--file-bg)}
    a{color:\(theme.palette.accent.displayString)}
    blockquote{color:\(ansi(8));border-color:\(ansi(8))}
    th,td{border-color:\(ansi(8))}
    """
  }
}
