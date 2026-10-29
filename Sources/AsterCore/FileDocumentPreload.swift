// Files 预览槽的后台预读结果：在主线程之外完成 lstat、类型判定和文本读取，
// 主线程只拿到值类型结果去创建 Pane 运行态，连续按 ↑/↓ 时不卡输入和渲染。
import Foundation

/// 预读失败的原因。只描述可恢复的文件状态，不携带底层错误对象，保证 `Sendable`。
public enum FileDocumentPreloadError: Error, Equatable, Sendable {
  /// 文本类型但读取失败（编码不是 UTF-8、权限不足等），附带系统描述供 Pane 展示。
  case unreadable(String)
  /// 超过编辑缓冲上限（10 MiB），与 `DocumentBuffer.load` 的限制一致。
  case tooLarge
}

/// 一次预读的完整结果。`document` 只对 `usesTextContent` 的类型有值；
/// 图片、PDF、富文档和二进制由 File Pane 自己的渲染路径按路径读取。
public struct FileDocumentPreload: Sendable, Equatable {
  public let url: URL
  public let presentationKind: FilePresentationKind
  public let document: Result<DocumentBuffer, FileDocumentPreloadError>?
  public let modificationDate: Date?
  public let fileSize: Int?

  public init(
    url: URL,
    presentationKind: FilePresentationKind,
    document: Result<DocumentBuffer, FileDocumentPreloadError>?,
    modificationDate: Date?,
    fileSize: Int?
  ) {
    self.url = url
    self.presentationKind = presentationKind
    self.document = document
    self.modificationDate = modificationDate
    self.fileSize = fileSize
  }

  /// 分类读取的前缀长度，与 File Pane 和 `AppModel.openResource` 的 `.automatic` 保持一致。
  public static let classificationPrefixBytes = 64 * 1_024
  /// 文本读取上限，与 `DocumentBuffer.load` 保持一致。
  public static let maximumTextBytes = 10 * 1_024 * 1_024

  /// 同步预读一个普通文件；调用方应在后台任务中执行。
  /// - Returns: 符号链接、目录、FIFO、socket、设备等非普通文件返回 `nil`，
  ///   与 Files「特殊文件不得打开或预读」的规则一致。
  public static func load(
    _ url: URL,
    trustedAgentProvider: AgentProvider? = nil
  ) -> FileDocumentPreload? {
    // 用 lstat 语义检查：符号链接本身不跟随，避免借链接读到 Files 根目录之外的文件。
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return nil }
    let fileSize = (attributes[.size] as? NSNumber)?.intValue
    let modificationDate = attributes[.modificationDate] as? Date
    let prefix = readPrefix(of: url, maximumBytes: classificationPrefixBytes)
    let kind = FileDocumentClassifier.classify(
      fileName: url.lastPathComponent,
      prefix: prefix,
      trustedAgentProvider: trustedAgentProvider
    )
    var document: Result<DocumentBuffer, FileDocumentPreloadError>?
    if kind.usesTextContent {
      if (fileSize ?? 0) > maximumTextBytes {
        document = .failure(.tooLarge)
      } else {
        do {
          document = .success(try DocumentBuffer.load(from: url))
        } catch DocumentBufferError.fileTooLarge {
          document = .failure(.tooLarge)
        } catch {
          document = .failure(.unreadable(error.localizedDescription))
        }
      }
    }
    return FileDocumentPreload(
      url: url,
      presentationKind: kind,
      document: document,
      modificationDate: modificationDate,
      fileSize: fileSize
    )
  }

  /// 读取有界前缀用于类型判定；打不开时返回空数据，由扩展名规则兜底。
  private static func readPrefix(of url: URL, maximumBytes: Int) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: maximumBytes)) ?? Data()
  }
}
