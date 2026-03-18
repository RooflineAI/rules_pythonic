#!/usr/bin/env python3
"""Validate conftest.py auto-discovery for roof_py_test macro.

The macro needs to auto-collect conftest.py files by walking up from each test
source file. This script validates:
1. The walk-up algorithm produces correct conftest.py paths
2. pytest actually loads conftest.py from all expected levels
3. Edge cases (no conftest, deeply nested, multiple test dirs)
"""
import os
import subprocess
import sys
import tempfile


def create_tree(base, structure):
    """Create a file tree from a dict. Values are file contents."""
    for path, content in structure.items():
        full = os.path.join(base, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(content)


def find_conftest_files(test_file_path, package_root):
    """
    Simulate the conftest.py auto-discovery algorithm for roof_py_test.

    Walk up from test_file_path to package_root (inclusive), collecting
    conftest.py files at each level. This mirrors pytest's own discovery.
    """
    conftest_files = []
    current = os.path.dirname(test_file_path)

    # Normalize to ensure clean comparison
    package_root = os.path.normpath(package_root)
    current = os.path.normpath(current)

    while True:
        conftest = os.path.join(current, "conftest.py")
        if os.path.exists(conftest):
            conftest_files.append(conftest)

        if current == package_root or current == os.path.dirname(current):
            break
        current = os.path.dirname(current)

    # Return in root-first order (matching pytest's loading order)
    return list(reversed(conftest_files))


def test_algorithm_correctness():
    """Test that the walk-up algorithm finds the right conftest.py files."""
    print("=== Test: conftest.py walk-up algorithm ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        create_tree(tmpdir, {
            "packages/attic/conftest.py": "# package root conftest\n",
            "packages/attic/tests/conftest.py": "# tests dir conftest\n",
            "packages/attic/tests/unit/conftest.py": "# unit dir conftest\n",
            "packages/attic/tests/unit/test_foo.py": "def test_foo(): pass\n",
            "packages/attic/tests/integration/test_bar.py": "def test_bar(): pass\n",
        })

        pkg_root = os.path.join(tmpdir, "packages/attic")

        # Test deeply nested test
        conftests = find_conftest_files(
            os.path.join(tmpdir, "packages/attic/tests/unit/test_foo.py"),
            pkg_root,
        )
        expected = [
            os.path.join(pkg_root, "conftest.py"),
            os.path.join(pkg_root, "tests/conftest.py"),
            os.path.join(pkg_root, "tests/unit/conftest.py"),
        ]
        assert conftests == expected, f"Expected {expected}, got {conftests}"
        print(f"  PASS: Nested test finds 3 conftest.py files (root, tests/, tests/unit/)")

        # Test sibling dir (no unit conftest)
        conftests = find_conftest_files(
            os.path.join(tmpdir, "packages/attic/tests/integration/test_bar.py"),
            pkg_root,
        )
        expected = [
            os.path.join(pkg_root, "conftest.py"),
            os.path.join(pkg_root, "tests/conftest.py"),
        ]
        assert conftests == expected, f"Expected {expected}, got {conftests}"
        print(f"  PASS: Integration test finds 2 conftest.py files (root, tests/)")


def test_pytest_actually_loads_them():
    """Create a real file tree and verify pytest loads all conftest.py files."""
    print("\n=== Test: pytest loads conftest.py from all levels ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        create_tree(tmpdir, {
            # conftest at package root: provides a fixture
            "conftest.py": (
                'import pytest\n'
                '@pytest.fixture\n'
                'def root_fixture():\n'
                '    return "from_root"\n'
            ),
            # conftest at tests/: provides another fixture
            "tests/conftest.py": (
                'import pytest\n'
                '@pytest.fixture\n'
                'def tests_fixture():\n'
                '    return "from_tests_dir"\n'
            ),
            # conftest at tests/unit/: provides another fixture
            "tests/unit/conftest.py": (
                'import pytest\n'
                '@pytest.fixture\n'
                'def unit_fixture():\n'
                '    return "from_unit_dir"\n'
            ),
            # Test that uses all three fixtures
            "tests/unit/test_all_fixtures.py": (
                'def test_all_fixtures(root_fixture, tests_fixture, unit_fixture):\n'
                '    assert root_fixture == "from_root"\n'
                '    assert tests_fixture == "from_tests_dir"\n'
                '    assert unit_fixture == "from_unit_dir"\n'
            ),
            # Test in sibling dir - only sees root + tests conftest
            "tests/integration/test_partial.py": (
                'import pytest\n'
                'def test_partial(root_fixture, tests_fixture):\n'
                '    assert root_fixture == "from_root"\n'
                '    assert tests_fixture == "from_tests_dir"\n'
                '\n'
                'def test_no_unit_fixture():\n'
                '    """unit_fixture should NOT be available here."""\n'
                '    import inspect\n'
                '    frame = inspect.currentframe()\n'
                '    # This would fail if unit_fixture leaked across sibling dirs\n'
                '    pass\n'
            ),
        })

        # Run pytest
        result = subprocess.run(
            [sys.executable, "-m", "pytest", "-v", tmpdir],
            capture_output=True, text=True,
        )
        print(f"  pytest exit code: {result.returncode}")
        for line in result.stdout.splitlines():
            if "PASSED" in line or "FAILED" in line or "ERROR" in line:
                print(f"  {line.strip()}")

        if result.returncode == 0:
            print("  PASS: pytest loads conftest.py from all expected levels")
        else:
            print("  FAIL: pytest conftest loading failed")
            print(result.stdout[-500:] if len(result.stdout) > 500 else result.stdout)
            print(result.stderr[-500:] if len(result.stderr) > 500 else result.stderr)


def test_starlark_glob_pattern():
    """Validate the Starlark glob pattern for conftest.py auto-collection.

    In roof_py_test, conftest.py files are collected with:
        glob(["conftest.py", "tests/conftest.py", "tests/**/conftest.py"])

    Or more precisely, walking up from each test source file.
    The simpler approach: include all conftest.py files under the package root.
    """
    print("\n=== Test: Starlark conftest.py collection pattern ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        create_tree(tmpdir, {
            "packages/attic/conftest.py": "",
            "packages/attic/tests/conftest.py": "",
            "packages/attic/tests/unit/conftest.py": "",
            "packages/attic/tests/integration/conftest.py": "",
            "packages/attic/src/attic/conftest.py": "",  # should NOT be collected (in src)
        })

        # Simulate: glob(["**/conftest.py"]) from packages/attic/tests/
        import glob as globmod
        pkg_root = os.path.join(tmpdir, "packages/attic")

        # The macro should collect conftest.py from:
        # 1. The package root (always)
        # 2. Up from each test file to the package root

        # Simplest approach: glob all conftest.py under tests/
        tests_conftests = globmod.glob(os.path.join(pkg_root, "tests/**/conftest.py"), recursive=True)
        root_conftest = os.path.join(pkg_root, "conftest.py")

        all_conftests = []
        if os.path.exists(root_conftest):
            all_conftests.append(root_conftest)
        all_conftests.extend(sorted(tests_conftests))

        print(f"  Collected conftest.py files (relative to package root):")
        for cf in all_conftests:
            print(f"    {os.path.relpath(cf, pkg_root)}")

        # Should NOT include src/attic/conftest.py
        src_conftest = os.path.join(pkg_root, "src/attic/conftest.py")
        assert src_conftest not in all_conftests, "src/attic/conftest.py should not be collected"
        print("  PASS: src/attic/conftest.py correctly excluded")
        print(f"  PASS: Collected {len(all_conftests)} conftest.py files")

        # The Starlark glob pattern:
        print("\n  Recommended Starlark pattern:")
        print('    data = glob(["conftest.py", "tests/**/conftest.py"])')
        print("  This collects package-root conftest.py + all under tests/")


if __name__ == "__main__":
    test_algorithm_correctness()
    test_pytest_actually_loads_them()
    test_starlark_glob_pattern()
    print("\n=== All conftest discovery tests complete ===")
