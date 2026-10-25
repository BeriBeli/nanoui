#!/usr/bin/env python3
"""Optional Python 3 collector, run on the Linux machine hosting the app."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import subprocess
import sys


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().with_name("nanoui-x11-bench"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", default="", help="Record client X server, link, VDI, SSH compression and RTT here")
    parser.add_argument("benchmark_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if platform.system() != "Linux":
        parser.error("Collect X11 measurements on Linux; use nanoui snapshots for host checks")
    forwarded = args.benchmark_args
    if forwarded[:1] == ["--"]:
        forwarded = forwarded[1:]
    env = dict(os.environ, GDK_BACKEND="x11", NANOUI_GTK="3", NANOUI_RENDERER="cpu")
    if not env.get("DISPLAY"):
        parser.error("DISPLAY is empty; connect with working SSH X11 forwarding first")
    # Reserve a new result file. Never silently replace an earlier measurement.
    with args.output.open("x") as output:
        binary = args.binary.resolve()
        manifest_path = binary.with_name("build-manifest.json")
        cpuinfo = read("/proc/cpuinfo") or ""
        cpu_model = next((s.split(":", 1)[1].strip() for s in cpuinfo.splitlines() if s.startswith("model name")), None)
        started = datetime.now(timezone.utc).isoformat()
        binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        launch_error = None
        try:
            result = subprocess.run([str(binary), *forwarded], env=env, stdout=subprocess.PIPE, universal_newlines=True)
        except OSError as error:
            launch_error = str(error)
            result = subprocess.CompletedProcess([str(binary), *forwarded], 127, stdout="")
        try:
            benchmark = json.loads(result.stdout)
        except ValueError:
            benchmark = None
        report = {
            "schema": 1, "started_utc": started, "label": args.label,
            "environment": {"uname": list(platform.uname()), "os_release": read("/etc/os-release"),
                            "cpu_model": cpu_model, "display": env["DISPLAY"],
                            "ssh_connection_present": bool(env.get("SSH_CONNECTION")),
                            "gdk_backend": env["GDK_BACKEND"], "gtk": env["NANOUI_GTK"], "renderer": env["NANOUI_RENDERER"]},
            "binary_sha256": binary_hash,
            "build_manifest": json.loads(manifest_path.read_text()) if manifest_path.exists() else None,
            "exit_code": result.returncode,
            "launch_error": launch_error,
            "max_rss_kib": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
            "benchmark": benchmark,
            "valid": result.returncode == 0 and isinstance(benchmark, dict) and benchmark.get("complete") is True,
        }
        json.dump(report, output, indent=2)
        output.write("\n")
    if not report["valid"]:
        print("Run failed or incomplete; inspect stderr and the saved report.", file=sys.stderr)
        raise SystemExit(1)
    print("Saved:", args.output)


if __name__ == "__main__":
    main()
