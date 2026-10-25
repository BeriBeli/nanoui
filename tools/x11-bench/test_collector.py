"""Reporting checks with a fake child result; never connect to a display."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run as collector


class CollectorTests(unittest.TestCase):
    def invoke(self, folder, child):
        binary = folder / "fixture"
        binary.write_bytes(b"private collector fixture, not an executable")
        output = folder / "result.json"
        argv = ["run.py", "--binary", str(binary), "--output", str(output),
                "--label", "private-test", "--", "--mode=scroll", "--seconds=1"]
        with patch.object(sys, "argv", argv), patch.object(collector.platform, "system", return_value="Linux"), \
             patch.dict(os.environ, {"DISPLAY": ":9876"}), \
             patch.object(collector.subprocess, "run", return_value=child) as launch, \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            collector.main()
        return output, launch

    def test_success_preserves_arguments_and_binary_hash(self):
        with tempfile.TemporaryDirectory(prefix="nanoui-collector-") as name:
            folder = Path(name)
            output, launch = self.invoke(folder, subprocess.CompletedProcess([], 0, '{"complete":true}'))
            report = json.loads(output.read_text())
            self.assertTrue(report["valid"])
            self.assertEqual(launch.call_args.args[0][1:], ["--mode=scroll", "--seconds=1"])
            self.assertEqual(len(report["binary_sha256"]), 64)
            self.assertEqual(launch.call_args.kwargs["env"]["GDK_BACKEND"], "x11")
            self.assertEqual(launch.call_args.kwargs["env"]["NANOUI_GTK"], "3")
            with self.assertRaises(FileExistsError):
                self.invoke(folder, subprocess.CompletedProcess([], 0, '{"complete":true}'))

    def test_failed_or_malformed_runs_never_become_valid(self):
        for code, payload in [(1, '{"complete":true}'), (0, '[]'), (0, 'broken'), (0, '{"complete":false}')]:
            with self.subTest(code=code, payload=payload), tempfile.TemporaryDirectory(prefix="nanoui-collector-") as name:
                folder = Path(name)
                with self.assertRaises(SystemExit):
                    self.invoke(folder, subprocess.CompletedProcess([], code, payload))
                self.assertFalse(json.loads((folder / "result.json").read_text())["valid"])


if __name__ == "__main__":
    unittest.main()
