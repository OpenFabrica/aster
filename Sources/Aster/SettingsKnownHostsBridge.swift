import AsterCore
import Foundation

// 设置页「主机 → 已知主机」的桥接协作者：把 `SSHKnownHostsService` 的状态写成网页快照，
// 把 `hosts.knownHosts.*` 动作的 payload 还原成结构化请求交给服务。
//
// 列出、校验与删除的规则都在 `SSHKnownHostsService`（原生「已知主机」页共用）；
// 这里只做网页形状的编解码。由 `SettingsHostsBridge` 持有，快照放在 `hosts.knownHosts` 下。

/// 「已知主机」网页的快照与动作适配。
@MainActor
final class SettingsKnownHostsBridge {
  /// 外部依赖，与服务共用；`SettingsHostsBridge.Dependencies` 沿用这个名字。
  typealias Dependencies = SSHKnownHostsService.Dependencies
  /// 列表状态，与服务共用。
  typealias State = SSHKnownHostsService.State

  /// 实际执行列出与删除的服务。
  let service: SSHKnownHostsService

  /// 状态变化后推送新快照。
  var pushSnapshot: () -> Void = {} {
    didSet { service.didChange = { [weak self] in self?.pushSnapshot() } }
  }
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in } {
    didSet { service.toast = { [weak self] in self?.toast($0, $1) } }
  }

  var state: State { service.state }
  /// 最近一次成功的列表。
  var listing: SSHKnownHostsListing? { service.listing }

  /// 用给定依赖与主机来源建一个服务。
  init(
    dependencies: Dependencies,
    hosts: @escaping @MainActor () -> [SSHHostProfile],
    machineTargets: @escaping @MainActor () -> [String]
  ) {
    service = SSHKnownHostsService(dependencies: dependencies, hosts: hosts, machineTargets: machineTargets)
  }

  // MARK: - 快照

  /// 快照的 `knownHosts` 字段：`state`、`error`、`files`、`entries`（带 `names` 与 `removable`）、`skipped`。
  func snapshot() -> [String: Any] {
    var object: [String: Any] = ["state": stateName]
    if case .failed(let message) = state { object["error"] = message }
    guard let listing else { return object }
    object["files"] = listing.files.map { file in
      var row: [String: Any] = [
        "path": Self.displayPath(file.path), "rawPath": file.path, "exists": file.exists,
        "writable": file.writable, "global": file.global,
      ]
      row["error"] = file.error
      return row
    }
    object["entries"] = listing.entries.map { entry in
      var row: [String: Any] = [
        "file": entry.file, "line": entry.line, "hosts": entry.hosts, "hashed": entry.hashed,
        "algorithm": entry.algorithm, "fingerprint": entry.fingerprint, "lineDigest": entry.lineDigest,
        "matches": entry.matches.map { ["host": $0.host, "port": $0.port] as [String: Any] },
        // 每个命中主机对应的已保存主机名；没有名称的跳板或旧机器地址为空数组。
        "names": entry.matches.map { service.names(for: $0) },
        "removable": service.isRemovable(entry),
      ]
      row["marker"] = entry.marker
      row["comment"] = entry.comment
      return row
    }
    object["skipped"] = listing.skipped.map {
      ["file": $0.file, "line": $0.line, "reason": $0.reason] as [String: Any]
    }
    return object
  }

  /// 状态的网页名。
  private var stateName: String {
    switch state {
    case .idle: "idle"
    case .loading: "loading"
    case .loaded: "loaded"
    case .failed: "error"
    }
  }

  /// 家目录下的路径写成 `~/…`，只用于显示。
  static func displayPath(_ path: String) -> String {
    SSHKnownHostsService.displayPath(path)
  }

  // MARK: - 动作

  /// 分发 `hosts.knownHosts.` 前缀的动作；返回 false 表示不是本组动作。
  func handle(action: String, payload: [String: Any], complete: @escaping (Bool) -> Void) -> Bool {
    switch action {
    case "hosts.knownHosts.refresh":
      refresh(complete: complete)
    case "hosts.knownHosts.remove":
      remove(payload, complete: complete)
    default:
      return false
    }
    return true
  }

  /// 重新列出 known_hosts。
  func refresh(complete: @escaping (Bool) -> Void = { _ in }) {
    service.refresh(complete: complete)
  }

  /// 删除一条记录或其中一个主机模式；payload 无效时直接 toast 拒绝。
  private func remove(_ payload: [String: Any], complete: @escaping (Bool) -> Void) {
    guard !service.isRemoving else {
      complete(false)
      return
    }
    let request: SSHKnownHostsRemoveRequest
    do { request = try validatedRemoveRequest(payload) } catch {
      toast(Self.describe(error), true)
      complete(false)
      return
    }
    service.remove(request, complete: complete)
  }

  /// 把网页 payload 还原成删除请求，并交给服务确认它对应上一次列表里一条可写文件中的记录。
  func validatedRemoveRequest(_ payload: [String: Any]) throws -> SSHKnownHostsRemoveRequest {
    guard let file = payload["file"] as? String, let line = payload["line"] as? Int,
      let digest = payload["lineDigest"] as? String, listing != nil
    else { throw SSHKnownHostsError.invalidPayload }
    var host: SSHHostPort?
    if let raw = payload["host"] as? [String: Any] {
      guard let name = raw["host"] as? String, let port = raw["port"] as? Int else {
        throw SSHKnownHostsError.invalidPayload
      }
      host = SSHHostPort(host: name, port: port)
    }
    return try service.validated(
      SSHKnownHostsRemoveRequest(file: file, line: line, lineDigest: digest, host: host))
  }

  /// 把错误转成一句给用户看的话。
  static func describe(_ error: Error) -> String {
    SSHKnownHostsService.describe(error)
  }
}
