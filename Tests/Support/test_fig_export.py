"""只导出 upstream 规格；非公开来源或翻译覆盖必须拒绝且不产生输出。"""
import importlib.util
import json
import lzma
from pathlib import Path
import sqlite3
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/export-fig-upstream.py"
SPEC = importlib.util.spec_from_file_location("fig_export", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FigExportTests(unittest.TestCase):
    def fixture(self, path, source="upstream", translations=False):
        with sqlite3.connect(":memory:") as db:
            db.executescript("CREATE TABLE specs(name,spec,source); CREATE TABLE spec_i18n(name,lang,overlay); CREATE TABLE db_meta(key,value);")
            db.execute("INSERT INTO specs VALUES(?,?,?)", ("git", '{"name":"git"}', source))
            db.executemany("INSERT INTO db_meta VALUES(?,?)", [("schema_version", "2"), ("spec_count", "1"), ("fig_current_date", "2026-10-05"), ("fig_commit", "snapshot")])
            if translations:
                db.execute("INSERT INTO spec_i18n VALUES('git','zh','{}')")
            path.write_bytes(lzma.compress(db.serialize()))

    def test_only_upstream_specs_and_metadata_are_exported(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "input.lzma", Path(directory) / "output.json"
            self.fixture(source)
            original = source.read_bytes()
            MODULE.export(source, output)
            data = json.loads(output.read_text())
            self.assertEqual(data["specs"], [{"name": "git"}])
            self.assertEqual(data["sourceDate"], "2026-10-05")
            self.assertEqual(source.read_bytes(), original)

    def test_other_sources_and_translations_leave_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "input.lzma", Path(directory) / "output.json"
            for origin, translations in [("learned", False), ("upstream", True)]:
                self.fixture(source, source=origin, translations=translations)
                with self.assertRaises(ValueError):
                    MODULE.export(source, output)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
