import CryptoKit
import Foundation

// OpenSSH 公钥指纹的纯计算：与 `ssh-keygen -l -E sha256` 和 aster-ssh `keys inspect` 输出一致。
// 用于加密私钥无法在不问 passphrase 的情况下解析时，靠旁边的 `.pub` 文件确认它是哪把密钥。

/// OpenSSH 公钥的 SHA256 指纹。
public enum SSHPublicKeyFingerprint {
  /// 计算一行 OpenSSH 公钥（`<类型> <base64> [注释]`）的指纹，形如 `SHA256:<base64 无填充>`。
  ///
  /// blob 必须是合法 base64，且线格式里的第一个字段（类型名）与行首类型一致；
  /// 否则返回 nil，避免把随便一段 base64 当成公钥。
  public static func sha256(publicKeyLine line: String) -> String? {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])),
      embeddedKeyType(blob) == String(fields[0])
    else { return nil }
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
  }

  /// 在 `.pub` 文件内容里找第一行能算出指纹的公钥；空行与 `#` 注释行跳过。
  public static func sha256(publicKeyFile text: String) -> String? {
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if let fingerprint = sha256(publicKeyLine: line) { return fingerprint }
    }
    return nil
  }

  /// 读出 SSH 线格式 blob 开头的类型名（uint32 大端长度 + 字节）；格式不对返回 nil。
  private static func embeddedKeyType(_ blob: Data) -> String? {
    let bytes = [UInt8](blob)
    guard bytes.count >= 4 else { return nil }
    let length = bytes[0..<4].reduce(0) { $0 << 8 | Int($1) }
    guard length > 0, length <= bytes.count - 4 else { return nil }
    return String(bytes: bytes[4..<(4 + length)], encoding: .utf8)
  }
}
