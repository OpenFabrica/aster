import Foundation

// 已保存主机的系统与硬件信息：操作系统、内核、架构、CPU、内存、根分区。
// 由一次非交互的远端 `/bin/sh` 探测脚本采集（`SSHHostSystemProbe`），按主机 ID 持久化，
// 主机页用它决定卡片图标并在副标题里显示配置摘要。全部是纯数据与纯函数，不碰网络与文件。

/// 操作系统大类，决定卡片图标。
public enum SSHHostOSFamily: String, Codable, Equatable, Sendable {
  case macOS
  case linux
  case bsd
  case windows
  case other

  /// 从 `uname -s` 归类。Windows 上的 MSYS / Cygwin / Git Bash 也能跑这段脚本，按 Windows 算。
  public static func classify(unameS: String) -> SSHHostOSFamily {
    let name = unameS.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = name.lowercased()
    if name == "Darwin" { return .macOS }
    if name == "Linux" { return .linux }
    if lower.hasSuffix("bsd") || lower.hasPrefix("dragonfly") { return .bsd }
    if lower.contains("mingw") || lower.contains("cygwin") || lower.contains("msys") || lower.contains("windows") {
      return .windows
    }
    return .other
  }

  /// 卡片图标块里的 SF Symbol。SF Symbols 没有 Linux / BSD 的发行版标志，只能按大类区分。
  public var symbolName: String {
    switch self {
    case .macOS: "apple.logo"
    case .linux: "terminal"
    case .bsd: "network"
    case .windows: "pc"
    case .other: "server.rack"
    }
  }
}

/// 有自绘标志的发行版。SF Symbols 没有发行版标志，这些由应用层自己画；不在表里的走 `SSHHostOSFamily` 的通用图标。
public enum SSHHostOSBrand: String, Equatable, Sendable {
  case ubuntu
}

/// 一台主机的系统与硬件信息快照。字段缺失表示脚本在该系统上取不到，不是错误。
public struct SSHHostSystemFacts: Codable, Equatable, Sendable {
  public var family: SSHHostOSFamily
  /// 给人看的系统名，例如「Ubuntu 22.04.3 LTS」「macOS 14.5」「FreeBSD 14.0-RELEASE」。
  public var osName: String
  /// `/etc/os-release` 的 `ID`（ubuntu、debian、alpine…）；非 Linux 为 nil。
  public var distroID: String?
  public var kernel: String
  public var architecture: String
  public var hostname: String
  public var cpuModel: String?
  public var cpuCount: Int?
  public var memoryBytes: Int64?
  public var diskTotalBytes: Int64?
  public var diskUsedBytes: Int64?
  /// 采集时间。
  public var collectedAt: Date

  public init(
    family: SSHHostOSFamily, osName: String, distroID: String? = nil, kernel: String, architecture: String,
    hostname: String, cpuModel: String? = nil, cpuCount: Int? = nil, memoryBytes: Int64? = nil,
    diskTotalBytes: Int64? = nil, diskUsedBytes: Int64? = nil, collectedAt: Date
  ) {
    self.family = family
    self.osName = osName
    self.distroID = distroID
    self.kernel = kernel
    self.architecture = architecture
    self.hostname = hostname
    self.cpuModel = cpuModel
    self.cpuCount = cpuCount
    self.memoryBytes = memoryBytes
    self.diskTotalBytes = diskTotalBytes
    self.diskUsedBytes = diskUsedBytes
    self.collectedAt = collectedAt
  }

  /// 按 os-release 的 `ID` 认出的发行版标志；没有专用标志时为 nil。
  public var brand: SSHHostOSBrand? {
    distroID.flatMap { SSHHostOSBrand(rawValue: $0.lowercased()) }
  }

  /// 卡片副标题用的一行摘要：「Ubuntu 22.04 · 4 核 · 7.8 GB」；取不到的部分省略。
  public var summary: String {
    var parts = [osName]
    if let cpuCount { parts.append(L("\(String(cpuCount)) 核")) }
    if let memoryBytes { parts.append(Self.formatBytes(memoryBytes)) }
    return parts.joined(separator: " · ")
  }

  /// 工具提示用的多行详情。
  public var details: String {
    var lines = [L("系统：\(osName)"), L("内核：\(kernel)"), L("架构：\(architecture)"), L("主机名：\(hostname)")]
    if let cpuModel, let cpuCount {
      lines.append(L("CPU：\(cpuModel)（\(String(cpuCount)) 核）"))
    } else if let cpuModel {
      lines.append(L("CPU：\(cpuModel)"))
    } else if let cpuCount {
      lines.append(L("CPU：\(String(cpuCount)) 核"))
    }
    if let memoryBytes { lines.append(L("内存：\(Self.formatBytes(memoryBytes))")) }
    if let diskTotalBytes {
      let used = diskUsedBytes.map { L("已用 \(Self.formatBytes($0))") }
      lines.append(L("根分区：\(Self.formatBytes(diskTotalBytes))") + (used.map { "（\($0)）" } ?? ""))
    }
    return lines.joined(separator: "\n")
  }

  /// 按 1024 进制格式化到 GB / MB，最多一位小数（「7.8 GB」「512 MB」）。
  public static func formatBytes(_ bytes: Int64) -> String {
    let gib = Double(bytes) / 1_073_741_824
    if gib >= 1 { return "\(trimmed(gib)) GB" }
    let mib = Double(bytes) / 1_048_576
    return "\(trimmed(mib)) MB"
  }

  /// 一位小数，整数时不带「.0」。
  private static func trimmed(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
  }
}

/// 远端探测脚本与输出解析。
public enum SSHHostSystemProbe {
  /// 输出首标记；与其它探测（`RemoteAgentProbe`、`RemoteHostMonitor`）隔离。
  public static let marker = "ASTER_HOST_FACTS_V1"
  /// 单次探测的最长等待秒数。
  public static let timeout: TimeInterval = 20

  /// 探测脚本 argv。只读命令，POSIX sh 可跑：Linux 读 /proc 与 os-release，macOS / BSD 用 sysctl。
  /// 每个字段单独容错，缺某个命令只会少一个字段。
  public static func probeCommand() -> [String] {
    let script = """
      set -u
      printf '%s\\n' '\(marker)'
      printf 'uname_s=%s\\n' "$(uname -s 2>/dev/null || true)"
      printf 'uname_r=%s\\n' "$(uname -r 2>/dev/null || true)"
      printf 'uname_m=%s\\n' "$(uname -m 2>/dev/null || true)"
      printf 'hostname=%s\\n' "$(hostname 2>/dev/null || true)"
      if [ -r /etc/os-release ]; then grep -E '^(ID|PRETTY_NAME|VERSION_ID)=' /etc/os-release 2>/dev/null | sed 's/^/os_/'; fi
      if command -v sw_vers >/dev/null 2>&1; then
        printf 'sw_name=%s\\n' "$(sw_vers -productName 2>/dev/null || true)"
        printf 'sw_version=%s\\n' "$(sw_vers -productVersion 2>/dev/null || true)"
      fi
      printf 'cpu_count=%s\\n' "$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
      if [ -r /proc/cpuinfo ]; then
        printf 'cpu_model=%s\\n' "$(grep -m1 -E '^(model name|Model|cpu model|Hardware)[[:space:]]*:' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//' || true)"
      else
        printf 'cpu_model=%s\\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || true)"
      fi
      if [ -r /proc/meminfo ]; then
        printf 'mem_kb=%s\\n' "$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)"
      else
        printf 'mem_bytes=%s\\n' "$(sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.physmem 2>/dev/null || true)"
      fi
      printf 'disk_kb=%s\\n' "$(df -kP / 2>/dev/null | awk 'NR==2{print $2" "$3}' || true)"
      printf '%s\\n' 'end'
      """
    return ["/bin/sh", "-c", script]
  }

  /// 解析脚本输出。标记可以不在第一行（登录 Shell 可能先打 MOTD）；缺标记或连 `uname -s` 都没有时返回 nil。
  public static func parse(_ output: String, at date: Date = Date()) -> SSHHostSystemFacts? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
      return nil
    }
    var fields: [String: String] = [:]
    for line in lines[(start + 1)...] {
      if line == "end" { break }
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<separator])
      var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      // os-release 的值可能带双引号。
      if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
      if !value.isEmpty { fields[key] = value }
    }
    guard let unameS = fields["uname_s"] else { return nil }
    let family = SSHHostOSFamily.classify(unameS: unameS)
    let osName: String
    if let name = fields["sw_name"] {
      osName = [name, fields["sw_version"]].compactMap { $0 }.joined(separator: " ")
    } else if let pretty = fields["os_PRETTY_NAME"] {
      osName = pretty
    } else {
      osName = [unameS, fields["uname_r"]].compactMap { $0 }.joined(separator: " ")
    }
    var memory = fields["mem_bytes"].flatMap { Int64($0) }
    if memory == nil, let kb = fields["mem_kb"].flatMap({ Int64($0) }) { memory = kb * 1024 }
    var diskTotal: Int64?
    var diskUsed: Int64?
    if let disk = fields["disk_kb"] {
      let parts = disk.split(separator: " ").compactMap { Int64($0) }
      if parts.count == 2 {
        diskTotal = parts[0] * 1024
        diskUsed = parts[1] * 1024
      }
    }
    return SSHHostSystemFacts(
      family: family, osName: osName, distroID: fields["os_ID"]?.lowercased(),
      kernel: fields["uname_r"] ?? "", architecture: fields["uname_m"] ?? "",
      hostname: fields["hostname"] ?? "", cpuModel: fields["cpu_model"],
      cpuCount: fields["cpu_count"].flatMap { Int($0) }, memoryBytes: memory,
      diskTotalBytes: diskTotal, diskUsedBytes: diskUsed,
      // 落盘用 ISO 8601（秒级），这里先截到整秒，存取往返后仍相等。
      collectedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
  }
}
