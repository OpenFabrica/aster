// 根据原版实际消费的静态 Fig 字段解析上下文并枚举候选，不执行生成器或访问文件系统。
import Foundation

/// 静态规格的解析位置。`completed` 只包含可执行命令之后已经完成的 token。
/// 选项按完整名称精确匹配，并按声明的参数数量跳过 token；不解释短选项组合、
/// `--name=value` 或 `--` 的额外语法，也不读取可选、可重复、可变参数等扩展字段。
public struct FigCompletionContext: Sendable {
  public private(set) var command: AutocompleteCommandSpec
  /// 从根到最近父级；候选枚举时按逆序继承。
  public private(set) var ancestors: [AutocompleteCommandSpec] = []
  public private(set) var commandPath: [String]
  public private(set) var positionalCount = 0

  public init(root: AutocompleteCommandSpec, completed: [String]) {
    command = root
    commandPath = [root.name]
    var index = 0
    while index < completed.count {
      let token = completed[index]
      if token.utf8.first == 45 {
        let option = ([command] + ancestors.reversed()).lazy.compactMap { specification in
          specification.options.first { $0.names.contains { $0.utf8.elementsEqual(token.utf8) } }
        }.first
        index += 1 + (option?.args.count ?? 0)
        continue
      }
      if let child = command.subcommands.first(where: {
        $0.name.utf8.elementsEqual(token.utf8) || $0.aliases.contains { $0.utf8.elementsEqual(token.utf8) }
      }) {
        ancestors.append(command)
        command = child
        commandPath.append(child.name)
        positionalCount = 0
      } else {
        positionalCount += 1
      }
      index += 1
    }
  }
}

/// Fig 静态字段的消费规则。返回完整、原序的字面名称和描述；排序、去重、候选上限与
/// 终端插入由调用方负责，不能在这里按 Shell token 白名单或显示行数截断规格数据。
public enum FigCompletionRules {
  public enum FilesystemMode: Equatable, Sendable { case none, folders, filesAndFolders }

  /// 原版对名称和前缀各做 Unicode lowercase，再比较前缀；保留返回文本的原始大小写。
  public static func matches(_ name: String, prefix: String) -> Bool {
    // String.hasPrefix 会按 Unicode 规范等价比较；原版比较的是 lowercase 后的 UTF-8 字节。
    name.lowercased().utf8.starts(with: prefix.lowercased().utf8)
  }

  /// 子命令只列主名称。别名用于解析；精确别名 `hidden` 是原版特殊隐藏标记。
  /// JSON 的 `hidden` 布尔字段不参与这条路径。
  public static func subcommands(
    of command: AutocompleteCommandSpec, prefix: String
  ) -> [AutocompleteCommandSpec] {
    command.subcommands.filter { !$0.aliases.contains("hidden") && matches($0.name, prefix: prefix) }
  }

  /// 所有祖先选项都继承，按当前、最近父级、根的顺序枚举各 names。
  /// 已用选项、hidden、isRepeatable、isPersistent、互斥和依赖等字段不在原版消费集合内。
  public static func options(
    of command: AutocompleteCommandSpec, ancestors: [AutocompleteCommandSpec] = [], prefix: String
  ) -> [AutocompleteSpecItem] {
    ([command] + ancestors.reversed()).flatMap { specification in
      specification.options.flatMap { option in
        option.names.filter { matches($0, prefix: prefix) }.map {
          AutocompleteSpecItem(name: $0, description: option.description)
        }
      }
    }
  }

  /// 枚举当前命令全部位置参数的静态候选，与位置参数索引和上一个选项的 args 无关。
  public static func suggestions(
    of command: AutocompleteCommandSpec, prefix: String
  ) -> [AutocompleteSpecItem] {
    command.arguments.flatMap(\.suggestions).filter { matches($0.name, prefix: prefix) }
  }

  /// 当前命令的全部参数模板取并集；只有大小写敏感的 folders/filepaths 有效。
  /// 含斜杠的前缀另外启用文件和目录，与参数模板和位置无关。
  public static func filesystemMode(
    of command: AutocompleteCommandSpec, prefix: String
  ) -> FilesystemMode {
    if prefix.utf8.contains(47) { return .filesAndFolders }
    let templates = command.arguments.flatMap(\.template)
    if templates.contains("filepaths") { return .filesAndFolders }
    return templates.contains("folders") ? .folders : .none
  }
}
