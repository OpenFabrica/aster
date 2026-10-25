#!/usr/bin/env node
// 把 @withfig/autocomplete npm 包里编译好的 Fig 规格转换成 Aster 的 fig-specs.json(schema v2)。
// 用法: node scripts/build-fig-specs.mjs [--version <npm 版本> | --input <离线 JSON>] [--source-date <日期>] [--source-revision <版本>] [--out <路径>]
// 只保留静态字段；npm 模式沿用中文描述，离线模式只采用输入数据以确保可复现。
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const flags = new Map();
const allowed = new Set(["--version", "--input", "--out", "--source-date", "--source-revision"]);
for (let index = 0; index < args.length; index += 2) {
  const flag = args[index];
  const value = args[index + 1];
  if (!allowed.has(flag) || !value || value.startsWith("--") || flags.has(flag)) {
    throw new Error(`无效参数: ${flag}`);
  }
  flags.set(flag, value);
}
if (flags.has("--input") && flags.has("--version")) throw new Error("--input 与 --version 不可同时使用");
const version = flags.get("--version") ?? "latest";
const inputPath = flags.get("--input");
const outPath = resolve(flags.get("--out") ?? join(scriptDir, "..", "Resources", "autocomplete", "fig-specs.json"));

// 与 Swift 侧 AutocompleteSpecStore 保持一致的上限;超出即在生成阶段失败,而不是让 app 拒绝加载。
const LIMITS = {
  itemNameBytes: 512,
  descriptionBytes: 16 * 1024,
  childrenPerNode: 2000,
  suggestionsPerArgument: 10000,
  nodesPerCommand: 20000,
  encodedBytes: 32 * 1024 * 1024,
};

/// 下载并解包 npm 包,返回解包目录。
function fetchPackage() {
  const dir = mkdtempSync(join(tmpdir(), "fig-specs-"));
  execFileSync("npm", ["pack", `@withfig/autocomplete@${version}`, "--silent"], { cwd: dir, stdio: "pipe" });
  const tarball = readdirSync(dir).find((name) => name.endsWith(".tgz"));
  execFileSync("tar", ["xzf", tarball], { cwd: dir });
  return join(dir, "package");
}

/// 读取旧文件中的中文描述,按命令路径("git/commit")建索引以便合并。
function loadChineseOverlay(path) {
  if (!existsSync(path)) return new Map();
  const map = new Map();
  const walk = (command, prefix) => {
    const key = prefix ? `${prefix}/${command.name}` : command.name;
    const chinese = typeof command.description === "object" ? command.description?.chinese : "";
    if (chinese) map.set(key, chinese);
    for (const sub of command.subcommands ?? []) walk(sub, key);
  };
  try {
    for (const command of JSON.parse(readFileSync(path, "utf8")).commands ?? []) walk(command, "");
  } catch {
    // 旧文件损坏就当没有中文覆盖,不阻塞生成。
  }
  return map;
}

const utf8Length = (value) => Buffer.byteLength(value, "utf8");
const preservedText = (value, maxBytes) => {
  if (typeof value !== "string") return "";
  // 原版逐字复制描述；换行、emoji 的连接符和长说明均不是需要改写的数据。
  // 超出文件导入预算时显式失败，不能悄悄截断一份标称相同版本的规格。
  if (utf8Length(value) > maxBytes) throw new Error(`Fig 文本超过 ${maxBytes} 字节限制`);
  return value;
};
const asArray = (value) => (value == null ? [] : Array.isArray(value) ? value : [value]);
// Fig 候选是字面文本，包含空格、Unicode、通配符和多词子命令。不能按可执行文件名
// 的白名单过滤它们；插入编码属于终端适配层。Tab 是已发布规格中的字面候选字符。
const validItemName = (name) => {
  if (typeof name !== "string") return false;
  if (utf8Length(name) > LIMITS.itemNameBytes) throw new Error("Fig 字面名称超过字节限制");
  if (/[\x00-\x08\x0a-\x1f\x7f]/u.test(name)) throw new Error("Fig 字面名称包含不支持的控制字符");
  return true;
};
const boundedChildren = (items) => {
  if (items.length > LIMITS.childrenPerNode) throw new Error("Fig 节点子项超过数量限制");
  return items;
};

/// 转换参数:保留名称、描述、模板、静态候选和纯字符串数组形式的 generator 脚本。
function convertArgument(arg) {
  if (!arg || typeof arg !== "object") return null;
  const result = { name: preservedText(arg.name ?? "", LIMITS.itemNameBytes) || "arg" };
  const description = preservedText(arg.description, LIMITS.descriptionBytes);
  if (description) result.description = description;
  const template = asArray(arg.template).filter((t) => typeof t === "string");
  if (template.length) result.template = template;
  const suggestions = asArray(arg.suggestions)
    .map((s) => (typeof s === "string" ? { name: s } : s && typeof s === "object" ? { name: asArray(s.name)[0], description: preservedText(s.description, LIMITS.descriptionBytes) } : null))
    .filter((s) => s && validItemName(s.name))
    .map((s) => (s.description ? s : { name: s.name }));
  if (suggestions.length > LIMITS.suggestionsPerArgument) {
    throw new Error(`Fig 参数候选超过 ${LIMITS.suggestionsPerArgument} 项限制`);
  }
  if (suggestions.length) result.suggestions = suggestions;
  const scripts = asArray(arg.generators)
    // 多行 bash 脚本含换行(控制字符),Swift 侧会拒绝,直接丢弃这类 generator。
    .map((g) => g && Array.isArray(g.script) && g.script.length > 0 && g.script.length <= 32
      && g.script.every((s) => typeof s === "string" && utf8Length(s) <= 512 && !/[\p{Cc}\p{Cf}]/u.test(s)) ? g.script : null)
    .filter(Boolean);
  if (scripts.length) result.generatorScripts = scripts.slice(0, 8);
  if (arg.isOptional) result.isOptional = true;
  if (arg.isVariadic) result.isVariadic = true;
  return result;
}

/// 转换选项:Fig 的 name 可能是字符串或数组,统一为 names 数组。
function convertOption(opt) {
  if (!opt || typeof opt !== "object") return null;
  const names = asArray(opt.name ?? opt.names).filter(validItemName);
  if (!names.length) return null;
  const result = { names };
  const description = preservedText(opt.description, LIMITS.descriptionBytes);
  if (description) result.description = description;
  const optionArgs = asArray(opt.args).map(convertArgument).filter(Boolean);
  if (optionArgs.length) result.args = optionArgs;
  if (opt.isRequired) result.isRequired = true;
  if (opt.isRepeatable) result.isRepeatable = true;
  if (opt.hidden) result.hidden = true;
  return result;
}

/// 递归转换命令/子命令。name 数组的首项是主名,其余作为 aliases。
function convertCommand(spec, path, overlay, counter) {
  if (!spec || typeof spec !== "object") return null;
  const names = asArray(spec.name).filter(validItemName);
  if (!names.length) return null;
  counter.nodes += 1;
  if (counter.nodes > LIMITS.nodesPerCommand) throw new Error("Fig 命令节点超过数量限制");
  const key = path ? `${path}/${names[0]}` : names[0];
  const english = preservedText(spec.description, LIMITS.descriptionBytes);
  const chinese = overlay.get(key) ?? "";
  const result = {
    name: names[0],
    description: chinese ? { english, chinese } : english,
  };
  const aliases = [...new Set([...names.slice(1), ...asArray(spec.aliases)].filter(validItemName))];
  if (aliases.length) result.aliases = aliases;
  if (spec.hidden) result.hidden = true;
  const subcommands = boundedChildren(asArray(spec.subcommands)
    .map((sub) => convertCommand(sub, key, overlay, counter))
    .filter(Boolean));
  if (subcommands.length) result.subcommands = subcommands;
  const options = boundedChildren(asArray(spec.options).map(convertOption).filter(Boolean));
  if (options.length) result.options = options;
  const commandArgs = boundedChildren(asArray(spec.args).map(convertArgument).filter(Boolean));
  if (commandArgs.length) result.arguments = commandArgs;
  return result;
}

const commands = [];
const skipped = [];
let sourceDate;
let sourceRevision;
if (inputPath) {
  const input = JSON.parse(readFileSync(resolve(inputPath), "utf8"));
  if (!input || !Array.isArray(input.specs) || input.specs.length === 0) {
    throw new Error("离线输入必须包含非空 specs 数组");
  }
  if (input.source !== undefined && input.source !== "upstream") {
    throw new Error("离线输入不是 upstream Fig 规格");
  }
  sourceDate = flags.get("--source-date") ?? input.sourceDate;
  sourceRevision = flags.get("--source-revision") ?? input.sourceRevision;
  // 精确离线模式不读取输出文件里的旧覆盖，也不执行任何输入代码。
  for (const spec of input.specs) {
    const converted = convertCommand(spec, "", new Map(), { nodes: 0 });
    if (!converted || !converted.name) throw new Error("离线规格包含无效的命令定义");
    commands.push(converted);
  }
} else {
  const packageDir = fetchPackage();
  const packageJson = JSON.parse(readFileSync(join(packageDir, "package.json"), "utf8"));
  const overlay = loadChineseOverlay(outPath);
  const buildDir = join(packageDir, "build");
  // build/ 每个顶层 .js 是一个命令规格；index.js 是清单，dynamic/shared 不在此范围。
  for (const file of readdirSync(buildDir).sort()) {
    if (!file.endsWith(".js") || file === "index.js") continue;
    const name = file.slice(0, -3);
    if (!/^[A-Za-z0-9][A-Za-z0-9._+@-]*$/.test(name)) { skipped.push(name); continue; }
    try {
      const module = await import(pathToFileURL(join(buildDir, file)).href);
      const converted = convertCommand({ ...module.default, name }, "", overlay, { nodes: 0 });
      if (converted) commands.push(converted); else skipped.push(name);
    } catch (error) {
      skipped.push(`${name} (${error.message.split("\n")[0]})`);
    }
  }
  sourceRevision = flags.get("--source-revision") ?? `npm-${packageJson.version}`;
  sourceDate = flags.get("--source-date") ?? new Date().toISOString().slice(0, 10);
  if (!flags.has("--source-date")) {
    try {
      const times = JSON.parse(execFileSync("npm", ["view", `@withfig/autocomplete@${packageJson.version}`, "time", "--json"], { stdio: "pipe" }));
      const published = times?.[packageJson.version] ?? times?.modified;
      if (published) sourceDate = String(published).slice(0, 10);
    } catch {}
  }
}
if (typeof sourceDate !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(sourceDate)
  || typeof sourceRevision !== "string" || !sourceRevision || utf8Length(sourceRevision) > 128
  || /[\p{Cc}\p{Cf}]/u.test(sourceRevision)) {
  throw new Error("需要有效的 sourceDate 与 sourceRevision 元数据");
}
if (new Set(commands.map(command => command.name)).size !== commands.length) {
  throw new Error("离线规格包含重复顶级命令");
}
commands.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

const database = {
  schemaVersion: 2,
  sourceRevision,
  sourceDate,
  commands,
};
const encoded = JSON.stringify(database);
if (utf8Length(encoded) > LIMITS.encodedBytes) {
  console.error(`fig-specs.json 超过 ${LIMITS.encodedBytes} 字节上限: ${utf8Length(encoded)}`);
  process.exit(1);
}
const temporaryPath = `${outPath}.${process.pid}.tmp`;
writeFileSync(temporaryPath, encoded + "\n", { flag: "wx" });
renameSync(temporaryPath, outPath);
console.log(`已写入 ${outPath}: ${commands.length} 条命令, ${(utf8Length(encoded) / 1024 / 1024).toFixed(2)} MB, 版本 ${database.sourceRevision} (${sourceDate})`);
if (skipped.length) console.log(`跳过 ${skipped.length}: ${skipped.join(", ")}`);
