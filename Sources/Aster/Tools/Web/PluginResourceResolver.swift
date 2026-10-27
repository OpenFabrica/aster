// `aster-plugin://<id>/<path>` 的资源解析：把请求地址映射成插件目录里的普通文件，给出 MIME 与安全响应头。
// 这里只有纯函数和可在后台调用的文件读取；WebKit 接线在 `PluginSchemeHandler`。
import AsterCore
import Foundation

/// 插件资源请求失败的原因。
enum PluginResourceFailure: Error, Equatable, Sendable {
  /// 地址不属于本插件：scheme、host 不对，或带了端口、用户信息。
  case foreignURL
  /// 路径含 `..`、`.`、隐藏段、空段、编码后的分隔符或控制字符。
  case forbiddenPath
  /// 解析符号链接后落到了插件目录之外。
  case outsideRoot
  /// 文件不存在，或者不是普通文件（目录、管道等）。
  case notFound
  /// 文件存在但读取失败。
  case unreadable

  /// 对应的 HTTP 状态码。
  var statusCode: Int {
    switch self {
    case .foreignURL, .forbiddenPath, .outsideRoot: 403
    case .notFound: 404
    case .unreadable: 500
    }
  }
}

/// 一次资源加载的结果。只含值类型，可以从后台交回主线程。
struct PluginResourceResponse: Equatable, Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data
}

/// 插件资源解析的纯函数集合。
enum PluginResourceResolver {
  /// 编码后路径的长度上限，防止异常长的地址进入文件系统调用。
  static let maximumEncodedPathBytes = 2_048

  /// 扩展名到 Content-Type。文本类型带 charset，避免浏览器按其它编码猜。
  private static let contentTypes: [String: String] = [
    "html": "text/html; charset=utf-8",
    "js": "text/javascript; charset=utf-8",
    "mjs": "text/javascript; charset=utf-8",
    "css": "text/css; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "map": "application/json; charset=utf-8",
    "txt": "text/plain; charset=utf-8",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "ico": "image/x-icon",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "ttf": "font/ttf",
    "otf": "font/otf",
    "wasm": "application/wasm",
  ]

  /// 未知扩展名的 Content-Type；配合 `nosniff`，浏览器不会把它当脚本或页面执行。
  static let fallbackContentType = "application/octet-stream"

  /// 从请求地址取出插件内的相对路径（逐段百分号解码后用 `/` 连接）。只做字符串检查，不访问文件系统。
  static func relativePath(of url: URL, pluginID: String) throws(PluginResourceFailure) -> String {
    // host 必须逐字等于插件 id：每个 WebView 的 scheme handler 只服务一个插件，
    // 大小写不同或带端口、用户信息的地址都按外来地址拒绝。
    guard url.scheme?.lowercased() == ToolBridgeProtocol.scheme,
      url.host(percentEncoded: false) == pluginID,
      url.port == nil, url.user == nil, url.password == nil
    else { throw .foreignURL }
    let encodedPath = url.path(percentEncoded: true)
    guard encodedPath.hasPrefix("/"), encodedPath.utf8.count <= maximumEncodedPathBytes else {
      throw .forbiddenPath
    }
    // 先按原始 `/` 切段、再逐段解码：`%2F` 解码出的斜杠因此留在段内并被拒绝，
    // `%2e%2e` 解码成 `..` 同样被拒绝，WebKit 是否预先规范化都不影响结论。
    var segments: [String] = []
    for raw in encodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      guard let segment = String(raw).removingPercentEncoding, isAllowedSegment(segment) else {
        throw .forbiddenPath
      }
      segments.append(segment)
    }
    return segments.joined(separator: "/")
  }

  /// 单个路径段是否可以访问：非空、不是 `.`/`..`、不以 `.` 开头（隐藏文件）、不含分隔符与控制字符。
  static func isAllowedSegment(_ segment: String) -> Bool {
    guard !segment.isEmpty, !segment.hasPrefix(".") else { return false }
    return !segment.unicodeScalars.contains { scalar in
      scalar == "/" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar)
    }
  }

  /// 把相对路径解析成插件目录内的普通文件。会访问文件系统，不要在主线程调用。
  static func resolveFile(relativePath: String, root: URL) throws(PluginResourceFailure) -> URL {
    // 根目录与候选文件用同一个函数解析符号链接再比较前缀：`resolvingSymlinksInPath`
    // 会去掉 `/private` 前缀，两边一致处理才不会把合法文件误判成越界。
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = resolvedRoot.appendingPathComponent(relativePath, isDirectory: false)
      .standardizedFileURL.resolvingSymlinksInPath()
    guard candidate.path.hasPrefix(resolvedRoot.path + "/") else { throw .outsideRoot }
    // 不存在的文件取属性会抛错，目录、管道等取到 isRegularFile == false，统一按找不到处理。
    let values: URLResourceValues
    do {
      values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
    } catch {
      throw .notFound
    }
    guard values.isRegularFile == true else { throw .notFound }
    return candidate
  }

  /// 按扩展名给 Content-Type（大小写无关）；未知扩展名返回 `fallbackContentType`。
  static func contentType(forPath path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    return contentTypes[ext] ?? fallbackContentType
  }

  /// 每个响应都带的头：CSP、Content-Type、禁止 MIME 嗅探、禁止缓存（开发目录热重载要拿到新文件），
  /// 并关闭 DNS 预取——CSP 管不到 `<link rel="dns-prefetch">`，否则页面能把数据编进域名发出去。
  static func headers(contentType: String, contentLength: Int) -> [String: String] {
    [
      "Content-Security-Policy": ToolBridgeProtocol.contentSecurityPolicy,
      "Content-Type": contentType,
      "Content-Length": String(contentLength),
      "X-Content-Type-Options": "nosniff",
      "Cache-Control": "no-store",
      "X-DNS-Prefetch-Control": "off",
    ]
  }

  /// 失败时的响应：纯文本正文，仍然带全部安全头。
  static func failureResponse(_ failure: PluginResourceFailure) -> PluginResourceResponse {
    let body = Data(HTTPURLResponse.localizedString(forStatusCode: failure.statusCode).utf8)
    return PluginResourceResponse(
      statusCode: failure.statusCode,
      headers: headers(contentType: "text/plain; charset=utf-8", contentLength: body.count),
      body: body)
  }

  /// 完整加载一个请求：解析地址、定位文件、读取内容。会访问文件系统，只在后台调用。
  static func load(url: URL?, pluginID: String, root: URL) -> PluginResourceResponse {
    guard let url else { return failureResponse(.foreignURL) }
    do throws(PluginResourceFailure) {
      let relative = try relativePath(of: url, pluginID: pluginID)
      let file = try resolveFile(relativePath: relative, root: root)
      let body: Data
      do {
        body = try Data(contentsOf: file, options: .mappedIfSafe)
      } catch {
        throw .unreadable
      }
      return PluginResourceResponse(
        statusCode: 200,
        headers: headers(contentType: contentType(forPath: file.path), contentLength: body.count),
        body: body)
    } catch {
      return failureResponse(error)
    }
  }
}
