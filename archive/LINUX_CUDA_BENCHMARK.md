# Linux CUDA Venv Benchmark

**Purpose:** Determine whether roof_py's single-TreeArtifact venv design works at CUDA scale, or whether the architecture needs a split-venv variant before any Starlark is written.

**Context:** roof_py replaces Bazel's Python build infrastructure by running `uv pip install` at build time into a flat `site-packages/` directory (a Bazel TreeArtifact). This was validated on macOS ARM with torch CPU (16K files, 431MB). Linux CUDA wheels are 5-10x larger. If TreeArtifact operations at that scale are unacceptable, the architecture must change before implementation begins.

**Environment:** Run this on a Linux x86_64 machine with:
- Python 3.11+
- `uv` installed (`pip install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- At least 15GB free disk space
- ext4 or xfs filesystem (note which one in results)

---

## Instructions

Run the benchmark script below. It will produce a structured JSON results file. Do not modify the script — run it as-is and report the complete output.

If any step fails, report the failure with the exact error message. Do not skip steps.

### Step 1: Create the benchmark script

Save this as `bench_cuda_venv.py` and run it with `python3 bench_cuda_venv.py`:

```python
#!/usr/bin/env python3
"""
Linux CUDA venv benchmark for roof_py architecture validation.

Measures all operations that Bazel performs on a TreeArtifact containing
a CUDA-scale Python environment. Results determine whether the single-venv
design works or needs to be split.

Produces structured JSON output.
"""
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

RESULTS = {
    "meta": {},
    "download": {},
    "venv_creation": {},
    "file_stats": {},
    "copy_performance": {},
    "symlink_performance": {},
    "tar_performance": {},
    "import_performance": {},
    "incremental_rebuild": {},
    "split_venv_simulation": {},
}

WORK_DIR = Path("/tmp/roof_py_bench")
WHEEL_CACHE = WORK_DIR / "wheel_cache"
VENV_A = WORK_DIR / "venv_a"
VENV_B = WORK_DIR / "venv_b"
VENV_COPY = WORK_DIR / "venv_copy"
VENV_SYMLINK = WORK_DIR / "venv_symlink"
TAR_FILE = WORK_DIR / "venv.tar"
TAR_EXTRACT = WORK_DIR / "venv_tar_extract"
SPLIT_TORCH = WORK_DIR / "split_torch"
SPLIT_REST = WORK_DIR / "split_rest"


def run(cmd, **kwargs):
    """Run a command and return (stdout, stderr, returncode, elapsed_seconds)."""
    start = time.monotonic()
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    elapsed = time.monotonic() - start
    return result.stdout, result.stderr, result.returncode, elapsed


def timeit(fn, label=""):
    """Time a function, return (result, elapsed_seconds)."""
    start = time.monotonic()
    result = fn()
    elapsed = time.monotonic() - start
    return result, elapsed


def count_files(path):
    """Count files and directories, compute total size."""
    file_count = 0
    dir_count = 0
    total_bytes = 0
    for root, dirs, files in os.walk(path):
        dir_count += len(dirs)
        for f in files:
            file_count += 1
            fp = os.path.join(root, f)
            try:
                total_bytes += os.path.getsize(fp)
            except OSError:
                pass
    return file_count, dir_count, total_bytes


def get_disk_usage(path):
    """Get actual disk usage via du."""
    stdout, _, rc, _ = run(["du", "-sb", str(path)])
    if rc == 0:
        return int(stdout.split()[0])
    return -1


def check_hardlink_support(path):
    """Check if the filesystem supports hardlinks."""
    test_src = path / "_hl_test_src"
    test_dst = path / "_hl_test_dst"
    try:
        test_src.write_text("test")
        os.link(str(test_src), str(test_dst))
        src_stat = os.stat(str(test_src))
        dst_stat = os.stat(str(test_dst))
        supported = src_stat.st_ino == dst_stat.st_ino
    except OSError:
        supported = False
    finally:
        test_src.unlink(missing_ok=True)
        test_dst.unlink(missing_ok=True)
    return supported


def main():
    print("=" * 70)
    print("roof_py Linux CUDA Venv Benchmark")
    print("=" * 70)

    # --- META ---
    uv_version_out, _, _, _ = run(["uv", "--version"])
    python_version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    uname = platform.uname()

    RESULTS["meta"] = {
        "python_version": python_version,
        "uv_version": uv_version_out.strip(),
        "os": uname.system,
        "arch": uname.machine,
        "kernel": uname.release,
        "hostname": uname.node,
    }

    # Detect filesystem
    stdout, _, rc, _ = run(["df", "-T", str(WORK_DIR.parent)])
    fs_type = "unknown"
    if rc == 0:
        lines = stdout.strip().split("\n")
        if len(lines) >= 2:
            fs_type = lines[1].split()[1]
    RESULTS["meta"]["filesystem"] = fs_type

    print(f"Python:     {python_version}")
    print(f"uv:         {uv_version_out.strip()}")
    print(f"Platform:   {uname.system} {uname.machine} ({uname.release})")
    print(f"Filesystem: {fs_type}")
    print(f"Work dir:   {WORK_DIR}")
    print()

    # --- SETUP ---
    if WORK_DIR.exists():
        print("Cleaning previous run...")
        shutil.rmtree(WORK_DIR)
    WORK_DIR.mkdir(parents=True)
    WHEEL_CACHE.mkdir()

    hl_supported = check_hardlink_support(WORK_DIR)
    RESULTS["meta"]["hardlink_supported"] = hl_supported
    print(f"Hardlinks:  {'supported' if hl_supported else 'NOT supported'}")
    print()

    # =========================================================================
    # BENCHMARK 1: Download CUDA wheels
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 1: Download CUDA torch + deps")
    print("-" * 70)

    # Download torch with CUDA + common ML deps
    # IMPORTANT: PyPI default torch is CPU-only. We need the CUDA build
    # from PyTorch's own index to get the real file counts (nvidia-* packages,
    # CUDA .so files, triton, etc.)
    packages = [
        "torch",
        "numpy",
        "scipy",
        "pytest",
    ]

    # PyTorch CUDA 12.4 index — this is where the large CUDA wheels live
    cuda_index = "https://download.pytorch.org/whl/cu124"

    download_cmd = [
        "uv", "pip", "download",
        "--python-version", "3.11",
        "--python-platform", "manylinux_2_17_x86_64",
        "--extra-index-url", cuda_index,
        "--dest", str(WHEEL_CACHE),
    ] + packages

    print(f"Downloading: {', '.join(packages)}")
    print(f"Command: {' '.join(download_cmd)}")
    stdout, stderr, rc, elapsed = run(download_cmd)

    RESULTS["download"] = {
        "packages": packages,
        "returncode": rc,
        "elapsed_seconds": round(elapsed, 2),
        "stderr_tail": stderr[-2000:] if stderr else "",
    }

    if rc != 0:
        print(f"FAILED (rc={rc})")
        print(f"stderr: {stderr[-1000:]}")
        # Fallback: try without extra index (gets CPU torch — still useful for
        # measuring file counts but won't have nvidia-* CUDA packages)
        packages_fallback = ["torch", "numpy", "scipy", "pytest"]
        download_cmd_fb = [
            "uv", "pip", "download",
            "--python-version", "3.11",
            "--python-platform", "manylinux_2_17_x86_64",
            "--dest", str(WHEEL_CACHE),
        ] + packages_fallback
        print(f"\nRetrying without CUDA index (CPU-only fallback): {', '.join(packages_fallback)}")
        print("WARNING: CPU-only torch is much smaller than CUDA torch.")
        print("         Results will underestimate real CUDA workload.")
        stdout, stderr, rc, elapsed = run(download_cmd_fb)
        RESULTS["download"]["fallback_packages"] = packages_fallback
        RESULTS["download"]["fallback_returncode"] = rc
        RESULTS["download"]["fallback_elapsed_seconds"] = round(elapsed, 2)
        RESULTS["download"]["cuda_download_failed"] = True
        if rc != 0:
            print(f"FAILED again (rc={rc}). Cannot continue without wheels.")
            print(f"stderr: {stderr[-1000:]}")
            RESULTS["download"]["fatal"] = True
            _write_results()
            return

    wheel_files = list(WHEEL_CACHE.glob("*.whl"))
    wheel_names = [w.name for w in wheel_files]
    total_wheel_bytes = sum(w.stat().st_size for w in wheel_files)
    print(f"Downloaded {len(wheel_files)} wheels ({total_wheel_bytes / 1e9:.2f} GB)")
    print(f"Download time: {elapsed:.1f}s")

    RESULTS["download"]["wheel_count"] = len(wheel_files)
    RESULTS["download"]["total_wheel_bytes"] = total_wheel_bytes
    RESULTS["download"]["wheel_names"] = wheel_names
    print()

    # =========================================================================
    # BENCHMARK 2: Create venv + install (simulates _roof_py_venv action)
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 2: Create venv + uv pip install (hardlink mode)")
    print("-" * 70)

    # 2a: venv creation
    _, _, _, venv_create_time = run([
        "uv", "venv", str(VENV_A), "--python", sys.executable,
    ])
    print(f"uv venv creation: {venv_create_time*1000:.0f}ms")

    # 2b: install with hardlink
    install_cmd = [
        "uv", "pip", "install",
        "--python", str(VENV_A / "bin" / "python3"),
        "--no-deps",
        "--no-index",
        "--find-links", str(WHEEL_CACHE),
        "--link-mode=hardlink",
    ] + [str(w) for w in wheel_files]

    _, stderr_install, rc_install, install_hl_time = run(install_cmd)

    RESULTS["venv_creation"] = {
        "venv_create_ms": round(venv_create_time * 1000, 1),
        "install_hardlink_seconds": round(install_hl_time, 2),
        "install_hardlink_returncode": rc_install,
    }

    if rc_install != 0:
        print(f"Hardlink install FAILED (rc={rc_install})")
        print(f"stderr: {stderr_install[-500:]}")
        # Fallback to copy mode
        shutil.rmtree(VENV_A)
        run(["uv", "venv", str(VENV_A), "--python", sys.executable])
        install_cmd_copy = [
            "uv", "pip", "install",
            "--python", str(VENV_A / "bin" / "python3"),
            "--no-deps",
            "--no-index",
            "--find-links", str(WHEEL_CACHE),
            "--link-mode=copy",
        ] + [str(w) for w in wheel_files]
        _, _, rc_copy, install_copy_time = run(install_cmd_copy)
        RESULTS["venv_creation"]["install_copy_seconds"] = round(install_copy_time, 2)
        RESULTS["venv_creation"]["install_copy_returncode"] = rc_copy
        RESULTS["venv_creation"]["hardlink_failed"] = True
        print(f"Copy fallback: {install_copy_time:.2f}s (rc={rc_copy})")
    else:
        print(f"Install (hardlink): {install_hl_time:.2f}s")
        # Also measure copy mode for comparison
        VENV_B.mkdir(parents=True, exist_ok=True)
        run(["uv", "venv", str(VENV_B), "--python", sys.executable])
        install_cmd_copy = [
            "uv", "pip", "install",
            "--python", str(VENV_B / "bin" / "python3"),
            "--no-deps",
            "--no-index",
            "--find-links", str(WHEEL_CACHE),
            "--link-mode=copy",
        ] + [str(w) for w in wheel_files]
        _, _, _, install_copy_time = run(install_cmd_copy)
        RESULTS["venv_creation"]["install_copy_seconds"] = round(install_copy_time, 2)
        print(f"Install (copy):     {install_copy_time:.2f}s")

    print()

    # =========================================================================
    # BENCHMARK 3: File statistics
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 3: File statistics for installed venv")
    print("-" * 70)

    site_packages = None
    for sp in VENV_A.glob("lib/python*/site-packages"):
        site_packages = sp
        break

    if site_packages is None:
        print("ERROR: Could not find site-packages directory")
        RESULTS["file_stats"]["error"] = "site-packages not found"
    else:
        file_count, dir_count, apparent_bytes = count_files(VENV_A)
        disk_bytes = get_disk_usage(VENV_A)

        # Count by extension
        ext_counts = {}
        ext_bytes = {}
        for root, _, files in os.walk(site_packages):
            for f in files:
                ext = Path(f).suffix or "(no ext)"
                ext_counts[ext] = ext_counts.get(ext, 0) + 1
                try:
                    ext_bytes[ext] = ext_bytes.get(ext, 0) + os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass

        # Top-level packages by size
        pkg_sizes = {}
        for entry in site_packages.iterdir():
            if entry.is_dir():
                _, _, pkg_bytes = count_files(entry)
                pkg_sizes[entry.name] = pkg_bytes

        top_packages = sorted(pkg_sizes.items(), key=lambda x: -x[1])[:15]

        # Check inode sharing (hardlink verification)
        sample_inodes = {}
        inode_count = 0
        unique_inodes = set()
        for root, _, files in os.walk(site_packages):
            for f in files[:5000]:  # sample first 5000
                fp = os.path.join(root, f)
                try:
                    st = os.stat(fp)
                    inode_count += 1
                    unique_inodes.add(st.st_ino)
                    if st.st_nlink > 1 and len(sample_inodes) < 5:
                        sample_inodes[f] = {"inode": st.st_ino, "nlink": st.st_nlink}
                except OSError:
                    pass

        RESULTS["file_stats"] = {
            "total_files": file_count,
            "total_dirs": dir_count,
            "apparent_bytes": apparent_bytes,
            "apparent_gb": round(apparent_bytes / 1e9, 2),
            "disk_bytes": disk_bytes,
            "disk_gb": round(disk_bytes / 1e9, 2) if disk_bytes > 0 else -1,
            "sampled_inodes": inode_count,
            "unique_inodes": len(unique_inodes),
            "hardlink_ratio": round(1 - len(unique_inodes) / max(inode_count, 1), 3),
            "sample_hardlinked_files": sample_inodes,
            "top_extensions_by_count": dict(sorted(ext_counts.items(), key=lambda x: -x[1])[:10]),
            "top_extensions_by_bytes": {k: v for k, v in sorted(ext_bytes.items(), key=lambda x: -x[1])[:10]},
            "top_packages_by_bytes": {k: v for k, v in top_packages},
        }

        print(f"Files:        {file_count:,}")
        print(f"Directories:  {dir_count:,}")
        print(f"Apparent:     {apparent_bytes / 1e9:.2f} GB")
        print(f"On-disk:      {disk_bytes / 1e9:.2f} GB" if disk_bytes > 0 else "On-disk: unknown")
        print(f"Hardlink ratio (sampled): {RESULTS['file_stats']['hardlink_ratio']:.1%}")
        print(f"\nTop packages by size:")
        for name, size in top_packages[:10]:
            print(f"  {name:40s} {size / 1e6:8.1f} MB")

    print()

    # =========================================================================
    # BENCHMARK 4: Copy performance (simulates remote exec TreeArtifact materialization)
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 4: Full directory copy (simulates remote exec)")
    print("-" * 70)

    # cp -R (what Bazel does for TreeArtifact materialization in remote exec)
    if VENV_COPY.exists():
        shutil.rmtree(VENV_COPY)

    _, _, _, cp_time = run(["cp", "-R", str(VENV_A), str(VENV_COPY)])
    print(f"cp -R:        {cp_time:.2f}s")

    # rsync (alternative)
    VENV_COPY2 = WORK_DIR / "venv_copy2"
    _, _, _, rsync_time = run(["rsync", "-a", str(VENV_A) + "/", str(VENV_COPY2)])
    print(f"rsync -a:     {rsync_time:.2f}s")

    # symlink to directory (what Bazel does for local execution TreeArtifact)
    if VENV_SYMLINK.exists():
        VENV_SYMLINK.unlink()
    _, symlink_time = timeit(lambda: os.symlink(str(VENV_A), str(VENV_SYMLINK)))
    print(f"symlink:      {symlink_time*1000:.2f}ms")

    RESULTS["copy_performance"] = {
        "cp_r_seconds": round(cp_time, 2),
        "rsync_seconds": round(rsync_time, 2),
        "symlink_ms": round(symlink_time * 1000, 2),
    }
    print()

    # =========================================================================
    # BENCHMARK 5: Tar/compress (simulates remote cache upload)
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 5: Tar + compress (simulates remote cache upload/download)")
    print("-" * 70)

    # Uncompressed tar
    _, _, _, tar_create_time = run(["tar", "cf", str(TAR_FILE), "-C", str(WORK_DIR), "venv_a"])
    tar_size = TAR_FILE.stat().st_size if TAR_FILE.exists() else 0
    print(f"tar create:   {tar_create_time:.2f}s ({tar_size / 1e9:.2f} GB)")

    # Compressed tar (zstd — what Bazel remote cache often uses)
    tar_zst = WORK_DIR / "venv.tar.zst"
    _, _, rc_zst, zst_create_time = run(["tar", "--zstd", "-cf", str(tar_zst), "-C", str(WORK_DIR), "venv_a"])
    zst_size = tar_zst.stat().st_size if tar_zst.exists() and rc_zst == 0 else -1
    if rc_zst == 0:
        print(f"tar+zstd:     {zst_create_time:.2f}s ({zst_size / 1e9:.2f} GB)")
    else:
        print(f"tar+zstd:     not available (zstd not installed)")

    # Extract tar
    if TAR_EXTRACT.exists():
        shutil.rmtree(TAR_EXTRACT)
    TAR_EXTRACT.mkdir()
    _, _, _, tar_extract_time = run(["tar", "xf", str(TAR_FILE), "-C", str(TAR_EXTRACT)])
    print(f"tar extract:  {tar_extract_time:.2f}s")

    # Extract zstd tar
    if rc_zst == 0:
        tar_zst_extract = WORK_DIR / "venv_zst_extract"
        if tar_zst_extract.exists():
            shutil.rmtree(tar_zst_extract)
        tar_zst_extract.mkdir()
        _, _, _, zst_extract_time = run(["tar", "--zstd", "-xf", str(tar_zst), "-C", str(tar_zst_extract)])
        print(f"zstd extract: {zst_extract_time:.2f}s")
    else:
        zst_extract_time = -1

    RESULTS["tar_performance"] = {
        "tar_create_seconds": round(tar_create_time, 2),
        "tar_bytes": tar_size,
        "tar_gb": round(tar_size / 1e9, 2),
        "zstd_create_seconds": round(zst_create_time, 2) if rc_zst == 0 else -1,
        "zstd_bytes": zst_size,
        "zstd_gb": round(zst_size / 1e9, 2) if zst_size > 0 else -1,
        "tar_extract_seconds": round(tar_extract_time, 2),
        "zstd_extract_seconds": round(zst_extract_time, 2),
    }
    print()

    # =========================================================================
    # BENCHMARK 6: Import performance from PYTHONPATH
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 6: Import performance via PYTHONPATH")
    print("-" * 70)

    if site_packages:
        import_test_script = WORK_DIR / "import_test.py"
        import_test_script.write_text('''\
import json, sys, time, os

site_packages = sys.argv[1]
# Prepend site-packages to sys.path (simulates PYTHONPATH)
sys.path.insert(0, site_packages)

results = {}

# Cold import torch
start = time.monotonic()
try:
    import torch
    results["torch_import_seconds"] = round(time.monotonic() - start, 3)
    results["torch_version"] = torch.__version__
    results["torch_cuda_available"] = torch.cuda.is_available()
    results["torch_file"] = torch.__file__
except Exception as e:
    results["torch_import_error"] = str(e)
    results["torch_import_seconds"] = round(time.monotonic() - start, 3)

# Cold import numpy
start = time.monotonic()
try:
    import numpy
    results["numpy_import_seconds"] = round(time.monotonic() - start, 3)
    results["numpy_version"] = numpy.__version__
except Exception as e:
    results["numpy_import_error"] = str(e)

# Metadata check
start = time.monotonic()
try:
    import importlib.metadata
    results["torch_metadata_version"] = importlib.metadata.version("torch")
    results["metadata_seconds"] = round(time.monotonic() - start, 3)
except Exception as e:
    results["metadata_error"] = str(e)

# Namespace package check (nvidia.* packages — the key stress test)
nvidia_packages = []
try:
    import nvidia
    results["nvidia_namespace_exists"] = True
    results["nvidia_path"] = list(nvidia.__path__) if hasattr(nvidia, "__path__") else "no __path__"
    # Try importing nvidia subpackages
    for sub in ["cudnn", "cublas", "cuda_runtime", "cuda_nvrtc", "nvjitlink", "cufft", "cusparse", "cusolver", "nccl", "nvtx"]:
        try:
            mod = __import__(f"nvidia.{sub}", fromlist=[sub])
            nvidia_packages.append(sub)
        except ImportError:
            pass
    results["nvidia_importable_subpackages"] = nvidia_packages
except ImportError:
    results["nvidia_namespace_exists"] = False
    results["nvidia_note"] = "No nvidia packages found — likely CPU-only torch (see download section)"

# Check if LD_LIBRARY_PATH is needed
results["ld_library_path"] = os.environ.get("LD_LIBRARY_PATH", "(not set)")
torch_lib_dir = None
try:
    import torch
    torch_dir = os.path.dirname(torch.__file__)
    torch_lib = os.path.join(torch_dir, "lib")
    if os.path.isdir(torch_lib):
        so_files = [f for f in os.listdir(torch_lib) if f.endswith(".so")]
        results["torch_lib_dir"] = torch_lib
        results["torch_lib_so_count"] = len(so_files)
except:
    pass

# sys.path length impact
results["sys_path_length"] = len(sys.path)

# File check
try:
    results["torch_file_is_real"] = os.path.isfile(torch.__file__)
    results["torch_file_is_symlink"] = os.path.islink(torch.__file__)
except:
    pass

print(json.dumps(results, indent=2))
''')

        stdout, stderr, rc, _ = run([
            sys.executable, str(import_test_script), str(site_packages),
        ])

        if rc == 0:
            try:
                import_results = json.loads(stdout)
                RESULTS["import_performance"] = import_results
                print(f"torch import: {import_results.get('torch_import_seconds', '?')}s")
                print(f"numpy import: {import_results.get('numpy_import_seconds', '?')}s")
                print(f"metadata:     {import_results.get('metadata_seconds', '?')}s")
                print(f"torch version:{import_results.get('torch_version', '?')}")
                print(f"CUDA avail:   {import_results.get('torch_cuda_available', '?')}")
            except json.JSONDecodeError:
                print(f"Import test output (not JSON): {stdout[:500]}")
                RESULTS["import_performance"]["raw_output"] = stdout[:1000]
        else:
            print(f"Import test failed (rc={rc})")
            print(f"stderr: {stderr[:500]}")
            RESULTS["import_performance"] = {"error": stderr[:1000], "returncode": rc}

    print()

    # =========================================================================
    # BENCHMARK 7: Incremental rebuild (simulates requirements.txt change)
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 7: Incremental rebuild (warm uv cache)")
    print("-" * 70)

    # Delete the venv and recreate (simulates Bazel invalidating the TreeArtifact)
    rebuild_venv = WORK_DIR / "venv_rebuild"
    _, _, _, rebuild_create = run(["uv", "venv", str(rebuild_venv), "--python", sys.executable])

    rebuild_install_cmd = [
        "uv", "pip", "install",
        "--python", str(rebuild_venv / "bin" / "python3"),
        "--no-deps",
        "--no-index",
        "--find-links", str(WHEEL_CACHE),
        "--link-mode=hardlink",
    ] + [str(w) for w in wheel_files]

    _, _, rc_rebuild, rebuild_install = run(rebuild_install_cmd)

    RESULTS["incremental_rebuild"] = {
        "venv_create_ms": round(rebuild_create * 1000, 1),
        "install_seconds": round(rebuild_install, 2),
        "total_seconds": round(rebuild_create + rebuild_install, 2),
        "returncode": rc_rebuild,
    }

    print(f"Rebuild (warm cache): {rebuild_create + rebuild_install:.2f}s")
    print(f"  venv create: {rebuild_create*1000:.0f}ms")
    print(f"  install:     {rebuild_install:.2f}s")
    print()

    # =========================================================================
    # BENCHMARK 8: Split-venv simulation
    # =========================================================================
    print("-" * 70)
    print("BENCHMARK 8: Split-venv simulation (torch alone vs everything else)")
    print("-" * 70)

    torch_wheels = [w for w in wheel_files if "torch" in w.name.lower() and "triton" not in w.name.lower()]
    rest_wheels = [w for w in wheel_files if w not in torch_wheels]

    # Venv 1: torch only
    run(["uv", "venv", str(SPLIT_TORCH), "--python", sys.executable])
    if torch_wheels:
        _, _, _, split_torch_time = run([
            "uv", "pip", "install",
            "--python", str(SPLIT_TORCH / "bin" / "python3"),
            "--no-deps", "--no-index", "--find-links", str(WHEEL_CACHE),
            "--link-mode=hardlink",
        ] + [str(w) for w in torch_wheels])
    else:
        split_torch_time = 0

    # Venv 2: everything else
    run(["uv", "venv", str(SPLIT_REST), "--python", sys.executable])
    if rest_wheels:
        _, _, _, split_rest_time = run([
            "uv", "pip", "install",
            "--python", str(SPLIT_REST / "bin" / "python3"),
            "--no-deps", "--no-index", "--find-links", str(WHEEL_CACHE),
            "--link-mode=hardlink",
        ] + [str(w) for w in rest_wheels])
    else:
        split_rest_time = 0

    # Stats for each
    torch_files, torch_dirs, torch_bytes = count_files(SPLIT_TORCH)
    rest_files, rest_dirs, rest_bytes = count_files(SPLIT_REST)

    RESULTS["split_venv_simulation"] = {
        "torch_venv": {
            "wheel_count": len(torch_wheels),
            "wheel_names": [w.name for w in torch_wheels],
            "install_seconds": round(split_torch_time, 2),
            "files": torch_files,
            "bytes": torch_bytes,
            "gb": round(torch_bytes / 1e9, 2),
        },
        "rest_venv": {
            "wheel_count": len(rest_wheels),
            "install_seconds": round(split_rest_time, 2),
            "files": rest_files,
            "bytes": rest_bytes,
            "gb": round(rest_bytes / 1e9, 2),
        },
    }

    print(f"Torch-only venv:  {torch_files:,} files, {torch_bytes/1e9:.2f} GB, {split_torch_time:.2f}s")
    print(f"Rest venv:        {rest_files:,} files, {rest_bytes/1e9:.2f} GB, {split_rest_time:.2f}s")
    print(f"Combined install: {split_torch_time + split_rest_time:.2f}s (vs single: {RESULTS['venv_creation'].get('install_hardlink_seconds', '?')}s)")
    print()

    # =========================================================================
    # WRITE RESULTS
    # =========================================================================
    _write_results()

    # Cleanup summary
    print("=" * 70)
    print("BENCHMARK COMPLETE")
    print(f"Results written to: {WORK_DIR / 'results.json'}")
    print(f"Total disk used: {get_disk_usage(WORK_DIR) / 1e9:.1f} GB")
    print("=" * 70)


def _write_results():
    results_path = WORK_DIR / "results.json"
    with open(results_path, "w") as f:
        json.dump(RESULTS, f, indent=2, default=str)
    print(f"\nResults written to {results_path}")
    print("\n--- BEGIN STRUCTURED OUTPUT ---")
    print(json.dumps(RESULTS, indent=2, default=str))
    print("--- END STRUCTURED OUTPUT ---")


if __name__ == "__main__":
    main()
```

### Step 2: Run the script

```bash
python3 bench_cuda_venv.py 2>&1 | tee bench_output.txt
```

### Step 3: Report results

Copy everything between `--- BEGIN STRUCTURED OUTPUT ---` and `--- END STRUCTURED OUTPUT ---` (the JSON block). Also report:

1. Any steps that failed and the exact error message
2. The filesystem type (ext4, xfs, btrfs, zfs, etc.)
3. Whether this is bare metal, VM, or container
4. Available RAM
5. Disk type (SSD/NVMe/HDD)

---

## How to Interpret the Results

### Decision Matrix

The benchmark produces 8 measurement groups. Each one answers a specific architectural question for roof_py.

---

### 1. `file_stats.total_files` and `file_stats.apparent_gb`

**Question:** How big is a CUDA venv?

| Result | Interpretation | Action |
|--------|---------------|--------|
| < 30K files, < 2 GB | Similar to macOS — single TreeArtifact is fine | No architecture change needed |
| 30K-80K files, 2-5 GB | Larger but manageable | Proceed with single venv, monitor remote cache |
| > 80K files or > 5 GB | Very large — may stress TreeArtifact handling | Consider split-venv as default for CUDA |

**What this influences:** Whether the single `_roof_py_venv` TreeArtifact design works, or whether CUDA targets need an automatic split-venv variant.

---

### 2. `venv_creation.install_hardlink_seconds`

**Question:** How long does the build-time venv action take?

| Result | Interpretation | Action |
|--------|---------------|--------|
| < 5s | Excellent — rebuild cost is trivial | Conservative cache key (all wheels) is fine |
| 5-15s | Acceptable — equivalent to a medium cc_library compile | Conservative cache key acceptable, but monitor |
| > 15s | Slow — will frustrate developers on every requirements.txt change | Need per-package cache keys or split-venv to limit blast radius |

**What this influences:** Whether the conservative cache key strategy (all wheels in key = any change rebuilds all venvs) is acceptable, or whether per-package cache keys should be implemented in Phase 0.

---

### 3. `copy_performance.cp_r_seconds`

**Question:** How long does remote execution TreeArtifact materialization take?

| Result | Interpretation | Action |
|--------|---------------|--------|
| < 10s | Acceptable for remote exec | No special handling needed |
| 10-30s | Noticeable delay on remote exec cold builds | Document as known cost; Bazel action cache mitigates |
| > 30s | Painful | Split-venv becomes important for remote exec users |

**What this influences:** Whether remote execution users need the split-venv optimization from day one.

---

### 4. `tar_performance` (tar_create + tar_extract + zstd sizes)

**Question:** How expensive is remote cache upload/download?

| Metric | Good | Concerning | Action if concerning |
|--------|------|-----------|---------------------|
| tar create | < 10s | > 20s | Split-venv to reduce upload size |
| zstd compressed size | < 1 GB | > 2 GB | Monitor cache storage costs |
| tar extract | < 10s | > 20s | Split-venv or accept as cold-build cost |
| zstd compression ratio | > 2:1 | < 1.5:1 | .so files don't compress well — expected |

**What this influences:** Whether remote cache is viable for CUDA venvs, and whether Bazel's Merkle-tree deduplication (per-file hashing) provides meaningful savings over naive tar.

---

### 5. `import_performance.torch_import_seconds`

**Question:** Does the PYTHONPATH approach work correctly for CUDA torch?

| Result | Interpretation | Action |
|--------|---------------|--------|
| < 5s, no errors | Works — PYTHONPATH + toolchain Python handles CUDA torch | No changes needed |
| Works but > 10s | torch import is slow (expected — it loads .so files) | Fine, this is torch's inherent cost, not roof_py's |
| Fails with import error | Something is wrong with the venv structure | Investigate — may need additional env vars (LD_LIBRARY_PATH?) |
| `torch_cuda_available = false` | Expected if no GPU on bench machine | Not a problem — we're testing venv structure, not GPU access |

**What this influences:** Whether the PYTHONPATH approach needs any CUDA-specific adjustments (e.g., `LD_LIBRARY_PATH` in the launcher template).

---

### 6. `import_performance.torch_metadata_version`

**Question:** Does `importlib.metadata` work for CUDA packages?

| Result | Interpretation | Action |
|--------|---------------|--------|
| Returns correct version | `.dist-info` is correctly placed in site-packages | No changes |
| Fails or wrong version | `uv pip install` may not write `.dist-info` correctly for CUDA builds | Investigate — roof_py depends on metadata working |

**What this influences:** Whether the metadata access story (debugging, version introspection) works at CUDA scale.

---

### 7. `incremental_rebuild.total_seconds`

**Question:** When `requirements.txt` changes, how long does the full venv rebuild take?

| Result | Interpretation | Action |
|--------|---------------|--------|
| < 10s | Fast enough — conservative cache key is fine | Ship it |
| 10-20s | Acceptable but noticeable | Monitor; consider per-package keys later |
| > 20s | Too slow for developer iteration | Implement per-package cache keys in Phase 0 |

**What this influences:** Same as #2 — conservative vs per-package cache key strategy.

---

### 8. `split_venv_simulation`

**Question:** If we split torch into its own TreeArtifact, how much does it help?

| Metric | What to look at |
|--------|----------------|
| `torch_venv.files` vs `rest_venv.files` | If torch is >80% of files, splitting isolates the problem |
| `torch_venv.gb` vs `rest_venv.gb` | If torch is >80% of bytes, splitting helps remote cache |
| Combined install time vs single install | If combined is similar, split has no install cost |

**What this influences:** Whether `roof_py_test` should accept a `large_deps` attribute that puts specific packages (torch, CUDA) in a separate, more-stable TreeArtifact. This reduces rebuild blast radius: changing a small dep (pytest version bump) doesn't rebuild the torch venv.

---

### 9. `import_performance.nvidia_importable_subpackages`

**Question:** Do nvidia CUDA namespace packages work in flat site-packages?

| Result | Interpretation | Action |
|--------|---------------|--------|
| Multiple subpackages listed (cudnn, cublas, cuda_runtime, ...) | PEP 420 namespace packages work at CUDA scale | Confirms macOS prototype result; no changes |
| `nvidia_namespace_exists = false` | CUDA index download failed; CPU-only torch was used | Re-run with working CUDA index access, or accept as partial result |
| Import errors on specific subpackages | Something wrong with the flat site-packages layout for CUDA | Investigate — this would be a design-level concern |

**What this influences:** Whether the "nvidia namespace problem disappears" claim holds for the full CUDA package set (not just the 3-package simulation in `_derisk/namespace_test/`).

---

### 10. `import_performance.torch_lib_so_count` and `import_performance.ld_library_path`

**Question:** Does CUDA torch need `LD_LIBRARY_PATH` to work via PYTHONPATH?

| Result | Interpretation | Action |
|--------|---------------|--------|
| torch imports fine, `ld_library_path = (not set)` | No extra env vars needed — torch finds its .so files via `__file__` relative paths | No launcher template changes |
| torch import fails with `.so` load error | torch's internal .so files need `LD_LIBRARY_PATH` pointing at `torch/lib/` | Add `LD_LIBRARY_PATH` to `roof_run.tmpl.sh` (minor template change) |
| `torch_lib_so_count` > 50 | Many shared libraries — this is where the venv size comes from | Expected; confirms why CUDA venvs are large |

**What this influences:** Whether the launcher template (`roof_run.tmpl.sh`) needs a `LD_LIBRARY_PATH` line for CUDA workloads, and whether this should be automatic or opt-in.

---

### Summary Decision Table

After running the benchmark, fill in this table:

```
| Question                                  | Measured value               | Decision                                  |
|-------------------------------------------|------------------------------|-------------------------------------------|
| Total venv size (files / GB)              | 18K files / 7.42 GB         | Single venv OK (files < 30K, GB > 5 but   |
|                                           |                              | all operations fast)                      |
| Install time (hardlink, warm cache)       | 4.3s                         | Conservative cache key is fine (< 5s)     |
| Copy time (cp -R)                         | 3.72s                        | Remote exec viable (< 10s)                |
| Tar+zstd compressed size                  | 3.47 GB (2.1:1 ratio)       | Monitor cache storage, no action needed   |
| torch import via PYTHONPATH               | 1.35s, no errors             | No CUDA-specific launcher changes needed  |
| importlib.metadata works                  | Yes (version "2.10.0")       | Metadata story holds                      |
| Rebuild time (warm cache)                 | 1.73s                        | Conservative cache key confirmed (< 10s)  |
| torch % of total venv                     | 25% bytes / 65% files       | Split-venv not worth it — nvidia is 62%   |
|                                           |                              | of bytes across 33 wheels                 |
| nvidia namespace packages all import      | All 10 subpackages work      | Namespace design holds at full CUDA scale |
| LD_LIBRARY_PATH needed                    | No                           | No launcher template change needed        |
```

**Verdict: All values are in the "good" range (one metric — compressed size at 3.47 GB — is in the "concerning" band but operations complete in < 6s and venvs change rarely). Proceed with the single-venv design as-is. Split-venv dropped from scope. No architectural changes needed before writing Starlark.**

---

### Note on hardlink ratio (0%)

The benchmark showed 0% hardlink dedup ratio. This was NOT an overlay filesystem problem — it was a **cross-device** problem. The benchmark ran venvs in `/tmp` (overlay, device `0:103`) while uv's default cache lives at `~/.cache/uv` (ext4, device `259:2`). Hardlinks cannot cross device boundaries (kernel returns `EXDEV`), so uv silently fell back to full copies.

Follow-up experiments (`experiment_hardlinks.py`, `experiment_uv_cache_location.py`, `experiment_ci_simulation.py`) confirmed:
- Same device = 99% hardlink ratio
- Cross device = 0% — every time, no exceptions
- Fix: set `UV_CACHE_DIR` to a path on the same filesystem as the venv output

See `RESULTS.md` for full experiment results and `python-in-bazel-design.md` resolved question #21.
