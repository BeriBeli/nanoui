#!/usr/bin/env python3
"""Build/package nanoui's X11 workload; never launch a visible UI."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    paths = [ROOT / name for name in ("build.zig", "build.zig.zon", "LICENSE", "tools/build-x11-bench.py")]
    paths += [p for p in sorted((ROOT / "src").rglob("*")) if p.is_file()]
    paths += [p for p in sorted((ROOT / "tools/x11-bench").iterdir()) if p.is_file()]
    return {str(p.relative_to(ROOT)): digest(p) for p in paths}


def run(command, env):
    print("+", " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=ROOT, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=os.environ.get("ZIG") or shutil.which("zig"))
    parser.add_argument("--native", action="store_true", help="Host build and offscreen tests; no X11 performance claim")
    args = parser.parse_args()
    if not args.zig or subprocess.check_output([args.zig, "version"], text=True).strip() != "0.17.0":
        raise SystemExit("Requires exactly Zig 0.17.0; pass --zig=/path/to/zig")
    identity = inputs()
    suffix = "native" if args.native else "linux"
    out = ROOT / "zig-out" / ("x11-bench-" + suffix)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.environ.get("ZIG_GLOBAL_CACHE_DIR", str(ROOT / ".zig-cache/global")), PYTHONDONTWRITEBYTECODE="1")
    target = [] if args.native else ["-Dtarget=x86_64-linux.3.10-gnu.2.17", "-Dcpu=baseline"]
    command = [args.zig, "build", "--prefix", out, "-Doptimize=ReleaseSafe", *target, "-j4"]
    run([*command, "x11-bench"], env)
    if args.native:
        run([*command, "test-x11-bench"], env)
        run(["python3", "tools/x11-bench/test_collector.py"], env)
    if identity != inputs():
        raise SystemExit("Benchmark or nanoui source changed during build; rerun")
    binary = out / "bin/nanoui-x11-bench"
    if args.native:
        print("Host checks passed:", binary)
        return
    spec = importlib.util.spec_from_file_location("elf_audit", ROOT / "tools/x11-bench/audit_elf.py")
    audit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(audit)
    readelf = shutil.which("readelf") or shutil.which("llvm-readelf")
    if not readelf:
        raise SystemExit("readelf or llvm-readelf required before packaging")
    receipt = audit.audit(binary, readelf)
    package = ROOT / "zig-out/packages/nanoui-x11-bench-linux-x86_64"
    package.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, package / binary.name)
    for name in ("README.md", "run.py"):
        shutil.copy2(ROOT / "tools/x11-bench" / name, package / name)
    shutil.copy2(ROOT / "LICENSE", package / "LICENSE-nanoui")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True).strip())
    manifest = {
        "schema": 1, "target": "x86_64-linux.3.10-gnu.2.17", "cpu": "baseline",
        "optimize": "ReleaseSafe", "zig": "0.17.0", "renderer": "CPU",
        "nanoui": {"revision": revision, "dirty": dirty,
                   "version": re.search(r'\.version\s*=\s*"([^"]+)"', (ROOT / "build.zig.zon").read_text()).group(1)},
        "sources": identity, "elf_audit": receipt,
        "scope": "Cross-build and static ABI checks only; run on the target X11 connection for acceptance.",
    }
    (package / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    archive = package.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        for name in (binary.name, "README.md", "run.py", "LICENSE-nanoui", "build-manifest.json"):
            tar.add(package / name, arcname=package.name + "/" + name)
    print("Built and ABI-audited:", binary)
    print("Target package:", archive)


if __name__ == "__main__":
    main()
