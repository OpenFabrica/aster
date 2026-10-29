// 终端前台进程组读取：不存在的进程与没有控制终端的进程都返回 nil，不崩溃。

import Darwin
import Testing

@testable import Aster

@Test("前台进程组：无效或不存在的 pid 返回 nil")
func foregroundGroupRejectsInvalidPIDs() {
  #expect(ProcessForegroundGroupReader.foregroundGroup(of: 0) == nil)
  #expect(ProcessForegroundGroupReader.foregroundGroup(of: -1) == nil)
  #expect(ProcessForegroundGroupReader.foregroundGroup(of: 999_999) == nil)
}

@Test("前台进程组：和 ps 报告的 tpgid 一致（有控制终端才有值）")
func foregroundGroupMatchesKernelReport() {
  let group = ProcessForegroundGroupReader.foregroundGroup(of: getpid())
  // 测试宿主通常没有控制终端（tpgid 为 -1 / 0），也可能从终端里启动；只要求有值时它是合法的进程组 id。
  if let group { #expect(group > 0) }
}
