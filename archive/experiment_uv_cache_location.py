#!/usr/bin/env python3
"""
Experiment 2: Does co-locating the uv cache fix hardlink dedup?

Installs a small package (numpy) twice with different UV_CACHE_DIR settings
and checks whether hardlinks actually share inodes.

Run from the mounted source directory (not /tmp).
"""

import os
import shutil
import subprocess
import sys
import time

WORK = os.path.join(os.getcwd(), "_hl_experiment")
UV = "uv"

# Find a wheel to test with — download numpy if needed
WHEEL_DIR = os.path.join(WORK, "wheels")
VENV_SAME_FS = os.path.join(WORK, "venv_same_fs")
VENV_DIFF_FS = os.path.join(WORK, "venv_diff_fs")  # will be in /tmp
CACHE_SAME_FS = os.path.join(WORK, "uv_cache")
CACHE_DIFF_FS = "/tmp/_hl_exp_uv_cache"

PYTHON = sys.executable


def check_hardlinks(venv_path):
    """Check nlink on files in site-packages."""
    sp = None
    for root, dirs, files in os.walk(venv_path):
        if root.endswith("site-packages"):
            sp = root
            break
    if not sp:
        return {"error": "no site-packages found"}

    total = 0
    hardlinked = 0
    for root, _, files in os.walk(sp):
        for f in files:
            fp = os.path.join(root, f)
            try:
                st = os.stat(fp)
                total += 1
                if st.st_nlink > 1:
                    hardlinked += 1
            except OSError:
                pass
    return {
        "total": total,
        "hardlinked": hardlinked,
        "ratio": hardlinked / max(total, 1),
    }


def install_and_check(label, venv_path, cache_dir):
    """Create venv, install numpy, check hardlinks."""
    print(f"\n--- {label} ---")
    print(f"  venv:  {venv_path}")
    print(f"  cache: {cache_dir}")
    print("  same device? ", end="")

    venv_dev = os.stat(os.path.dirname(venv_path)).st_dev
    os.makedirs(cache_dir, exist_ok=True)
    cache_dev = os.stat(cache_dir).st_dev
    same = venv_dev == cache_dev
    print(
        f"{'YES' if same else 'NO'} (venv={os.major(venv_dev)}:{os.minor(venv_dev)}, cache={os.major(cache_dev)}:{os.minor(cache_dev)})"
    )

    # Clean
    shutil.rmtree(venv_path, ignore_errors=True)
    shutil.rmtree(cache_dir, ignore_errors=True)
    os.makedirs(cache_dir, exist_ok=True)

    # Create venv
    subprocess.run(
        [UV, "venv", venv_path, "--python", PYTHON], capture_output=True, check=True
    )

    # Install with hardlink mode
    env = os.environ.copy()
    env["UV_CACHE_DIR"] = cache_dir
    wheels = list(f for f in os.listdir(WHEEL_DIR) if f.endswith(".whl"))

    start = time.monotonic()
    subprocess.run(
        [
            UV,
            "pip",
            "install",
            "--python",
            os.path.join(venv_path, "bin", "python3"),
            "--no-deps",
            "--no-index",
            "--find-links",
            WHEEL_DIR,
            "--link-mode=hardlink",
        ]
        + [os.path.join(WHEEL_DIR, w) for w in wheels],
        capture_output=True,
        check=True,
        env=env,
    )
    elapsed = time.monotonic() - start

    result = check_hardlinks(venv_path)
    print(f"  install: {elapsed:.2f}s")
    print(
        f"  files: {result['total']}, hardlinked: {result['hardlinked']} ({result['ratio']:.0%})"
    )

    if result["ratio"] > 0.5:
        print("  HARDLINKS WORKING")
    elif result["ratio"] > 0:
        print("  PARTIAL — some hardlinks work")
    else:
        print("  NO HARDLINKS — full copy, no dedup")

    return result


def main():
    print("=" * 60)
    print("Experiment 2: UV_CACHE_DIR location vs hardlink dedup")
    print("=" * 60)

    # Setup
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(WHEEL_DIR, exist_ok=True)

    # Download numpy (small, fast)
    print("\nDownloading numpy wheel...")
    subprocess.run(
        [
            UV,
            "pip",
            "download",
            "--python-version",
            "3.11",
            "--python-platform",
            "manylinux_2_17_x86_64",
            "--dest",
            WHEEL_DIR,
            "numpy",
        ],
        capture_output=True,
        check=True,
    )

    # Test 1: cache and venv on SAME filesystem (both in cwd)
    r1 = install_and_check(
        "Same filesystem (cache in cwd)", VENV_SAME_FS, CACHE_SAME_FS
    )

    # Test 2: cache in /tmp, venv in cwd (likely DIFFERENT filesystem)
    r2 = install_and_check(
        "Cache in /tmp, venv in cwd",
        os.path.join(WORK, "venv_cache_in_tmp"),
        CACHE_DIFF_FS,
    )

    # Test 3: both in /tmp
    r3 = install_and_check("Both in /tmp", "/tmp/_hl_exp_venv", "/tmp/_hl_exp_cache")

    # Test 4: cache in cwd, venv in /tmp
    r4 = install_and_check(
        "Cache in cwd, venv in /tmp",
        "/tmp/_hl_exp_venv2",
        os.path.join(WORK, "uv_cache2"),
    )

    # Summary
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    results = [
        ("Same fs (both cwd)", r1),
        ("Cache /tmp, venv cwd", r2),
        ("Both /tmp", r3),
        ("Cache cwd, venv /tmp", r4),
    ]
    for label, r in results:
        status = "HARDLINKS" if r["ratio"] > 0.5 else "NO DEDUP"
        print(f"  {label:<30s} {status} ({r['hardlinked']}/{r['total']})")

    # Cleanup
    print(f"\nCleanup: rm -rf {WORK} /tmp/_hl_exp_*")
    shutil.rmtree(WORK, ignore_errors=True)
    for p in [
        CACHE_DIFF_FS,
        "/tmp/_hl_exp_venv",
        "/tmp/_hl_exp_cache",
        "/tmp/_hl_exp_venv2",
    ]:
        shutil.rmtree(p, ignore_errors=True)


if __name__ == "__main__":
    main()
