// `aster-plugin://` 资源解析：路径越界、隐藏文件、符号链接、错误 host、MIME 与安全响应头。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

private let pluginID = "com.example.webtest"

/// 解析一个地址字符串的相对路径，失败时返回错误。
private func resolve(_ text: String) -> Result<String, PluginResourceFailure> {
  guard let url = URL(string: text) else { return .failure(.foreignURL) }
  do throws(PluginResourceFailure) {
    return .success(try PluginResourceResolver.relativePath(of: url, pluginID: pluginID))
  } catch {
    return .failure(error)
  }
}

@Test("普通路径与多级路径解析成相对路径，百分号编码逐段解码")
func pluginResourceAcceptsOrdinaryPaths() {
  #expect(resolve("aster-plugin://com.example.webtest/index.html") == .success("index.html"))
  #expect(resolve("aster-plugin://com.example.webtest/assets/app.js?v=1#top") == .success("assets/app.js"))
  #expect(resolve("aster-plugin://com.example.webtest/my%20file.txt") == .success("my file.txt"))
}

@Test("拒绝 ..、编码的 ..、编码的斜杠、隐藏段、空段与目录")
func pluginResourceRejectsTraversalAndHiddenSegments() {
  for text in [
    "aster-plugin://com.example.webtest/../etc/passwd",
    "aster-plugin://com.example.webtest/a/%2e%2e/%2E%2E/etc/passwd",
    "aster-plugin://com.example.webtest/.%2e/secret",
    "aster-plugin://com.example.webtest/a%2F..%2Fb",
    "aster-plugin://com.example.webtest/.git/config",
    "aster-plugin://com.example.webtest/.DS_Store",
    "aster-plugin://com.example.webtest/assets/",
    "aster-plugin://com.example.webtest//index.html",
    "aster-plugin://com.example.webtest/",
    "aster-plugin://com.example.webtest/a%00b.js",
  ] {
    #expect(resolve(text) == .failure(.forbiddenPath), "\(text)")
  }
}

@Test("别的插件、大小写不同的 host、端口、用户信息与其它 scheme 都按外来地址拒绝")
func pluginResourceRejectsForeignURLs() {
  for text in [
    "aster-plugin://com.example.other/index.html",
    "aster-plugin://Com.Example.WebTest/index.html",
    "aster-plugin://com.example.webtest:8080/index.html",
    "aster-plugin://user@com.example.webtest/index.html",
    "https://com.example.webtest/index.html",
    "file:///etc/passwd",
  ] {
    #expect(resolve(text) == .failure(.foreignURL), "\(text)")
  }
}

@Test("符号链接解析后越出插件目录的拒绝，目录内的放行；目录与不存在的文件按找不到处理")
func pluginResourceResolvesSymlinksInsideRootOnly() throws {
  let outside = try makeTemporaryPluginDirectory(files: ["secret.txt": "secret"])
  let root = try makeTemporaryPluginDirectory(files: ["index.html": "<p>hi</p>", "assets/app.js": "1"])
  defer {
    try? FileManager.default.removeItem(at: outside)
    try? FileManager.default.removeItem(at: root)
  }
  let fileManager = FileManager.default
  try fileManager.createSymbolicLink(
    at: root.appendingPathComponent("leak.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
  try fileManager.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
  try fileManager.createSymbolicLink(
    at: root.appendingPathComponent("alias.html"), withDestinationURL: root.appendingPathComponent("index.html"))

  #expect(throws: PluginResourceFailure.outsideRoot) {
    try PluginResourceResolver.resolveFile(relativePath: "leak.txt", root: root)
  }
  #expect(throws: PluginResourceFailure.outsideRoot) {
    try PluginResourceResolver.resolveFile(relativePath: "linked/secret.txt", root: root)
  }
  let alias = try PluginResourceResolver.resolveFile(relativePath: "alias.html", root: root)
  #expect(alias.lastPathComponent == "index.html")
  #expect(throws: PluginResourceFailure.notFound) {
    try PluginResourceResolver.resolveFile(relativePath: "assets", root: root)
  }
  #expect(throws: PluginResourceFailure.notFound) {
    try PluginResourceResolver.resolveFile(relativePath: "missing.js", root: root)
  }
}

@Test("按扩展名给 MIME，大小写无关，未知类型回退 octet-stream")
func pluginResourceContentTypes() {
  #expect(PluginResourceResolver.contentType(forPath: "index.html") == "text/html; charset=utf-8")
  #expect(PluginResourceResolver.contentType(forPath: "a/APP.JS") == "text/javascript; charset=utf-8")
  #expect(PluginResourceResolver.contentType(forPath: "m.mjs") == "text/javascript; charset=utf-8")
  #expect(PluginResourceResolver.contentType(forPath: "s.css") == "text/css; charset=utf-8")
  #expect(PluginResourceResolver.contentType(forPath: "i.svg") == "image/svg+xml")
  #expect(PluginResourceResolver.contentType(forPath: "p.jpeg") == "image/jpeg")
  #expect(PluginResourceResolver.contentType(forPath: "f.woff2") == "font/woff2")
  #expect(PluginResourceResolver.contentType(forPath: "w.wasm") == "application/wasm")
  #expect(PluginResourceResolver.contentType(forPath: "x.map") == "application/json; charset=utf-8")
  #expect(PluginResourceResolver.contentType(forPath: "bin.exe") == "application/octet-stream")
  #expect(PluginResourceResolver.contentType(forPath: "README") == "application/octet-stream")
}

@Test("成功与失败的响应都带 CSP、nosniff 与 no-store")
func pluginResourceResponsesCarrySecurityHeaders() throws {
  let root = try makeTemporaryPluginDirectory(files: ["index.html": "<p>hi</p>"])
  defer { try? FileManager.default.removeItem(at: root) }

  let ok = PluginResourceResolver.load(
    url: URL(string: "aster-plugin://com.example.webtest/index.html"), pluginID: pluginID, root: root)
  #expect(ok.statusCode == 200)
  #expect(ok.body == Data("<p>hi</p>".utf8))
  #expect(ok.headers["Content-Type"] == "text/html; charset=utf-8")

  let missing = PluginResourceResolver.load(
    url: URL(string: "aster-plugin://com.example.webtest/missing.html"), pluginID: pluginID, root: root)
  #expect(missing.statusCode == 404)
  let forbidden = PluginResourceResolver.load(
    url: URL(string: "aster-plugin://com.example.webtest/.hidden"), pluginID: pluginID, root: root)
  #expect(forbidden.statusCode == 403)

  for response in [ok, missing, forbidden] {
    #expect(response.headers["Content-Security-Policy"] == ToolBridgeProtocol.contentSecurityPolicy)
    #expect(response.headers["X-Content-Type-Options"] == "nosniff")
    #expect(response.headers["Cache-Control"] == "no-store")
    #expect(response.headers["X-DNS-Prefetch-Control"] == "off")
  }
}
