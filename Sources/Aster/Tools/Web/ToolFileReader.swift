// `files.read` 的路径规范化与读取。允许列表由桥接按会话维护，这里只负责安全地读一个普通文件。
import AsterCore
import Foundation

/// `files.read` 返回内容的编码。
enum ToolFileReadEncoding: String, Sendable {
  case utf8
  case base64
}

/// 读取用户选中或作为输入传入的文件。
enum ToolFileReader {
  /// 把路径规范化成用于比对允许列表的形式：必须是绝对路径，去掉 `.`、`..` 与多余的斜杠。
  static func normalizedPath(_ path: String) -> String? {
    guard path.hasPrefix("/"), !path.unicodeScalars.contains("\0") else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  /// 读一个普通文件，超过 `maximumBytes` 报 `payload_too_large`。会阻塞，只在后台调用。
  static func read(path: String, encoding: ToolFileReadEncoding, maximumBytes: Int) throws -> String {
    let url = URL(fileURLWithPath: path)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw ToolBridgeError.failed(L("文件不存在或无法访问"))
    }
    // 只读普通文件：命名管道一打开就会一直阻塞，目录读出来也没有意义。
    guard values.isRegularFile == true else { throw ToolBridgeError.invalidParams(L("不是普通文件")) }
    if let size = values.fileSize, size > maximumBytes { throw ToolBridgeError.payloadTooLarge }
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      // 多读一个字节判断是否超限：文件可能在取属性之后又变大。
      data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    } catch {
      throw ToolBridgeError.failed(L("无法读取文件"))
    }
    guard data.count <= maximumBytes else { throw ToolBridgeError.payloadTooLarge }
    switch encoding {
    case .utf8: return String(decoding: data, as: UTF8.self)
    case .base64: return data.base64EncodedString()
    }
  }
}
