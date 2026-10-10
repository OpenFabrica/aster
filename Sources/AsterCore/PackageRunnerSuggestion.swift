// 命令没装时改用包运行器（npx / uvx / bundle exec …）临时执行的纠错规则。
import Foundation

/// 对 "command not found" 给出 `<runner> <原命令>` 的建议。只在两类证据下开口：
/// 项目里确有这个可执行文件（`node_modules/.bin/<cmd>`），或命令名是已知的
/// npm / PyPI / RubyGems CLI 且（gem 场景）项目有 Gemfile。不认识的名字一律不猜，
/// 避免把 `gti` 这类拼写错误包装成 `npx gti`。
public enum PackageRunnerSuggestion {
  /// 向上查找项目标记的最大层数，与动态来源的 `maximumParentWalk` 一致。
  static let maximumParentWalk = 24

  static let npmCommands: Set<String> = [
    "prettier", "eslint", "tsc", "vite", "serve", "http-server", "create-next-app", "create-react-app",
    "create-vite", "degit", "json-server", "nodemon", "ts-node", "tsx", "vercel", "netlify", "wrangler",
    "firebase", "expo", "eas", "pm2", "webpack", "rollup", "esbuild", "parcel", "jest", "vitest", "mocha",
    "playwright", "cypress", "storybook", "turbo", "nx", "lerna", "changeset", "husky", "lint-staged",
    "commitlint", "madge", "depcheck", "npm-check-updates", "ncu", "svgo", "tailwindcss", "postcss",
    "sass", "biome", "oxlint", "knip", "tsup", "nuxi", "astro", "next", "remix", "gatsby", "ng", "nest",
  ]
  static let pypiCommands: Set<String> = [
    "ruff", "black", "isort", "flake8", "mypy", "pyright", "pytest", "httpie", "http", "cookiecutter",
    "pre-commit", "mkdocs", "pipdeptree", "yt-dlp", "ansible", "ansible-playbook", "llm", "aider",
    "jupyter", "jupyterlab", "ipython", "tox", "nox", "twine", "bandit", "pylint", "autopep8", "yapf",
    "pip-audit", "sqlfluff", "dbt", "locust", "mitmproxy", "glances", "pgcli", "mycli", "litecli",
    "copier", "hatch", "pdm", "poetry", "maturin", "pipx",
  ]
  static let gemCommands: Set<String> = [
    "rubocop", "rails", "rake", "rspec", "jekyll", "fastlane", "pod", "solargraph", "brakeman",
    "erb_lint", "standardrb", "sorbet", "srb", "foreman", "puma", "sidekiq", "guard", "thor",
  ]

  /// `command` 是解引号后的命令名；`commandLine` 是保留引号的原始整行，建议直接在它
  /// 前面拼运行器，参数原样跟随。`fileExists` 以当前目录为基准解析相对路径。
  public static func suggestion(
    command: String,
    commandLine: String,
    fileExists: (String) -> Bool
  ) -> CommandCorrection? {
    guard AutocompleteLearnTarget.isBareBinaryName(command), !command.hasPrefix("-") else { return nil }
    var prefix = ""
    var sawNodeLock: String?
    var sawGemfile = false
    var sawPythonLock: String?
    for _ in 0...maximumParentWalk {
      // 项目里确有这个二进制：按锁文件挑运行器，这是最强的证据。
      if fileExists(prefix + "node_modules/.bin/" + command) {
        return make(nodeRunner(prefix: prefix, fileExists: fileExists), command: command, line: commandLine)
      }
      if sawNodeLock == nil { sawNodeLock = nodeLock(prefix: prefix, fileExists: fileExists) }
      if !sawGemfile, fileExists(prefix + "Gemfile") { sawGemfile = true }
      if sawPythonLock == nil { sawPythonLock = pythonRunner(prefix: prefix, fileExists: fileExists) }
      prefix += "../"
    }
    if npmCommands.contains(command) {
      let runner = sawNodeLock == "pnpm-lock.yaml" ? "pnpm dlx" : (sawNodeLock == "bun.lockb" || sawNodeLock == "bun.lock" ? "bunx" : "npx")
      return make(runner, command: command, line: commandLine)
    }
    if pypiCommands.contains(command) {
      return make(sawPythonLock ?? "uvx", command: command, line: commandLine)
    }
    if gemCommands.contains(command), sawGemfile {
      return make("bundle exec", command: command, line: commandLine)
    }
    return nil
  }

  private static func make(_ runner: String, command: String, line: String) -> CommandCorrection {
    CommandCorrection(command: "\(runner) \(line)", kind: .packageRunner(runner: runner))
  }

  private static func nodeLock(prefix: String, fileExists: (String) -> Bool) -> String? {
    ["pnpm-lock.yaml", "bun.lockb", "bun.lock", "yarn.lock", "package-lock.json"].first { fileExists(prefix + $0) }
  }

  /// `node_modules/.bin` 命中时的运行器：按同一层或更上层的锁文件选择。
  private static func nodeRunner(prefix: String, fileExists: (String) -> Bool) -> String {
    var current = prefix
    for _ in 0...maximumParentWalk {
      switch nodeLock(prefix: current, fileExists: fileExists) {
      case "pnpm-lock.yaml": return "pnpm exec"
      case "bun.lockb", "bun.lock": return "bunx"
      case "yarn.lock": return "yarn"
      case "package-lock.json": return "npx"
      default: current += "../"
      }
    }
    return "npx"
  }

  /// Python 项目的运行器：有 uv.lock 用 `uv run`，poetry.lock 用 `poetry run`，pdm.lock 用 `pdm run`。
  private static func pythonRunner(prefix: String, fileExists: (String) -> Bool) -> String? {
    if fileExists(prefix + "uv.lock") { return "uv run" }
    if fileExists(prefix + "poetry.lock") { return "poetry run" }
    if fileExists(prefix + "pdm.lock") { return "pdm run" }
    return nil
  }
}
