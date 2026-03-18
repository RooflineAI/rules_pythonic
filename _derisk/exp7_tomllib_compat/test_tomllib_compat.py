#!/usr/bin/env python3
"""Validate tomllib availability and fallback strategy.

The install_venv.py script uses `import tomllib` (Python 3.11+ stdlib).
Questions:
1. What Python versions does rules_python toolchain provide?
2. Do we need a fallback for Python 3.10/3.9?
3. What's the simplest fallback approach?
"""
import sys


def test_tomllib_import():
    """Test tomllib availability."""
    print(f"=== Test: tomllib on Python {sys.version.split()[0]} ===")

    try:
        import tomllib
        print(f"  PASS: tomllib available (stdlib)")
    except ImportError:
        print(f"  INFO: tomllib not available (Python < 3.11)")
        print(f"  Checking for tomli fallback...")
        try:
            import tomli as tomllib
            print(f"  PASS: tomli available as fallback")
        except ImportError:
            print(f"  FAIL: Neither tomllib nor tomli available")


def test_tomllib_parsing():
    """Test that tomllib can parse a real pyproject.toml."""
    print("\n=== Test: Parse a realistic pyproject.toml ===")

    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            print("  SKIP: No TOML parser available")
            return

    sample = """\
[build-system]
requires = ["setuptools>=68.0"]
build-backend = "setuptools.backends._legacy:_Backend"

[project]
name = "attic"
dynamic = ["version"]
dependencies = [
    "torch>=2.1",
    "numpy",
    "attic-rt",
    "scipy>=1.10; python_version>='3.9'",
    "Pillow>=9.0",
    "my.dotted.pkg>=1.0",
]

[project.optional-dependencies]
test = ["pytest>=7.0", "pytest-xdist"]
gpu = ["nvidia-cudnn-cu12", "nvidia-cublas-cu12"]
dev = ["ruff", "mypy>=1.0"]

[tool.setuptools.dynamic]
version = {file = "VERSION"}

[tool.mypy]
strict = true
python_version = "3.11"
"""

    pp = tomllib.loads(sample)

    # Verify structure
    deps = pp["project"]["dependencies"]
    print(f"  dependencies: {deps}")
    assert len(deps) == 6
    print(f"  PASS: Parsed {len(deps)} dependencies")

    # Verify optional-dependencies
    test_deps = pp["project"]["optional-dependencies"]["test"]
    gpu_deps = pp["project"]["optional-dependencies"]["gpu"]
    print(f"  test extras: {test_deps}")
    print(f"  gpu extras: {gpu_deps}")
    assert len(test_deps) == 2
    assert len(gpu_deps) == 2
    print(f"  PASS: Parsed optional-dependencies groups")

    # Verify name
    assert pp["project"]["name"] == "attic"
    print(f"  PASS: Project name = {pp['project']['name']}")


def test_compat_import_pattern():
    """Test the recommended compat import pattern for install_venv.py."""
    print("\n=== Test: Recommended compat import pattern ===")

    # This is what install_venv.py should use:
    compat_code = """\
import sys
if sys.version_info >= (3, 11):
    import tomllib
else:
    # Python 3.9/3.10: tomli must be provided as a build dependency
    # (downloaded via pip.parse, passed as a tool input)
    try:
        import tomli as tomllib
    except ImportError:
        print("ERROR: Python < 3.11 requires the 'tomli' package.", file=sys.stderr)
        print("       Add tomli to pip.parse() requirements.", file=sys.stderr)
        sys.exit(1)
"""

    # Execute it
    exec(compat_code)
    print(f"  PASS: Compat import pattern works on Python {sys.version.split()[0]}")
    print(f"  NOTE: For Python 3.11+, no external dependency needed")
    print(f"  NOTE: For Python 3.9/3.10, must provide tomli as build dep")


def test_minimum_python_version():
    """Check what Python versions are realistic for roof_py."""
    print(f"\n=== Test: Python version assessment ===")
    print(f"  Current Python: {sys.version}")
    print(f"  tomllib available: {sys.version_info >= (3, 11)}")

    # Python 3.9 EOL: 2025-10-05
    # Python 3.10 EOL: 2026-10-04
    # Python 3.11+ has tomllib
    print(f"\n  Python 3.9:  EOL 2025-10-05 (PAST) - no tomllib")
    print(f"  Python 3.10: EOL 2026-10-04 (soon) - no tomllib")
    print(f"  Python 3.11: Active - HAS tomllib")
    print(f"  Python 3.12: Active - HAS tomllib")
    print(f"  Python 3.13: Active - HAS tomllib")
    print(f"  Python 3.14: Active - HAS tomllib")
    print(f"\n  RECOMMENDATION: Require Python >= 3.11 for install_venv.py")
    print(f"  This is the BUILD-TIME Python (from rules_python toolchain),")
    print(f"  not the application's runtime Python. Can be different.")


if __name__ == "__main__":
    test_tomllib_import()
    test_tomllib_parsing()
    test_compat_import_pattern()
    test_minimum_python_version()
    print("\n=== All tomllib compat tests complete ===")
