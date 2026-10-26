# HighlighterSwift upstream

- Upstream: https://github.com/smittytone/HighlighterSwift
- Version: 3.1.0
- Revision: `fe7aae9c9b31d3b296fd3d2dd575e1a207bb29e0`

## Aster patch surface

`Sources/Highlighter/Highlighter.swift` 不直接访问 SwiftPM 生成的 `Bundle.module`。
它优先从 macOS App 的 `Contents/Resources/Highlighter_Highlighter.bundle` 加载资源，
并兼容 SwiftPM 命令行构建与 `.xctest` 布局。缺失资源时初始化返回 `nil`，不得在发布
App 脱离构建机后触发 `fatalError`。

`Highlighter.setTheme(css:usingFont:)` 允许调用方提供当前终端主题生成的 CSS 和字体，
复用上游解析器与 token 渲染，不修改内置 CSS，也不按固定颜色反推 token 类别。
验证入口为 `fileRenderPipelineSupportsOperatorToken`、`fileRenderPipelineUsesLightTextInDarkAppearance`
及 `FilePaneThemeAndEditorTests`。

升级上游时必须重新应用并验证该资源定位补丁，然后运行 Aster 的资源 Bundle 专项测试、
完整串行测试和 DMG 挂载后资源自检。
