// 原生 SSH 标签复用服务器监控与文件页：真实会话投影、旁路 argv 和目录回退。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("原生 SSH 会话立即投影远端上下文，localhost 目录也不污染本地路径")
@MainActor
func nativeSSHInspectorProjectsContextAndDirectory() async throws {
  let spec = try #require(NativeSSHPaneSpec.target("deploy@box:2222"))
  let session = TerminalSession(workingDirectory: "/tmp")
  defer { session.stop(immediately: true) }
  session.bindNativeSSH(spec)
  #expect(session.remoteInspectionContext == .nativeSSH(spec: spec, label: "box"))
  #expect(!session.currentWorkingDirectoryIsLocal)
  let source = AsterTerminalView(frame: .zero)
  for report in ["file://server/srv", "file://localhost/var/log", "/home/deploy"] {
    session.hostCurrentDirectoryUpdate(source: source, directory: report)
    for _ in 0..<20 { await Task.yield() }
    #expect(session.remoteWorkingDirectory?.path == URL(string: report)?.path)
    #expect(!session.currentWorkingDirectoryIsLocal)
    #expect(session.currentWorkingDirectory == "/tmp")
    #expect(session.remoteInspectionContext?.displayLabel == "box")
  }
}

@Test("原生 SSH 旁路按目标隔离缓存，使用 broker 非交互 exec 且无 ControlMaster 回退")
@MainActor
func nativeSSHInspectorResolvesBrokerChannel() throws {
  let routing = SSHEngineRouting.shared
  let previous = routing.nativeEndpoint
  defer { routing.publish(previous) }
  let spec = try #require(NativeSSHPaneSpec.target("deploy@box:2222"))
  let context = RemoteInspectionContext.nativeSSH(spec: spec, label: "box")
  routing.publish(nil)
  #expect(RemoteSideChannelResolver.resolve(context) == nil)
  let endpoint = NativeSSHEndpoint(executablePath: "/opt/aster-ssh", brokerSocketPath: "/tmp/test.sock")
  routing.publish(endpoint)
  let channel = try #require(RemoteSideChannelResolver.resolve(context))
  let command = ["/bin/sh", "-c", "printf '%s' \"$1\"", "sh", "/srv/a'b"]
  #expect(channel.sshArguments(command) == NativeSSHClientInvocation(
    endpoint: endpoint, target: spec.clientTarget, noPrompt: true, remoteCommand: command).arguments())
  #expect(channel.controlCheckArguments == nil)
  #expect(channel.identity.key == RemoteSideChannelResolver.channelKey(for: context))
  let renamed = RemoteInspectionContext.nativeSSH(spec: spec, label: "新名称")
  #expect(RemoteSideChannelResolver.channelKey(for: renamed) == channel.identity.key)
  let other = RemoteInspectionContext.nativeSSH(spec: .host(UUID()), label: "box")
  #expect(RemoteSideChannelResolver.channelKey(for: other) != channel.identity.key)
  // 已删除主机不能退回文本目标建立连接。
  #expect(RemoteSideChannelResolver.resolve(other) == nil)
}

@Test("原生 SSH 面板从真实会话识别远端，Info 读监控，Files 无集成时浏览远端 HOME",
  arguments: [0, 3])
@MainActor
func nativeSSHInspectorUsesServerSections(section: Int) async throws {
  _ = NSApplication.shared
  let suite = "NativeSSHInspectorTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.tabs.forEach { $0.stop(immediately: true) } }
  let tab = try #require(model.selectedTab)
  let spec = try #require(NativeSSHPaneSpec.target("deploy@box:2222"))
  tab.activeSession?.bindNativeSSH(spec)
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = section
  var localCalls = 0
  var remoteDirectories: [String] = []
  var monitorCalls = 0
  let inspection = WorkspaceInspectionClient(
    information: { _ in localCalls += 1; return WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in localCalls += 1; return GitStatusSummary() },
    files: { _, _ in localCalls += 1; return [] })
  let remote = RemoteInspectionClient(
    listDirectory: { context, directory in
      #expect(context == .nativeSSH(spec: spec, label: "box"))
      remoteDirectories.append(directory)
      return .success(RemoteDirectoryListing(
        directory: directory.isEmpty ? "/home/deploy" : directory,
        entries: [RemoteDirectoryEntry(
          name: "server.log", kind: .file, targetIsDirectory: false, size: 4096,
          modifiedAt: Date(), mode: 0o644, isHidden: false, nameDecodedLossy: false)],
        totalCount: 1, isTruncated: false))
    },
    monitor: { context, pid in
      #expect(context == .nativeSSH(spec: spec, label: "box"))
      #expect(pid == nil)
      monitorCalls += 1
      return .success(RemoteHostMonitorSnapshot(host: "box", uname: "Linux 6.8 x86_64"))
    })
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: inspection, remoteClient: remote)
  controller.loadViewIfNeeded()
  defer { controller.setPresentationActive(false) }
  try await Task.sleep(for: .milliseconds(450))
  #expect(controller.inspectorRemoteContext == .nativeSSH(spec: spec, label: "box"))
  #expect(localCalls == 0)
  #expect(monitorCalls == (section == 0 ? 1 : 0))
  #expect(remoteDirectories == (section == 3 ? [""] : []))
  let expectedID = section == 0 ? "details-remote-monitor" : "details-remote-files-table"
  #expect(descendants(controller.view).contains { $0.identifier?.rawValue == expectedID })

  if section == 3 {
    // 收到 OSC 7 后通过生产事件链切换目录，不再停在 HOME。
    tab.activeSession?.hostCurrentDirectoryUpdate(
      source: AsterTerminalView(frame: .zero), directory: "file://localhost/srv")
    try await Task.sleep(for: .milliseconds(450))
    #expect(remoteDirectories.last == "/srv")
  }

  // 挂载真实 AppKit 窗口验收复用后的页布局；按需导出窗口位图。
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 720),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  defer { window.contentViewController = nil; window.orderOut(nil) }
  window.setContentSize(NSSize(width: 320, height: 720))
  window.orderFront(nil)
  try await Task.sleep(for: .milliseconds(150))
  window.layoutIfNeeded()
  controller.view.layoutSubtreeIfNeeded()
  #expect(controller.view.bounds.height >= 700)
  if let directory = ProcessInfo.processInfo.environment["ASTER_NATIVE_INSPECTOR_EVIDENCE_DIR"] {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-ssh-\(section).png"))
  }

  // 切回本地 Pane 后恢复本机检查，旧服务器不再轮询。
  tab.split(direction: .right, kind: .terminal, workingDirectory: "/tmp")
  try await Task.sleep(for: .milliseconds(450))
  #expect(controller.inspectorRemoteContext == nil)
  #expect(localCalls > 0)
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
  view.subviews + view.subviews.flatMap { descendants($0) }
}
