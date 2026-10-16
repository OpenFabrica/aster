// MCP stdio 传输用的 JSON-RPC 2.0 信封。aster-memory-mcp 与 `aster mcp` 共用，
// 因此从 AsterMemoryMCP 下沉到 AsterCore；线格式与原实现逐字节一致。
import Foundation

/// JSON-RPC 2.0 请求。MCP stdio 传输为逐行 JSON；id 可能是数字或字符串。
public struct JSONRPCRequest: Decodable, Sendable {
  public let jsonrpc: String
  public let id: JSONRPCID?
  public let method: String
  public let params: JSONValue?

  /// 构造请求（测试与进程内调用用；线上请求走 Decodable）。
  public init(jsonrpc: String = "2.0", id: JSONRPCID?, method: String, params: JSONValue? = nil) {
    self.jsonrpc = jsonrpc
    self.id = id
    self.method = method
    self.params = params
  }
}

/// 请求 id 的两种合法形态。响应必须原样回传。
public enum JSONRPCID: Codable, Equatable, Sendable {
  case number(Int)
  case string(String)

  /// 先试整数再试字符串：JSON-RPC 只允许这两种 id。
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Int.self) {
      self = .number(number)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  /// 按原形态写回。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    }
  }
}

/// JSON-RPC 响应（成功或错误二选一）。
public struct JSONRPCResponse: Encodable, Sendable {
  public let jsonrpc = "2.0"
  public let id: JSONRPCID?
  public var result: JSONValue?
  public var error: JSONRPCError?

  private enum CodingKeys: String, CodingKey {
    case jsonrpc, id, result, error
  }

  /// 构造响应；`error` 非空时编码只写 error。
  public init(id: JSONRPCID?, result: JSONValue? = nil, error: JSONRPCError? = nil) {
    self.id = id
    self.result = result
    self.error = error
  }

  /// id 永远写出（缺省为 null），result 与 error 只写一个。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(jsonrpc, forKey: .jsonrpc)
    try container.encode(id, forKey: .id)
    if let error {
      try container.encode(error, forKey: .error)
    } else {
      try container.encode(result ?? .null, forKey: .result)
    }
  }
}

/// JSON-RPC 错误对象。
public struct JSONRPCError: Encodable, Equatable, Sendable {
  public let code: Int
  public let message: String

  /// 构造错误对象。
  public init(code: Int, message: String) {
    self.code = code
    self.message = message
  }
}
