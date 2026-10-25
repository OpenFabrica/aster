// 离线 Fig 输入必须确定性生成，不混入旧翻译或执行输入代码。
import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const script = resolve("scripts/build-fig-specs.mjs");

test("offline input preserves normalized Fig aliases/options and explicit metadata without old overlays", () => {
  const directory = mkdtempSync(join(tmpdir(), "aster-fig-test-"));
  try {
    const input = join(directory, "input.json"), output = join(directory, "output.json");
    writeFileSync(input, JSON.stringify({ source: "upstream", sourceDate: "2026-10-05", sourceRevision: "snapshot", specs: [
      { name: "git", aliases: ["g"], description: "Version control", options: [{ names: ["--version", "-v"], description: "Version" }] },
      { name: "@forge/cli" },
    ] }));
    writeFileSync(output, JSON.stringify({ commands: [{ name: "git", description: { chinese: "旧覆盖" } }] }));
    const run = spawnSync(process.execPath, [script, "--input", input, "--out", output, "--source-date", "2026-10-06", "--source-revision", "override"], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const data = JSON.parse(readFileSync(output, "utf8"));
    assert.equal(data.commands.length, 2);
    assert.equal(data.sourceDate, "2026-10-06");
    assert.equal(data.sourceRevision, "override");
    const git = data.commands.find(item => item.name === "git");
    assert.equal(git.description, "Version control");
    assert.deepEqual(git.aliases, ["g"]);
    assert.deepEqual(git.options[0].names, ["--version", "-v"]);
  } finally { rmSync(directory, { recursive: true }); }
});

test("invalid provenance and duplicate names fail before replacing the previous output", () => {
  const directory = mkdtempSync(join(tmpdir(), "aster-fig-test-"));
  try {
    const input = join(directory, "input.json"), output = join(directory, "output.json");
    writeFileSync(output, "previous");
    for (const value of [
      { source: "learned", specs: [{ name: "git" }] },
      { source: "upstream", specs: [{ name: "git" }, { name: "git" }] },
    ]) {
      writeFileSync(input, JSON.stringify({ sourceDate: "2026-10-05", sourceRevision: "snapshot", ...value }));
      const run = spawnSync(process.execPath, [script, "--input", input, "--out", output], { encoding: "utf8" });
      assert.notEqual(run.status, 0);
      assert.equal(readFileSync(output, "utf8"), "previous");
    }
    const run = spawnSync(process.execPath, [script, "--input", "--out", output], { encoding: "utf8" });
    assert.notEqual(run.status, 0);
    assert.equal(readFileSync(output, "utf8"), "previous");
  } finally { rmSync(directory, { recursive: true }); }
});

test("offline conversion preserves literal candidates, complete lists and descriptions", () => {
  const directory = mkdtempSync(join(tmpdir(), "aster-fig-test-"));
  try {
    const input = join(directory, "input.json"), output = join(directory, "output.json");
    const names = Array.from({ length: 4004 }, (_, index) => `package-${index}`);
    const description = `👩‍✈️\n${"long description ".repeat(200)}\u0000ending`;
    const literals = ["Content-Type: application/json", "alias.*", "分支 名称", "amqp\t", ""];
    writeFileSync(input, JSON.stringify({ source: "upstream", sourceDate: "2026-10-05", sourceRevision: "snapshot", specs: [
      { name: "tool", description, subcommands: [{ name: "two words" }, { name: "" }], options: [{ names: [""] }], args: [
        { suggestions: names },
        { template: ["help", "history"], suggestions: literals.map(name => ({ name, description })) },
      ] },
    ] }));
    const run = spawnSync(process.execPath, [script, "--input", input, "--out", output], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const command = JSON.parse(readFileSync(output, "utf8")).commands[0];
    assert.equal(command.description, description);
    assert.equal(command.subcommands[0].name, "two words");
    assert.equal(command.subcommands[1].name, "");
    assert.deepEqual(command.options[0].names, [""]);
    assert.deepEqual(command.arguments[0].suggestions.map(item => item.name), names);
    assert.deepEqual(command.arguments[1].suggestions.map(item => item.name), literals);
    assert.equal(command.arguments[1].suggestions[0].description, description);
    assert.deepEqual(command.arguments[1].template, ["help", "history"]);
  } finally { rmSync(directory, { recursive: true }); }
});

test("oversized literal data fails without replacing the previous output", () => {
  const directory = mkdtempSync(join(tmpdir(), "aster-fig-test-"));
  try {
    const input = join(directory, "input.json"), output = join(directory, "output.json");
    writeFileSync(output, "previous");
    for (const spec of [
      { name: "tool", description: "x".repeat(16 * 1024 + 1) },
      { name: "tool", args: { suggestions: Array.from({ length: 10001 }, (_, index) => `item-${index}`) } },
      { name: "tool", args: { suggestions: ["x".repeat(513)] } },
      { name: "tool", subcommands: Array.from({ length: 2001 }, (_, index) => ({ name: `child-${index}` })) },
    ]) {
      writeFileSync(input, JSON.stringify({ source: "upstream", sourceDate: "2026-10-05", sourceRevision: "snapshot", specs: [spec] }));
      const run = spawnSync(process.execPath, [script, "--input", input, "--out", output], { encoding: "utf8" });
      assert.notEqual(run.status, 0);
      assert.equal(readFileSync(output, "utf8"), "previous");
    }
  } finally { rmSync(directory, { recursive: true }); }
});
