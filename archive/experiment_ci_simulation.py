#!/usr/bin/env python3
"""
Experiment 3: Simulate CI container with mounted source dir.

Typical CI setup:
  - Source dir is a volume mount (real fs, e.g., ext4/xfs)
  - /tmp may be tmpfs (different fs)
  - Bazel output base is under source or home dir (same fs as source)

This experiment puts everything on the mounted volume (simulating correct
Bazel config) and verifies hardlinks work + measures disk savings.

Run this FROM the mounted source directory.
"""
import os
import shutil
import subprocess
import sys
import time

WORK = os.path.join(os.getcwd(), "_ci_sim")
UV = "uv"
PYTHON = sys.executable

UV_CACHE = os.path.join(WORK, "uv_cache")       # simulates sandbox_writable_path on same fs
WHEEL_DIR = os.path.join(WORK, "wheels")
VENV_1 = os.path.join(WORK, "venv_target_a")    # first test target's venv
VENV_2 = os.path.join(WORK, "venv_target_b")    # second test target's venv (same deps)
VENV_3 = os.path.join(WORK, "venv_target_c")    # third (same deps)


def du(path):
    """Actual disk usage in bytes."""
    result = subprocess.run(["du", "-sb", path], capture_output=True, text=True)
    if result.returncode == 0:
        return int(result.stdout.split()[0])
    return -1


def check_nlink(venv_path):
    """Sample nlink values from site-packages."""
    for root, _, files in os.walk(venv_path):
        if "site-packages" in root:
            count = 0
            for f in files[:5]:
                fp = os.path.join(root, f)
                st = os.stat(fp)
                print(f"    {f}: nlink={st.st_nlink}")
                count += 1
            if count:
                return
    print("    (no files found)")


def create_venv(label, venv_path):
    """Create and install into a venv, return elapsed time."""
    shutil.rmtree(venv_path, ignore_errors=True)

    env = os.environ.copy()
    env["UV_CACHE_DIR"] = UV_CACHE

    subprocess.run([UV, "venv", venv_path, "--python", PYTHON],
                   capture_output=True, check=True)

    wheels = [os.path.join(WHEEL_DIR, w) for w in os.listdir(WHEEL_DIR) if w.endswith(".whl")]

    start = time.monotonic()
    result = subprocess.run(
        [UV, "pip", "install",
         "--python", os.path.join(venv_path, "bin", "python3"),
         "--no-deps", "--no-index",
         "--find-links", WHEEL_DIR,
         "--link-mode=hardlink"] + wheels,
        capture_output=True, text=True, env=env)
    elapsed = time.monotonic() - start

    if result.returncode != 0:
        print(f"  INSTALL FAILED: {result.stderr[-300:]}")

    return elapsed


def main():
    print("=" * 60)
    print("Experiment 3: CI simulation — co-located cache + 3 venvs")
    print("=" * 60)

    cwd_dev = os.stat(os.getcwd()).st_dev
    print(f"Working dir device: {os.major(cwd_dev)}:{os.minor(cwd_dev)}")
    print(f"Working dir: {os.getcwd()}")

    # Try to detect if /tmp is different
    tmp_dev = os.stat("/tmp").st_dev
    if tmp_dev != cwd_dev:
        print(f"/tmp device:        {os.major(tmp_dev)}:{os.minor(tmp_dev)} — DIFFERENT filesystem!")
        print("This confirms hardlinks would fail with UV_CACHE_DIR=/tmp/...")
    else:
        print(f"/tmp device:        {os.major(tmp_dev)}:{os.minor(tmp_dev)} — same filesystem")
    print()

    # Setup
    for d in [WORK, UV_CACHE, WHEEL_DIR]:
        os.makedirs(d, exist_ok=True)

    # Download torch CUDA (the real test) — or fall back to smaller set
    print("Downloading torch (CUDA) + numpy + pytest...")
    result = subprocess.run(
        [UV, "pip", "download",
         "--python-version", "3.11",
         "--python-platform", "manylinux_2_17_x86_64",
         "--extra-index-url", "https://download.pytorch.org/whl/cu124",
         "--dest", WHEEL_DIR,
         "torch", "numpy", "pytest"],
        capture_output=True, text=True)

    if result.returncode != 0:
        print("CUDA download failed, trying CPU torch...")
        subprocess.run(
            [UV, "pip", "download",
             "--python-version", "3.11",
             "--python-platform", "manylinux_2_17_x86_64",
             "--dest", WHEEL_DIR,
             "torch", "numpy", "pytest"],
            capture_output=True, check=True)

    wheel_count = len([f for f in os.listdir(WHEEL_DIR) if f.endswith(".whl")])
    wheel_bytes = sum(os.path.getsize(os.path.join(WHEEL_DIR, f))
                      for f in os.listdir(WHEEL_DIR) if f.endswith(".whl"))
    print(f"Wheels: {wheel_count} ({wheel_bytes / 1e9:.2f} GB)")
    print()

    # Create 3 identical venvs (simulates 3 test targets with same deps)
    print("--- Creating 3 venvs with UV_CACHE_DIR on same filesystem ---")

    t1 = create_venv("venv_1", VENV_1)
    print(f"  Venv 1: {t1:.2f}s (cold uv cache)")
    check_nlink(VENV_1)

    t2 = create_venv("venv_2", VENV_2)
    print(f"  Venv 2: {t2:.2f}s (warm uv cache)")
    check_nlink(VENV_2)

    t3 = create_venv("venv_3", VENV_3)
    print(f"  Venv 3: {t3:.2f}s (warm uv cache)")
    print()

    # Measure disk usage
    print("--- Disk usage ---")
    cache_du = du(UV_CACHE)
    v1_du = du(VENV_1)
    v2_du = du(VENV_2)
    v3_du = du(VENV_3)
    total_du = du(WORK)

    print(f"  UV cache:     {cache_du / 1e9:.2f} GB")
    print(f"  Venv 1:       {v1_du / 1e9:.2f} GB")
    print(f"  Venv 2:       {v2_du / 1e9:.2f} GB")
    print(f"  Venv 3:       {v3_du / 1e9:.2f} GB")
    print(f"  Wheels:       {wheel_bytes / 1e9:.2f} GB")
    print(f"  Total work:   {total_du / 1e9:.2f} GB")
    print()

    naive_total = cache_du + 3 * v1_du  # what it would be without hardlinks
    print(f"  Without hardlink dedup (3 full copies): ~{(3 * v1_du) / 1e9:.1f} GB for venvs alone")
    print(f"  Actual total:                           {total_du / 1e9:.1f} GB")

    if v2_du < v1_du * 0.1:
        print(f"\n  HARDLINKS WORKING — venv 2+3 are nearly free ({v2_du / 1e6:.1f} MB each)")
    elif v2_du < v1_du * 0.5:
        print(f"\n  PARTIAL DEDUP — venv 2+3 are smaller but not free")
    else:
        print(f"\n  NO DEDUP — each venv is a full copy")
        print(f"  Wasted disk: {(2 * v1_du) / 1e9:.1f} GB")

    # Cleanup
    print(f"\nCleanup: rm -rf {WORK}")
    shutil.rmtree(WORK, ignore_errors=True)


if __name__ == "__main__":
    main()
