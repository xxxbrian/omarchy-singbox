import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
READER = ROOT / "config_reader.py"
SPEC = importlib.util.spec_from_file_location("config_reader", READER)
config_reader = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config_reader)


def run_reader(*args, timeout=2):
    return subprocess.run(
        ["python3", str(READER), *map(str, args)],
        check=True,
        capture_output=True,
        timeout=timeout,
    ).stdout


class ConfigReaderTest(unittest.TestCase):
    def test_reads_small_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "override"
            path.write_text("endpoint = 127.0.0.1:9090\n")
            self.assertEqual(run_reader("read", path), path.read_bytes())

    def test_rejects_symlink_fifo_and_oversized_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("secret")
            link = root / "link"
            link.symlink_to(target)
            fifo = root / "fifo"
            os.mkfifo(fifo)
            large = root / "large"
            large.write_bytes(b"x" * (config_reader.OVERRIDE_LIMIT + 1))

            self.assertEqual(run_reader("read", link), b"")
            self.assertEqual(run_reader("read", fifo), b"")
            self.assertEqual(run_reader("read", large), b"")

    def test_path_replacement_after_fstat_does_not_change_open_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "config.json"
            path.write_bytes(b"original")
            replacement = root / "replacement.json"
            replacement.write_bytes(b"replacement")
            real_fstat = os.fstat

            def replace_path(fd):
                info = real_fstat(fd)
                path.unlink()
                path.symlink_to(replacement)
                return info

            with mock.patch.object(config_reader.os, "fstat", side_effect=replace_path):
                data, _ = config_reader.read_regular(str(path), 1024)
            self.assertEqual(data, b"original")

    def test_merges_directory_in_name_order_and_minimizes_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "01.json").write_text(json.dumps({
                "outbounds": [{"password": "must-not-leak"}],
                "experimental": {"clash_api": {
                    "external_controller": "127.0.0.1:9090",
                    "secret": "first",
                }},
            }))
            (root / "02.json").write_text(json.dumps({
                "experimental": {"clash_api": {"secret": "last"}},
            }))

            result = json.loads(run_reader("config", f"dir:{root}"))
            self.assertEqual(result, {"experimental": {"clash_api": {
                "external_controller": "127.0.0.1:9090",
                "secret": "last",
            }}})
            self.assertNotIn("must-not-leak", json.dumps(result))

    def test_rejects_symlinked_directory_and_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config"
            config.mkdir()
            target = root / "target.json"
            target.write_text('{"experimental":{"clash_api":{}}}')
            (config / "linked.json").symlink_to(target)
            linked_dir = root / "linked-dir"
            linked_dir.symlink_to(config, target_is_directory=True)

            self.assertEqual(run_reader("config", f"dir:{config}"), b"{}")
            self.assertEqual(run_reader("config", f"dir:{linked_dir}"), b"{}")

    def test_rejects_oversized_config_and_too_many_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            large = root / "large.json"
            with large.open("wb") as stream:
                stream.truncate(config_reader.CONFIG_LIMIT + 1)
            self.assertEqual(run_reader("config", f"file:{large}"), b"{}")

            configs = root / "configs"
            configs.mkdir()
            for index in range(config_reader.MAX_CONFIG_FILES + 1):
                (configs / f"{index:03}.json").write_text("{}")
            self.assertEqual(run_reader("config", f"dir:{configs}"), b"{}")

    def test_stat_uses_safe_open(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "config.json"
            path.write_text("{}")
            link = root / "link.json"
            link.symlink_to(path)

            output = run_reader("stat", path).decode()
            self.assertIn("size=2\n", output)
            self.assertIn("readable=1\n", output)
            self.assertEqual(run_reader("stat", link), b"")


if __name__ == "__main__":
    unittest.main()
