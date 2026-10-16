import Foundation
import Testing

@testable import AsterCore

// OpenSSH 公钥指纹：与 `ssh-keygen -l -E sha256` 的输出一致，拒绝不是公钥的内容。

/// `ssh-keygen -t ed25519 -C me@laptop` 生成的公钥及其指纹。
private let samplePublicKey =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICTYJWvaVFMKTBmpRfvvForC0KxD+MJTUCb7ynmlBqDa me@laptop"
private let sampleFingerprint = "SHA256:wQOc//ezWAIWB3kTbdhdvFDQov2cR0tddNWlQ44HUFM"

@Test("公钥指纹与 ssh-keygen 一致，注释与制表符不影响结果")
func publicKeyFingerprintMatchesSSHKeygen() {
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: samplePublicKey) == sampleFingerprint)
  let withoutComment = samplePublicKey.replacingOccurrences(of: " me@laptop", with: "")
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: withoutComment) == sampleFingerprint)
  let tabbed = samplePublicKey.replacingOccurrences(of: " ", with: "\t")
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: tabbed) == sampleFingerprint)
}

@Test("公钥指纹：.pub 文件跳过空行与注释，取第一行公钥")
func publicKeyFingerprintReadsFile() {
  let file = "\n# backup\n\(samplePublicKey)\n"
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyFile: file) == sampleFingerprint)
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyFile: "# only comments\n\n") == nil)
}

@Test("公钥指纹：类型与 blob 不符、base64 无效、字段不够都返回 nil")
func publicKeyFingerprintRejectsMalformedLines() {
  let mismatched = samplePublicKey.replacingOccurrences(of: "ssh-ed25519 ", with: "ssh-rsa ")
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: mismatched) == nil)
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: "ssh-ed25519 !!!notbase64") == nil)
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: "ssh-ed25519") == nil)
  // 合法 base64 但不是线格式：长度字段超出数据。
  let garbage = Data("key-p".utf8).base64EncodedString()
  #expect(SSHPublicKeyFingerprint.sha256(publicKeyLine: "ssh-ed25519 \(garbage)") == nil)
}
