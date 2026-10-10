import Foundation
import Testing

@testable import AsterCore

private func makeProject() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-cargo-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url.standardizedFileURL
}

private func write(_ contents: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: url, atomically: true, encoding: .utf8)
}

@Test("cargo 的 --bin/--example 按参数名兜底，--features/--package 按脚本映射")
func cargoArgumentsMapToSources() {
  func sources(_ name: String, scripts: [[String]] = []) -> [AutocompleteDynamicSource] {
    AutocompleteDynamicSource.sources(
      for: AutocompleteArgumentSpec(name: name, generatorScripts: scripts), commandPath: ["cargo", "run"])
  }
  #expect(sources("bin") == [.cargoBinaries])
  #expect(sources("example") == [.cargoExamples])
  #expect(sources("features", scripts: [["cargo", "read-manifest"]]) == [.cargoFeatures])
  #expect(sources("package", scripts: [["cargo", "metadata", "--format-version", "1", "--no-deps"]]) == [.cargoPackages])
  #expect(sources("args").isEmpty)
  #expect(!AutocompleteDynamicSource.cargoFeatures.isMachineScoped)
}

@Test("Cargo.toml 与 src/bin、examples 目录读出 bin / example / feature / 包，不执行 cargo")
func cargoReaderReadsManifestAndDirectories() throws {
  let root = try makeProject()
  defer { try? FileManager.default.removeItem(at: root) }
  try write(
    """
    [package]
    name = "aster-ssh"   # 包名
    version = "0.1.0"

    [[bin]]
    name = "broker"
    path = "src/broker.rs"

    [[example]]
    name = "handshake"

    [features]
    default = ["tls"]
    tls = []
    "quoted-feature" = []

    [dependencies]
    serde = { version = "1", features = ["derive"] }

    [workspace]
    members = [
      "crates/core",
      "crates/*",
    ]
    """, to: root.appendingPathComponent("Cargo.toml"))
  try write("fn main() {}", to: root.appendingPathComponent("src/main.rs"))
  try write("fn main() {}", to: root.appendingPathComponent("src/bin/migrate.rs"))
  try write("fn main() {}", to: root.appendingPathComponent("src/bin/serve/main.rs"))
  try write("fn main() {}", to: root.appendingPathComponent("examples/demo.rs"))
  try write("[package]\nname = \"aster-core\"\n", to: root.appendingPathComponent("crates/core/Cargo.toml"))

  let reader = AutocompleteDiskDynamicReader()
  let nested = root.appendingPathComponent("src/bin").path
  #expect(Set(reader.items(for: .cargoBinaries, directory: nested).map(\.name)) == ["broker", "aster-ssh", "migrate", "serve"])
  #expect(Set(reader.items(for: .cargoExamples, directory: root.path).map(\.name)) == ["handshake", "demo"])
  #expect(reader.items(for: .cargoFeatures, directory: root.path).map(\.name) == ["default", "tls", "quoted-feature"])
  #expect(reader.items(for: .cargoPackages, directory: root.path).map(\.name) == ["aster-ssh", "aster-core"])
  #expect(reader.items(for: .cargoBinaries, directory: root.path).first?.description == L("Cargo 二进制"))
  // 没有 Cargo.toml 的目录：空。
  #expect(reader.items(for: .cargoFeatures, directory: FileManager.default.temporaryDirectory.path).isEmpty)
}

@Test("最小 TOML 读取忽略注释与引号内的 # 并支持多行数组")
func cargoManifestSummaryParsesMinimalToml() {
  let summary = CargoManifestSummary(toml: "[package]\nname = \"a#b\" # c\n[workspace]\nmembers = [\n\"x\",\n]\n")
  #expect(summary.packageName == "a#b")
  #expect(summary.workspaceMembers == ["x"])
  #expect(CargoManifestSummary.string("\"\"") == nil)
  #expect(CargoManifestSummary.stringArray("[\"a\", 'b']") == ["a", "b"])
}
