// 内置网页工具清单：按最终校验规则能解码，运行时会翻译的每条文案在每种语言的 Localizable.strings 里都有译文。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 仓库根目录（本文件在 `Tests/AsterTests/Tools/` 下）。
private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// `Resources/tools-builtin/<id>/aster-plugin.json` 的全部清单，按目录名排序。
private func builtinManifests() throws -> [(directory: String, manifest: ToolManifest)] {
  let base = repositoryRoot().appendingPathComponent("Resources/tools-builtin", isDirectory: true)
  let directories = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { !$0.hasPrefix(".") }.sorted()
  return try directories.map { name in
    let data = try Data(contentsOf: base.appendingPathComponent(name).appendingPathComponent(ToolManifest.fileName))
    return (name, try ToolManifest.decode(data, source: .builtin))
  }
}

@Test("内置清单按最终规则解码，目录名就是 aster. 开头的插件 id")
func builtinWebToolManifestsDecode() throws {
  let manifests = try builtinManifests()
  #expect(manifests.map(\.directory) == [
    "aster.claudebar", "aster.codexbar", "aster.color", "aster.diff", "aster.gitbar", "aster.jwt", "aster.password",
    "aster.regex", "aster.sysbar",
  ])
  for (directory, manifest) in manifests {
    #expect(manifest.id == directory)
    #expect(manifest.id.hasPrefix(ToolManifest.builtinIDPrefix))
    // 只贡献视图的插件（如 aster.gitbar）没有功能，也就不需要 ui；有功能的网页工具必须有 ui。
    if !manifest.features.isEmpty {
      #expect(manifest.ui != nil, "\(directory) 是网页工具，必须有 ui")
    }
  }
}

@Test("内置网页工具清单里运行时会翻译的文案，五种语言都有译文")
func builtinWebToolManifestTextsAreTranslated() throws {
  // 用运行时的同一个翻译入口收集原文，测试与 `localizedForBuiltin` 覆盖的字段始终一致。
  var texts: Set<String> = []
  for (_, manifest) in try builtinManifests() {
    _ = manifest.localizedForBuiltin { text in
      texts.insert(text)
      return text
    }
  }
  #expect(!texts.isEmpty)
  let localization = repositoryRoot().appendingPathComponent("Sources/Aster/Localization", isDirectory: true)
  for language in ["en", "ja", "fr", "de", "zh-Hant"] {
    let url = localization.appendingPathComponent("\(language).lproj/Localizable.strings")
    let table = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(language) 翻译表无法解析")
    for text in texts.sorted() {
      #expect(table[text]?.isEmpty == false, "\(language) 缺少内置工具文案：\(text)")
    }
  }
}
