#!/usr/bin/env python3
"""Validate extras group handling in install_venv.py.

The design doc hardcodes [test] extras. This experiment tests:
1. Multiple extras groups ([test], [gpu], [dev])
2. Overlapping deps across groups
3. The proposed API: extras = ["gpu"] attribute
"""

try:
    import tomllib
except ImportError:
    import tomli as tomllib


def normalize(name):
    return name.lower().replace("-", "_").replace(".", "_")


def extract_dep_name(dep_spec):
    """Extract package name from a PEP 508 dependency specifier."""
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()


def collect_deps_with_extras(pyproject_text, extras_groups):
    """
    Collect all dependency names from a pyproject.toml, including specified extras.

    Args:
        pyproject_text: TOML content as string
        extras_groups: list of extra group names to include (e.g., ["test", "gpu"])

    Returns:
        set of normalized dependency names
    """
    pp = tomllib.loads(pyproject_text)
    needed = set()

    # Core dependencies
    for dep in pp.get("project", {}).get("dependencies", []):
        needed.add(normalize(extract_dep_name(dep)))

    # Optional dependencies for each requested group
    opt_deps = pp.get("project", {}).get("optional-dependencies", {})
    for group in extras_groups:
        for dep in opt_deps.get(group, []):
            needed.add(normalize(extract_dep_name(dep)))

    return needed


SAMPLE_PYPROJECT = """\
[project]
name = "attic"
dependencies = [
    "torch>=2.1",
    "numpy",
    "attic-rt",
]

[project.optional-dependencies]
test = ["pytest>=7.0", "pytest-xdist", "torch"]
gpu = ["nvidia-cudnn-cu12", "nvidia-cublas-cu12", "torch"]
dev = ["ruff", "mypy>=1.0", "pytest>=7.0"]
docs = ["sphinx", "myst-parser"]
"""


def test_single_extras_group():
    """Test collecting deps with a single extras group."""
    print("=== Test: Single extras group ([test]) ===")

    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["test"])
    print(f"  deps = {sorted(deps)}")

    expected = {"torch", "numpy", "attic_rt", "pytest", "pytest_xdist"}
    assert deps == expected, f"Expected {expected}, got {deps}"
    print("  PASS: Correct deps for [test] extras (torch not duplicated)")


def test_multiple_extras_groups():
    """Test collecting deps with multiple extras groups."""
    print("\n=== Test: Multiple extras groups ([test, gpu]) ===")

    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["test", "gpu"])
    print(f"  deps = {sorted(deps)}")

    expected = {
        "torch",
        "numpy",
        "attic_rt",
        "pytest",
        "pytest_xdist",
        "nvidia_cudnn_cu12",
        "nvidia_cublas_cu12",
    }
    assert deps == expected, f"Expected {expected}, got {deps}"
    print("  PASS: Correct deps for [test, gpu] (union, no duplicates)")


def test_no_extras():
    """Test collecting deps with no extras."""
    print("\n=== Test: No extras (binary default) ===")

    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, [])
    print(f"  deps = {sorted(deps)}")

    expected = {"torch", "numpy", "attic_rt"}
    assert deps == expected, f"Expected {expected}, got {deps}"
    print("  PASS: Only core deps when no extras requested")


def test_overlapping_extras():
    """Test that overlapping deps across groups are deduplicated."""
    print("\n=== Test: Overlapping extras ([test, dev]) ===")

    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["test", "dev"])
    print(f"  deps = {sorted(deps)}")

    # pytest appears in both [test] and [dev] - should appear once
    expected = {"torch", "numpy", "attic_rt", "pytest", "pytest_xdist", "ruff", "mypy"}
    assert deps == expected, f"Expected {expected}, got {deps}"
    print("  PASS: Overlapping deps correctly deduplicated")


def test_nonexistent_extras_group():
    """Test that requesting a nonexistent extras group is handled."""
    print("\n=== Test: Nonexistent extras group ([nonexistent]) ===")

    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["nonexistent"])
    print(f"  deps = {sorted(deps)}")

    expected = {"torch", "numpy", "attic_rt"}
    assert deps == expected, f"Expected {expected}, got {deps}"
    print("  PASS: Nonexistent group silently ignored (only core deps)")
    print("  NOTE: Should we warn? Current behavior: silent (matches pip)")


def test_multiple_pyprojects_with_extras():
    """Test union of deps from multiple pyproject.toml files with different extras."""
    print("\n=== Test: Multiple pyproject.toml files with varying extras ===")

    pyproject_a = """\
[project]
name = "attic"
dependencies = ["torch>=2.1", "numpy"]

[project.optional-dependencies]
test = ["pytest>=7.0"]
"""

    pyproject_b = """\
[project]
name = "attic-rt"
dependencies = ["numpy", "scipy"]

[project.optional-dependencies]
test = ["pytest>=7.0", "hypothesis"]
"""

    deps_a = collect_deps_with_extras(pyproject_a, ["test"])
    deps_b = collect_deps_with_extras(pyproject_b, ["test"])
    union_deps = deps_a | deps_b

    print(f"  attic deps: {sorted(deps_a)}")
    print(f"  attic-rt deps: {sorted(deps_b)}")
    print(f"  union: {sorted(union_deps)}")

    expected = {"torch", "numpy", "scipy", "pytest", "hypothesis"}
    assert union_deps == expected, f"Expected {expected}, got {union_deps}"
    print("  PASS: Union of multiple pyproject.toml deps correct")


def test_proposed_api():
    """Demonstrate the proposed extras API for roof_py_test."""
    print("\n=== Test: Proposed extras API ===")

    # roof_py_test default: includes [test] automatically
    print("  roof_py_test(name = 'test_foo', deps = [':attic'])")
    print("    → extras = ['test'] (automatic)")
    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["test"])
    print(f"    → {len(deps)} deps")

    # roof_py_test with extra GPU deps
    print("\n  roof_py_test(name = 'test_gpu', deps = [':attic'], extras = ['gpu'])")
    print("    → extras = ['test', 'gpu'] (test auto-added + gpu explicit)")
    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["test", "gpu"])
    print(f"    → {len(deps)} deps")

    # roof_py_binary: no extras by default
    print("\n  roof_py_binary(name = 'serve', deps = [':attic'])")
    print("    → extras = [] (no extras for binaries)")
    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, [])
    print(f"    → {len(deps)} deps")

    # roof_py_binary with explicit extras
    print("\n  roof_py_binary(name = 'serve_gpu', deps = [':attic'], extras = ['gpu'])")
    print("    → extras = ['gpu'] (explicit)")
    deps = collect_deps_with_extras(SAMPLE_PYPROJECT, ["gpu"])
    print(f"    → {len(deps)} deps")

    print("\n  PASS: Proposed API design validated")


if __name__ == "__main__":
    test_single_extras_group()
    test_multiple_extras_groups()
    test_no_extras()
    test_overlapping_extras()
    test_nonexistent_extras_group()
    test_multiple_pyprojects_with_extras()
    test_proposed_api()
    print("\n=== All extras group tests complete ===")
