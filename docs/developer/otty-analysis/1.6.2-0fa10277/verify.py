#!/usr/bin/env python3
"""只读校验 Otty 导出证据；--local 同时校验本机 Hopper 与完整原始归档。"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import tarfile
from typing import BinaryIO


def stream_digest(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def check_file(path: Path, expected: str, size: int | None = None) -> None:
    if not path.is_file():
        raise ValueError(f"缺少文件：{path}")
    if size is not None and path.stat().st_size != size:
        raise ValueError(f"文件大小不符：{path}")
    with path.open("rb") as stream:
        if stream_digest(stream) != expected:
            raise ValueError(f"SHA-256 不符：{path}")


def verify(base: Path, local_root: Path | None) -> None:
    manifest = json.loads((base / "manifest.json").read_text())
    portable = manifest["portableArchive"]
    archive_path = base / portable["file"]
    check_file(archive_path, portable["sha256"], portable["bytes"])
    expected = {item["name"]: item for item in portable["entries"]}
    seen: set[str] = set()
    with tarfile.open(archive_path, "r:gz") as archive:
        for entry in archive:
            if not entry.isfile() or entry.name not in expected or entry.name in seen:
                raise ValueError(f"压缩包包含非预期项：{entry.name}")
            item = expected[entry.name]
            stream = archive.extractfile(entry)
            if stream is None or entry.size != item["bytes"]:
                raise ValueError(f"压缩包文件大小不符：{entry.name}")
            with stream:
                if stream_digest(stream) != item["sha256"]:
                    raise ValueError(f"压缩包文件 SHA-256 不符：{entry.name}")
            seen.add(entry.name)
    if seen != set(expected):
        raise ValueError("压缩包文件清单不完整")
    print(f"Git 证据包：{len(seen)} 个文件校验通过")
    if local_root is not None:
        local = json.loads((base / "local-manifest.json").read_text())
        for item in local["files"]:
            check_file(local_root / "rea" / item["name"], item["sha256"], item["bytes"])
        for key in ("hopper", "inputSlice"):
            item = manifest[key]
            check_file(local_root / Path(item["file"]).relative_to("local"), item["sha256"], item.get("bytes"))
        print(f"本机归档：{len(local['files'])} 个文件及 Hopper 输入校验通过")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--local", action="store_true", help="校验本机 local/ 原始归档")
    parser.add_argument("--local-root", type=Path, help="显式指定 local/，用于迁移归档校验")
    args = parser.parse_args()
    base = Path(__file__).resolve().parent
    try:
        verify(base, args.local_root or (base / "local" if args.local else None))
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        parser.exit(1, f"校验失败：{error}\n")
