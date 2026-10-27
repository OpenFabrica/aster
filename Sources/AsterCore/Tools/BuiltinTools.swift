// 内置原生工具：处理器标识与内置插件清单。转换纯函数在 BuiltinTextTools.swift，日期解析在 BuiltinDateParsing.swift。
import Foundation

/// 内置原生工具的处理器。原始值写在内置清单的 `action.handler` 里。
public enum ToolBuiltinHandler: String, CaseIterable, Codable, Sendable {
  case timestamp
  case base64
  case url
  case hash
  case uuid
  case ports
  case json
}

/// 内置原生工具的插件清单（id `aster.builtin`）。标题随界面语言变化，所以每次现算。
/// 关键词固定中英文各一组，不随界面语言变化：切换语言后老用户的输入习惯仍然有效。
/// match 正则只是粗筛，命中后还要经过 `BuiltinTextTools.acceptsContent` 确认，正则都容忍首尾空白。
public enum BuiltinToolCatalog {
  public static let pluginID = "aster.builtin"
  /// 时间戳：10 位秒或 13 位毫秒。
  static let timestampPattern = #"^\s*\d{10}(?:\d{3})?\s*$"#
  /// 常见日期：`2024-01-02[ 03:04[:05[.123]]][Z|±08:00]`（也可用 `/`、`.` 分隔或 `T` 连接）与 `2024年1月2日 03:04:05`。
  static let datePattern =
    #"^\s*(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2}(?:[Tt ]\s*\d{1,2}:\d{2}(?::\d{2}(?:[.,]\d{1,9})?)?)?"#
    + #"\s*(?:[Zz]|UTC|GMT|[+-]\d{2}(?::?\d{2})?)?|\d{4}年\d{1,2}月\d{1,2}日(?:\s*\d{1,2}:\d{2}(?::\d{2})?)?)\s*$"#
  /// Base64：单行或按行折断，末尾最多两个补位。用占有量词避免长输入上的回溯。
  static let base64Pattern = #"^\s*[A-Za-z0-9+/_-]++(?:\r?\n[A-Za-z0-9+/_-]++)*+={0,2}\s*$"#
  static let percentEncodedPattern = "%[0-9A-Fa-f]{2}"
  static let httpURLPattern = #"^\s*(?i:https?)://\S+\s*$"#
  static let portPattern = #"^\s*:?\d{2,5}\s*$"#
  static let jsonPattern = #"^\s*[\[{]"#

  /// 内置插件清单；`validate(source: .builtin)` 对它同样成立（有测试保证）。
  public static func manifest() -> ToolManifest {
    ToolManifest(
      id: pluginID,
      name: L("Aster 内置工具"),
      version: "1.0.0",
      features: [
        feature(
          .timestamp, title: L("时间戳转换"), subtitle: L("秒 / 毫秒 ↔ 日期"),
          keywords: ["timestamp", "ts", "unix", "epoch", "date", "时间戳", "日期", "时间"],
          match: [
            .regex(ToolRegexRule(label: L("转成日期"), pattern: timestampPattern, maxLength: 64)),
            .regex(ToolRegexRule(label: L("转成时间戳"), pattern: datePattern, maxLength: 64)),
          ]),
        feature(
          .base64, title: L("Base64 编解码"), subtitle: L("编码 · 解码"),
          keywords: ["base64", "b64", "encode", "decode", "编码", "解码"],
          match: [.regex(ToolRegexRule(label: L("Base64 解码"), pattern: base64Pattern, maxLength: 1_048_576))]),
        feature(
          .url, title: L("URL 编解码"), subtitle: L("编码 · 解码 · 拆参数"),
          keywords: ["url", "uri", "encode", "decode", "query", "编码", "解码", "参数"],
          match: [
            .regex(ToolRegexRule(label: L("URL 解码"), pattern: percentEncodedPattern, maxLength: 65_536)),
            .regex(ToolRegexRule(label: L("拆解 URL"), pattern: httpURLPattern, maxLength: 65_536)),
          ]),
        feature(
          .hash, title: L("Hash 计算"), subtitle: "MD5 · SHA-1 · SHA-256 · SHA-512",
          keywords: ["hash", "md5", "sha1", "sha256", "sha512", "digest", "哈希", "摘要"],
          match: [.text(ToolTextRule(label: L("计算 Hash"), maxLength: 1_048_576))]),
        feature(
          .uuid, title: L("UUID / 随机串"), subtitle: "UUID v4 · v7",
          keywords: ["uuid", "guid", "random", "password", "随机", "随机串", "密码", "唯一标识"]),
        feature(
          .ports, title: L("端口占用"), subtitle: L("查看监听端口与进程"),
          keywords: ["port", "ports", "lsof", "listen", "kill", "端口", "占用", "进程"],
          match: [.regex(ToolRegexRule(label: L("谁占用了这个端口"), pattern: portPattern, maxLength: 16))]),
        feature(
          .json, title: L("JSON 格式化"), subtitle: L("格式化 · 压缩 · 树视图"),
          keywords: ["json", "format", "pretty", "minify", "格式化", "压缩", "美化"],
          match: [.regex(ToolRegexRule(label: L("格式化 JSON"), pattern: jsonPattern, maxLength: 1_048_576))]),
      ])
  }

  /// 内置功能的统一构造：功能代码就是处理器的原始值。
  private static func feature(
    _ handler: ToolBuiltinHandler,
    title: String,
    subtitle: String,
    keywords: [String],
    match: [ToolMatchRule] = []
  ) -> ToolFeature {
    ToolFeature(
      code: handler.rawValue, title: title, subtitle: subtitle, keywords: keywords, match: match,
      action: .builtin(ToolBuiltinAction(handler: handler)))
  }
}

/// 结果里的一行：标签 + 值，界面上每行可单独复制。
public struct ToolResultLine: Equatable, Sendable {
  public let label: String
  public let value: String

  /// 逐字段构造。
  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

/// 随机串可用的字符集。
public enum ToolRandomAlphabet: String, CaseIterable, Sendable {
  case alphanumeric
  case hex
  case symbols
}
