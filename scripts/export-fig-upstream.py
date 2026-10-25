#!/usr/bin/env python3
"""从显式提供的压缩 SQLite 快照导出公开 upstream Fig 规格，不提取应用代码或学习数据。"""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import sqlite3


def export(source: Path, destination: Path) -> None:
    compressed = source.read_bytes()
    database = lzma.decompress(compressed)
    if not database.startswith(b"SQLite format 3\0"):
        raise ValueError("输入不是 SQLite 数据库")
    # 发行资源没有 WAL sidecar；仅将内存副本的读写版本设为 rollback-journal，
    # 允许 sqlite3.deserialize 只读查询。原始文件与校验散列不发生变化。
    memory = bytearray(database)
    memory[18] = memory[19] = 1
    with sqlite3.connect(":memory:") as connection:
        connection.deserialize(memory)
        connection.execute("PRAGMA query_only=ON")
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("数据库完整性检查失败")
        rows = connection.execute("SELECT name, spec, source FROM specs ORDER BY name").fetchall()
        if not rows or any(origin != "upstream" for _, _, origin in rows):
            raise ValueError("数据库包含非 upstream 来源；不导出任何内容")
        if connection.execute("SELECT count(*) FROM spec_i18n").fetchone()[0] != 0:
            raise ValueError("数据库存在翻译覆盖，须单独核实其来源后再导出")
        metadata = dict(connection.execute("SELECT key, value FROM db_meta"))
        if metadata.get("schema_version") != "2" or int(metadata.get("spec_count", "0")) != len(rows):
            raise ValueError("数据库版本或规格计数不一致")
        specs = []
        for name, encoded, _ in rows:
            spec = json.loads(encoded)
            names = spec.get("name") if isinstance(spec, dict) else None
            names = [names] if isinstance(names, str) else names
            if not isinstance(names, list) or not names or names[0] != name:
                raise ValueError("规格名称与数据库主键不一致")
            specs.append(spec)
    result = {
        "source": "upstream",
        "sourceDate": metadata["fig_current_date"],
        "sourceRevision": metadata["fig_commit"],
        "specs": specs,
        "provenance": {
            "compressedSHA256": hashlib.sha256(compressed).hexdigest(),
            "databaseSHA256": hashlib.sha256(database).hexdigest(),
        },
    }
    # 不覆盖已有证据。相同输入可另选输出路径复跑并比较内容。
    with destination.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, separators=(",", ":"))
        output.write("\n")
    print(f"已导出 {len(specs)} 条 upstream 规格到 {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    export(args.source, args.destination)
