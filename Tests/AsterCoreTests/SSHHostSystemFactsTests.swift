import Foundation
import Testing

@testable import AsterCore

// SSHHostSystemProbe：探测脚本输出解析、系统大类归类、容量格式化与 host-facts.json 往返。

@Test("解析 Linux 输出：os-release 去引号、MemTotal 换算、df 根分区、/proc/cpuinfo 型号")
func hostFactsParseLinux() throws {
  let output = """
    Welcome to the box (MOTD noise)
    ASTER_HOST_FACTS_V1
    uname_s=Linux
    uname_r=6.8.0-45-generic
    uname_m=x86_64
    hostname=web-01
    os_PRETTY_NAME="Ubuntu 24.04.1 LTS"
    os_ID=ubuntu
    os_VERSION_ID="24.04"
    cpu_count=4
    cpu_model=Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
    mem_kb=8148104
    disk_kb=102687672 23456789
    end
    """
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let facts = try #require(SSHHostSystemProbe.parse(output, at: date))
  #expect(facts.family == .linux)
  #expect(facts.osName == "Ubuntu 24.04.1 LTS")
  #expect(facts.distroID == "ubuntu")
  #expect(facts.kernel == "6.8.0-45-generic")
  #expect(facts.architecture == "x86_64")
  #expect(facts.hostname == "web-01")
  #expect(facts.cpuModel == "Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz")
  #expect(facts.cpuCount == 4)
  #expect(facts.memoryBytes == Int64(8_148_104) * 1024)
  #expect(facts.diskTotalBytes == Int64(102_687_672) * 1024)
  #expect(facts.diskUsedBytes == Int64(23_456_789) * 1024)
  #expect(facts.collectedAt == date)
  #expect(facts.summary == "Ubuntu 24.04.1 LTS · \(L("\("4") 核")) · 7.8 GB")
  #expect(facts.details.contains("web-01") && facts.details.contains("97.9 GB"))
}

@Test("解析 macOS 输出：sw_vers 组成系统名，hw.memsize 直接是字节；缺标记或缺 uname 返回 nil")
func hostFactsParseMacOSAndFailures() throws {
  let output = """
    ASTER_HOST_FACTS_V1
    uname_s=Darwin
    uname_r=23.5.0
    uname_m=arm64
    hostname=studio.local
    sw_name=macOS
    sw_version=14.5
    cpu_count=12
    cpu_model=Apple M2 Max
    mem_bytes=68719476736
    disk_kb=
    end
    """
  let facts = try #require(SSHHostSystemProbe.parse(output))
  #expect(facts.family == .macOS)
  #expect(facts.osName == "macOS 14.5")
  #expect(facts.distroID == nil)
  #expect(facts.memoryBytes == 68_719_476_736)
  #expect(facts.diskTotalBytes == nil)
  #expect(facts.family.symbolName == "apple.logo")
  #expect(SSHHostSystemProbe.parse("bash: sh: command not found") == nil)
  #expect(SSHHostSystemProbe.parse("ASTER_HOST_FACTS_V1\nend\n") == nil)
  // 没有 os-release 也没有 sw_vers：退回 uname。
  let bare = try #require(SSHHostSystemProbe.parse("ASTER_HOST_FACTS_V1\nuname_s=FreeBSD\nuname_r=14.0-RELEASE\nend"))
  #expect(bare.family == .bsd && bare.osName == "FreeBSD 14.0-RELEASE")
}

@Test("系统大类归类与容量格式化")
func hostFactsClassifyAndFormat() {
  #expect(SSHHostOSFamily.classify(unameS: "Darwin") == .macOS)
  #expect(SSHHostOSFamily.classify(unameS: "Linux\n") == .linux)
  #expect(SSHHostOSFamily.classify(unameS: "OpenBSD") == .bsd)
  #expect(SSHHostOSFamily.classify(unameS: "DragonFly") == .bsd)
  #expect(SSHHostOSFamily.classify(unameS: "MINGW64_NT-10.0") == .windows)
  #expect(SSHHostOSFamily.classify(unameS: "SunOS") == .other)
  #expect(SSHHostSystemFacts.formatBytes(16 * 1_073_741_824) == "16 GB")
  #expect(SSHHostSystemFacts.formatBytes(8_148_104 * 1024) == "7.8 GB")
  #expect(SSHHostSystemFacts.formatBytes(512 * 1_048_576) == "512 MB")
  // 探测脚本是单个 sh -c 字符串，带标记与结束行。
  let command = SSHHostSystemProbe.probeCommand()
  #expect(command.count == 3 && command[0] == "/bin/sh" && command[1] == "-c")
  #expect(command[2].contains(SSHHostSystemProbe.marker) && command[2].hasSuffix("printf '%s\\n' 'end'"))
}

@Test("host-facts.json：往返保存、损坏按空处理")
func hostFactsStoreRoundTrip() throws {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-host-facts-\(UUID().uuidString)").appendingPathComponent("host-facts.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let store = SSHHostFactsStore(fileURL: url)
  #expect(store.load().isEmpty)
  let id = UUID()
  let facts = SSHHostSystemFacts(
    family: .linux, osName: "Debian GNU/Linux 12 (bookworm)", distroID: "debian", kernel: "6.1.0",
    architecture: "aarch64", hostname: "pi", cpuCount: 4, memoryBytes: 4_000_000_000,
    collectedAt: Date(timeIntervalSince1970: 1_700_000_000))
  try store.save([id: facts])
  #expect(SSHHostFactsStore(fileURL: url).load() == [id: facts])
  try Data("{broken".utf8).write(to: url)
  #expect(SSHHostFactsStore(fileURL: url).load().isEmpty)
}

@Test("探测脚本在本机 /bin/sh 上真实运行：解析出 macOS、CPU 数与内存")
func hostFactsProbeRunsLocally() throws {
  let process = Process()
  let command = SSHHostSystemProbe.probeCommand()
  process.executableURL = URL(fileURLWithPath: command[0])
  process.arguments = Array(command.dropFirst())
  process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  let facts = try #require(SSHHostSystemProbe.parse(String(decoding: data, as: UTF8.self)))
  #expect(facts.family == .macOS)
  #expect(facts.osName.hasPrefix("macOS"))
  #expect((facts.cpuCount ?? 0) > 0)
  #expect((facts.memoryBytes ?? 0) > 0)
  #expect((facts.diskTotalBytes ?? 0) > 0)
  #expect(facts.cpuModel?.isEmpty == false)
}
