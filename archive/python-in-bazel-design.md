# RFC: roof_py — Pythonic build infrastructure for Bazel

**Status:** Draft
**Authors:** [TBD]
**Last updated:** 2026-02-16

## TL;DR

Replace the entire Python build infrastructure (`rules_python` wrappers, `aspect_rules_py` fork, `rules_pycross`, `wheel_helper.bzl`, the Rust venv tool) with a small, opinionated set of rules that delegate to standard Python tools (`uv`) and use standard Python conventions (`pyproject.toml`, `PYTHONPATH`, flat `site-packages`).

The goal: a Python developer joining the team should be able to read a BUILD file, understand what it does, and debug a failing test — without learning Starlark providers, runfiles semantics, or `.pth` file escaping.

---

## Why this matters

This is load-bearing infrastructure. Every engineer on the team interacts with it daily. When it breaks, people can't work. When it's confusing, people waste time. When it fights Python's conventions, people stop trusting the build system.

The complaints we hear:

- "Why does `import torch` fail? It's installed." (runfiles symlink issue)
- "I changed one file and everything rebuilt." (venv recreated from scratch)
- "Where is my package's pyproject.toml?" (it's generated, symlinked from bazel-bin)
- "How do I debug this import path?" (4 levels of `../` in a `.pth` file)
- "The build works locally but fails in CI." (nvidia sibling problem on Linux)
- "I just want to run pytest." (need to understand venv toolchains, Rust binary, collision strategies)

These aren't edge cases. They're the daily experience.

---

## The current stack and what's wrong with it

### What we have today

```
Layer          | Component                    | Lines  | Purpose
---------------+------------------------------+--------+----------------------------------------
Dependency     | rules_python pip.parse()     | ~500   | Download wheels, wrap in py_library
resolution     | Per-platform requirements.txt| ~400   | Lock files for macOS + Linux
               |                              |        |
Package        | py_wheel (rules_python)      | ~200   | Build .whl files
building       | py_wheel_with_info (custom)  | ~190   | Starlark -> JSON -> TOML pipeline
               | generate_pyproject_toml.py   | ~100   | JSON -> TOML converter
               | link_pyproject_tomls.py      | ~50    | Symlink generated TOML to source
               | rules_pycross wheel_library  | ~300   | Unpack wheels for integration tests
               |                              |        |
Test/binary    | aspect_rules_py (fork)       | ~2500  | py_test, py_binary rules
runtime        | Rust venv tool (pth.rs)      | ~540   | .pth file processing, symlink creation
               | Rust venv tool (venv.rs)     | ~940   | Venv creation, namespace merging
               | Rust venv tool (main.rs)     | ~185   | CLI, strategy composition
               | Rust venv shim               | ~150   | bin/python proxy
               | run.tmpl.sh                  | ~60    | Test launcher
               |                              |        |
Import path    | PyInfo provider              | ~100   | Transitive import path collection
plumbing       | py_library.bzl               | ~300   | Source and import management
               | py_semantics.bzl             | ~100   | Toolchain resolution
               |                              |        |
Dev environment| create_devenv.py             | ~290   | Dev venv from runfiles
               | setup_dev_environment.py     | ~200   | Full dev env setup
               |                              |        |
Toolchains     | Rust venv toolchain          | ~100   | Venv binary selection
               | Rust shim toolchain          | ~100   | Shim binary selection
               | Rust unpack toolchain        | ~100   | Wheel unpacking
               | ~600 Rust crate actions      |        | Building the Rust tools
               |                              |        |
Gazelle        | gazelle_python config        | ~50    | Auto-generate py_library targets
               | ~170 BUILD files             |        | Generated load() statements
---------------+------------------------------+--------+----------------------------------------
Total          |                              | ~7000+ | + Rust crate ecosystem + Gazelle Go binary
```

### The five structural problems

**1. Reimplementation instead of delegation**

The stack reimplements Python packaging concepts in non-Python languages:

- Dependency resolution: `PyInfo.imports` depsets instead of reading the lock file
- Package installation: Rust symlink/copy tool instead of `uv pip install`
- Import path config: `.pth` files with `../../../../` escaping instead of `PYTHONPATH`
- Package metadata: Starlark encoding instead of reading `pyproject.toml`
- Wheel building: `py_wheel` rule instead of `uv build`

Each reimplementation is incomplete, buggy in edge cases, and opaque to Python developers.

**2. Runtime overhead where there should be none**

Every `bazel test` invocation runs a Rust binary that:

1. Creates a fresh venv (~63ms)
2. Processes a `.pth` file (~24ms)
3. Creates symlinks or copies for every third-party package
4. Handles namespace package conflicts via recursive directory merging

This happens per test, every time, even when nothing changed. The result is thrown away and recreated next run.

The correct approach: create the environment once at build time, cache it, and reuse it. Test startup cost should be zero.

**3. Information flows backwards**

```
Natural flow:
  pyproject.toml -> build tool -> .whl -> install -> test

Current flow:
  BUILD.bazel -> JSON genrule -> TOML genrule -> symlink to source -> py_wheel -> .whl
                                                                          |
                                                        pycross_wheel_library -> PyInfo
```

Package metadata originates in Starlark and is converted _back_ to standard Python formats so that standard tools can read it. The source of truth is in the wrong place.

**4. Abstraction layers that don't abstract**

A developer debugging a failing import must understand:

- Bazel runfiles tree structure
- The `imports` attribute and how it translates to `.pth` entries
- How `.pth` entries use relative paths with `../../../../` escaping
- The Rust venv tool's strategy pattern (PthStrategy vs SymlinkStrategy vs CopyAndPatchStrategy)
- The difference between `static-pth` and `static-symlink` modes
- How `package_collisions` affects namespace package resolution
- The venv shim's interpreter resolution logic

None of these concepts exist in Python. A Python developer's mental model is: "packages are in site-packages, I import them." The abstraction layers don't simplify — they add concepts.

**5. The fork trap**

The `aspect_rules_py` fork is load-bearing. We can't upgrade to upstream releases without rebasing patches that touch core venv creation logic. The patches exist because the upstream design doesn't support our needs (top-level symlinks, .pth-to-external optimization, nvidia namespace merging). Each optimization makes the fork harder to maintain and upstream harder to track.

---

## Prototype results

The core architecture has been validated via an end-to-end prototype on macOS ARM (APFS, Python 3.11.10, uv 0.9.22, torch 2.10.0). The prototype simulates the full roof_py flow: `install_venv.py` creates a venv with `uv pip install --link-mode=hardlink`, then a test launcher uses the toolchain Python with `PYTHONPATH` pointing at first-party source roots + the venv's `site-packages/`.

**Key measurements (macOS ARM, torch + numpy + pytest + 17 transitive deps):**

| Metric                                     | Value           |
| ------------------------------------------ | --------------- |
| Venv creation (`uv venv`)                  | 28ms            |
| Package install (warm uv cache, hardlink)  | 3.5s            |
| Package install (warm uv cache, copy)      | 2.0s (APFS CoW) |
| Cold install (including download)          | 46s             |
| Files in site-packages                     | 16,386          |
| Apparent size                              | 431MB           |
| On-disk size (hardlink to uv cache)        | 392MB           |
| Additional venv (shared hardlinks)         | ~2-4MB          |
| TreeArtifact copy (simulated remote exec)  | 4.7s            |
| TreeArtifact symlink (local execution)     | 0ms             |
| Test execution (4 pytest tests with torch) | 2.5s            |
| torch import time                          | ~2s             |

**What was verified:**

- Toolchain Python + PYTHONPATH imports torch, numpy, all third-party packages correctly
- `importlib.metadata.version()` works for all installed packages
- `__file__` points to real files (hardlinked, not symlinks)
- First-party source roots shadow third-party packages correctly
- Namespace packages work in flat site-packages (nvidia simulation)
- Namespace packages work across MULTIPLE PYTHONPATH directories
- Broken venv `bin/python3` symlink has zero impact
- Console scripts discoverable via `shutil.which()`, `python -m` bypasses broken shebangs
- End-to-end pytest: 4/4 tests pass (first-party imports + third-party imports + metadata checks)

**Additional validation (wheel build action, uv 0.9.22, macOS ARM):**

- `uv build --wheel` from a symlinked source tree (simulating Bazel sandbox): **works** (0.42s)
- `uv build --wheel --no-build-isolation` with pre-installed setuptools: **works**
- `uv build --wheel` with build isolation (default): **works** — uv auto-fetches setuptools
- `--no-build-isolation` without setuptools: **fails correctly** — rule must provide setuptools
- Dynamic `version = {file = "VERSION"}` (local): **works** — reads VERSION from package dir
- Dynamic `version = {file = "../../VERSION"}` (escaping): **fails** — setuptools rejects paths outside package root
- Combined: symlinked sandbox + `--no-build-isolation` + local VERSION: **works** — full Bazel simulation passes

**Additional validation (platform wheel selection, uv 0.9.22, pip3 25.3):**

- `uv pip install --no-index --find-links <dir>` with both macOS and Linux wheels: **works** — uv selects correct platform
- Only wrong-platform wheels available: **fails correctly** with clear platform hint
- Direct `.whl` file install of wrong-platform wheel: **fails correctly** — uv checks platform even for direct paths
- Conclusion: uv handles platform filtering automatically; no `select()` needed in Starlark

**Additional validation (first-party dep handling):**

- Three-way dep classification (match wheel / match first-party / fail): **works** for all cases
- Name normalization (case, dots, hyphens, extras, PEP 508 markers): **all handled correctly**
- Genuinely missing dep (not first-party, not in wheels): **caught with clear error message**

**Additional validation (PYTHONPATH scaling, Python 3.14, macOS ARM):**

- 20 PYTHONPATH entries: all packages import correctly, shadowing works
- Namespace packages across 5 separate PYTHONPATH roots: all resolve correctly, `__path__` aggregates all roots
- Import performance: 1 entry = 50us, 10 entries = 200us, 50 entries = 800us (15.6x ratio)
- Real projects have 5-10 source roots + 1 site-packages = ~200us per fresh import. Acceptable.
- First-party-before-third-party ordering holds with any number of entries

**Additional validation (editable install + PYTHONPATH, uv 0.9.22, Python 3.14):**

- `uv pip install -e .` creates `.dist-info` in site-packages: **works** (0.44s)
- `importlib.metadata.version("mypkg")` via PYTHONPATH: **works** — finds `.dist-info` via `sys.path` search
- Editable `.pth` file in site-packages: **NOT processed** by PYTHONPATH (expected and correct — only `site.addsitedir()` processes `.pth` files)
- roof_py scenario (src_root + site-packages on PYTHONPATH): **works** — source imported via src_root, metadata found via `.dist-info`, `.pth` file is dead weight but harmless
- Conclusion: editable install in venv build action enables `importlib.metadata` for first-party packages without any `.pth` file processing

**Additional validation (extras groups, Python 3.14):**

- Multiple extras groups (`[test]`, `[gpu]`, `[dev]`): union-based collection works correctly
- Overlapping deps across groups: deduplicated by normalized name
- Nonexistent extras group: silently ignored (matches pip behavior)
- Multiple pyproject.toml files with different extras: union produces correct superset

**Additional validation (conftest.py auto-discovery):**

- Walk-up algorithm (test file → package root): correctly finds conftest.py at each directory level
- Sibling test directories get shared parent conftest.py but not each other's
- Starlark glob pattern validated: `glob(["conftest.py", "tests/**/conftest.py"])` collects correct set
- Source directory conftest.py files (`src/attic/conftest.py`) correctly excluded

**Linux CUDA benchmark results (overlay fs, Python 3.11, uv 0.10.3, torch 2.10.0+cu128):**

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
| importlib.metadata                         | Works (version "2.10.0")     |
| nvidia namespace subpackages               | All 10 import correctly      |
| LD_LIBRARY_PATH needed                     | No                           |

**Key finding: file count grew modestly (18K vs 16K on macOS), byte size grew 17x (7.42 GB vs 431 MB) — driven by nvidia CUDA `.so` libraries (4.59 GB). All operations remain well within acceptable thresholds. Split-venv provides marginal benefit: torch is only 25% of bytes (nvidia is 62%), and install times are already fast.**

**Top packages by size:**

| Package                | Size         |
| ---------------------- | ------------ |
| nvidia (all CUDA libs) | 4,589 MB     |
| torch                  | 1,757 MB     |
| triton                 | 669 MB       |
| cuda                   | 111 MB       |
| scipy                  | 83 MB        |
| Everything else        | < 30 MB each |

**nvidia namespace validation (full CUDA scale):** All 10 nvidia subpackages (cudnn, cublas, cuda_runtime, cuda_nvrtc, nvjitlink, cufft, cusparse, cusolver, nccl, nvtx) import correctly from flat site-packages via PYTHONPATH. No `LD_LIBRARY_PATH`, no `__init__.py`, no merge logic. PEP 420 implicit namespace packages work at full CUDA scale.

---

## Design principles

1. **pyproject.toml is the single source of truth.** Dependency information lives in pyproject.toml and nowhere else. BUILD files do not duplicate it. Bazel reads pyproject.toml at build time and resolves deps against pre-downloaded wheels.

2. **Delegate, don't reimplement.** Wheel installation is `uv pip install`. Wheel building is `uv build`. Test running is `pytest`. Dep resolution is reading pyproject.toml. We write glue, not reimplementations.

3. **Opinionated defaults, Python escape hatches.** pytest is the test runner. When you need something different, the escape hatch is "write a Python script," not "learn a Starlark DSL."

4. **Standard Python conventions.** `PYTHONPATH` for import paths. Flat `site-packages` for installed packages. No `.pth` files, no symlink forests, no `imports` attributes.

5. **Zero test-time overhead.** The Python environment is built and cached at build time. Test startup is `exec python -m pytest test_file.py`.

6. **Debuggable.** When an import fails, `sys.path` shows you exactly where Python is looking. `__file__` points to a real file. `importlib.metadata.version("torch")` works.

7. **Mutual exclusion migration.** Old and new rules do not interoperate. A `constraint_setting` makes them mutually exclusive — you build with one or the other, never both in the same invocation. This forces clean, bottom-up migration and prevents permanent hybrid states. CI runs both platforms until migration is complete, then the old one is deleted.

8. **No forks, no custom toolchains.** The only external tool is `uv`, which is a standard, well-maintained Python tool. No Rust venv binary. No shim toolchain. No unpack toolchain. Build-time scripts use only Python stdlib (`tomllib`, `pathlib`, `subprocess`).

---

## Architecture

### Overview

```
+--------------------------------------------------------------+
| BUILD file (user-facing)                                      |
|                                                               |
|   roof_py_package(                                            |
|       name = "attic",                                         |
|       pyproject = "pyproject.toml",                           |
|       src_root = "src",                                       |
|   )                                                           |
|                                                               |
|   roof_py_test(                                               |
|       name = "test_compiler",                                 |
|       srcs = ["tests/test_compiler.py"],                      |
|       deps = [":attic", ":attic-rt"],                         |
|   )                                                           |
+--------+-------------------------------------+----------------+
         |                                     |
+--------v----------+          +---------------v---------------+
| Source roots       |          | Venv TreeArtifact              |
|                    |          |                                |
| packages/attic/src |          | site-packages/                 |
|   attic/           |          |   torch/                       |
|     compiler/      |          |   numpy/                       |
|     utils/         |          |   pytest/                      |
+---------+----------+          |   nvidia/cudnn/                |
          |                     |   nvidia/cublas/               |
          |                     |   *.dist-info/                 |
          |                     +---------------+----------------+
          |                                     |
+---------v-------------------------------------v----------------+
| Launcher (roof_run.tmpl.sh)                                    |
|                                                                |
| PYTHONPATH=<source roots>:<site-packages>                      |
| exec python -B -s -m pytest test_compiler.py                   |
+----------------------------------------------------------------+
```

### How deps work — no duplication

Third-party dependency information lives exclusively in `pyproject.toml`. BUILD files never reference `@pypi//` targets directly. The venv build action reads pyproject.toml at execution time and matches dep names against pre-downloaded wheels from `pip.parse()`.

```
pyproject.toml (human-written, single source of truth)
       |
       +-- install_venv.py reads it at build time (Python tomllib, stdlib)
       |     matches dep names against @pypi//:all_whl_files
       |     installs with: uv pip install --no-deps --no-index
       |
       +-- uv build reads it to build .whl
       |
       +-- uv pip install -e . reads it for dev workflow
       |
       +-- ruff/mypy/pytest read [tool.*] sections

One file. Read by everything. Written by the developer. Never duplicated.
```

**Cache key trade-off:** The venv action's inputs are `pyproject.toml` + all wheels from `@pypi`. This is conservative — changing any wheel (even one this package doesn't use) invalidates the venv. In practice this is fine: wheels change when `requirements.txt` changes (rare), and when it does, you want all venvs to rebuild to verify compatibility. The uv cache makes rebuilds fast (~2-5s).

**Hermeticity:** The install action uses `--no-index` (never contacts PyPI) and `--no-deps` (doesn't resolve transitive deps — `requirements.txt` already has the full closure). Only pre-downloaded wheels from `pip.parse()` are installed. If pyproject.toml references a package not in `requirements.txt`, the action fails with a clear error.

### Rule inventory

| Rule / Macro                 | Type             | Purpose                                              |
| ---------------------------- | ---------------- | ---------------------------------------------------- |
| `roof_py_package`            | macro            | Declare a Python package (source + wheel targets)    |
| `roof_py_test`               | macro            | Run a Python test (pytest by default)                |
| `roof_py_binary`             | macro            | Run a Python binary                                  |
| `_roof_py_venv`              | rule (private)   | Create a cached site-packages TreeArtifact           |
| `_roof_py_test_rule`         | rule (private)   | Test rule with launcher generation                   |
| `_roof_py_binary_rule`       | rule (private)   | Binary rule with launcher generation                 |
| `roof_py` module extension   | module extension | Version flag, version-aware wheel aliases            |
| `_python_version_transition` | transition       | Per-target Python version pin (opt-in)               |
| `install_venv.py`            | build action     | Parse pyproject.toml, install matching wheels via uv |
| `_roof_pytest_runner.py`     | test entry point | Bazel env var to pytest flag translation             |
| `roof_run.tmpl.sh`           | template         | Environment setup launcher                           |

~545 lines of Starlark, ~105 lines of Python, ~20 lines of bash. No Rust. No custom toolchains. No providers beyond `DefaultInfo` and `RoofPyPackageInfo`.

---

### roof_py_package

Replaces: `py_library` + `py_wheel` + `py_wheel_with_info` + `pycross_wheel_library` + `generate_pyproject_toml.py` + `link_pyproject_tomls.py`

```starlark
# packages/attic/BUILD.bazel
roof_py_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    data = glob(["src/**/*.mlir", "src/**/*.json"]),
    deps = ["//packages/attic-rt:attic-rt"],  # first-party cross-package deps only
)
```

The macro creates two targets:

- **`:attic`** — source dep. When used in `deps`, the test rule adds `packages/attic/src` to PYTHONPATH. Source files are available in runfiles. Changes are reflected instantly without rebuilding.

- **`:attic.wheel`** — built wheel. When used in `deps`, the test rule installs the `.whl` file into the venv alongside third-party packages. Changes require a wheel rebuild.

The choice between source and wheel is made by the consumer, not the package:

```starlark
# Fast iteration — source on PYTHONPATH
roof_py_test(name = "test_fast", srcs = [...], deps = [":attic"])

# Test the built artifact — wheel in venv
roof_py_test(name = "test_wheel", srcs = [...], deps = [":attic.wheel"])

# Package with compiled extensions — wheel is the only option
roof_py_test(name = "test_iree", srcs = [...], deps = [":roof-iree.wheel"])
```

The `pyproject.toml` is a normal, hand-written file committed to source control. Dev tools read it directly. No generation, no symlinks.

**No `@pypi//` in BUILD files.** Third-party deps come from pyproject.toml:

```toml
# packages/attic/pyproject.toml
[project]
name = "attic"
dependencies = ["torch>=2.1", "numpy", "attic-rt"]

[project.optional-dependencies]
test = ["pytest>=7.0"]
```

The `deps` attribute in `roof_py_package` only lists first-party cross-package Bazel targets (so Bazel can build the dep graph for runfiles). These are maintained manually — they change rarely (new cross-package dependencies are infrequent). Third-party deps are never listed in BUILD files.

**Provider:**

```starlark
RoofPyPackageInfo = provider(fields = {
    "src_root",    # string: directory to add to PYTHONPATH (e.g., "packages/attic/src")
    "srcs",        # depset[File]: source files
    "pyproject",   # File: the pyproject.toml
    "wheel",       # File or None: the .whl file (built lazily)
    "first_party_deps",  # depset[RoofPyPackageInfo]: transitive first-party deps
})
```

This is deliberately simple. No `imports` depsets, no transitive source collection, no `.pth` generation. Just "here's where the source is" and "here are my neighbors."

**Version management:**

The pyproject.toml uses dynamic versioning:

```toml
[project]
dynamic = ["version"]

[tool.setuptools.dynamic]
version = {file = "VERSION"}
```

The VERSION file is copied into the package directory by the wheel build action. **`{file = "../../VERSION"}` does not work** — setuptools' `_assert_local()` rejects any path that escapes the package root (verified via prototype: `DistutilsOptionError: Cannot access ... (or anything outside ...)`). Instead, the `_roof_py_wheel_build` rule declares the repo-root VERSION file as an input, and the build action copies or symlinks it next to pyproject.toml before invoking `uv build`. pyproject.toml uses `{file = "VERSION"}` (local path, no escaping). The version comes from one source (the repo VERSION file), not from Starlark.

---

### roof_py_test

Replaces: `py_test` from `aspect_rules_py`, the Rust venv tool, `run.tmpl.sh`

```starlark
# packages/attic/tests/BUILD.bazel (Gazelle-generated)
roof_py_test(name = "test_compiler", srcs = ["test_compiler.py"], deps = ["//packages/attic"])
roof_py_test(name = "test_utils",    srcs = ["test_utils.py"],    deps = ["//packages/attic"])
roof_py_test(name = "test_ir",       srcs = ["test_ir.py"],       deps = ["//packages/attic"])
```

**API:** `name`, `srcs`, `deps`, `data`, `env`, `env_inherit`, `extras`, `timeout`, `tags`, `size`, `shard_count`, `main`, `main_module`, `interpreter_args`, `python_version`.

**Dep classification:**

The macro classifies each dep by its provider:

```
:attic                 -> RoofPyPackageInfo     -> source on PYTHONPATH
:attic.wheel           -> DefaultInfo (.whl)     -> wheel installed in venv
:roof-iree.wheel       -> DefaultInfo (.whl)     -> wheel installed in venv
```

- `RoofPyPackageInfo` target: source dep. Collect `src_root` for PYTHONPATH. Collect transitive first-party deps' `src_root` too.
- `.wheel` target: built wheel. Install into venv alongside third-party wheels.

Third-party wheels are not in `deps` at all. They come from pyproject.toml.

**Extras groups:**

`roof_py_test` automatically includes the `[test]` optional-dependencies group. Additional groups are specified via `extras`:

```starlark
# Default: includes [test] extras automatically
roof_py_test(name = "test_foo", srcs = [...], deps = [":attic"])

# GPU tests: includes [test] + [gpu] extras
roof_py_test(name = "test_gpu", srcs = [...], deps = [":attic"], extras = ["gpu"])
```

`roof_py_binary` includes no extras by default:

```starlark
# No extras
roof_py_binary(name = "serve", main = "serve.py", deps = [":attic"])

# Explicit extras
roof_py_binary(name = "serve_gpu", main = "serve.py", deps = [":attic"], extras = ["gpu"])
```

The install_venv.py action receives `--extras test gpu` and collects the union of deps from core `[project.dependencies]` + each requested `[project.optional-dependencies.<group>]`. Overlapping deps across groups are deduplicated by normalized name.

**Venv construction:**

The venv is the **union** of all deps' third-party requirements:

```starlark
roof_py_test(
    name = "test_e2e",
    srcs = ["test_e2e.py"],
    deps = [":attic", ":attic-rt"],
)

# Resulting environment:
#   PYTHONPATH = attic/src : attic-rt/src
#   venv = union(attic's pyproject.toml deps, attic-rt's pyproject.toml deps)
```

The `_roof_py_venv` rule receives all pyproject.toml files from the dep chain + all `.whl` files from `@pypi`. The `install_venv.py` action:

1. Parses each pyproject.toml with `tomllib` (Python 3.11+ stdlib)
2. Collects all dependency names + optional `[test]` extras
3. Matches names against pre-downloaded wheel filenames from `@pypi`
4. Installs only the matching wheels: `uv pip install --no-deps --no-index --link-mode=hardlink`

If a dep in pyproject.toml doesn't match any wheel, the action fails with: "package X required by pyproject.toml but not found in @pypi — add it to requirements.txt". This catches drift between pyproject.toml and the lock file.

**Venv deduplication:**

Tests with identical dep sets share one venv. The macro hashes the sorted set of pyproject.toml files + internal wheels to create a `_roof_venv_<hash>` target. Typical project: 5-10 unique venvs, not 50.

**conftest.py auto-collection:**

The macro auto-discovers `conftest.py` files by walking up from each test source file, mirroring pytest's own discovery behavior. Developers never need to manually add conftest.py to `data`.

Implementation: the macro uses `glob(["conftest.py", "tests/**/conftest.py"])` to collect conftest files from the package root and all test subdirectories. Source directory conftest.py files (e.g., `src/attic/conftest.py`) are correctly excluded because the glob is rooted at the package directory and scoped to `tests/`. Verified: nested conftest.py at package root, `tests/`, `tests/unit/`, and `tests/integration/` all load correctly, and sibling directories share parent conftest.py but not each other's.

---

### Test runner: pytest (opinionated default)

pytest is the default and only built-in test runner. The rules ship a thin Python entry point that bridges Bazel's env vars to pytest:

```python
# _roof_pytest_runner.py (~25 lines)
"""Bazel <-> pytest bridge. This is the entire test driver integration."""
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

    args.append("-v")

    import pytest
    sys.exit(pytest.main(args))

if __name__ == "__main__":
    main()
```

**Why pytest specifically:**

- De facto standard (~90%+ of Python projects)
- Runs unittest tests too (no migration needed for legacy tests)
- Filtering via `-k` maps directly to Bazel's `--test_filter`
- JUnit XML output for Bazel's test result parsing
- conftest.py fixture discovery is already how the ecosystem works

**Sharding without plugins:**

No `pytest-shard` dependency. The runner splits test files across Bazel shards directly:

- Shard 0 gets files 0, 4, 8, ...
- Shard 1 gets files 1, 5, 9, ...
- Each shard runs pytest on its subset

This works because Gazelle generates per-file test targets (one target per test file = Bazel-level parallelism). Sharding is only needed for glob targets with many files, where file-level splitting is sufficient.

**Escape hatch: custom entrypoint**

When pytest isn't the right runner, use `main` (file) or `main_module` (dotted module name):

```starlark
# File-based escape hatch — full control via a Python script
roof_py_test(
    name = "test_distributed",
    main = "tests/run_distributed.py",
    deps = [":attic"],
    tags = ["gpu", "exclusive"],
)

# Module-based escape hatch — the Pythonic way to run packages
# python -m sets __package__ correctly, enabling relative imports
roof_py_test(
    name = "test_distributed",
    main_module = "torch.distributed.run",
    deps = [":attic"],
    data = ["tests/test_distributed_impl.py"],
    tags = ["gpu", "exclusive"],
)
```

`main` and `main_module` are mutually exclusive. For `roof_py_binary`, one is required. For `roof_py_test`, both are optional (default: `_roof_pytest_runner.py`). `main_module` is preferred when running packages — it's how Python developers do it (`python -m pytest`, `python -m http.server`).

**Interpreter args**

Most Python interpreter flags have environment variable equivalents that work via the `env` attribute — Python's own interface:

```starlark
# Fail on deprecation warnings — via Python's own PYTHONWARNINGS env var
roof_py_test(
    name = "test_strict",
    srcs = ["tests/test_strict.py"],
    deps = [":attic"],
    env = {
        "PYTHONWARNINGS": "error::DeprecationWarning",
        "PYTHONDEVMODE": "1",
    },
)
```

For flags without env var equivalents (`-X frozen_modules=off`, `-X importtime`, `-X showrefcount`), use `interpreter_args`:

```starlark
# Profile import times — no env var equivalent for -X importtime
roof_py_test(
    name = "test_import_perf",
    srcs = ["tests/test_imports.py"],
    deps = [":attic"],
    interpreter_args = ["-X", "importtime"],
)
```

`interpreter_args` are inserted between the Python interpreter and the script/module in the exec line. When not set, no extra args are added.

---

### Test launcher

```bash
#!/usr/bin/env bash
# roof_run.tmpl.sh — environment setup only, no test driver logic

{{BASH_RLOCATION_FN}}
runfiles_export_envvars
set -o errexit -o nounset -o pipefail

# Toolchain Python (NOT the venv's bin/python3 — that symlink is broken,
# it points to the sandbox Python used during the build action).
PYTHON="$(rlocation {{PYTHON_TOOLCHAIN}})"

# Pre-built site-packages from runfiles
VENV_DIR="$(rlocation {{VENV_DIR}})"
SITE_PACKAGES="${VENV_DIR}/lib/python{{PYTHON_VERSION}}/site-packages"

# Console scripts on PATH (discoverable via shutil.which, shebangs are broken)
export PATH="${VENV_DIR}/bin:${PATH}"

# Import order: first-party before third-party (source shadows installed)
export PYTHONPATH="{{FIRST_PARTY_PYTHONPATH}}:${SITE_PACKAGES}"

# User env vars
{{PYTHON_ENV}}

# -B: no .pyc    -s: no user site-packages
hash -r 2>/dev/null
exec "${PYTHON}" -B -s {{INTERPRETER_ARGS}} {{EXEC_CMD}} "$@"
```

`{{EXEC_CMD}}` is composed by the Starlark rule based on which mode is active:

- **Default (pytest runner):** `"$(rlocation .../runner.py)" "$(rlocation test1.py)" "$(rlocation test2.py)"`
- **`main = file.py`:** `"$(rlocation .../file.py)"`
- **`main_module = "attic.serve"`:** `-m attic.serve`

`{{INTERPRETER_ARGS}}` is empty when `interpreter_args` is not set, or contains the user's flags (e.g., `-X importtime -W error`). The launcher does environment setup only — no test driver logic in bash.

**Why the venv's python symlink is broken and why it doesn't matter:**

`uv venv` creates `bin/python3` as a symlink to the Python used during the build action. In Bazel's sandbox, that's an ephemeral path. When the sandbox is torn down, the symlink breaks. The launcher uses the toolchain Python directly and sets `PYTHONPATH` to the venv's `site-packages`. The broken symlink exists but is never called.

Verified via prototype (macOS ARM, Python 3.11, APFS, torch 2.10 + numpy + pytest):

```
Test                                             Result   Notes
-----------------------------------------------  ------   ------------------------------------
torch import via PYTHONPATH (toolchain python)   Pass     __file__ points to site-packages
numpy import via PYTHONPATH                      Pass     real files, not symlinks
importlib.metadata.version("torch")              Pass     .dist-info found via sys.path search
importlib.metadata for source deps               Fail     expected — no .dist-info for PYTHONPATH deps
__file__ is real file (not symlink)              Pass     hardlinked from uv cache
First-party import via PYTHONPATH                Pass     PYTHONPATH order: first-party wins
First-party shadows third-party                  Pass     first entry on PYTHONPATH takes priority
Cross-import (first-party using third-party)     Pass     attic.compiler importing torch works
shutil.which() finds console scripts             Pass     venv/bin on PATH, shebangs broken
python -m pytest (recommended approach)          Pass     bypasses broken shebangs entirely
Namespace packages (simulated nvidia)            Pass     implicit namespace across MULTIPLE dirs
Broken venv bin/python3 symlink                  Pass     toolchain python ignores it completely
Symlinked TreeArtifact (Bazel runfiles)          Pass     imports work through symlink indirection
Copied TreeArtifact (remote execution sim)       Pass     imports work from full copy
End-to-end pytest (4 tests)                      Pass     first-party + third-party + metadata
```

**Namespace packages across PYTHONPATH entries:** Python's `_NamespacePath` automatically aggregates namespace packages split across multiple PYTHONPATH directories. A first-party `nvidia.custom` on one PYTHONPATH entry and third-party `nvidia.cudnn` on another both resolve correctly — `nvidia.__path__` contains both directories. This eliminates the need for the 935 lines of Rust recursive directory merging in aspect_rules_py.

---

### roof_py_binary

Same as `roof_py_test` but creates an executable instead of a test. Same launcher template, same dep classification, same venv sharing, same optional `python_version` pin, same `interpreter_args`. No pytest runner — `main` or `main_module` is required (one or the other).

```starlark
# File-based entry point
roof_py_binary(
    name = "serve",
    main = "src/attic/serve.py",
    deps = [":attic"],
)

# Module-based entry point (more Pythonic — sets __package__ correctly)
roof_py_binary(
    name = "serve",
    main_module = "attic.serve",
    deps = [":attic"],
)
```

---

### install_venv.py — build-time helper

```python
#!/usr/bin/env python3
"""Build-time action: parse pyproject.toml, install matching wheels via uv."""
import pathlib, subprocess, sys

# tomllib is stdlib in Python 3.11+; tomli is the backport for 3.9/3.10
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
pyproject_paths = sys.argv[5:]  # one or more pyproject.toml files
internal_wheels = []        # populated from --internal-wheels flag if present

# Parse flags from the positional args
first_party_packages = set()
extras_groups = []          # e.g., ["test", "gpu"]
remaining_pyprojects = []
i = 0
while i < len(pyproject_paths):
    if pyproject_paths[i] == "--first-party-packages":
        i += 1
        while i < len(pyproject_paths) and not pyproject_paths[i].startswith("-"):
            first_party_packages.add(pyproject_paths[i])
            i += 1
    elif pyproject_paths[i] == "--extras":
        i += 1
        while i < len(pyproject_paths) and not pyproject_paths[i].startswith("-"):
            extras_groups.append(pyproject_paths[i])
            i += 1
    else:
        remaining_pyprojects.append(pyproject_paths[i])
        i += 1
pyproject_paths = remaining_pyprojects

def normalize(name):
    return name.lower().replace("-", "_").replace(".", "_")

def extract_dep_name(dep_spec):
    """Extract package name from a PEP 508 dependency specifier."""
    for ch in "><=!;[":
        dep_spec = dep_spec.split(ch)[0]
    return dep_spec.strip()

# Collect dep names from all pyproject.toml files
needed = set()
current_python = f"{sys.version_info.major}.{sys.version_info.minor}"
for pp_path in pyproject_paths:
    pp = tomllib.loads(pathlib.Path(pp_path).read_text())
    # Validate requires-python constraint
    requires_python = pp.get("project", {}).get("requires-python")
    if requires_python:
        # Simple >=X.Y check (covers the common case)
        if requires_python.startswith(">="):
            min_ver = requires_python[2:].strip()
            if tuple(int(x) for x in current_python.split(".")) < tuple(int(x) for x in min_ver.split(".")):
                print(f'ERROR: {pp_path} requires python {requires_python}, '
                      f'but building with {current_python}', file=sys.stderr)
                sys.exit(1)
    for dep in pp.get("project", {}).get("dependencies", []):
        needed.add(normalize(extract_dep_name(dep)))
    # Include deps from each requested extras group
    opt_deps = pp.get("project", {}).get("optional-dependencies", {})
    for group in extras_groups:
        for dep in opt_deps.get(group, []):
            needed.add(normalize(extract_dep_name(dep)))

# Build wheel index from pre-downloaded wheels
wheel_index = {}
for whl in pathlib.Path(wheel_dir).glob("*.whl"):
    wheel_index[normalize(whl.name.split("-")[0])] = whl

# Normalize first-party names
fp_normalized = {normalize(n) for n in first_party_packages}

# Three-way classification: match wheel, match first-party, or fail
wheels_to_install = list(internal_wheels)  # .wheel targets from deps
missing = []
for dep_name in sorted(needed):
    if dep_name in wheel_index:
        wheels_to_install.append(str(wheel_index[dep_name]))
    elif dep_name in fp_normalized:
        pass  # handled via PYTHONPATH, not installed in venv
    else:
        missing.append(dep_name)

if missing:
    for m in missing:
        print(f'ERROR: package "{m}" required by pyproject.toml but not found '
              f'in @pypi wheels and not a first-party dep.', file=sys.stderr)
        print(f'       Add it to requirements.txt or to deps = [...] in BUILD.', file=sys.stderr)
    sys.exit(1)

# Create venv and install (no --seed: skip pip/setuptools, saves ~2000 files)
subprocess.check_call([uv, "venv", venv_dir, "--python", python])
if wheels_to_install:
    subprocess.check_call([
        uv, "pip", "install",
        "--python", f"{venv_dir}/bin/python3",
        "--no-deps",            # don't resolve transitive — requirements.txt has the closure
        "--no-index",           # don't contact PyPI — only use pre-downloaded wheels
        "--link-mode=hardlink", # zero disk overhead — REQUIRES same filesystem as UV_CACHE_DIR
    ] + wheels_to_install)

    # Verify hardlinks actually worked. uv silently falls back to full copies
    # when the cache and venv are on different filesystems — no error, no warning,
    # just 7+ GB of duplicated .so files per venv. Fail fast with an actionable error.
    site_packages = pathlib.Path(venv_dir)
    for sp in site_packages.glob("lib/python*/site-packages"):
        for f in sp.iterdir():
            if f.is_file():
                import os as _os
                if _os.stat(str(f)).st_nlink < 2:
                    uv_cache = _os.environ.get("UV_CACHE_DIR", "~/.cache/uv")
                    print(
                        f"ERROR: hardlinks not working — files have nlink=1.\n"
                        f"  UV_CACHE_DIR ({uv_cache}) and venv output ({venv_dir})\n"
                        f"  are likely on different filesystems.\n"
                        f"  Fix: set sandbox_writable_path in .bazelrc to a path on\n"
                        f"  the same filesystem as Bazel's output base.",
                        file=sys.stderr,
                    )
                    sys.exit(1)
                break  # one file is enough to verify
            break
```

**Critical: `--no-deps` requires the full transitive closure.** The wheel directory from `@pypi` must contain ALL transitive dependencies, not just the top-level names from pyproject.toml. For example, pyproject.toml lists `pytest`, but `--no-deps` means uv won't pull in `pluggy`, `iniconfig`, or `pygments`. This is correct by design: `pip.parse()` downloads the full closure from requirements.txt, so `wheel_dir` already contains every transitive dep. The name-matching loop picks up transitive deps because they appear as wheel files in the directory. Verified via prototype: installing `torch + numpy + pytest` with `--no-deps` from a complete wheel directory succeeds; installing from an incomplete set fails with clear import errors at test time (e.g., `ModuleNotFoundError: No module named 'pluggy'`).

---

### Granularity and test discovery: no Gazelle

With third-party deps in pyproject.toml and per-directory `py_library` eliminated, Gazelle has nothing meaningful left to generate. A glob + list comprehension gives per-file test targets without any code generation tooling:

```starlark
# packages/attic/BUILD.bazel — the ENTIRE build file, no Gazelle
load("@roof//python:defs.bzl", "roof_py_package", "roof_py_test")

roof_py_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],  # first-party only, changes ~monthly
)

# One test target per file — glob handles discovery
[roof_py_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(["tests/test_*.py"])]
```

Add a test file, glob picks it up. Add a third-party dep, edit pyproject.toml. Add a cross-package dep, add one line to `deps`. No `bazel run //:gazelle`. No generated code.

Each test is an independent Bazel target. Bazel runs them in parallel. Change one test file, only that test reruns. No sharding needed.

Tests that need special configuration are pulled out of the comprehension:

```starlark
# Most tests — auto-discovered
[roof_py_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(
    ["tests/test_*.py"],
    exclude = ["tests/test_distributed.py"],
)]

# Special case — custom runner, GPU tags
roof_py_test(
    name = "test_distributed",
    main = "tests/run_distributed.py",
    deps = [":attic"],
    tags = ["gpu", "exclusive"],
)
```

For a single-target convenience with sharding:

```starlark
roof_py_test(
    name = "tests",
    srcs = glob(["tests/test_*.py"]),
    deps = [":attic"],
    shard_count = 4,
)
```

File load balancing is the developer's responsibility: if a test file is too big, split it. That's the Python solution, not a build system problem.

---

### Dev environment

The dev environment story simplifies too. Today, `create_devenv.py` builds a venv by globbing for wheels in runfiles. With `roof_py_package`, each package has a real `pyproject.toml`. The dev environment is:

```bash
# Create a dev venv — standard Python workflow
uv venv .venv --python python3.11
uv pip install -e packages/attic -e packages/attic-rt -e packages/roofbench-v3
uv pip install -r build_tools/external_requirements.arm64-Darwin.txt
```

No Bazel involved. No symlinks from bazel-bin. The pyproject.toml files are in the source tree where they belong. `uv pip install -e .` does an editable install that points at the source directly. IDE integration, pytest discovery, mypy — they all just work because the project structure is standard Python.

For packages that depend on compiled artifacts (IREE bindings), the editable install can reference a Bazel-built wheel:

```bash
uv pip install bazel-bin/packages/roof-iree/compiler/compiler_wheel.whl
```

---

### CI/CD

Wheel building in CI:

```bash
# Build all wheels
bazel build //packages/attic:attic.wheel //packages/attic-rt:attic_rt.wheel ...
# Or via a target group
bazel build //packages:all_wheels
```

Testing:

```bash
bazel test //packages/...
```

Publishing:

```bash
# Wheels are standard .whl files, publish directly
twine upload bazel-bin/packages/*/dist/*.whl
```

---

### Coverage

The `_roof_py_test_rule` provides `InstrumentedFilesInfo` for Bazel's coverage integration. Source files from first-party deps are listed as instrumented. The `_lcov_merger` attribute is included for `--combined_report` support. Coverage runs via `bazel coverage //packages/...`.

### Linting and type checking

With real `pyproject.toml` files, tool configuration lives where tools expect it:

```toml
# packages/attic/pyproject.toml
[tool.mypy]
strict = true
python_version = "3.11"

[tool.ruff]
line-length = 100
```

Linting can run outside Bazel (`ruff check packages/attic/`) or inside it (via a `roof_py_lint` rule that runs ruff/mypy against source roots). Either way, the configuration is in pyproject.toml, not in a Bazel-specific format.

---

## Multi-version Python

### The tox model

The Pythonic approach to multi-version testing is tox/nox: same code, different interpreter, the system figures out the right wheels. roof_py follows this model: **BUILD files don't change. You tell Bazel which Python to use, and everything flows from that.**

```bash
# Default (3.12)
bazel test //packages/...

# Run against 3.11
bazel test //packages/... --@roof//python:version=3.11
```

CI is two lines in a matrix:

```yaml
strategy:
  matrix:
    python: ["3.11", "3.12"]
steps:
  - run: bazel test //... --@roof//python:version=${{ matrix.python }}
```

No BUILD file changes. No Starlark attributes. The mental model is: "same code, different Python."

### What changes per version

```
Python version (flag)
  ├── Which interpreter to exec          → toolchain resolution (already works)
  ├── Which wheels to install             → which pip.parse hub to read from
  └── site-packages path                  → lib/python3.XX/site-packages
```

What does NOT change:

- Source code (same .py files)
- pyproject.toml (same deps, same metadata)
- BUILD files (same targets)
- PYTHONPATH first-party entries (same source roots)

### Setup: MODULE.bazel

Version registration happens once, in MODULE.bazel — the only place the developer thinks about versions:

```starlark
# Toolchains — standard rules_python, register each version
python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.11")
python.toolchain(python_version = "3.12", is_default = True)

# Per-version wheel sets — standard pip.parse, one call per version
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")
pip.parse(
    hub_name = "pypi",
    python_version = "3.11",
    requirements_lock = "//build_tools:requirements.3.11.txt",
)
pip.parse(
    hub_name = "pypi",
    python_version = "3.12",
    requirements_lock = "//build_tools:requirements.3.12.txt",
)
use_repo(pip, "pypi")

# roof_py — just declare the default
roof = use_extension("@roof//python:extensions.bzl", "roof_py")
roof.configure(default_python_version = "3.12")
```

`pip.parse()` already supports multiple `python_version` calls with the same `hub_name` — it creates version-aware hub repos that resolve based on the active Python version. roof_py rides this existing mechanism.

### Mechanism: one flag, everything follows

The module extension generates a `string_flag` and version-aware aliases:

```starlark
# Generated by roof_py module extension in @roof//python:BUILD.bazel
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

string_flag(
    name = "version",
    build_setting_default = "3.12",  # from roof.configure()
    values = ["3.11", "3.12"],       # from registered python.toolchain() calls
)

config_setting(
    name = "is_3.11",
    flag_values = {":version": "3.11"},
)

config_setting(
    name = "is_3.12",
    flag_values = {":version": "3.12"},
)
```

```starlark
# Generated version-aware wheel alias in @roof_pypi//:BUILD.bazel
alias(
    name = "all_whl_files",
    actual = select({
        "@roof//python:is_3.11": "@pypi_311//:all_whl_files",
        "@roof//python:is_3.12": "@pypi_312//:all_whl_files",
    }),
)
```

The venv rule references `@roof_pypi//:all_whl_files` and gets the right wheels for the active Python version. **No version logic in the venv rule, the macros, or install_venv.py.** The version flows through Bazel's existing mechanisms: toolchain resolution picks the interpreter, `select()` picks the wheels.

### Per-target version pinning (migration)

During a Python version migration, individual targets can be pinned:

```starlark
# This target uses match/case — requires 3.12
roof_py_test(
    name = "test_new_syntax",
    srcs = ["tests/test_new_syntax.py"],
    deps = [":attic"],
    python_version = "3.12",  # overrides the global flag
)
```

Under the hood, this applies a transition that sets `--@roof//python:version=3.12` for this target's subgraph:

```starlark
def _python_version_transition_impl(settings, attr):
    if attr.python_version:
        return {"@roof//python:version": attr.python_version}
    return {}

_python_version_transition = transition(
    implementation = _python_version_transition_impl,
    inputs = [],
    outputs = ["@roof//python:version"],
)
```

This is the only transition in the system. It fires only when `python_version` is explicitly set on a target — no analysis blowup, no hidden graph forking.

### requires-python validation

`install_venv.py` validates the Python version against pyproject.toml's `requires-python`:

```python
requires_python = pp.get("project", {}).get("requires-python")
if requires_python:
    current = f"{sys.version_info.major}.{sys.version_info.minor}"
    if not version_satisfies(current, requires_python):
        print(f'ERROR: {pp_path} requires python {requires_python}, '
              f'but building with {current}', file=sys.stderr)
        sys.exit(1)
```

`bazel test //... --@roof//python:version=3.10` fails immediately with "attic requires Python >=3.11, but building with 3.10" — not a cryptic import error 5 minutes into the build. The version constraint lives in pyproject.toml, where every Python developer expects it.

### Three levels of adoption

**Level 1: "I don't care" (most teams).** Register one Python version. Don't set the flag. Everything works exactly as described in the rest of this RFC. Zero overhead, zero complexity.

**Level 2: "Test against two versions in CI" (tox model).** Register two versions in MODULE.bazel. CI matrix runs `--@roof//python:version=X` twice. BUILD files unchanged. Same mental model as tox.

**Level 3: "Migrating 3.11 → 3.12 target-by-target" (monorepo migration).** Default is 3.11. Add `python_version = "3.12"` to individual targets as they're ready. Eventually flip the default. Remove the per-target pins. Done.

Each level is a strict superset. You opt into complexity only when you need it.

### Implementation cost

| Component                                  | Lines added |
| ------------------------------------------ | ----------- |
| Module extension (flag + aliases)          | ~20         |
| Transition function                        | ~10         |
| `requires-python` check in install_venv.py | ~5          |
| **Total**                                  | **~35**     |

The venv rule, the launcher template, and the core macros require zero changes — the version flows through existing Bazel mechanisms.

---

## Caching strategy

### Three layers

**Layer 1: uv extraction cache (within a build job)**

`uv pip install` extracts wheels into its internal cache, then hardlinks from cache to `site-packages/`. Shared across Bazel actions via `sandbox_writable_path` pointing to a path **on the same filesystem as Bazel's output base** (e.g., `$HOME/.cache/roof-uv` — NOT `/tmp`, which is often a separate tmpfs/overlay mount in containers).

If venv A needs {torch, numpy, pytest} and venv B needs {torch, numpy, scipy}, torch+numpy are extracted once. Venv B's creation is near-instant for overlapping packages.

**Layer 2: Bazel action cache (across builds)**

The `_roof_py_venv` rule produces a TreeArtifact. Cache key = `pyproject.toml content` + `all wheel files from @pypi`. Conservative but correct: any wheel change invalidates all venvs. Rebuilds are fast (uv cache + hardlinks).

**Layer 3: Bazel remote cache (across machines)**

TreeArtifacts are uploaded as Merkle trees. On cache hit, the action is skipped entirely.

### Hardlinks

`uv pip install --link-mode=hardlink` creates hardlinks from the uv cache to `site-packages/`. Same inode, zero disk overhead. `os.path.dirname(__file__)` returns the venv path — the file IS there.

**Critical: the uv cache and the venv output MUST be on the same filesystem.** Hardlinks cannot cross filesystem/device boundaries. If they're on different devices, uv silently falls back to full copies — no error, no warning, just 7.42 GB per venv instead of ~0. `install_venv.py` verifies hardlinks actually worked after install and fails with an actionable error if they didn't.

**Verified via experiment (Linux ext4 + overlay, uv 0.10.3):**

| Scenario                              | Same device? | Hardlink ratio | Verdict                 |
| ------------------------------------- | ------------ | -------------- | ----------------------- |
| Cache + venv both on ext4             | YES          | 99%            | Hardlinks working       |
| Cache on ext4, venv on overlay `/tmp` | NO           | 0%             | Silent fallback to copy |
| Cache + venv both on overlay `/tmp`   | YES          | 99%            | Hardlinks working       |
| Cache on overlay, venv on ext4        | NO           | 0%             | Silent fallback to copy |

Hardlinks work if and only if cache and venv are on the same device. The common container pitfall: `/tmp` is often tmpfs or overlay (a separate mount), while the workspace/home dir is ext4. Setting `UV_CACHE_DIR=/tmp/...` breaks dedup silently.

**Cross-venv deduplication (verified, 3 identical venvs on same fs):**

| Venv                      | Install time | nlink | Disk (per `du`) | Actual additional cost          |
| ------------------------- | ------------ | ----- | --------------- | ------------------------------- |
| Venv 1 (cold cache)       | 0.15s        | 2     | 0.22 GB         | 0.22 GB (real data)             |
| Venv 2 (warm cache)       | 0.06s        | 3     | 0.22 GB\*       | ~0 (hardlinks to same inodes)   |
| Venv 3 (warm cache)       | 0.06s        | 4     | 0.22 GB\*       | ~0 (hardlinks to same inodes)   |
| **Total (all 3 + cache)** |              |       | **0.28 GB**     | **60% less than 3 full copies** |

\* `du` reports apparent size per subtree; total `du` on the parent counts each inode once, showing true savings.

With CUDA torch at 7.42 GB per venv, this is the difference between 5 venvs costing ~7.5 GB total vs ~37 GB.

**macOS APFS note:** On APFS, copy mode is faster than hardlink mode (2.0s vs 3.5s) because APFS copies are copy-on-write (zero actual data copying). Both modes show identical on-disk size because APFS deduplicates at the block level. Either mode works on macOS; hardlink mode is essential on Linux.

### Rebuild cost (measured)

| Change                       | What rebuilds                           | macOS (CPU torch) | Linux (CUDA torch)   |
| ---------------------------- | --------------------------------------- | ----------------- | -------------------- |
| Edit first-party source      | Nothing (PYTHONPATH points to runfiles) | 0s                | 0s                   |
| Change @pypi dep version     | All venv TreeArtifacts                  | ~3.5s per venv    | ~1.7s per venv       |
| Change internal wheel source | Internal wheel + its venv TreeArtifact  | ~1-2s             | ~1-2s                |
| Clean build (no uv cache)    | Everything                              | ~46s              | ~17s (download only) |
| Cached build (no changes)    | Nothing                                 | 0s                | 0s                   |
| Venv creation (uv venv only) | N/A                                     | 28ms              | 25ms                 |

---

## The nvidia sibling problem (and why it disappears)

The problem: `nvidia-cudnn-cu12` and `nvidia-cublas-cu12` are separate PyPI packages that both install files under `nvidia/`. When Bazel downloads them into separate repos (`@pypi//nvidia_cudnn_cu12`, `@pypi//nvidia_cublas_cu12`), each has its own `nvidia/` directory. The current system creates symlinks from individual packages into a shared venv, requiring a recursive directory merge algorithm to make `nvidia.cudnn` and `nvidia.cublas` both importable.

With `uv pip install` into a single flat `site-packages/`, this problem doesn't exist. `nvidia/cudnn/` and `nvidia/cublas/` end up as sibling directories under one `nvidia/` package. Python's implicit namespace package mechanism handles the rest. No merge algorithm. No collision detection. No special handling.

**Verified via prototype — including the harder cross-directory case:**

The prototype tested namespace packages split across _multiple_ PYTHONPATH entries (first-party `nvidia.custom` on one path, third-party `nvidia.cudnn` + `nvidia.cublas` on another). All imports succeed. Python's `_NamespacePath` automatically aggregates:

```python
>>> nvidia.__path__
_NamespacePath([
    '/first_party/nvidia',         # first-party source root
    '/site-packages/nvidia',       # third-party venv
])
>>> import nvidia.custom     # from first-party
>>> import nvidia.cudnn      # from third-party
>>> import nvidia.cublas     # from third-party — all coexist
```

No `__init__.py` needed in the `nvidia/` root directory. This is standard PEP 420 implicit namespace package behavior — it has worked since Python 3.3. The 935 lines of Rust in aspect_rules_py's `venv.rs` + `pth.rs` exist because the old architecture split packages into separate repos and then tried to reassemble them. With flat `site-packages`, the problem doesn't arise. With PYTHONPATH-based source roots, the cross-directory case is handled natively.

---

## The sandbox at test time

When Bazel runs a test, the runfiles tree looks like:

```
$RUNFILES_DIR/
  _main/
    packages/attic/
      src/attic/                                  # first-party source (symlinks)
        __init__.py -> /src/packages/attic/...
        compiler/
          __init__.py -> ...
          ir.py -> ...
      tests/
        test_compiler.py -> ...                   # test file
        conftest.py -> ...                        # auto-collected by macro
    packages/attic-rt/
      src/attic_rt/                               # transitive first-party dep
        __init__.py -> ...
    _roof_venv_a1b2c3/                            # TreeArtifact (built at build time)
      bin/
        python3 -> (broken, never called)
        pytest -> (shebang broken, discoverable via shutil.which)
      lib/python3.11/site-packages/
        torch/...                                 # real files, hardlinked from uv cache
        numpy/...
        pytest/...
        nvidia/cudnn/...                          # namespace packages just work
        nvidia/cublas/...
        *.dist-info/                              # metadata works
      pyvenv.cfg
    tools/python/python3.11 -> ...                # toolchain interpreter
    _roof_pytest_runner.py -> ...                  # test entry point
    packages/attic/tests/_roof_test_compiler.sh   # launcher script
```

Build actions that produce this:

```
Action 1: _roof_py_venv (cached across tests with same deps)
  Inputs:  all .whl files from @pypi + pyproject.toml files from deps
  Tool:    uv + python (from toolchains)
  Output:  TreeArtifact(_roof_venv_a1b2c3/)
  Script:  install_venv.py

Action 2: launcher generation (string substitution, trivial)
  Inputs:  roof_run.tmpl.sh + resolved paths
  Output:  _roof_test_compiler.sh

Source files are symlinked directly — no action needed.
```

---

## Comparison with existing approaches

### vs. aspect_rules_py (current)

| Aspect                    | aspect_rules_py                       | roof_py                              |
| ------------------------- | ------------------------------------- | ------------------------------------ |
| Venv creation             | Runtime, per test, ~87ms              | Build time, cached, 0ms at test time |
| Import mechanism          | .pth files with ../../../../ escaping | PYTHONPATH                           |
| Namespace packages        | Rust recursive merge algorithm        | Just works (flat site-packages)      |
| Package installation      | Rust symlink/copy tool                | uv pip install --link-mode=hardlink  |
| Package metadata          | Starlark -> JSON -> TOML -> symlink   | Hand-written pyproject.toml          |
| Third-party deps in BUILD | `deps = ["@pypi//torch"]` per target  | Not in BUILD files (pyproject.toml)  |
| Test runner               | User's problem                        | pytest (opinionated default)         |
| Custom tooling            | ~1700 lines Rust + fork               | ~80 lines Python                     |
| Maintenance               | Fork of upstream, rebases required    | No fork, no upstream dependency      |

### vs. stock rules_python

| Aspect               | rules_python                        | roof_py                                    |
| -------------------- | ----------------------------------- | ------------------------------------------ |
| Third-party packages | py_library wrappers with PyInfo     | Wheel files, installed by uv               |
| Third-party deps     | `@pypi//` in BUILD files            | pyproject.toml only                        |
| Import config        | PyInfo.imports depsets              | PYTHONPATH                                 |
| .dist-info           | Not available                       | Available (real installation)              |
| Namespace packages   | Broken (separate repos)             | Works (flat site-packages)                 |
| Multi-version Python | `python_version` attr + transitions | `--@roof//python:version` flag (tox model) |
| Dev environment      | Separate tooling needed             | Standard uv workflow                       |

### vs. Pants

| Aspect           | Pants                    | roof_py                        |
| ---------------- | ------------------------ | ------------------------------ |
| Python support   | First-class, Pythonic    | Bolt-on to Bazel, but Pythonic |
| C++/MLIR support | Limited                  | Full (Bazel native)            |
| Migration cost   | Multi-quarter, high risk | Incremental, per-phase         |
| Lock file        | Native support           | Per-platform requirements.txt  |

---

## Migration roadmap

### Migration strategy: mutual exclusion

The old rules (rules_python `py_library` / aspect_rules_py `py_test`) and the new rules (`roof_py_package` / `roof_py_test`) do **not interoperate**. They use fundamentally different mechanisms (PyInfo providers vs PYTHONPATH, @pypi// labels vs pyproject.toml, runfiles symlink forests vs flat site-packages). Bridging these would create the hardest-to-debug part of the system — the exact opposite of the goal.

Instead, a Bazel `constraint_setting` makes the two worlds mutually exclusive:

```starlark
# //build_tools/python:constraints.bzl
constraint_setting(name = "python_rules")
constraint_value(name = "legacy", constraint_setting = ":python_rules")
constraint_value(name = "roof",   constraint_setting = ":python_rules")
```

Each target declares which world it belongs to via `target_compatible_with`. Build with one platform or the other — never both in the same invocation:

```bash
bazel test //packages/... --platforms=//config:dev_roof    # new world only
bazel test //packages/... --platforms=//config:dev_legacy   # old world only
```

During migration, both targets coexist in the same BUILD file:

```starlark
# Legacy — skipped when building with roof platform
py_library(
    name = "attic_legacy",
    target_compatible_with = ["//build_tools/python:legacy"],
    ...
)

# New — skipped when building with legacy platform
roof_py_package(
    name = "attic",
    target_compatible_with = ["//build_tools/python:roof"],
    pyproject = "pyproject.toml",
    ...
)
```

CI runs both platforms until migration is complete. No hybrid state ever exists in a single build invocation. Adding `target_compatible_with` to existing targets can be done with `buildozer` across the repo in a single pass.

**This forces bottom-up migration:** a `roof_py_test` cannot depend on a legacy `py_library`. Leaf packages (no first-party deps) migrate first, then their dependents. Each phase is independently testable by running the roof platform in CI.

### Phase 0: Constraint mechanism + one leaf package

**Goal:** Prove the full architecture: constraint mechanism, PYTHONPATH + cached venv, pytest integration.

- Create `constraint_setting` and platform definitions
- Create `roof_py.bzl`, `install_venv.py`, `_roof_pytest_runner.py`, `roof_run.tmpl.sh`
- Add `rules_uv` to MODULE.bazel
- Add `sandbox_writable_path` to .bazelrc (must be on same filesystem as output base — NOT `/tmp`)
- Add `target_compatible_with = ["//build_tools/python:legacy"]` to all existing Python targets (via buildozer)
- Migrate one leaf package + its tests to roof_py
- CI runs both platforms; verify both pass independently

**Deliverables:** Constraint mechanism, 4 new roof_py files, 1 migrated package. Both worlds working in CI.

### Phase 1: Leaf packages + test migration

**Goal:** All packages with no first-party deps migrated to roof_py.

- Migrate leaf packages: create `roof_py_package` + `roof_py_test` targets alongside legacy targets
- Write hand-written pyproject.toml for each migrated package
- Convert test macros (attic_test, attic_rt_test, etc.) to roof_py versions
- Grep for `subprocess.run(["pytest"` / `subprocess.run(["torchrun"` — convert to `main` escape hatch
- Add `roof_py_binary` (same approach, binary instead of test)
- Benchmark: compare aggregate test time between legacy and roof platforms

**Deliverables:** Leaf packages dual-targeting. Test time comparison data.

### Phase 2: Mid-tier and top-level packages

**Goal:** All packages migrated. Legacy platform passes but is no longer developed against.

- Migrate mid-tier packages (depend on already-migrated leaves)
- Migrate top-level packages (integration tests, binaries, benchmarks)
- Remove all `@pypi//` references from BUILD files — deps come from pyproject.toml
- Remove `generate_pyproject_toml.py`, `link_pyproject_tomls.py`, `wheel_helper.bzl`
- Convert BUILD files to glob + list comprehension pattern for test discovery
- Update dev environment scripts to use the new pyproject.toml files directly

**Deliverables:** All packages on roof platform. Legacy platform still passes but is vestigial.

### Phase 3: Delete legacy

**Goal:** Remove all legacy infrastructure. Single platform.

- Remove legacy `py_library`, `py_test`, `py_wheel_with_info`, `pycross_wheel_library` targets
- Remove `target_compatible_with` from all roof_py targets (no longer needed)
- Remove `constraint_setting` and platform definitions
- Remove `local_path_override` for `aspect_rules_py` from MODULE.bazel
- Remove `third-party/aspect_rules_py` git submodule
- Remove Rust toolchain registrations
- Remove `rules_pycross` dependency
- Remove Gazelle Python configuration
- Remove `create_devenv.py` (replaced by standard `uv pip install -e .` workflow)
- Update CI scripts to single platform

**Deliverables:** ~7000 lines of Starlark/Rust/Python removed. No fork. No custom toolchains. No constraint mechanism overhead.

---

## Risk analysis

| Risk                                         | Severity       | Status                            | Mitigation                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------- | -------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TreeArtifact at CUDA scale                   | Low            | **Verified (macOS + Linux)**      | macOS: 16K files / 431MB. Linux CUDA: 18K files / 7.42 GB. File count grew modestly (18K, not the feared 50-100K); byte size driven by nvidia `.so` files. All operations well within thresholds: install 4.3s, copy 3.7s, tar+zstd 4.8s, rebuild 1.7s. Split-venv not needed.                                                                                                                                                      |
| TreeArtifact copy for remote execution       | Low            | **Verified**                      | Full copy: 3.72s for 18K files / 7.42 GB on Linux overlay fs. Symlink (local execution): 0.04ms. Well within the < 10s threshold. Bazel action cache avoids re-runs.                                                                                                                                                                                                                                                                |
| Remote cache TreeArtifact size               | Low            | **Measured**                      | Zstd-compressed: 3.47 GB (2.1:1 ratio). Operations < 6s. Venvs shared (~5-10 unique) and change rarely. Storage cost bounded. Bazel Merkle-tree deduplication may help further. Monitor but no action needed.                                                                                                                                                                                                                       |
| Console script shebangs broken               | Low            | Verified                          | Shebangs point to sandbox python (broken). `shutil.which()` finds them, `python -m <module>` bypasses shebangs entirely. This is the recommended approach.                                                                                                                                                                                                                                                                          |
| Conservative cache key (all wheels)          | Low            | **Verified**                      | Rebuild with warm uv cache: 1.7s per venv on Linux CUDA (3.5s on macOS). Wheels change rarely. Conservative key is fine.                                                                                                                                                                                                                                                                                                            |
| Hardlink cross-device silent fallback        | Medium         | **Verified + mitigated**          | uv silently falls back to full copies when cache and venv are on different filesystems — no error, just 7+ GB wasted per venv. Common in containers where `/tmp` is tmpfs/overlay. Fix: (1) `UV_CACHE_DIR` must be on same fs as output base (NOT `/tmp`), (2) `install_venv.py` verifies `nlink > 1` after install and fails with actionable error if hardlinks didn't work. Verified: same-device = 99% dedup, cross-device = 0%. |
| nvidia namespace at CUDA scale               | **Eliminated** | **Verified**                      | All 10 nvidia CUDA subpackages (cudnn, cublas, cuda_runtime, cuda_nvrtc, nvjitlink, cufft, cusparse, cusolver, nccl, nvtx) import correctly from flat site-packages. No `LD_LIBRARY_PATH`, no `__init__.py`, no merge logic needed.                                                                                                                                                                                                 |
| LD_LIBRARY_PATH for CUDA torch               | **Eliminated** | **Verified**                      | torch 2.10.0+cu128 imports fine without `LD_LIBRARY_PATH` set. torch finds its 11 `.so` files via `__file__` relative paths. No launcher template change needed.                                                                                                                                                                                                                                                                    |
| `sys.prefix` wrong (toolchain, not venv)     | Low            | Verified                          | `sys.prefix` points to toolchain, not venv. `importlib.metadata` works anyway (finds `.dist-info` via `sys.path`). No ML/test package relies on `sys.prefix`.                                                                                                                                                                                                                                                                       |
| `importlib.metadata` for source deps         | Low            | Confirmed                         | `importlib.metadata.version("attic")` raises `PackageNotFoundError` for first-party source deps (no `.dist-info`). Only matters if code introspects its own version at runtime. Editable install in venv build action can fix this if needed.                                                                                                                                                                                       |
| pyproject.toml drift from requirements.txt   | Low            | Verified                          | install_venv.py uses three-way classification: matches wheel, matches first-party, or fails with actionable error. Catches genuine missing deps while correctly skipping first-party packages.                                                                                                                                                                                                                                      |
| `--no-deps` requires full transitive closure | Low            | Confirmed                         | install_venv.py must receive ALL transitive deps from requirements.txt, not just top-level names from pyproject.toml. Matching against the full wheel set from `@pypi` handles this (the wheel set IS the closure).                                                                                                                                                                                                                 |
| PYTHONPATH scaling with many entries         | Low            | **Measured**                      | 10 entries = 200us/import, 50 entries = 800us. Real projects have 5-10 roots. Sub-millisecond per import. No action needed.                                                                                                                                                                                                                                                                                                         |
| `.pth` files not processed via PYTHONPATH    | **Eliminated** | Verified                          | Editable install `.pth` files are NOT processed when site-packages is on PYTHONPATH (only `site.addsitedir()` triggers `.pth` processing). This is correct and expected — first-party sources are on PYTHONPATH directly.                                                                                                                                                                                                           |
| Build-time Python < 3.11 (no tomllib)        | Low            | **Addressed**                     | install_venv.py includes `try: import tomllib; except: import tomli as tomllib` fallback. For Python 3.11+ (all active versions), no external dependency needed.                                                                                                                                                                                                                                                                    |
| System site-packages leakage                 | Low            | Verified                          | `-s` flag disables user site-packages. Toolchain stdlib site-packages (pip/setuptools) remains on sys.path but at lower priority. rules_python's hermetic interpreter has minimal site-packages.                                                                                                                                                                                                                                    |
| Namespace packages                           | **Eliminated** | **Verified (macOS + Linux CUDA)** | Works natively in flat site-packages on both platforms. All 10 nvidia CUDA namespace subpackages import correctly. Also verified across multiple PYTHONPATH directories. Zero code needed.                                                                                                                                                                                                                                          |
| Wheel build in sandbox                       | Low            | Verified                          | `uv build --wheel` follows symlinks, works with `--no-build-isolation`, produces correct wheels (0.42s). Setuptools must be pre-provided as a Bazel dep.                                                                                                                                                                                                                                                                            |
| VERSION file escaping                        | Medium         | **Resolved**                      | `{file = "../../VERSION"}` blocked by setuptools `_assert_local()`. Fix: copy VERSION into package dir as declared Bazel input; use `{file = "VERSION"}` (local).                                                                                                                                                                                                                                                                   |
| Platform-specific wheel selection            | **Eliminated** | Verified                          | uv automatically filters by platform in `--no-index --find-links` mode, even for direct `.whl` paths. No Starlark `select()` needed.                                                                                                                                                                                                                                                                                                |
| First-party deps in install_venv.py          | Low            | Verified                          | Three-way classification (wheel / first-party / missing) catches real errors while correctly skipping first-party packages.                                                                                                                                                                                                                                                                                                         |

---

## Resolved questions

1. **Compiled extensions (roof-iree/compiler).** No special Python-level handling needed. `roof_py_package` accepts compiled artifacts via the standard `data` attribute — `.so` files are just files that end up in runfiles at the right relative paths. Python's import system loads them from PYTHONPATH. The assembly challenge (95+ `copy_file` rules) is general infrastructure solved by `copy_to_directory` or a custom `merge_trees` rule. See "Appendix: assembling packages with compiled artifacts."

2. **Exact cache keys (future optimization).** If the conservative cache key (all wheels) causes excessive rebuilds, a module extension with auto-discovery can parse pyproject.toml files and generate exact dep mappings. A Starlark TOML parser (~50 lines) makes this possible without external tools. Deferred until benchmarking shows it's needed.

3. **Collecting all wheels from `@pypi`.** `pip.parse()` already generates `all_whl_requirements` in `@pypi//:requirements.bzl` — a list of all `@pypi//<pkg>:whl` labels. Already used by `create_devenv` and root BUILD. Wrap in a filegroup or pass directly to the venv rule.

4. **`importlib.metadata` for source deps.** Editable install (`uv pip install -e`) in the venv build action creates `.dist-info` metadata in site-packages. The accompanying `.pth` file points to a broken sandbox path but is never processed (venv's site-packages is on PYTHONPATH, not a registered site dir for the toolchain Python). `importlib.metadata` finds the `.dist-info` via `sys.path` search.

5. **Namespace packages work natively (verified via prototype).** Tested with simulated nvidia-style packages: `nvidia.cudnn`, `nvidia.cublas`, `nvidia.cuda_runtime` in a flat `site-packages/` with no `__init__.py` in the `nvidia/` root. All imports succeed via PEP 420 implicit namespace packages. Also verified the harder case: namespace packages split across multiple PYTHONPATH directories (first-party `nvidia.custom` on one path + third-party `nvidia.cudnn` on another) both resolve correctly. Python's `_NamespacePath` aggregates both directories automatically.

6. **PYTHONPATH import order is correct (verified via prototype).** First-party source roots placed before `site-packages` on PYTHONPATH. Confirmed that first-party packages shadow third-party packages of the same name. Cross-imports (first-party code importing third-party packages) work correctly. The toolchain Python with `-B -s` flags and PYTHONPATH is a complete replacement for the venv-based import mechanism.

7. **Toolchain Python + external site-packages works (verified via prototype).** Using a Python interpreter that is NOT the venv's `bin/python3` with PYTHONPATH pointing to the venv's `site-packages/` directory: torch imports, numpy imports, `importlib.metadata.version()` returns correct versions, `__file__` points to real files (hardlinked from uv cache, not symlinks), `.dist-info` metadata is found via `sys.path` search.

8. **Broken venv symlinks are irrelevant (verified via prototype).** Deliberately broke `bin/python3` by pointing it to `/sandbox/linux-sandbox/42/execroot/...` (nonexistent). All imports still work through the toolchain Python + PYTHONPATH approach. Console scripts have broken shebangs but are discoverable via `shutil.which()` and bypassed via `python -m <module>`.

9. **Venv creation performance is acceptable (measured via prototype).** On macOS ARM with Python 3.11 and torch 2.10 (16,386 files): `uv venv` creation takes 28ms, `uv pip install` with warm cache takes 3.5s, total build action cost is 3.5s. Cold install (including download) is ~46s. APFS hardlink deduplication means additional venvs sharing the same packages cost ~2-4MB instead of ~400MB.

10. **Old and new rules should not interoperate (design decision).** PyInfo providers (rules_python) and RoofPyPackageInfo (roof_py) represent fundamentally different import mechanisms. A bridge between them would be the hardest-to-debug component in the system. Instead, a `constraint_setting` makes the two worlds mutually exclusive. CI runs both platforms during migration. This forces clean bottom-up migration and prevents permanent hybrid states.

11. **First-party deps in install_venv.py (verified via prototype).** pyproject.toml lists both first-party and third-party deps together (`dependencies = ["torch", "attic-rt"]`). install_venv.py uses three-way classification: (1) dep matches a wheel in `@pypi` → install it, (2) dep is in first-party package names (passed via `--first-party-packages`) → skip it (handled via PYTHONPATH), (3) dep matches neither → fail with actionable error (`package "X" not found in @pypi and not a first-party dep`). Verified: name normalization handles case, dots, hyphens, PEP 508 extras, and environment markers correctly.

12. **Wheel build action works in Bazel-like sandbox (verified via prototype, uv 0.9.22).** `uv build --wheel` from a symlinked source tree works correctly (0.42s). `--no-build-isolation` works with pre-installed setuptools. Without setuptools, the action fails with a clear error — the Bazel rule must provide setuptools (download via `pip.parse()` or `http_file`, install in a build venv). `version = {file = "VERSION"}` with a local VERSION file works. **`version = {file = "../../VERSION"}` does NOT work** — setuptools' `_assert_local()` rejects paths escaping the package root. The fix: the wheel build action copies the repo-root VERSION file into the package directory as a declared Bazel input.

13. **Platform-specific wheel selection is handled automatically by uv (verified via prototype, uv 0.9.22).** `uv pip install --no-index --find-links <dir>` with both macOS ARM and Linux x86_64 numpy wheels in the same directory: uv correctly selects the macOS wheel and ignores the Linux one. With only wrong-platform wheels: uv fails with a clear error including platform hints. Even direct `.whl` file path installs check platform compatibility. Conclusion: install_venv.py can receive all-platform wheel directories and uv handles filtering. No `select()` needed in Starlark for platform filtering of wheel inputs.

14. **PYTHONPATH scales acceptably (verified via experiment, Python 3.14, macOS ARM).** Tested 1 to 50 PYTHONPATH entries. At 10 entries (realistic for a large project): ~200us per fresh import. At 50 entries: ~800us. Import performance degrades ~linearly (15.6x at 50 entries vs 1 entry). Real projects have 5-10 first-party source roots + 1 site-packages entry = well within acceptable range. Namespace package aggregation works across all tested entry counts. First-party-before-third-party shadowing holds regardless of entry count.

15. **Editable install creates usable .dist-info via PYTHONPATH (verified via experiment, uv 0.9.22, Python 3.14).** `uv pip install -e .` creates `.dist-info` in site-packages (0.44s). `importlib.metadata.version("pkg")` finds it via PYTHONPATH — no site directory registration needed. The editable `.pth` file is also created but NOT processed (PYTHONPATH directories don't trigger `.pth` processing — only `site.addsitedir()` does). This is correct: the source root is on PYTHONPATH separately, so the `.pth` file is dead weight but harmless. Full roof_py scenario (src_root + site-packages) works: source imported via src_root, metadata found via `.dist-info`.

16. **Extras group collection works correctly (verified via experiment).** Union-based collection across multiple pyproject.toml files with different extras groups: correct. Overlapping deps across groups: deduplicated by normalized name. Nonexistent extras group: silently ignored (matches pip). Convention validated: `roof_py_test` auto-includes `[test]`, `roof_py_binary` includes nothing, `extras = ["gpu"]` adds additional groups. install_venv.py receives `--extras test gpu` flag.

17. **conftest.py auto-discovery algorithm works (verified via experiment).** Walk-up from test file to package root correctly collects conftest.py at each directory level. Sibling directories share parent conftest.py but not each other's. Starlark glob pattern: `glob(["conftest.py", "tests/**/conftest.py"])` — collects package-root conftest.py + all under tests/ while excluding source directory conftest.py files.

18. **Build-time Python must be >= 3.11 for tomllib (confirmed).** `install_venv.py` uses `tomllib` (stdlib since 3.11). Python 3.9 is EOL (2025-10-05), 3.10 EOL is 2026-10-04. Requiring 3.11+ for the build-time toolchain Python is reasonable. This is independent of the application's runtime Python version. For projects stuck on 3.10, install_venv.py includes a fallback: `try: import tomllib; except ImportError: import tomli as tomllib` — `tomli` must then be provided as a build dependency.

19. **Linux CUDA venv at full scale works with single-TreeArtifact design (verified via benchmark, Linux overlay fs, Python 3.11, uv 0.10.3, torch 2.10.0+cu128).** 34 wheels (4.18 GB compressed) installed into 18K files / 7.42 GB venv. All operations within acceptable thresholds: install 4.3s (hardlink) / 1.47s (copy), copy 3.72s, tar+zstd 4.76s (3.47 GB), rebuild 1.73s. All 10 nvidia CUDA namespace subpackages import correctly without `LD_LIBRARY_PATH`. torch imports in 1.35s via PYTHONPATH. `importlib.metadata` works. Split-venv not needed: nvidia is 62% of bytes but install times are already fast, and splitting 33 nvidia wheels provides marginal benefit over the complexity cost. The feared 50-100K file count did not materialize — the venv grew modestly from macOS (16K → 18K files) while growing 17x in bytes (driven by `.so` files that are few but large).

20. **Split-venv is not worth the complexity (determined via benchmark).** Split-venv simulation showed torch-only venv = 11,804 files / 1.83 GB, rest = 6,406 files / 5.66 GB. The "heavy" component is nvidia (4.59 GB across 33 wheels), not torch (1.76 GB, 1 wheel). Splitting torch alone captures 65% of files but only 25% of bytes. Combined split install (2.2s) was faster than single (4.3s) but both are already fast enough. Given that rebuild time is 1.7s and the complexity cost of managing multiple TreeArtifacts on PYTHONPATH, the single-venv design is confirmed correct. Split-venv removed from scope.

21. **Hardlink dedup requires same filesystem — cross-device silently fails (verified via 3 experiments, Linux ext4 + overlay, uv 0.10.3).** uv's `--link-mode=hardlink` silently falls back to full copies when `UV_CACHE_DIR` and the venv output are on different devices. No error, no warning — just `nlink=1` and 7+ GB wasted per venv. This is a kernel constraint (`EXDEV`), not a uv bug. Common in containers: `/tmp` is often tmpfs/overlay (separate device) from the workspace (ext4 volume mount). Fix: (1) `UV_CACHE_DIR` / `sandbox_writable_path` must point to a path on the same filesystem as Bazel's output base, (2) `install_venv.py` checks `nlink > 1` on a sample file after install and fails with an actionable error if hardlinks didn't work. Verified across 4 scenarios: same-device = 99% hardlink ratio, cross-device = 0%, no exceptions. Also verified cross-venv dedup: 3 identical venvs on same fs, nlink climbs 2→3→4, total disk 0.28 GB instead of 0.70 GB (60% savings).

22. **Multi-version Python uses flag + select, not per-target transitions (design decision).** The Pythonic approach to multi-version testing is tox/nox: same code, different interpreter, system figures out the right wheels. roof_py follows this model: a `string_flag` (`--@roof//python:version=X.Y`) selects the Python version globally. The module extension generates version-aware aliases that route to the correct `pip.parse()` hub repo via `select()`. The venv rule, macros, launcher template, and install_venv.py require zero changes — the version flows through Bazel's existing mechanisms (toolchain resolution + select). For the migration case (pinning individual targets during a Python version upgrade), an optional `python_version` attribute applies a transition that sets the flag for that target's subgraph — the only transition in the system, opt-in, fires only when explicitly set. Total implementation cost: ~35 lines (20 module extension + 10 transition + 5 requires-python validation). No derisking needed — every component (string_flag, select, toolchain resolution, pip.parse multi-version hubs) is a proven, widely-used Bazel mechanism.

---

## Open questions

### Blockers (must resolve before Phase 0)

_None remaining. All former blockers resolved via prototyping and benchmarking — see resolved questions #11-#20._

### Nice to resolve (can address during implementation)

**1. Venv deduplication hash — what exactly is hashed?**

The macro creates `_roof_venv_<hash>` targets to share venvs across tests with identical deps. But what's the hash input? Options:

- Hash of sorted dep labels (simple, but label changes invalidate unnecessarily)
- Hash of sorted pyproject.toml file paths (better, but path changes invalidate)
- Hash of pyproject.toml content (correct, but can't compute at analysis time — content isn't available)

Probably: hash of sorted dep labels + sorted extras list. Simple and correct enough. Two tests with `deps = [":attic"]` and the same extras get the same venv. A test with `deps = [":attic", ":attic-rt"]` or different extras gets a different one.

**2. Test name collisions with nested directories**

```starlark
[roof_py_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(["tests/test_*.py"])]
```

If tests are in subdirectories (`tests/unit/test_foo.py` and `tests/integration/test_foo.py`), both generate `name = "test_foo"` — collision. Need a naming convention:

- Flatten: `name = src.replace("/", "_").removesuffix(".py")` → `tests_unit_test_foo`
- Or keep tests flat (one directory, no nesting) as a project convention

**3. Remote execution (RBE) and uv cache**

The design uses `sandbox_writable_path` pointing to a path on the same filesystem as the output base (e.g., `$HOME/.cache/roof-uv`). **Must NOT be `/tmp`** — in containers, `/tmp` is often tmpfs/overlay on a different device, which breaks hardlink dedup silently (verified: cross-device = 0% hardlink ratio, same-device = 99%). In RBE, each action runs on a different machine — no shared cache. Every venv build does full extraction. This is slower but correct. The Bazel action cache still works (same inputs = no re-run). Only cold builds are affected.

**4. Circular first-party deps**

If attic's pyproject.toml lists `attic-rt` and attic-rt's lists `attic`, the `first_party_deps` provider chain loops. Starlark depsets handle cycles (they're DAGs enforced by Bazel's target graph), so this would be a Bazel-level circular dependency error — caught early with a clear message.

**5. Remote cache TreeArtifact size**

~~Measured locally: torch venv on macOS is 16,386 files / 431MB. Full copy takes 4.7s. On Linux with CUDA this will be 5-10x (50K-100K files, 2-5GB).~~

**Resolved via Linux CUDA benchmark.** Actual Linux CUDA venv: 18K files / 7.42 GB (not 50-100K files as feared). Zstd-compressed: 3.47 GB (2.1:1 ratio). All operations < 6s. Shared venvs (~5-10 unique) limit blast radius. Split-venv not needed — nvidia dominates bytes (4.59 GB / 62%) but splitting by package name is complex and marginal given fast install times (1.7s rebuild). Monitor cache storage costs but no architectural change required.

---

## Appendix: what stays

Not everything is replaced:

- **rules_python toolchain**: Hermetic Python interpreter management. Works well. Keep it.
- **rules_python pip.parse()**: Downloads wheels from per-platform requirements files. The download mechanism is fine. What we're replacing is everything _after_ the download.
- **Per-platform requirements files**: Pragmatic solution for multi-platform resolution. `uv.lock` breaks with many platforms + CUDA. Keep the separate files.
- **rules_uv**: Added as a dependency for hermetic uv binary. Small, well-maintained.

## Appendix: what a BUILD file looks like

Before (current):

```starlark
load("@aspect_rules_py//py:defs.bzl", "py_test")
load("@rules_python//python:defs.bzl", "py_library")
load("//build_tools:py_wheel_with_info.bzl", "py_wheel_with_info")
load("@rules_pycross//pycross:defs.bzl", "pycross_wheel_library")

py_library(
    name = "attic",
    srcs = glob(["src/**/*.py"]),
    imports = ["src"],
    deps = [
        "//packages/attic-rt/src/attic_rt:attic_rt",
        "@pypi//torch",
        "@pypi//numpy",
    ],
)

py_wheel_with_info(
    name = "attic_wheel",
    distribution = "attic",
    version_file = "//:VERSION",
    python_tag = "py3",
    deps = [":attic"],
    # ... 20 more lines of wheel config
)

pycross_wheel_library(
    name = "attic_wheel_lib",
    wheel = ":attic_wheel",
)

py_test(
    name = "test_compiler",
    srcs = ["tests/test_compiler.py"],
    deps = [
        ":attic",
        ":attic_wheel_lib",
        "@pypi//pytest",
        "@pypi//torch",
        "@pypi//numpy",
    ],
)
```

After (roof_py):

```starlark
load("@roof//python:defs.bzl", "roof_py_package", "roof_py_test")

roof_py_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],
)

roof_py_test(
    name = "test_compiler",
    srcs = ["tests/test_compiler.py"],
    deps = [":attic"],
)
```

## Appendix: assembling packages with compiled artifacts

Packages like `roof-iree/compiler` assemble files from multiple sources — `cc_binary` outputs, pre-built `.so` files from `@iree`, Python files from `@llvm-project`, and local binaries. Today this is 95+ individual `copy_file` rules (~500 lines of Starlark). This is a general file-assembly problem, not a Python problem.

**Recommended approach: `copy_to_directory` from `@aspect_bazel_lib`**

`copy_to_directory` (already available — we use `@aspect_bazel_lib` for `copy_file`) merges files from multiple sources into a single TreeArtifact with path remapping:

```starlark
load("@aspect_bazel_lib//lib:copy_to_directory.bzl", "copy_to_directory")

# Assemble the entire iree/compiler package tree — one rule
copy_to_directory(
    name = "compiler_tree",
    srcs = [
        # Python files from @iree — directory structure preserved
        "@iree//compiler/bindings/python:all_python_files",

        # Compiled MLIR dialect bindings (cc_binary outputs)
        ":_mlir_so",
        ":_mlirDialectsLinalg_so",
        ":_mlirDialectsLLVM_so",
        ":_mlirDialectsPDL_so",
        ":_mlirDialectsTransform_so",
        ":_mlirDialectsGPU_so",
        ":_mlirGPUPasses_so",
        ":_mlirLinalgPasses_so",
        ":_mlirTransformInterpreter_so",

        # Pre-built IREE libraries
        "@iree//lib:libIREECompiler_so",
        "@iree//compiler/bindings/python:_ireeCompilerDialects.so",
        "@iree//compiler/bindings/python:_site_initialize_0.so",

        # Binaries
        "@iree//compiler/bindings/python:iree-compile",
        "@iree//compiler/bindings/python:iree-opt",
        "@iree//compiler/bindings/python:iree-lld",
    ],
    # Remap source paths to package structure
    replace_prefixes = {
        "compiler/bindings/python/": "iree/compiler/",
        "lib/": "iree/compiler/_mlir_libs/",
    },
    include_external_repositories = ["iree", "llvm-project"],
)
```

Then `roof_py_package` just references the assembled tree:

```starlark
roof_py_package(
    name = "roof-iree-compiler",
    pyproject = "pyproject.toml",
    src_root = ".",
    data = [":compiler_tree"],  # TreeArtifact with the full package
)
```

**If `copy_to_directory` doesn't fit** (prefix logic too limited, platform selection needed), a custom `merge_trees` rule is ~30 lines of Starlark + a ~20-line Python action:

```starlark
merge_trees(
    name = "compiler_tree",
    trees = {
        "iree/compiler": [
            "@iree//compiler/bindings/python:python_files",
        ],
        "iree/compiler/_mlir_libs": [
            ":_mlir_so",
            ":_mlirDialectsLinalg_so",
            "@iree//lib:libIREECompiler_so",
            "@iree//compiler/bindings/python:iree-compile",
        ],
    },
)
```

Either way, the separation is clean:

```
General infra:   copy_to_directory / merge_trees   (assembles files from anywhere)
Python infra:    roof_py_package                    (makes it a Python package)

roof_py_package doesn't know or care HOW the files were assembled.
The assembly tool doesn't know it's building a Python package.
```

This replaces ~500 lines of `copy_file` rules with ~40 lines of structured configuration, and the pattern is reusable for any package that assembles artifacts from external repos.

## Appendix: precompilation stance

**Not supported. Deliberately.**

rules_python offers a 6-state precompilation matrix (`PrecompileAttr` × `PrecompileInvalidationMode`: enabled/inherit/disabled × checked_hash/unchecked_hash). This adds significant complexity to the provider system and build graph for a feature most Python projects don't use.

roof_py uses `-B` (don't write `.pyc` files) in the test launcher. Python reads `.py` files directly. This is correct for development and test workflows where source files change frequently. For production deployments, the built `.whl` file can be installed normally (with `pip install`), and Python will generate `.pyc` files in the standard `__pycache__/` directories at first import.

If precompilation becomes a measurable performance issue for specific test suites, it can be added later as an opt-in feature on `roof_py_test` — but it should not be part of the initial implementation.

## Appendix: what the audit found

A code audit of rules_python (53K lines Starlark), aspect_rules_py (10.8K lines Starlark + Rust), and rules_pycross (12K lines Starlark + Python) confirmed the structural problems described in this RFC. Key findings by project:

**rules_python:**

- PyInfo provider: 13 fields, 704 lines, including legacy `has_py2_only_sources`
- VenvSymlinkEntry system: 470 lines of path optimization with namespace package special-casing (`_WELL_KNOWN_NAMESPACE_PACKAGES = ["nvidia"]` — hardcoded)
- 30+ TODO/FIXME comments including known unicode bugs in wheel filename escaping, Windows path separator issues, and incomplete shebang rewriting
- Marker evaluation shells out to a Python subprocess (fragile, can't handle free-threaded Python)
- Three-stage bootstrap (C++ → shell → Python) makes debugging extremely difficult
- pip integration unwraps wheels into separate Bazel repos, destroying flat site-packages layout — this is the root cause of namespace package breakage

**aspect_rules_py:**

- 1,700 lines of Rust (venv.rs 935, pth.rs 293, venv_shim 431) to do what `uv pip install` does
- Runtime venv creation (~87ms per test, every time, thrown away and recreated)
- .pth file escape path: `"/".join([".."] * (4 + target_depth))` — magic numbers based on runfiles structure
- Collision resolution: `FIXME` on line 840 admits "last wins doesn't actually work"
- Pinned to specific uv Git commit for internal Rust crate dependencies
- py_venv.bzl comment: `# FIXME: This is PoC quality`

**rules_pycross:**

- Most defensible of the three: solves real cross-compilation problem
- Clean translate → resolve → render pipeline using standard libraries (pypa/build, pypa/installer)
- BUT coupled to PyInfo from rules_python, inheriting all import path complexity
- 12K lines for a problem that roof_py sidesteps entirely (uv handles platform selection automatically)

Total lines replaced by roof_py: ~73K → ~600 lines (500 Starlark + 80 Python + 20 bash).

## Appendix: build-time Python requirements

The `install_venv.py` build action requires:

- **Python >= 3.11** for `tomllib` (stdlib TOML parser). For projects on Python 3.10, a fallback imports `tomli` (the backport), which must be provided as a build dependency via `pip.parse()`.
- **No other dependencies.** The script uses only `pathlib`, `subprocess`, `sys`, and `tomllib` — all stdlib. No `packaging`, no `pip`, no `setuptools`.

The build-time Python version is independent of the application's runtime Python. A project can target Python 3.9 for its application code while using Python 3.12 as the build-time toolchain interpreter.

---

## Appendix: conftest.py discovery in the sandbox (needs derisking)

**Status:** Proposed design — needs experiments before integration into the main design.

### The problem

pytest discovers `conftest.py` files by walking up from the test file toward `rootdir`, importing fixtures at each directory level. In Bazel's runfiles sandbox, this creates two problems:

1. **Only declared files exist.** Files not in the test's dependency chain are invisible — they don't exist in the runfiles tree.
2. **rootdir is unpredictable.** pytest determines rootdir by walking up from test file paths looking for `pyproject.toml`. In a monorepo with per-package `pyproject.toml` files, rootdir anchors at the package — anything above it (including a global conftest.py) is invisible to pytest.

This matters in monorepos with a conftest hierarchy:

```
repo/
  conftest.py                    # global fixtures
  pyproject.toml                 # root-level
  packages/
    conftest.py                  # shared across all packages
    ml/
      conftest.py                # ml group fixtures
      attic/
        BUILD.bazel              # roof_py_package here
        conftest.py              # package fixtures
        tests/
          conftest.py            # test fixtures
          test_compiler.py
```

Without intervention, `test_compiler` only sees conftest.py at the package level and below. The global, packages-level, and ml-level conftest files are missing from runfiles and invisible to pytest.

### Proposed solution: `--rootdir` + `pytest_root` chain

**Part 1: The runner always sets `--rootdir`**

`_roof_pytest_runner.py` passes `--rootdir` pointing at the repo root in runfiles. This anchors pytest's conftest discovery deterministically — from the repo root down to the test file, every conftest.py at every level gets discovered.

```python
# _roof_pytest_runner.py (addition)
import os

runfiles_dir = os.environ.get("RUNFILES_DIR", "")
repo_root = os.path.join(runfiles_dir, "_main")

args = list(test_files)
args.extend(["--rootdir", repo_root])
```

No changes to the launcher template. The runner always knows the repo root is `$RUNFILES_DIR/_main`.

**Part 2: `pytest_root` convention for getting conftest.py into runfiles**

Each directory with a conftest.py defines a `pytest_root` filegroup that includes its own conftest and chains to its parent:

```starlark
# /BUILD.bazel (repo root — the chain ends here)
filegroup(
    name = "pytest_root",
    srcs = ["conftest.py", "pyproject.toml"],
    visibility = ["//visibility:public"],
)

# packages/BUILD.bazel (chains to parent)
filegroup(
    name = "pytest_root",
    srcs = ["conftest.py", "//:pytest_root"],
    visibility = ["//visibility:public"],
)

# packages/ml/BUILD.bazel (chains to parent)
filegroup(
    name = "pytest_root",
    srcs = ["conftest.py", "//packages:pytest_root"],
    visibility = ["//visibility:public"],
)
```

Each level knows its parent. Adding a new intermediate level only touches one BUILD file. The chain mirrors pytest's own walk-up model — a child inherits from its parents.

**Part 3: Auto-discovery in the `roof_py_test` macro**

The macro checks if `:pytest_root` exists in the current package and uses it automatically:

```starlark
def roof_py_test(name, srcs, deps, pytest_root = None, **kwargs):
    if pytest_root == None:
        if native.existing_rule("pytest_root"):
            pytest_root = ":pytest_root"

    # If pytest_root is set (auto or explicit), add to runfiles
    data = list(kwargs.pop("data", []))
    if pytest_root:
        data.append(pytest_root)

    _roof_py_test_rule(
        name = name,
        srcs = srcs,
        deps = deps,
        data = data,
        **kwargs
    )
```

**Behavior when `:pytest_root` doesn't exist:** silently skipped. No error. Tests still run, they just don't get parent conftest fixtures. The user discovers the gap naturally ("my fixture isn't available") and adds the chain.

| Scenario                                  | Result                                        |
| ----------------------------------------- | --------------------------------------------- |
| `:pytest_root` exists in package          | Auto-used, full conftest chain in runfiles    |
| `:pytest_root` doesn't exist              | Silently skipped, package-local conftest only |
| `pytest_root = "//other:target"` explicit | Uses that, overrides auto-discovery           |

**Resulting runfiles tree (full chain):**

```
$RUNFILES_DIR/_main/
  conftest.py                    # from //:pytest_root
  pyproject.toml                 # from //:pytest_root
  packages/
    conftest.py                  # from //packages:pytest_root
    ml/
      conftest.py                # from //packages/ml:pytest_root
      attic/
        conftest.py              # from macro auto-collection
        tests/
          conftest.py            # from macro auto-collection
          test_compiler.py
```

pytest with `--rootdir=$RUNFILES_DIR/_main` walks the full hierarchy. Every conftest.py at every level is discovered and imported.

### What needs derisking

These experiments must pass before this design is integrated into the main architecture:

**Experiment 1: Does `--rootdir` anchor conftest discovery?**

Verify that `pytest.main(["--rootdir", "/some/dir", "/some/dir/sub/test.py"])` discovers conftest.py at `/some/dir/conftest.py` and `/some/dir/sub/conftest.py`. pytest docs say yes, but verify with the actual pytest version.

**Experiment 2: Does `$RUNFILES_DIR/_main` exist as a traversable directory?**

Inside a Bazel test, run `os.listdir(os.path.join(os.environ["RUNFILES_DIR"], "_main"))`. On Linux/macOS with symlink-based runfiles this should work. Check that the directory structure is walkable by pytest.

**Experiment 3: Which `pyproject.toml` does pytest read for `[tool.pytest.ini_options]`?**

With `--rootdir` at repo root, pytest reads the ROOT `pyproject.toml` for config. Per-package `[tool.pytest.ini_options]` sections would be ignored. Verify this is acceptable — it may actually be desirable (global pytest config, not per-package).

**Experiment 4: End-to-end conftest chain in sandbox**

Create a Bazel workspace with:

- Root conftest.py with a global fixture
- Intermediate directory with BUILD file and conftest.py with a mid-level fixture
- Package with its own conftest.py and a test that uses fixtures from ALL levels

Run `bazel test` and verify all three fixture levels are available.

**Experiment 5: No conftest case**

Verify that `--rootdir=$RUNFILES_DIR/_main` works correctly when NO conftest.py exists at the root — pytest should not error, just have no global fixtures.

## Appendix: Windows support (v2)

**Status:** Deferred to v2. No architectural changes needed — the core design (TreeArtifact venv, PYTHONPATH, `uv pip install` delegation) is platform-agnostic. Windows support is a launcher-level concern.

**Current scope (v1):** POSIX only (macOS + Linux). The launcher is a bash script (`roof_run.tmpl.sh`). If a user builds with `--platforms` targeting Windows, they'll get a build error from the bash dependency, not a silent failure.

### What needs to change for Windows

The design has four POSIX-specific assumptions, all in the launcher layer:

| Assumption          | POSIX                         | Windows             | Fix                                             |
| ------------------- | ----------------------------- | ------------------- | ----------------------------------------------- |
| Launcher language   | bash                          | N/A                 | Add `roof_run.tmpl.bat` (~10 lines)             |
| Path list separator | `:`                           | `;`                 | Starlark `select()` on `@platforms//os:windows` |
| site-packages path  | `lib/pythonX.Y/site-packages` | `Lib/site-packages` | Template variable or select                     |
| Scripts directory   | `bin/`                        | `Scripts/`          | Template variable or select                     |

Everything above the launcher (the venv rule, `install_venv.py`, the provider, the macros, the dep classification logic) is platform-independent. `uv` handles Windows natively. `install_venv.py` uses only Python stdlib. The TreeArtifact approach works on all platforms Bazel supports.

### The Windows launcher

Direct translation of the bash template:

```bat
@echo off
setlocal

set "PYTHON=%RUNFILES_DIR%\{{PYTHON_TOOLCHAIN}}"
set "VENV_DIR=%RUNFILES_DIR%\{{VENV_DIR}}"
set "SITE_PACKAGES=%VENV_DIR%\Lib\site-packages"

set "PATH=%VENV_DIR%\Scripts;%PATH%"
set "PYTHONPATH={{FIRST_PARTY_PYTHONPATH}};%SITE_PACKAGES%"

{{PYTHON_ENV}}

"%PYTHON%" -B -s {{INTERPRETER_ARGS}} {{EXEC_CMD}} %*
```

10 lines. Nearly identical structure to the bash version. Key differences:

- No runfiles library initialization — `%RUNFILES_DIR%` is set directly by Bazel's test runner on Windows
- No `exec` — batch files exit naturally after the command completes
- No `hash -r` — not applicable on Windows
- `set` instead of `export`, `%VAR%` instead of `${VAR}`, `%*` instead of `"$@"`

### Starlark changes

In `launcher.bzl`, select the template based on target platform:

```starlark
_launcher_template = select({
    "@platforms//os:windows": "//python/private:roof_run.tmpl.bat",
    "//conditions:default": "//python/private:roof_run.tmpl.sh",
})
```

The substitution dict in `expand_template` is built with platform-aware values:

```starlark
path_sep = select({"@platforms//os:windows": ";", "//conditions:default": ":"})
```

Total Starlark diff: ~15 lines of `select()` statements in `launcher.bzl`.

### What doesn't change

- `install_venv.py` — stdlib Python, no platform-specific code (uv handles platform internally)
- `_roof_pytest_runner.py` — pure Python, no platform assumptions
- `RoofPyPackageInfo` provider — data structure, no platform logic
- `venv.bzl` — the TreeArtifact action runs uv, which handles Windows natively
- `package_rule.bzl` — collects metadata, no platform logic
- `defs.bzl` macros — dep classification and venv deduplication are platform-independent

### Known risks for Windows

1. **Long paths.** Windows has a 260-character default path limit. Deep `site-packages` paths (e.g., `nvidia/cuda_runtime/lib/...`) may exceed this. Mitigation: enable long path support via Windows registry or app manifest. This is a system config issue, not an architectural one.

2. **Hardlink behavior on NTFS.** NTFS supports hardlinks, and `uv --link-mode=hardlink` works on Windows. The `install_venv.py` hardlink verification (`nlink > 1`) works on NTFS. However, some antivirus software flags unusual hardlink patterns. If this surfaces, `--link-mode=copy` is the fallback — uv supports it on all platforms.

3. **Manifest-only runfiles.** On Windows, Bazel sometimes uses a runfiles manifest instead of a directory tree. The `.bat` launcher uses `%RUNFILES_DIR%` which works for directory-based runfiles. For manifest-only scenarios (remote execution on Windows), a small `rloc.bat` helper (~10 lines of `findstr` + `for /f`) would be needed. This is a niche case — remote execution on Windows is uncommon.

### Implementation estimate

| Component                         | Lines                 | Effort                         |
| --------------------------------- | --------------------- | ------------------------------ |
| `roof_run.tmpl.bat`               | ~10                   | Trivial — direct translation   |
| `launcher.bzl` select() additions | ~15                   | Trivial — mechanical           |
| Testing on Windows CI             | —                     | 1-2 days (the real cost)       |
| **Total**                         | **~25 lines of code** | **~2 days including CI setup** |

### Why not a Python launcher instead?

Considered and rejected. A Python launcher (~55 lines) would be cross-platform in a single file, but:

- More complex than both shell templates combined (~30 lines total for bash + bat)
- Introduces a chicken-and-egg problem (needs Python to find Python)
- Adds ~30ms startup overhead per test invocation (`os.execvp` after Python init)
- The inline runfiles resolution logic is less battle-tested than Bazel's native mechanisms

Two small, platform-specific templates are simpler and more transparent than one cross-platform abstraction.

---

## Appendix: Starlark implementation sketch

The private `_roof_py_venv` rule (the only non-trivial rule) declares a TreeArtifact and runs install_venv.py:

```starlark
def _roof_py_venv_impl(ctx):
    venv_dir = ctx.actions.declare_directory(ctx.attr.name)

    # Collect all pyproject.toml files from deps
    pyprojects = []
    first_party_names = []
    for dep in ctx.attr.deps:
        if RoofPyPackageInfo in dep:
            info = dep[RoofPyPackageInfo]
            pyprojects.append(info.pyproject)
            first_party_names.append(info.pyproject.owner.name)
            for transitive in info.first_party_deps.to_list():
                pyprojects.append(transitive.pyproject)
                first_party_names.append(transitive.pyproject.owner.name)

    # Collect internal wheels (from .wheel targets in deps)
    internal_wheels = []
    for dep in ctx.attr.deps:
        if RoofPyPackageInfo not in dep:
            # Assume it's a .wheel target (DefaultInfo with .whl file)
            for f in dep[DefaultInfo].files.to_list():
                if f.path.endswith(".whl"):
                    internal_wheels.append(f)

    args = ctx.actions.args()
    args.add(ctx.executable._uv)
    args.add(ctx.executable._python)
    args.add(venv_dir.path)
    args.add(ctx.file._wheel_dir.path)
    args.add_all(pyprojects)
    args.add("--first-party-packages")
    args.add_all(first_party_names)
    args.add("--extras")
    args.add_all(ctx.attr.extras)

    ctx.actions.run(
        executable = ctx.executable._python,
        arguments = [ctx.file._install_script.path, args],
        inputs = depset(
            pyprojects + internal_wheels + [ctx.file._wheel_dir, ctx.file._install_script],
            transitive = [ctx.attr._uv[DefaultInfo].files, ctx.attr._python[DefaultInfo].files],
        ),
        outputs = [venv_dir],
        mnemonic = "RoofPyVenv",
        progress_message = "Creating Python venv for %s" % ctx.label,
        # MUST be on same filesystem as output base — NOT /tmp (often tmpfs/overlay in containers).
        # Cross-device breaks hardlink dedup silently: 0% ratio, 7+ GB wasted per venv.
        env = {"UV_CACHE_DIR": ctx.attr._uv_cache_path},
    )

    return [DefaultInfo(files = depset([venv_dir]))]
```

This is ~50 lines. The macro that wraps it (for venv deduplication and dep classification) is ~30 lines. The full Starlark implementation — all rules, macros, and the provider — targets ~500 lines total.
