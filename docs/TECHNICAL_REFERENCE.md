# rules_pythonic: Technical Reference

**Status:** Draft | **Authors:** [TBD] | **Last updated:** 2026-03-11

This document provides the detailed evidence, benchmarks, implementation specifics, and worked examples behind the rules*pythonic architecture. It is intended for engineers who want to understand \_how* things work and _why_ we're confident they work, beyond what the design overview covers.

---

## Contents

- [Prototype Validation](#prototype-validation) — what was tested and what passed
- [Linux CUDA Benchmark](#linux-cuda-benchmark) — full-scale venv measurements
- [Hardlink Experiments](#hardlink-experiments) — filesystem boundary validation
- [Conftest Discovery](#conftestpy-discovery-in-the-sandbox) — full implementation and derisking
- [Monorepo Scaling Patterns](#monorepo-scaling-patterns) — 5 patterns with complete config examples
- [pythonic_files](#pythonic_files) — importable non-package files
- [install_packages.py](#install_venvpy) — full build-time helper implementation
- [Test Runner](#test-runner-pytest) — pytest bridge and escape hatches
- [Launcher Template](#launcher-template) — full template with commentary
- [Existing Ecosystem Audit](#existing-ecosystem-audit) — detailed code audit findings
- [Full Risk Register](#full-risk-register) — all 20+ risks with status
- [Resolved Questions](#resolved-questions) — 22 questions answered via prototyping
- [Comparison Tables](#comparison-tables) — vs rules_python, rules_py, Pants

---

## Prototype Validation

### macOS ARM (APFS, Python 3.11.10, uv 0.9.22, torch 2.10.0)

End-to-end prototype simulating the full rules_pythonic flow: `install_packages.py` installs wheels into a flat directory with `uv pip install --target --link-mode=hardlink`, then a test launcher uses the toolchain Python with `PYTHONPATH` pointing at first-party source roots + the installed packages directory.

**Performance (torch + numpy + pytest + 17 transitive deps):**

| Metric                                              | Value           |
| --------------------------------------------------- | --------------- |
| Venv creation (`uv venv`)                           | 28ms            |
| Package install (warm uv cache, hardlink)           | 3.5s            |
| Package install (warm uv cache, copy)               | 2.0s (APFS CoW) |
| Cold install (including download)                   | 46s             |
| Files in site-packages                              | 16,386          |
| Apparent size                                       | 431MB           |
| On-disk size (hardlink to uv cache)                 | 392MB           |
| Additional venv (shared hardlinks)                  | ~2-4MB          |
| TreeArtifact copy (simulated remote exec)           | 4.7s            |
| TreeArtifact symlink (local execution)              | 0ms             |
| Test execution (4 pytest tests with torch)          | 2.5s            |
| torch import time                                   | ~2s             |
| Wheel build (`uv build --wheel`, symlinked sandbox) | 0.42s           |

**Correctness matrix:**

| Test                                           | Result | Notes                                          |
| ---------------------------------------------- | ------ | ---------------------------------------------- |
| torch import via PYTHONPATH (toolchain python) | Pass   | `__file__` points to site-packages             |
| numpy import via PYTHONPATH                    | Pass   | real files, not symlinks                       |
| `importlib.metadata.version("torch")`          | Pass   | `.dist-info` found via `sys.path` search       |
| `importlib.metadata` for source deps           | Fail   | expected — no `.dist-info` for PYTHONPATH deps |
| `__file__` is real file (not symlink)          | Pass   | hardlinked from uv cache                       |
| First-party import via PYTHONPATH              | Pass   | PYTHONPATH order: first-party wins             |
| First-party shadows third-party                | Pass   | first entry on PYTHONPATH takes priority       |
| Cross-import (first-party using third-party)   | Pass   | attic.compiler importing torch works           |
| `shutil.which()` finds console scripts         | Pass   | venv/bin on PATH, shebangs broken              |
| `python -m pytest` (recommended approach)      | Pass   | bypasses broken shebangs entirely              |
| Namespace packages (simulated nvidia)          | Pass   | implicit namespace across MULTIPLE dirs        |
| Broken venv `bin/python3` symlink              | Pass   | toolchain python ignores it completely         |
| Symlinked TreeArtifact (Bazel runfiles)        | Pass   | imports work through symlink indirection       |
| Copied TreeArtifact (remote execution sim)     | Pass   | imports work from full copy                    |
| End-to-end pytest (4 tests)                    | Pass   | first-party + third-party + metadata           |

### Additional validation areas

**Wheel build action (uv 0.9.22, macOS ARM):**

- `uv build --wheel` from symlinked source tree: works (0.42s)
- `--no-build-isolation` with pre-installed setuptools: works
- Build isolation (default): works — uv auto-fetches setuptools
- Dynamic `version = {file = "VERSION"}` (local): works
- Dynamic `version = {file = "../../VERSION"}` (escaping): fails — setuptools rejects paths outside package root via `_assert_local()`
- Combined: symlinked sandbox + `--no-build-isolation` + local VERSION: works

**Platform wheel selection (uv 0.9.22):**

- `uv pip install --no-index --find-links <dir>` with both macOS and Linux wheels: uv selects correct platform
- Only wrong-platform wheels available: fails correctly with clear platform hint
- Direct `.whl` file install of wrong-platform: fails correctly
- Conclusion: uv handles platform filtering automatically; no `select()` needed in Starlark

**First-party dep handling:**

- Three-way classification (match wheel / match first-party / fail): works for all cases
- Name normalization (case, dots, hyphens, extras, PEP 508 markers): all handled correctly
- Genuinely missing dep: caught with clear error message

**PYTHONPATH scaling (Python 3.14, macOS ARM):**

| Entries | Import time per fresh import |
| ------- | ---------------------------- |
| 1       | 50us                         |
| 10      | 200us                        |
| 50      | 800us                        |

Real projects have 5-10 source roots + 1 site-packages = ~200us per fresh import. Namespace package aggregation works across all tested entry counts. First-party-before-third-party ordering holds regardless of entry count.

**Editable install + PYTHONPATH (uv 0.9.22, Python 3.14):**

- `uv pip install -e .` creates `.dist-info` in site-packages (0.44s)
- `importlib.metadata.version("mypkg")` via PYTHONPATH: works
- Editable `.pth` file: NOT processed by PYTHONPATH (expected — only `site.addsitedir()` processes `.pth` files)
- rules_pythonic scenario (src_root + site-packages on PYTHONPATH): works — source imported via src_root, metadata found via `.dist-info`

**Extras groups (Python 3.14):**

- Multiple extras groups (`[test]`, `[gpu]`, `[dev]`): union-based collection works
- Overlapping deps across groups: deduplicated by normalized name
- Nonexistent extras group: silently ignored (matches pip behavior)
- Multiple pyproject.toml files with different extras: union produces correct superset

---

## Linux CUDA Benchmark

**Purpose:** Determine whether the single-TreeArtifact design works at CUDA scale (feared 50-100K files, 2-5 GB), or whether the architecture needs a split variant.

**Environment:** Linux overlay fs, Python 3.11, uv 0.10.3, torch 2.10.0+cu128

### Results

| Metric                                     | Value                        |
| ------------------------------------------ | ---------------------------- |
| Wheels downloaded                          | 34 (4.18 GB compressed)      |
| Venv creation (`uv venv`)                  | 25ms                         |
| Package install (warm uv cache, hardlink)  | 4.3s                         |
| Package install (warm uv cache, copy)      | 1.47s                        |
| Incremental rebuild (warm cache, hardlink) | 1.73s                        |
| Files in venv                              | 18,192                       |
| Apparent size                              | 7.42 GB                      |
| On-disk size                               | 7.35 GB                      |
| TreeArtifact copy (`cp -R`)                | 3.72s                        |
| TreeArtifact symlink (local execution)     | 0.04ms                       |
| Tar create (uncompressed)                  | 4.48s (7.36 GB)              |
| Tar+zstd create                            | 4.76s (3.47 GB, 2.1:1 ratio) |
| Tar extract                                | 4.88s                        |
| Zstd extract                               | 5.52s                        |
| torch import time                          | 1.35s                        |
| numpy import time                          | <1ms                         |
| `importlib.metadata`                       | Works (version "2.10.0")     |
| nvidia namespace subpackages               | All 10 import correctly      |
| LD_LIBRARY_PATH needed                     | No                           |

### Top packages by size

| Package                | Size         |
| ---------------------- | ------------ |
| nvidia (all CUDA libs) | 4,589 MB     |
| torch                  | 1,757 MB     |
| triton                 | 669 MB       |
| cuda                   | 111 MB       |
| scipy                  | 83 MB        |
| Everything else        | < 30 MB each |

### Split-venv simulation

| Venv             | Files  | Size    | Install time          |
| ---------------- | ------ | ------- | --------------------- |
| Torch-only       | 11,804 | 1.83 GB | —                     |
| Everything else  | 6,406  | 5.66 GB | —                     |
| Combined install | —      | —       | 2.2s (vs 4.3s single) |

**Key finding:** File count grew modestly (16K macOS → 18K Linux CUDA), not the feared 50-100K. The 17x byte increase is driven by nvidia `.so` libraries (4.59 GB), not file count. torch is only 25% of bytes — nvidia across 33 wheels is 62%. Splitting provides marginal benefit vs the complexity cost of multiple TreeArtifacts on PYTHONPATH.

**Verdict:** Single-venv design confirmed. Split-venv dropped from scope. No architectural changes needed.

### nvidia namespace validation (full CUDA scale)

All 10 nvidia subpackages import correctly from flat site-packages via PYTHONPATH: cudnn, cublas, cuda_runtime, cuda_nvrtc, nvjitlink, cufft, cusparse, cusolver, nccl, nvtx. No `LD_LIBRARY_PATH`, no `__init__.py`, no merge logic. PEP 420 implicit namespace packages work at full CUDA scale.

---

## Hardlink Experiments

**Context:** uv's `--link-mode=hardlink` silently falls back to full copies when cache and venv are on different filesystems. No error, no warning — just 7+ GB wasted per venv. This is a kernel constraint (`EXDEV`), not a uv bug.

### Experiment 1: Filesystem boundaries

**Environment:** Linux 6.14.0-37-generic, ext4 root, uv 0.10.3

| Location                         | Device | Filesystem |
| -------------------------------- | ------ | ---------- |
| Home dir (`~`)                   | 259:2  | ext4       |
| Default uv cache (`~/.cache/uv`) | 259:2  | ext4       |
| Working dir (cwd)                | 259:2  | ext4       |
| `/tmp`                           | 0:103  | overlay    |

Cross-path hardlink test results:

| Test        | Result                                        |
| ----------- | --------------------------------------------- |
| cwd → cwd   | OK (same inode, nlink=2)                      |
| /tmp → /tmp | OK (same inode, nlink=2)                      |
| cwd → /tmp  | FAIL — `[Errno 18] Invalid cross-device link` |

**Conclusion:** `/tmp` is on a separate overlay filesystem on this system (and many CI containers).

### Experiment 2: UV_CACHE_DIR location vs hardlink dedup

| Scenario                     | Same device?        | Hardlinked files | Ratio | Verdict   |
| ---------------------------- | ------------------- | ---------------- | ----- | --------- |
| Same fs (both in cwd)        | YES (259:2 / 259:2) | 1003/1010        | 99%   | HARDLINKS |
| Cache in `/tmp`, venv in cwd | NO (259:2 / 0:103)  | 0/1010           | 0%    | NO DEDUP  |
| Both in `/tmp`               | YES (0:103 / 0:103) | 1003/1010        | 99%   | HARDLINKS |
| Cache in cwd, venv in `/tmp` | NO (0:103 / 259:2)  | 0/1010           | 0%    | NO DEDUP  |

**Conclusion:** Hardlinks work **if and only if** the uv cache and the target venv are on the **same filesystem/device**. Cross-device combinations silently fall back to full copies with zero dedup.

### Experiment 3: CI simulation — co-located cache + 3 venvs

Simulated CI environment with 3 test targets sharing identical deps, uv cache co-located on same filesystem.

| Venv                | Install time | nlink sample                             |
| ------------------- | ------------ | ---------------------------------------- |
| Venv 1 (cold cache) | 0.15s        | nlink=2 (shared with cache)              |
| Venv 2 (warm cache) | 0.06s        | nlink=3 (shared with cache + venv 1)     |
| Venv 3 (warm cache) | 0.06s        | nlink=4 (shared with cache + venv 1 + 2) |

| Component                                 | Disk usage   |
| ----------------------------------------- | ------------ |
| Per-venv `du` (apparent)                  | 0.22 GB each |
| **Total work dir** (counting inodes once) | **0.28 GB**  |
| Naive (3 full copies, no dedup)           | ~0.70 GB     |

**Conclusion:** Hardlinks are working: nlink values increase with each venv (2→3→4), total disk 0.28 GB instead of 0.70 GB (60% savings). With CUDA torch at 7.42 GB per venv, this is the difference between 5 venvs costing ~7.5 GB total vs ~37 GB.

### Mitigation in rules_pythonic

1. `UV_CACHE_DIR` and `sandbox_writable_path` must point to the same filesystem as Bazel's output base (NOT `/tmp`)
2. `install_packages.py` verifies `nlink > 1` on a sample file after install and fails with an actionable error if hardlinks didn't work

---

## Conftest.py Discovery in the Sandbox

pytest discovers `conftest.py` files by walking up from the test file toward `rootdir`, importing fixtures at each directory level. In Bazel's runfiles sandbox, this creates two problems: (1) only declared files exist in the runfiles tree, so conftest files outside the test's dependency chain are invisible, and (2) pytest determines `rootdir` by walking up looking for `pyproject.toml`, and in a monorepo with per-package `pyproject.toml` files, it anchors at the package — anything above it is invisible.

### The problem illustrated

```
repo/
  conftest.py                    # global fixtures (e.g., database setup)
  pyproject.toml                 # root-level
  packages/
    conftest.py                  # shared across all packages (e.g., common mocks)
    ml/
      conftest.py                # ml group fixtures (e.g., GPU device selection)
      attic/
        BUILD.bazel
        conftest.py              # package fixtures
        tests/
          conftest.py            # test fixtures
          test_compiler.py
```

Without intervention, `test_compiler` only sees conftest files at the package level and below. The global, packages-level, and ml-level conftest files are missing from runfiles and invisible to pytest.

### Solution: three parts

**Part 1: The runner always sets `--rootdir`.** `pythonic_pytest_runner.py` passes `--rootdir` pointing at the repo root in runfiles. This anchors pytest's conftest discovery deterministically — from the repo root down to the test file, every conftest.py at every level gets discovered.

```python
# pythonic_pytest_runner.py (relevant addition)
import os

runfiles_dir = os.environ.get("RUNFILES_DIR", "")
repo_root = os.path.join(runfiles_dir, "_main")

args = list(test_files)
args.extend(["--rootdir", repo_root])
```

No changes to the launcher template. The runner always knows the repo root is `$RUNFILES_DIR/_main`.

**Part 2: `conftest` filegroup chain gets conftest files into runfiles.** Each directory with a conftest.py defines a filegroup that includes its own conftest and chains to its parent:

```starlark
# /BUILD.bazel (repo root — the chain ends here)
filegroup(
    name = "conftest",
    srcs = ["conftest.py", "pyproject.toml"],
    visibility = ["//visibility:public"],
)

# packages/BUILD.bazel (chains to parent)
filegroup(
    name = "conftest",
    srcs = ["conftest.py", "//:conftest"],
    visibility = ["//visibility:public"],
)

# packages/ml/BUILD.bazel (chains to parent)
filegroup(
    name = "conftest",
    srcs = ["conftest.py", "//packages:conftest"],
    visibility = ["//visibility:public"],
)
```

Each level knows its parent. Adding a new intermediate level only touches one BUILD file. The chain mirrors pytest's own walk-up model — a child inherits from its parents.

**Part 3: The `conftest` attribute on `pythonic_test`.** Pass the conftest filegroup chain to make conftest files available in runfiles:

```starlark
pythonic_test(
    name = "test_training",
    srcs = ["test_training.py"],
    deps = [":ml"],
    conftest = ":conftest",
)
```

Without `conftest`, tests still run but don't get parent conftest fixtures.

### Resulting runfiles tree

```
$RUNFILES_DIR/_main/
  conftest.py                    # from //:conftest
  pyproject.toml                 # from //:conftest (pytest reads [tool.pytest.ini_options])
  packages/
    conftest.py                  # from //packages:conftest
    ml/
      conftest.py                # from //packages/ml:conftest
      attic/
        conftest.py              # from macro auto-collection
        tests/
          conftest.py            # from macro auto-collection
          test_compiler.py
```

pytest with `--rootdir=$RUNFILES_DIR/_main` walks the full hierarchy. Every conftest.py at every level is discovered and imported. A side effect: with `--rootdir` at the repo root, pytest reads the root `pyproject.toml` for `[tool.pytest.ini_options]`, giving global pytest configuration rather than per-package. This is desirable.

### Derisking results (pytest 9.0.2, Python 3.14.2, macOS ARM)

All five experiments passed:

1. **`--rootdir` anchors conftest discovery.** Without `--rootdir`, running a test in `sub/` cannot see `root_fixture` from the parent conftest. With `--rootdir` pointing at the parent, all fixtures from the root conftest are discovered and available.

2. **Symlink-based runfiles directory is traversable.** A simulated runfiles tree (`_main/` with symlinks to real source files, mirroring Bazel's structure) is fully walkable by `os.walk()` and pytest. `--rootdir` pointing at the `_main/` directory discovers conftest files through symlinks at all levels.

3. **pytest reads root `pyproject.toml` for config.** With `--rootdir` set, pytest finds and reads the `pyproject.toml` at the rootdir for `[tool.pytest.ini_options]` (confirmed via `configfile: pyproject.toml` in session header). Custom markers defined in the root config are recognized. Per-package `pyproject.toml` sections are not read — global pytest config lives at the root, which is desirable for consistency.

4. **End-to-end 5-level conftest chain.** A hierarchy with conftest files at 5 levels (repo root, `packages/`, `packages/ml/`, `packages/ml/attic/`, `packages/ml/attic/tests/`) — pytest discovers and imports fixtures from every level. A test using fixtures from all 5 levels passes. Non-adjacent levels (root + ml + tests, skipping packages and attic) also work.

5. **No conftest at root.** `--rootdir` pointing at an empty directory (no conftest.py, no pyproject.toml) works without error. Tests run normally with only their local conftest fixtures.

**Remaining gap:** Experiments simulated runfiles with local symlinks rather than running inside an actual Bazel sandbox. Verify with a real `bazel test` invocation during Phase 0.

---

## Monorepo Scaling Patterns

Five patterns handle increasing complexity, all validated with uv 0.9.22 across 100+ automated checks.

### Pattern 1: Single product, shared dependencies

**When to use:** One team, one product (or tightly coupled products). All packages agree on dependency versions. This is the default — start here.

```
monorepo/
  MODULE.bazel
  pyproject.toml                    # uv workspace root
  uv.lock
  requirements-linux.txt
  requirements-darwin.txt
  packages/
    attic/
      pyproject.toml                # dependencies = ["torch", "numpy"]
      src/attic/...
      BUILD.bazel
```

**uv workspace:**

```toml
# pyproject.toml (root)
[tool.uv.workspace]
members = ["packages/*"]
```

**Resolution:**

```bash
uv lock
uv export --all-packages --all-extras --no-hashes --no-emit-workspace -o requirements-universal.txt
uv pip compile requirements-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux.txt
uv pip compile requirements-universal.txt --python-platform aarch64-apple-darwin -o requirements-darwin.txt
```

**MODULE.bazel:**

```starlark
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")

pip.parse(
    hub_name = "pypi",
    python_version = "3.11",
    requirements_by_platform = {
        "//:requirements-linux.txt": "linux_*",
        "//:requirements-darwin.txt": "osx_*",
    },
)

use_repo(pip, "pypi")
```

**BUILD files:**

```starlark
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_package", "pythonic_test")

pythonic_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],
)

[pythonic_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(["tests/test_*.py"])]
```

No platform awareness in BUILD files. `@pypi` handles platform selection internally via `select()`.

### Pattern 2: Single product, platform variants (GPU/CUDA)

**When to use:** Same product deployed to different hardware. Some configurations need different package builds (CUDA 11 vs CUDA 12) or additional packages (triton, pycuda). The variants are mutually exclusive at deployment time.

**pyproject.toml with conflicting extras:**

```toml
# packages/trainer/pyproject.toml
[project]
name = "trainer"
dependencies = ["numpy", "scipy"]

[project.optional-dependencies]
cpu = ["torch==2.1.0"]
cuda12 = ["torch==2.1.0+cu121", "triton"]

[tool.uv]
conflicts = [
    [
        { extra = "cpu" },
        { extra = "cuda12" },
    ],
]
```

`uv lock` resolves each branch separately within one lock file.

**Resolution:**

```bash
uv lock
uv export --package trainer --extra cpu --no-hashes --no-emit-workspace -o requirements-cpu-universal.txt
uv export --package trainer --extra cuda12 --no-hashes --no-emit-workspace -o requirements-cuda12-universal.txt
uv pip compile requirements-cpu-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cpu.txt
uv pip compile requirements-cuda12-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cuda12.txt
```

**Bazel platform definitions:**

```starlark
# config/BUILD.bazel
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

string_flag(name = "accelerator", build_setting_default = "cpu")
config_setting(name = "is_cuda12", flag_values = {":accelerator": "cuda12"})
```

**MODULE.bazel:**

```starlark
pip.default(
    platform = "linux_x86_64_cuda12",
    os_name = "linux",
    arch_name = "x86_64",
    config_settings = ["@//config:is_cuda12"],
)

pip.parse(
    hub_name = "pypi",
    python_version = "3.11",
    requirements_by_platform = {
        "//:requirements-linux-cpu.txt": "linux_x86_64",
        "//:requirements-linux-cuda12.txt": "linux_x86_64_cuda12",
        "//:requirements-darwin.txt": "osx_*",
    },
)
```

BUILD files are identical to Pattern 1. `select()` in `@pypi` picks the right wheel.

```bash
bazel test //packages/trainer/...                              # CPU (default)
bazel test //packages/trainer/... --//config:accelerator=cuda12  # CUDA 12
```

### Pattern 3: Multiple products, additional test dependencies

**When to use:** Multiple test suites that need extra packages (locust, moto, httpx) that don't belong in production.

Test folders get their own minimal `pyproject.toml` and join the workspace:

```toml
# integration-tests/pyproject.toml
[project]
name = "integration-tests"
version = "0.0.0"
requires-python = ">=3.11"

[dependency-groups]
test = ["locust", "moto", "httpx"]
```

```toml
# pyproject.toml (root) — updated members
[tool.uv.workspace]
members = ["packages/*", "integration-tests"]
```

The `[project]` stub is required — uv workspace members must have a `[project]` table.

**BUILD files:**

```starlark
# integration-tests/tests/BUILD.bazel
pythonic_test(
    name = "test_load",
    srcs = ["test_load.py"],
    pyproject = "//integration-tests:pyproject.toml",
    deps = ["//packages/api"],
)
```

The test target's `pyproject` attribute adds locust and moto to the venv alongside the package's deps. `install_packages.py` unions all pyproject.toml files.

### Pattern 4: Multiple products, incompatible dependencies

**When to use:** Products genuinely cannot agree on a package version (pydantic 2.x vs 1.x). This adds real maintenance cost (multiple lock files). Only use when conflicts are genuine and unavoidable.

```
monorepo/
  pyproject.toml              # workspace for modern product
  uv.lock
  requirements-linux.txt
  packages/
    core/pyproject.toml       # dependencies = ["pydantic>=2.0"]
  legacy/
    pyproject.toml            # separate workspace for legacy product
    uv.lock                   # separate lock file
    requirements-linux.txt    # separate requirements
    packages/
      pipeline/pyproject.toml # dependencies = ["pydantic<2.0"]
```

Two `pip.parse()` calls in MODULE.bazel with different `hub_name` values:

```starlark
pip.parse(hub_name = "pypi", ...)
pip.parse(hub_name = "pypi_legacy", ...)
use_repo(pip, "pypi", "pypi_legacy")
```

Legacy targets specify the legacy wheel pool:

```starlark
pythonic_test(
    name = "test_pipeline",
    srcs = glob(["tests/test_*.py"]),
    deps = [":pipeline"],
    pypi = "@pypi_legacy",
)
```

Shared libraries tested against both resolves:

```starlark
pythonic_test(name = "test_core", srcs = [...], deps = [":core"])
pythonic_test(name = "test_core_legacy", srcs = [...], deps = [":core"], pypi = "@pypi_legacy")
```

### Pattern 5: Combined (variants + multiple products)

Patterns 2 + 4 together. Main workspace uses `[tool.uv] conflicts` for CPU/CUDA12, legacy workspace uses its own extras. Independent resolution. This is rare — most repos never need it.

```starlark
# MODULE.bazel — two parse calls, each with custom platforms
pip.default(platform = "linux_x86_64_cuda12", ...)
pip.parse(hub_name = "pypi", ...)

pip.default(platform = "linux_x86_64_cuda11", ...)
pip.parse(hub_name = "pypi_legacy", ...)
```

### Choosing a pattern

| Pattern                  | Products        | Dep conflicts                 | Lock files | Complexity |
| ------------------------ | --------------- | ----------------------------- | ---------- | ---------- |
| 1. Single product        | 1               | None                          | 1          | Minimal    |
| 2. Platform variants     | 1               | Platform-only                 | 1          | Low        |
| 3. Additional test deps  | Multiple suites | None (additive)               | 1          | Low        |
| 4. Incompatible products | Multiple        | Genuine version conflicts     | N          | Medium     |
| 5. Combined              | Multiple        | Conflicts + platform variants | N          | High       |

Start with Pattern 1. Move to Pattern 2 when you need GPU/CUDA variants. Use Pattern 3 freely for test-only deps. Only reach for Pattern 4 when version alignment is truly impossible.

### The information flow (all patterns)

```
pyproject.toml (per package/test folder)
    |
    v
uv lock (per workspace — usually one, sometimes two)
    |
    v
uv export (universal, with environment markers)
    |
    v
uv pip compile --python-platform (optional — resolves markers per platform)
    |
    v
requirements-*.txt (checked in — universal or per-platform)
    |
    v
pip.parse() + pip.default() (MODULE.bazel — maps files to platforms)
    |
    v
@pypi hub repo (select() picks right wheel per config)
    |
    v
PythonicInstall action (receives wheels, installs packages — platform-unaware)
    |
    v
install_packages.py (matches pyproject.toml names against wheels — platform-unaware)
```

rules_pythonic itself is the same in every pattern. The complexity lives in the resolution layer (uv) and the platform layer (pip.parse + pip.default).

---

## pythonic_files

For importable code that isn't a package — shared test utilities, config modules, generated protobuf stubs, compiled extension wrappers. These have no `pyproject.toml`, no version, no third-party deps, and will never be published as a wheel.

### API

```starlark
pythonic_files(
    name,
    srcs,          # label_list(allow_files = True) — any file type
    src_root,      # string — directory added to PYTHONPATH
    data = [],     # additional files not on import path
    visibility = None,
)
```

Returns `PythonicPackageInfo` with `pyproject = None` and `wheel = None`. Downstream rules consume it identically to a package — the `src_root` goes on PYTHONPATH, the `srcs` go into runfiles.

### Key properties

- **No `deps`.** Leaf node only. The consuming package owns the dependency graph.
- **No file type filter.** Python packages contain `.py`, `.so`, `.pyi`, `.json`. User controls inclusion via `glob()`.
- **No `.wheel` target.** Never builds wheels.
- **Upgrade path:** Add a 3-line `pyproject.toml` and switch to `pythonic_package`. Code with dependencies is a package.

### Use cases

**Shared test utilities:**

```starlark
# lib/testing/BUILD.bazel
pythonic_files(name = "testing", srcs = glob(["**/*.py"]), src_root = ".", visibility = ["//visibility:public"])

# packages/attic/BUILD.bazel
pythonic_test(name = "test_compiler", srcs = [...], deps = [":attic", "//lib/testing"])
```

**Compiled extension with wrapper:**

```starlark
cc_binary(name = "_native.so", srcs = ["native.cc"], linkshared = True)
pythonic_files(name = "bindings", srcs = ["wrapper.py", ":_native.so"], src_root = ".")
```

**Generated protobuf code:**

```starlark
py_proto_library(name = "myservice_py_proto", deps = [":myservice_proto"])
pythonic_files(name = "myservice_py", srcs = [":myservice_py_proto"], src_root = ".")
```

### Implementation (~20 lines Starlark)

```starlark
def _pythonic_files_impl(ctx):
    if ".." in ctx.attr.src_root:
        fail("src_root must not contain '..' — use a BUILD file in the parent directory instead")

    full_src_root = ctx.label.package
    if ctx.attr.src_root and ctx.attr.src_root != ".":
        full_src_root = full_src_root + "/" + ctx.attr.src_root

    srcs_depset = depset(ctx.files.srcs)

    return [
        PythonicPackageInfo(
            src_root = full_src_root,
            srcs = srcs_depset,
            pyproject = None,
            wheel = None,
            first_party_deps = depset(),
        ),
        DefaultInfo(
            files = srcs_depset,
            runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.data),
        ),
    ]
```

### Provider impact

One field type change to `PythonicPackageInfo`:

```starlark
"pyproject": "File or None: the pyproject.toml file (None for pythonic_files targets)",
```

Downstream code paths that touch `pyproject` need an `if info.pyproject:` guard. `install_packages.py` requires no change (filtered upstream in Starlark).

---

## install_packages.py

Full build-time helper (~80 lines of Python stdlib). Receives pyproject.toml files + wheel paths + flags from Starlark, installs all wheels into a flat target directory as a cached TreeArtifact.

> **Note:** The prototype code below used `uv venv` + `uv pip install --python`. The actual implementation uses `uv pip install --target` to produce a flat directory without a venv, avoiding dangling symlinks that Bazel's TreeArtifact validation rejects. See `pythonic/private/install_packages.py` for the current implementation.

```python
#!/usr/bin/env python3
"""Build-time action: parse pyproject.toml, install matching wheels via uv."""
import pathlib, subprocess, sys

if sys.version_info >= (3, 11):
    import tomllib
else:
    try:
        import tomli as tomllib
    except ImportError:
        print("ERROR: Python < 3.11 requires 'tomli'. Add it to pip.parse().", file=sys.stderr)
        sys.exit(1)

uv = sys.argv[1]           # uv binary (from rules_uv toolchain)
python = sys.argv[2]       # python interpreter (from rules_python toolchain)
venv_dir = sys.argv[3]     # output TreeArtifact path
wheel_dir = sys.argv[4]    # directory with all pre-downloaded .whl files
# remaining args: pyproject paths + --first-party-packages + --extras flags

# ... (flag parsing omitted for brevity — see full RFC) ...

def normalize(name):
    return name.lower().replace("-", "_").replace(".", "_")

def extract_dep_name(dep_spec):
    """Extract package name from a PEP 508 dependency specifier."""
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()

# Collect dep names from all pyproject.toml files
needed = set()
for pp_path in pyproject_paths:
    pp = tomllib.loads(pathlib.Path(pp_path).read_text())
    # Validate requires-python
    # ... (version check) ...
    for dep in pp.get("project", {}).get("dependencies", []):
        needed.add(normalize(extract_dep_name(dep)))
    opt_deps = pp.get("project", {}).get("optional-dependencies", {})
    for group in extras_groups:
        for dep in opt_deps.get(group, []):
            needed.add(normalize(extract_dep_name(dep)))

# Three-way classification: match wheel, match first-party, or fail
wheels_to_install = []
missing = []
for dep_name in sorted(needed):
    if dep_name in wheel_index:
        wheels_to_install.append(str(wheel_index[dep_name]))
    elif dep_name in fp_normalized:
        pass  # handled via PYTHONPATH
    else:
        missing.append(dep_name)

if missing:
    for m in missing:
        print(f'ERROR: package "{m}" required by pyproject.toml but not found '
              f'in @pypi wheels and not a first-party dep.', file=sys.stderr)
    sys.exit(1)

# Create venv and install
subprocess.check_call([uv, "venv", venv_dir, "--python", python])
if wheels_to_install:
    subprocess.check_call([
        uv, "pip", "install",
        "--python", f"{venv_dir}/bin/python3",
        "--no-deps", "--no-index", "--link-mode=hardlink",
    ] + wheels_to_install)

    # Verify hardlinks actually worked
    # ... (nlink check — fails with actionable error if cross-device) ...
```

**Critical design decisions:**

- `--no-deps`: does NOT resolve transitive deps — `requirements.txt` already has the full closure via `pip.parse()`
- `--no-index`: never contacts PyPI — only uses pre-downloaded wheels
- `--link-mode=hardlink`: zero disk overhead — REQUIRES same filesystem as `UV_CACHE_DIR`
- Hardlink verification: checks `nlink > 1` after install, fails fast if cross-device

---

## Test Runner: pytest

The default and only built-in test runner. A ~25-line Python bridge translates Bazel environment variables to pytest arguments:

```python
# pythonic_pytest_runner.py
import os, sys

def main():
    test_files = sys.argv[1:]

    # File-level sharding — no pytest-shard plugin needed
    shard_index = os.environ.get("TEST_SHARD_INDEX")
    total_shards = os.environ.get("TEST_TOTAL_SHARDS")
    if shard_index is not None:
        i, n = int(shard_index), int(total_shards)
        test_files = [f for idx, f in enumerate(test_files) if idx % n == i]
        if not test_files:
            sys.exit(0)

    args = list(test_files)

    # Bazel test filter -> pytest -k
    test_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
    if test_filter:
        args.extend(["-k", test_filter])

    # Bazel test output -> pytest --junitxml
    xml_output = os.environ.get("XML_OUTPUT_FILE")
    if xml_output:
        args.extend(["--junitxml", xml_output])

    # --rootdir anchors conftest discovery at repo root
    runfiles_dir = os.environ.get("RUNFILES_DIR", "")
    repo_root = os.path.join(runfiles_dir, "_main")
    args.extend(["--rootdir", repo_root])

    args.append("-v")

    import pytest
    sys.exit(pytest.main(args))

if __name__ == "__main__":
    main()
```

**Escape hatches for non-pytest tests:**

```starlark
# File-based: full control via a Python script
pythonic_test(name = "test_distributed", main = "tests/run_distributed.py", ...)

# Module-based: python -m sets __package__ correctly for relative imports
pythonic_test(name = "test_distributed", main_module = "torch.distributed.run", ...)
```

---

## Launcher Template

```bash
#!/usr/bin/env bash
# pythonic_run.tmpl.sh — launcher for rules_pythonic test and binary targets

# (runfiles resolution boilerplate omitted — see pythonic/private/pythonic_run.tmpl.sh)
set -o errexit -o nounset -o pipefail

PYTHON="$(rlocation {{PYTHON_TOOLCHAIN}})"
PACKAGES_DIR="$(rlocation {{PACKAGES_DIR}})"

export PYTHONPATH="{{FIRST_PARTY_PYTHONPATH}}:${PACKAGES_DIR}"

{{PYTHON_ENV}}

exec "${PYTHON}" -B -s {{INTERPRETER_ARGS}} {{EXEC_CMD}} "$@"
```

`{{EXEC_CMD}}` is composed by the Starlark rule:

- **Default (pytest):** `"$(rlocation .../runner.py)" "$(rlocation test1.py)" ...`
- **`main = file.py`:** `"$(rlocation .../file.py)"`
- **`main_module = "attic.serve"`:** `-m attic.serve`

**Why no venv:** The original design used `uv venv` + `uv pip install --python`, but `uv venv` creates a `bin/python3` symlink to the build-time interpreter path, which is ephemeral in Bazel's sandbox. Bazel's TreeArtifact validation rejects dangling symlinks. Using `uv pip install --target` instead produces a flat directory of packages with no bin/ or symlinks — simpler and avoids the problem entirely.

---

## Existing Ecosystem Audit

### rules_python (53K lines Starlark)

- `PyInfo` provider: 13 fields, 704 lines, including legacy `has_py2_only_sources`
- `VenvSymlinkEntry` system: 470 lines of path optimization with namespace package special-casing
- Hardcoded `_WELL_KNOWN_NAMESPACE_PACKAGES = ["nvidia"]`
- 30+ TODO/FIXME comments referencing known bugs: wheel filename escaping, Windows path separators, incomplete shebang rewriting
- pip integration unwraps wheels into separate Bazel repos, destroying flat `site-packages/` layout — root cause of namespace package breakage

### rules_py / aspect_rules_py (10.8K lines Starlark + Rust)

- 1,700 lines of Rust to create venvs at runtime (~87ms per test invocation, every time, thrown away and recreated)
- `.pth` escape path uses magic depth constants: `"/".join([".."] * (4 + target_depth))`
- Collision resolution code has a FIXME: "last wins doesn't actually work"
- The fork is load-bearing — can't track upstream without rebasing patches touching core venv logic
- Each optimization deepens the fork

### rules_pycross (12K lines)

- Most defensible of the three — clean translate → resolve → render pipeline for cross-compilation
- Coupled to `PyInfo` from rules_python, inheriting all import path complexity
- Solves a problem that `uv` now handles automatically

### Custom build infrastructure (~1,400 lines)

- `py_wheel_with_info` (~190 lines): Starlark → JSON → TOML pipeline
- `generate_pyproject_toml.py` (~100 lines): JSON → TOML converter
- `link_pyproject_tomls.py` (~50 lines): Symlink generated TOML to source
- `create_devenv.py` (~290 lines): Dev venv from runfiles
- `setup_dev_environment.py` (~200 lines): Full dev env setup

---

## Full Risk Register

All risks were prototyped or benchmarked. None remain as blockers.

| Risk                                              | Severity | Status        | Resolution                                                                    |
| ------------------------------------------------- | -------- | ------------- | ----------------------------------------------------------------------------- |
| TreeArtifact at CUDA scale (50-100K files feared) | High     | **Verified**  | 18K files, all ops < 5s. Feared file explosion didn't materialize.            |
| Hardlink cross-device silent fallback             | Medium   | **Mitigated** | Same-fs requirement + nlink check in install_packages.py.                     |
| Remote cache size                                 | Medium   | **Measured**  | Zstd 3.47 GB per venv. ~5-10 unique venvs limits blast radius.                |
| VERSION file escaping sandbox                     | Medium   | **Resolved**  | setuptools rejects `../../VERSION`. Fix: copy VERSION locally.                |
| nvidia namespace at CUDA scale                    | Medium   | **Verified**  | All 10 subpackages import correctly. Zero code needed.                        |
| LD_LIBRARY_PATH for CUDA torch                    | Medium   | **Verified**  | torch finds `.so` via `__file__` relative paths. No launcher changes.         |
| Split-venv needed                                 | Medium   | **Verified**  | Single venv fast enough. Splitting adds complexity for marginal gain.         |
| Conservative cache key causing rebuilds           | Low      | **Verified**  | Rebuild 1.7s with warm uv cache. Wheels change rarely.                        |
| PYTHONPATH scaling                                | Low      | **Measured**  | 10 entries = 200us/import. Sub-millisecond at realistic sizes.                |
| Platform wheel selection                          | Low      | **Verified**  | uv handles automatically in `--no-index --find-links` mode.                   |
| Wheel build in Bazel sandbox                      | Low      | **Verified**  | `uv build` follows symlinks, works with `--no-build-isolation`.               |
| Build-time Python < 3.11                          | Low      | **Addressed** | tomllib fallback to tomli for 3.9/3.10.                                       |
| Console script shebangs broken                    | Low      | **Verified**  | `shutil.which()` finds them, `python -m` bypasses shebangs.                   |
| `sys.prefix` wrong (toolchain, not venv)          | Low      | **Verified**  | `importlib.metadata` works anyway via `sys.path`.                             |
| `importlib.metadata` for source deps              | Low      | **Confirmed** | Raises `PackageNotFoundError` — expected. Editable install can fix if needed. |
| pyproject.toml drift from requirements.txt        | Low      | **Verified**  | Three-way classification catches missing deps.                                |
| `--no-deps` requires full transitive closure      | Low      | **Confirmed** | `@pypi` wheel set IS the closure.                                             |
| `.pth` files not processed via PYTHONPATH         | Low      | **Verified**  | Expected — `.pth` files only processed by `site.addsitedir()`.                |
| System site-packages leakage                      | Low      | **Verified**  | `-s` flag disables user site-packages.                                        |
| Namespace packages across PYTHONPATH dirs         | Low      | **Verified**  | Python's `_NamespacePath` aggregates automatically.                           |

---

## Resolved Questions

22 questions were resolved via prototyping and benchmarking before the design was finalized. Key resolutions:

1. **Compiled extensions:** No special handling. `pythonic_package` accepts compiled artifacts via `data`. Assembly uses `copy_to_directory`.

2. **Exact cache keys:** Deferred. Conservative key (all wheels) is fine — rebuild is 1.7s with warm cache. Per-package keys possible via ~50-line Starlark TOML parser if needed.

3. **Collecting all wheels from `@pypi`:** `pip.parse()` generates `all_whl_requirements` in `@pypi//:requirements.bzl`.

4. **`importlib.metadata` for source deps:** Editable install in venv build action creates `.dist-info`. The `.pth` file is harmless dead weight.

5. **Namespace packages:** Work natively — PEP 420 since Python 3.3. Verified across multiple PYTHONPATH directories.

6. **PYTHONPATH import order:** First-party before third-party confirmed via prototype. Shadowing works correctly.

7. **Toolchain Python + external site-packages:** Works. torch, numpy, metadata, `__file__` — all correct.

8. **Broken venv symlinks:** Irrelevant. Toolchain Python + PYTHONPATH bypasses them entirely.

9. **Venv creation performance:** 28ms for `uv venv`, 3.5s for install on macOS, 4.3s on Linux CUDA.

10. **Mutual exclusion migration:** Design decision. `constraint_setting` prevents hybrid states. CI runs both platforms.

11. **First-party deps in install_packages.py:** Three-way classification works. Name normalization handles all edge cases.

12. **Wheel build in sandbox:** `uv build --wheel` follows symlinks. `../../VERSION` blocked by setuptools — fix: copy locally.

13. **Platform wheel selection:** uv handles automatically. No Starlark `select()` needed.

14. **PYTHONPATH scaling:** 10 entries = 200us. 50 entries = 800us. Acceptable.

15. **Editable install metadata:** Works via PYTHONPATH. `.pth` file not processed (correct).

16. **Extras group collection:** Union-based, deduped by normalized name. Nonexistent groups silently ignored.

17. **conftest.py auto-discovery:** Walk-up algorithm verified. Starlark glob pattern validated.

18. **Build-time Python >= 3.11:** tomllib fallback to tomli for 3.9/3.10.

19. **Linux CUDA at full scale:** 18K files, 7.42 GB. All ops < 5s. Single venv confirmed.

20. **Split-venv not needed:** torch is 25% of bytes, nvidia is 62%. Marginal benefit vs complexity.

21. **Hardlink same-fs requirement:** Verified across 4 scenarios. install_packages.py checks nlink.

22. **Multi-version Python:** Flag + select, ~35 lines total. All components are proven Bazel mechanisms.

---

## Comparison Tables

### vs aspect_rules_py (current)

| Aspect                    | aspect_rules_py                           | rules_pythonic                        |
| ------------------------- | ----------------------------------------- | ------------------------------------- |
| Venv creation             | Runtime, per test, ~87ms                  | Build time, cached, 0ms at test time  |
| Import mechanism          | `.pth` files with `../../../../` escaping | PYTHONPATH                            |
| Namespace packages        | Rust recursive merge algorithm            | Just works (flat site-packages)       |
| Package installation      | Rust symlink/copy tool                    | `uv pip install --link-mode=hardlink` |
| Package metadata          | Starlark → JSON → TOML → symlink          | Hand-written pyproject.toml           |
| Third-party deps in BUILD | `deps = ["@pypi//torch"]` per target      | Not in BUILD files (pyproject.toml)   |
| Test runner               | User's problem                            | pytest (opinionated default)          |
| Custom tooling            | ~1700 lines Rust + fork                   | ~80 lines Python                      |
| Maintenance               | Fork of upstream, rebases required        | No fork, no upstream dependency       |

### vs stock rules_python

| Aspect               | rules_python                        | rules_pythonic                                         |
| -------------------- | ----------------------------------- | ------------------------------------------------------ |
| Third-party packages | py_library wrappers with PyInfo     | Wheel files, installed by uv                           |
| Third-party deps     | `@pypi//` in BUILD files            | pyproject.toml only                                    |
| Import config        | `PyInfo.imports` depsets            | PYTHONPATH                                             |
| `.dist-info`         | Not available                       | Available (real installation)                          |
| Namespace packages   | Broken (separate repos)             | Works (flat site-packages)                             |
| Multi-version Python | `python_version` attr + transitions | `--@rules_pythonic//pythonic:version` flag (tox model) |
| Dev environment      | Separate tooling needed             | Standard uv workflow                                   |

### vs Pants

| Aspect           | Pants                    | rules_pythonic                 |
| ---------------- | ------------------------ | ------------------------------ |
| Python support   | First-class, Pythonic    | Bolt-on to Bazel, but Pythonic |
| C++/MLIR support | Limited                  | Full (Bazel native)            |
| Migration cost   | Multi-quarter, high risk | Incremental, per-phase         |
| Lock file        | Native support           | Per-platform requirements.txt  |
