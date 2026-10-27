// 内置文本工具的 Hash、UUID 与随机串：已知向量、格式位、长度上限与字符集。
import Foundation
import Testing

@testable import AsterCore

@Suite("BuiltinTextToolsGenerator")
struct BuiltinTextToolsGeneratorTests {
  // MARK: Hash

  /// 四种 Hash 按固定顺序给出，值是小写十六进制；用 "abc" 的标准向量核对。
  @Test func hashesMatchKnownVectorsForABC() {
    let lines = BuiltinTextTools.hashes(of: Data("abc".utf8))
    #expect(lines.map(\.label) == ["MD5", "SHA-1", "SHA-256", "SHA-512"])
    #expect(
      lines.map(\.value) == [
        "900150983cd24fb0d6963f7d28e17f72",
        "a9993e364706816aba3e25717850c26c9cd0d89d",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
          + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
      ])
  }

  /// 空数据也有定义良好的 Hash。
  @Test func hashesOfEmptyDataMatchKnownVectors() {
    let values = BuiltinTextTools.hashes(of: Data()).map(\.value)
    #expect(values[0] == "d41d8cd98f00b204e9800998ecf8427e")
    #expect(values[1] == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    #expect(values[2] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(values[3].hasPrefix("cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"))
  }

  /// 输入按 UTF-8 字节计算；十六进制长度分别是 32/40/64/128 且全是小写。
  @Test func hashesOfUTF8TextHaveExpectedShape() {
    let lines = BuiltinTextTools.hashes(of: Data("你好".utf8))
    #expect(lines.map(\.value.count) == [32, 40, 64, 128])
    for line in lines {
      #expect(line.value.allSatisfy { "0123456789abcdef".contains($0) }, "\(line.label)")
    }
    #expect(lines[0].value == "7eca689f0d3389d9dea66ae112e5cfd7")
    #expect(lines[1].value == "440ee0853ad1e99f962b63e459ef992d7c211722")
    #expect(lines[2].value == "670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e")
  }

  /// 十六进制固定两位小写，空输入为空串。
  @Test func hexEncodesBytesAsTwoLowercaseDigits() {
    #expect(BuiltinTextTools.hex([0x00, 0x0A, 0xFF, 0xAB] as [UInt8]) == "000affab")
    #expect(BuiltinTextTools.hex([UInt8]()) == "")
  }

  // MARK: UUID

  /// v4：小写，版本位是 4，变体位是 8/9/a/b，连续生成不重复。
  @Test func uuidV4HasVersionAndVariantBits() {
    let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    var seen = Set<String>()
    for _ in 0..<200 {
      let uuid = BuiltinTextTools.uuidV4()
      #expect(uuid.range(of: pattern, options: .regularExpression) != nil, "\(uuid)")
      seen.insert(uuid)
    }
    #expect(seen.count == 200)
  }

  /// v7：前 48 位是 Unix 毫秒，版本位是 7，变体位是 8/9/a/b，其余随机；每次都满足。
  @Test func uuidV7EmbedsMillisecondsVersionAndVariant() {
    let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    // 1_700_000_000_500 毫秒 = 0x018b_cfe5_69f4。
    let now = Date(timeIntervalSince1970: 1_700_000_000.5)
    var seen = Set<String>()
    for _ in 0..<200 {
      let uuid = BuiltinTextTools.uuidV7(now: now)
      #expect(uuid.range(of: pattern, options: .regularExpression) != nil, "\(uuid)")
      #expect(uuid.hasPrefix("018bcfe5-69f4-7"), "\(uuid)")
      seen.insert(uuid)
    }
    #expect(seen.count == 200)
  }

  /// v7 按时间排序：更晚的时间生成的 UUID 字符串更大；早于 1970 年按 0 毫秒处理。
  @Test func uuidV7SortsByTimeAndClampsNegativeTime() {
    let early = BuiltinTextTools.uuidV7(now: Date(timeIntervalSince1970: 1_700_000_000))
    let late = BuiltinTextTools.uuidV7(now: Date(timeIntervalSince1970: 1_700_000_001))
    #expect(early < late)
    #expect(BuiltinTextTools.uuidV7(now: Date(timeIntervalSince1970: -5)).hasPrefix("00000000-0000-7"))
  }

  // MARK: 随机串

  /// 各字符集里生成的字符都在字符集内，长度正好，并且三个字符集都能出现各自的特征字符。
  @Test(arguments: ToolRandomAlphabet.allCases)
  func randomStringStaysInsideAlphabet(alphabet: ToolRandomAlphabet) {
    let digits = Set("0123456789")
    let letters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    let symbols = Set("!@#$%^&*()-_=+[]{}")
    let text = BuiltinTextTools.randomString(length: 4_096, alphabet: alphabet)
    #expect(text.count == 4_096)
    switch alphabet {
    case .alphanumeric:
      #expect(text.allSatisfy { digits.contains($0) || letters.contains($0) })
      #expect(text.contains { $0.isUppercase } && text.contains { $0.isLowercase } && text.contains { digits.contains($0) })
    case .hex:
      #expect(text.allSatisfy { "0123456789abcdef".contains($0) })
      #expect(text.contains { digits.contains($0) } && text.contains { "abcdef".contains($0) })
    case .symbols:
      #expect(text.allSatisfy { digits.contains($0) || letters.contains($0) || symbols.contains($0) })
      #expect(text.contains { symbols.contains($0) })
    }
  }

  /// 长度限制在 0...4096：负数与 0 给空串，超过上限按上限截。
  @Test(arguments: [(-5, 0), (0, 0), (1, 1), (32, 32), (4_095, 4_095), (4_096, 4_096), (4_097, 4_096), (1_000_000, 4_096)])
  func randomStringClampsLength(requested: Int, expected: Int) {
    #expect(BuiltinTextTools.maximumRandomLength == 4_096)
    #expect(BuiltinTextTools.randomString(length: requested, alphabet: .alphanumeric).count == expected)
  }

  /// 两次生成的结果不同（32 个字符碰撞的概率可以忽略）。
  @Test func randomStringDiffersBetweenCalls() {
    let first = BuiltinTextTools.randomString(length: 32, alphabet: .symbols)
    let second = BuiltinTextTools.randomString(length: 32, alphabet: .symbols)
    #expect(first != second)
  }
}
