import Foundation
import Testing

@testable import AsterCore

@Test("连续两次纯单词参数后不再列文件，传过路径立即恢复")
func pathHabitsLearnWordOnlyCommands() {
  var habits = AutocompletePathHabits()
  let noFiles: (String) -> Bool = { _ in false }
  #expect(habits.shouldEnumerate(command: "foo", currentToken: ""))
  habits.record(command: "foo bar", pathProbe: noFiles)
  #expect(habits.shouldEnumerate(command: "foo", currentToken: ""))
  habits.record(command: "foo baz --verbose", pathProbe: noFiles)
  #expect(!habits.shouldEnumerate(command: "foo", currentToken: ""))
  #expect(!habits.shouldEnumerate(command: "foo", currentToken: "ba"))
  // 明确在打路径时永远列。
  #expect(habits.shouldEnumerate(command: "foo", currentToken: "./"))
  #expect(habits.shouldEnumerate(command: "foo", currentToken: "~/"))
  #expect(habits.shouldEnumerate(command: "foo", currentToken: "src/"))
  // 路径参数（字面或探测到存在）恢复文件候选。
  habits.record(command: "foo README.md", pathProbe: { $0 == "README.md" })
  #expect(habits.shouldEnumerate(command: "foo", currentToken: ""))
  #expect(habits.habits["foo"]?.wordStreak == 0)
}

@Test("无参数、选项、非裸命令名不改变习惯；校验拒绝非法数据")
func pathHabitsIgnoreIrrelevantCommandsAndValidate() throws {
  var habits = AutocompletePathHabits()
  habits.record(command: "foo", pathProbe: { _ in false })
  habits.record(command: "foo --flag -v", pathProbe: { _ in false })
  habits.record(command: "./script.sh word", pathProbe: { _ in false })
  #expect(habits.habits.isEmpty)
  habits.record(command: "foo ../x", pathProbe: { _ in false })
  #expect(habits.habits["foo"]?.takesPaths == true)

  let data = try JSONEncoder().encode(habits)
  let decoded = try JSONDecoder().decode(AutocompletePathHabits.self, from: data)
  #expect(decoded.validated() == habits)
  let broken = try JSONDecoder().decode(
    AutocompletePathHabits.self,
    from: Data(#"{"habits":{"bad name":{"wordStreak":9,"takesPaths":false,"updatedAt":1}}}"#.utf8))
  #expect(broken.validated() == nil)
}

@Test("超过容量时淘汰最久未更新的命令")
func pathHabitsEvictOldest() {
  var habits = AutocompletePathHabits()
  for index in 0...AutocompletePathHabits.capacity {
    habits.record(
      command: "cmd\(index) word1", pathProbe: { _ in false },
      at: Date(timeIntervalSince1970: Double(index)))
  }
  #expect(habits.habits.count <= AutocompletePathHabits.capacity)
  #expect(habits.habits["cmd0"] == nil)
  #expect(habits.habits["cmd\(AutocompletePathHabits.capacity)"] != nil)
}
