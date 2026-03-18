#!/usr/bin/env python3
"""Validate PYTHONPATH scaling with many entries.

Tests:
1. Does Python handle 20+ PYTHONPATH entries correctly?
2. Does import ordering (first-party shadows third-party) hold?
3. What's the performance cost of many PYTHONPATH entries?
4. Do namespace packages still work across many entries?
"""
import os
import sys
import tempfile
import time
import importlib


def create_package(base_dir, pkg_name, content=""):
    """Create a minimal Python package in a directory."""
    pkg_dir = os.path.join(base_dir, pkg_name)
    os.makedirs(pkg_dir, exist_ok=True)
    with open(os.path.join(pkg_dir, "__init__.py"), "w") as f:
        f.write(content or f'NAME = "{pkg_name} from {base_dir}"\n')
    return base_dir


def create_namespace_subpackage(base_dir, namespace, subpkg, content=""):
    """Create a namespace package (no __init__.py in parent)."""
    sub_dir = os.path.join(base_dir, namespace, subpkg)
    os.makedirs(sub_dir, exist_ok=True)
    with open(os.path.join(sub_dir, "__init__.py"), "w") as f:
        f.write(content or f'NAME = "{namespace}.{subpkg} from {base_dir}"\n')
    return base_dir


def test_basic_scaling():
    """Test that 20 PYTHONPATH entries all work."""
    print("=== Test: Basic PYTHONPATH scaling (20 entries) ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        paths = []
        for i in range(20):
            src_root = os.path.join(tmpdir, f"src_root_{i:02d}")
            os.makedirs(src_root)
            create_package(src_root, f"pkg_{i:02d}")
            paths.append(src_root)

        # Add all to sys.path
        original_path = sys.path[:]
        sys.path = paths + sys.path

        try:
            successes = 0
            for i in range(20):
                mod = importlib.import_module(f"pkg_{i:02d}")
                assert f"pkg_{i:02d}" in mod.NAME, f"Wrong module loaded for pkg_{i:02d}"
                successes += 1
                # Clean up for next test
                del sys.modules[f"pkg_{i:02d}"]
            print(f"  PASS: All {successes}/20 packages imported correctly")
        finally:
            sys.path = original_path


def test_shadowing_with_many_entries():
    """Test that first entry on PYTHONPATH wins (shadowing)."""
    print("\n=== Test: First-party shadows third-party with many entries ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create 10 "first-party" roots, then 10 "third-party" roots
        first_party_roots = []
        third_party_roots = []

        for i in range(10):
            fp_root = os.path.join(tmpdir, f"first_party_{i}")
            os.makedirs(fp_root)
            first_party_roots.append(fp_root)

            tp_root = os.path.join(tmpdir, f"third_party_{i}")
            os.makedirs(tp_root)
            third_party_roots.append(tp_root)

        # Put "shadow_pkg" in first_party_0 AND third_party_0
        create_package(first_party_roots[0], "shadow_pkg", 'NAME = "FIRST_PARTY"\n')
        create_package(third_party_roots[0], "shadow_pkg", 'NAME = "THIRD_PARTY"\n')

        # PYTHONPATH order: first-party before third-party
        original_path = sys.path[:]
        sys.path = first_party_roots + third_party_roots + sys.path

        try:
            mod = importlib.import_module("shadow_pkg")
            assert mod.NAME == "FIRST_PARTY", f"Expected FIRST_PARTY, got {mod.NAME}"
            print("  PASS: First-party correctly shadows third-party")
            del sys.modules["shadow_pkg"]
        finally:
            sys.path = original_path


def test_namespace_across_many_entries():
    """Test namespace packages split across multiple PYTHONPATH entries."""
    print("\n=== Test: Namespace packages across 5 PYTHONPATH entries ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        roots = []
        for i in range(5):
            root = os.path.join(tmpdir, f"ns_root_{i}")
            os.makedirs(root)
            create_namespace_subpackage(root, "myns", f"sub_{i}")
            roots.append(root)

        original_path = sys.path[:]
        sys.path = roots + sys.path

        try:
            successes = 0
            for i in range(5):
                mod = importlib.import_module(f"myns.sub_{i}")
                assert f"myns.sub_{i}" in mod.NAME
                successes += 1
            print(f"  PASS: All {successes}/5 namespace subpackages imported from separate roots")

            # Verify myns.__path__ contains all roots
            import myns
            assert len(myns.__path__) >= 5, f"Expected >=5 paths, got {len(myns.__path__)}"
            print(f"  PASS: myns.__path__ has {len(myns.__path__)} entries (all roots aggregated)")

            # Clean up
            for i in range(5):
                del sys.modules[f"myns.sub_{i}"]
            del sys.modules["myns"]
        finally:
            sys.path = original_path


def test_import_performance():
    """Benchmark import time with varying PYTHONPATH sizes."""
    print("\n=== Test: Import performance with varying PYTHONPATH sizes ===")
    results = {}

    for n_entries in [1, 5, 10, 20, 50]:
        with tempfile.TemporaryDirectory() as tmpdir:
            roots = []
            for i in range(n_entries):
                root = os.path.join(tmpdir, f"root_{i}")
                os.makedirs(root)
                # Only put the target package in the LAST root
                # to maximize search time
                if i == n_entries - 1:
                    create_package(root, "target_pkg", 'X = 1\n')
                roots.append(root)

            original_path = sys.path[:]
            sys.path = roots + sys.path

            try:
                # Warm up
                importlib.import_module("target_pkg")
                del sys.modules["target_pkg"]

                # Measure
                times = []
                for _ in range(100):
                    # Clear module cache
                    if "target_pkg" in sys.modules:
                        del sys.modules["target_pkg"]
                    # Clear path finder caches
                    importlib.invalidate_caches()

                    start = time.perf_counter_ns()
                    importlib.import_module("target_pkg")
                    elapsed = time.perf_counter_ns() - start
                    times.append(elapsed)

                avg_us = sum(times) / len(times) / 1000
                p99_us = sorted(times)[98] / 1000
                results[n_entries] = (avg_us, p99_us)
                print(f"  {n_entries:3d} entries: avg={avg_us:8.1f}us  p99={p99_us:8.1f}us")

                del sys.modules["target_pkg"]
            finally:
                sys.path = original_path

    # Check degradation is acceptable
    if 50 in results and 1 in results:
        ratio = results[50][0] / results[1][0]
        print(f"\n  50-entry / 1-entry ratio: {ratio:.1f}x")
        if ratio < 10:
            print("  PASS: Performance degradation acceptable (<10x)")
        else:
            print(f"  WARN: Performance degradation is {ratio:.1f}x (may need investigation)")


if __name__ == "__main__":
    test_basic_scaling()
    test_shadowing_with_many_entries()
    test_namespace_across_many_entries()
    test_import_performance()
    print("\n=== All PYTHONPATH scaling tests complete ===")
