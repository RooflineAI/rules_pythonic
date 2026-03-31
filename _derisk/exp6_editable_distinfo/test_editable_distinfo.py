#!/usr/bin/env python3
"""Validate editable install creates .dist-info usable with PYTHONPATH approach.

Key question: If we do `uv pip install -e .` in the venv build action,
does importlib.metadata.version("pkg") work when we use PYTHONPATH
with the toolchain Python (NOT the venv's bin/python3)?

This matters for the design doc's resolved question #4.
"""

import os
import subprocess
import sys
import tempfile
import time


def test_editable_with_pythonpath():
    """Test that editable install .dist-info is found via PYTHONPATH."""
    print("=== Test: Editable install .dist-info via PYTHONPATH ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create a minimal package
        pkg_dir = os.path.join(tmpdir, "mypkg")
        src_dir = os.path.join(pkg_dir, "src", "mypkg")
        os.makedirs(src_dir)

        with open(os.path.join(src_dir, "__init__.py"), "w") as f:
            f.write('__version__ = "1.2.3"\nNAME = "mypkg"\n')

        with open(os.path.join(pkg_dir, "pyproject.toml"), "w") as f:
            f.write("""\
[build-system]
requires = ["setuptools>=75.0"]
build-backend = "setuptools.build_meta"

[project]
name = "mypkg"
version = "1.2.3"

[tool.setuptools.packages.find]
where = ["src"]
""")

        # Create a venv and do editable install
        venv_dir = os.path.join(tmpdir, "venv")
        subprocess.check_call(
            ["uv", "venv", venv_dir, "--python", sys.executable],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        venv_python = os.path.join(venv_dir, "bin", "python3")

        # Editable install
        result = subprocess.run(
            ["uv", "pip", "install", "-e", pkg_dir, "--python", venv_python],
            capture_output=True,
            text=True,
        )
        print(f"  uv pip install -e: exit={result.returncode}")
        if result.returncode != 0:
            print(f"  STDERR: {result.stderr[:300]}")
            return

        # Find site-packages
        site_packages = None
        for root, dirs, files in os.walk(venv_dir):
            if root.endswith("site-packages"):
                site_packages = root
                break

        print(f"  site-packages: {site_packages}")

        # Check what's in site-packages
        dist_infos = [d for d in os.listdir(site_packages) if d.endswith(".dist-info")]
        pth_files = [f for f in os.listdir(site_packages) if f.endswith(".pth")]
        print(f"  .dist-info dirs: {dist_infos}")
        print(f"  .pth files: {pth_files}")

        # Now test with toolchain Python + PYTHONPATH (NOT venv python)
        # This simulates what roof_py does at test time
        test_script = """\
import sys
import importlib.metadata

# Test 1: Can we find the version?
try:
    version = importlib.metadata.version("mypkg")
    print(f"  importlib.metadata.version('mypkg') = {version}")
    assert version == "1.2.3", f"Expected 1.2.3, got {version}"
    print("  PASS: Version metadata works via PYTHONPATH")
except importlib.metadata.PackageNotFoundError:
    print("  FAIL: PackageNotFoundError - .dist-info not found via PYTHONPATH")

# Test 2: Can we import the package?
try:
    import mypkg
    print(f"  mypkg.NAME = {mypkg.NAME}")
    print(f"  mypkg.__file__ = {mypkg.__file__}")
    print("  PASS: Package import works")
except ImportError as e:
    print(f"  FAIL: ImportError - {e}")

# Test 3: Does the .pth file get processed?
# Note: .pth files are ONLY processed by site.py when Python starts up
# with the directory as a "site" directory. PYTHONPATH dirs are NOT
# processed for .pth files. This is a critical distinction.
print(f"  sys.path entries: {len(sys.path)}")
"""

        # Test A: Using PYTHONPATH with site-packages
        env = os.environ.copy()
        env["PYTHONPATH"] = site_packages
        result = subprocess.run(
            [sys.executable, "-B", "-s", "-c", test_script],
            capture_output=True,
            text=True,
            env=env,
        )
        print(f"\n  --- Test A: PYTHONPATH={site_packages} ---")
        print(result.stdout)
        if result.stderr:
            print(f"  STDERR: {result.stderr[:200]}")

        # Test B: What about .pth processing?
        # .pth files in PYTHONPATH dirs are NOT processed.
        # Only dirs added via site.addsitedir() process .pth files.
        print("  --- Test B: .pth file processing with PYTHONPATH ---")
        pth_test = """\
import sys
import site
# Check if the editable .pth file was processed
# (It won't be, because PYTHONPATH dirs don't process .pth files)
pth_processed = False
for p in sys.path:
    if 'mypkg' in p and 'src' in p:
        pth_processed = True
        break
print(f"  .pth file processed: {pth_processed}")
if not pth_processed:
    # Manually process it via site.addsitedir
    site.addsitedir(sys.argv[1])
    pth_processed_after = False
    for p in sys.path:
        if 'mypkg' in p and 'src' in p:
            pth_processed_after = True
            break
    print(f"  .pth file processed after addsitedir: {pth_processed_after}")
"""
        result = subprocess.run(
            [sys.executable, "-B", "-c", pth_test, site_packages],
            capture_output=True,
            text=True,
            env=env,
        )
        print(result.stdout)

        # Test C: First-party source root + site-packages on PYTHONPATH
        # This is the actual roof_py scenario
        print("  --- Test C: roof_py scenario (src_root + site-packages) ---")
        env["PYTHONPATH"] = f"{os.path.join(pkg_dir, 'src')}:{site_packages}"
        result = subprocess.run(
            [sys.executable, "-B", "-s", "-c", test_script],
            capture_output=True,
            text=True,
            env=env,
        )
        print(result.stdout)


def test_editable_install_timing():
    """Benchmark editable install cost."""
    print("\n=== Test: Editable install timing ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        pkg_dir = os.path.join(tmpdir, "mypkg")
        src_dir = os.path.join(pkg_dir, "src", "mypkg")
        os.makedirs(src_dir)

        with open(os.path.join(src_dir, "__init__.py"), "w") as f:
            f.write('__version__ = "1.0.0"\n')

        with open(os.path.join(pkg_dir, "pyproject.toml"), "w") as f:
            f.write("""\
[build-system]
requires = ["setuptools>=75.0"]
build-backend = "setuptools.build_meta"

[project]
name = "mypkg"
version = "1.0.0"

[tool.setuptools.packages.find]
where = ["src"]
""")

        venv_dir = os.path.join(tmpdir, "venv")
        subprocess.check_call(
            ["uv", "venv", venv_dir, "--python", sys.executable],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        venv_python = os.path.join(venv_dir, "bin", "python3")

        start = time.perf_counter()
        subprocess.check_call(
            ["uv", "pip", "install", "-e", pkg_dir, "--python", venv_python],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        elapsed = time.perf_counter() - start
        print(f"  Editable install time: {elapsed:.3f}s")
        print(
            f"  {'PASS' if elapsed < 5.0 else 'WARN'}: {'Acceptable' if elapsed < 5.0 else 'Slow'} (<5s threshold)"
        )


if __name__ == "__main__":
    test_editable_with_pythonpath()
    test_editable_install_timing()
    print("\n=== All editable install tests complete ===")
