# rules_pythonic: Pythonic Build Infrastructure for Bazel

**Status:** Draft | **Authors:** [TBD] | **Last updated:** 2026-03-11

---

## TL;DR

Replace ~7,000 lines of Starlark + Rust (rules_python wrappers, aspect_rules_py fork, rules_pycross, Rust venv tool) with **~670 lines** that delegate to `uv` and standard Python conventions. Third-party deps come from `pyproject.toml`, not BUILD files. Environments are built once and cached as Bazel TreeArtifacts — test startup drops from ~87ms to zero. Namespace packages, metadata, and debugging all work the way Python developers expect.

**Decision requested:** Approve this as the replacement for our Python build infrastructure, migrated bottom-up over 4 phases.

---

## Contents

- [The Problem](#the-problem) — what's broken and why
- [The Solution](#the-solution) — three ideas, before/after
- [Design Principles](#design-principles)
- [Architecture](#architecture) — build-time flow, runfiles layout, dependency classification
- [Rule API](#rule-api) — pythonic_package, pythonic_test, pythonic_binary, pythonic_files, pythonic_devenv
- [Multi-Version Python](#multi-version-python)
- [Caching Strategy](#caching-strategy)
- [Monorepo pyproject.toml Layout](#monorepo-pyprojecttoml-layout)
- [Migration Roadmap](#migration-roadmap)
- [Validation](#validation) — benchmarks and correctness results
- [Design Trade-offs](#design-trade-offs)
- [Risk Analysis](#risk-analysis)
- [Open Questions](#open-questions)

---

## The Problem

Python in Bazel is hard. Not because the problem is inherently difficult, but because the existing ecosystem — `rules_python`, `rules_py`, `rules_pycross` — reimplements Python packaging concepts in non-Python languages. The result is a stack that's slow, fragile, and opaque to the Python developers who have to use it every day.

Consider what happens when a developer wants to understand why `import torch` fails. They need to trace through: Bazel runfiles trees, `PyInfo.imports` depsets, `.pth` files with `../../../../` escape paths, the rules_py Rust venv tool's strategy pattern (`PthStrategy` vs `SymlinkStrategy` vs `CopyAndPatchStrategy`), namespace collision modes, and shim interpreter resolution. None of these concepts exist in Python. A Python developer's mental model is: "packages are in site-packages, I import them." Every layer between that expectation and reality is a debugging trap.

### The existing ecosystem

```
Layer          | Component                    | Lines   | Source
---------------+------------------------------+---------+--------------------
Dependency     | rules_python pip.parse()     | ~500    | rules_python
resolution     | Per-platform requirements.txt| ~400    |

Package        | py_library wrappers          | ~200    | rules_python
building       | py_wheel rule                | ~200    | rules_python
               | rules_pycross wheel_library  | ~300    | rules_pycross

Test/binary    | rules_py py_test/py_binary   | ~2500   | rules_py
runtime        | Rust venv tool               | ~1665   | rules_py
               | Rust venv shim               | ~150    | rules_py

Import path    | PyInfo provider              | ~700    | rules_python
plumbing       | py_library.bzl               | ~300    | rules_python

Toolchains     | Rust venv/shim/unpack        | ~300    | rules_py
               | ~600 Rust crate actions      |         | rules_py

Gazelle        | Python config                | ~50+    | rules_python
---------------+------------------------------+---------+--------------------
```

A code audit reveals the weight of this approach:

- **rules_python (53K lines Starlark):** `PyInfo` has 13 fields and 704 lines. Namespace package handling includes a hardcoded `_WELL_KNOWN_NAMESPACE_PACKAGES = ["nvidia"]`. 30+ TODO/FIXME comments. The pip integration unwraps wheels into separate Bazel repos, destroying flat `site-packages/` — the root cause of namespace breakage.

- **rules_py (10.8K lines Starlark + Rust):** 1,700 lines of Rust to create throwaway venvs at runtime (~87ms each). Magic depth constants: `"/".join([".."] * (4 + target_depth))`. Collision resolution has a FIXME: "last wins doesn't actually work."

- **rules_pycross (12K lines):** The most defensible — clean cross-compilation pipeline. But coupled to `PyInfo`, inheriting all the import path complexity. And `uv` now handles the same problem automatically.

### Five structural problems

| #   | Problem                                         | Symptom                                                                                                                                                                                                                                                                                                     |
| --- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **Reimplementation instead of delegation**      | Dep resolution via `PyInfo.imports` depsets instead of a lock file. Package install via Rust symlink tool instead of `uv pip install`. Import paths via `.pth` files instead of `PYTHONPATH`. Each reimplementation is incomplete and opaque to Python developers.                                          |
| 2   | **Runtime overhead where there should be none** | Every `bazel test` creates a fresh venv (~63ms), processes `.pth` files (~24ms), creates symlinks — then throws it all away. Every test. Every time. Even when nothing changed.                                                                                                                             |
| 3   | **Information flows backwards**                 | In standard Python, `pyproject.toml` is the source of truth. Here, metadata originates in BUILD files and flows through Starlark -> JSON -> TOML -> symlinks to produce standard formats. The source of truth is in the wrong place.                                                                        |
| 4   | **Abstraction layers that don't abstract**      | `PyInfo.imports`, `VenvSymlinkEntry`, collision strategies, shim resolution — none of these have Python equivalents. When something breaks, the developer must understand both the Python packaging model _and_ the Bazel reimplementation.                                                                 |
| 5   | **The namespace package problem**               | `pip.parse()` puts `nvidia-cudnn-cu12` and `nvidia-cublas-cu12` in separate Bazel repos with separate `nvidia/` dirs. Making both importable requires a recursive directory merge algorithm — hundreds of lines to solve a problem that `pip install` into a single `site-packages/` handles automatically. |

---

## The Solution

Replace everything after wheel download with ~670 lines that delegate to standard Python tools:

- **545 lines of Starlark** (rules, macros, provider)
- **105 lines of Python** (install_packages.py, pytest runner)
- **20 lines of bash** (launcher template)
- **No Rust. No custom toolchains.**

Three ideas make this possible:

**1. `pyproject.toml` is the only place dependencies are declared.** To add `torch`, edit `pyproject.toml`. Not a BUILD file. At build time, a Python script reads `pyproject.toml` with `tomllib` (stdlib) and matches dep names against pre-downloaded wheels that Bazel fetches via `pip.parse()`. Dev tools (`ruff`, `mypy`, `pytest`), the build system, and `uv pip install -e .` all read the same file.

**2. `uv pip install --target` produces a flat package directory as a Bazel TreeArtifact.** Built once, cached, reused. Test startup drops from ~87ms to zero. Namespace packages like `nvidia.cudnn` coexist because files land in a single directory — the merge algorithm disappears because the problem doesn't arise.

**3. `PYTHONPATH` replaces `.pth` files, `PyInfo.imports`, and runfiles symlink forests.** The launcher sets `PYTHONPATH` with first-party source roots before `site-packages`. When an import fails, `print(sys.path)` shows exactly where Python is looking. This is how every Python developer already debugs import problems outside of Bazel.

### Before and after

```starlark
# BEFORE: rules_python + rules_py + rules_pycross
# 4 load() statements, deps duplicated across targets, 40+ lines per package
load("@rules_py//py:defs.bzl", "py_test")
load("@rules_python//python:defs.bzl", "py_library")
load("@rules_python//python:pip.bzl", "...")

py_library(
    name = "attic",
    srcs = glob(["src/**/*.py"]),
    imports = ["src"],
    deps = ["//packages/attic-rt/src/attic_rt:attic_rt", "@pypi//torch", "@pypi//numpy"],
)

py_test(
    name = "test_compiler",
    srcs = ["tests/test_compiler.py"],
    deps = [":attic", "@pypi//pytest", "@pypi//torch", "@pypi//numpy"],
)
```

```starlark
# AFTER: rules_pythonic
# 1 load(), no dep duplication, 10 lines
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_package", "pythonic_test")

pythonic_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],  # first-party only; torch/numpy from pyproject.toml
)

pythonic_test(name = "test_compiler", srcs = ["tests/test_compiler.py"], deps = [":attic"])
```

---

## Design Principles

1. **pyproject.toml is the single source of truth** for dependencies. BUILD files never list `@pypi//` targets.
2. **Delegate, don't reimplement.** Wheel installation = `uv pip install`. Wheel building = `uv build`. Test running = `pytest`. Build scripts use only Python stdlib.
3. **Opinionated defaults, Python escape hatches.** pytest is the default runner. When you need something different, write a Python script — not a Starlark DSL.
4. **Standard Python conventions.** `PYTHONPATH`, flat `site-packages`, no `.pth` files, no symlink forests.
5. **Zero test-time overhead.** The environment is built and cached. Test startup is `exec python`.
6. **Debuggable.** `sys.path` shows import resolution. `__file__` points to real files. `importlib.metadata.version("torch")` returns `"2.10.0"`.
7. **Mutual exclusion during migration.** Old and new rules are incompatible in the same build. This prevents permanent hybrid states and forces clean, bottom-up migration.
8. **No custom toolchains, no Rust dependencies.** `uv` is the only external tool. Build scripts are stdlib Python.

---

## Architecture

### How it works

```
pyproject.toml (human-written, single source of truth)
       |
       +-- install_packages.py reads it at build time (tomllib, stdlib)
       |     validates dep names against @pypi wheel files
       |     runs: uv pip install --target --no-deps --no-index --link-mode=hardlink
       |     produces: flat package directory as TreeArtifact (cached by Bazel)
       |
       +-- uv build reads it to build .whl (for deployment)
       +-- uv pip install -e . reads it for local dev
       +-- ruff/mypy/pytest read [tool.*] sections
```

At test time, the launcher sets up the environment and execs Python:

```bash
# pythonic_run.tmpl.sh — the entire launcher
PYTHON="$(rlocation {toolchain_python})"
PACKAGES_DIR="$(rlocation {packages_dir})"  # flat TreeArtifact from runfiles
SOURCE_ROOTS="{source_roots}"               # first-party before third-party

export PYTHONPATH="${SOURCE_ROOTS}:${PACKAGES_DIR}"
{env_vars}

exec "${PYTHON}" -B -s {interpreter_args} {entry_point} "$@"
```

`-B` skips `.pyc` generation. `-s` disables user site-packages. The launcher uses the toolchain Python directly — no venv is created, just a flat package directory via `uv pip install --target`.

### Runfiles at test time

```
$RUNFILES_DIR/_main/
  packages/attic/
    src/attic/                              # first-party source (symlinks to repo)
    tests/test_compiler.py                  # test file
    tests/conftest.py                       # auto-collected by macro
  packages/attic-rt/
    src/attic_rt/                           # transitive first-party dep
  _pythonic_packages_a1b2c3/                 # flat TreeArtifact (built once, cached)
      torch/ numpy/ pytest/                 # installed via uv pip install --target
      nvidia/cudnn/ nvidia/cublas/          # namespace packages just work
      *.dist-info/                          # importlib.metadata works
  tools/python/python3.11                   # toolchain interpreter
  pythonic_pytest_runner.py                 # Bazel<->pytest bridge
```

Two build actions produce this: (1) `PythonicInstall` installs packages into a flat TreeArtifact once and caches it across all tests with the same dependency set, and (2) launcher generation substitutes resolved paths into the template. Source files are symlinks — no action needed.

### Dependency flow

The `pythonic_test` macro classifies each dep by its provider:

| Dep            | Provider              | What happens                                             |
| -------------- | --------------------- | -------------------------------------------------------- |
| `:attic`       | `PythonicPackageInfo` | Source root added to PYTHONPATH                          |
| `:attic.wheel` | `DefaultInfo` (.whl)  | Wheel installed into venv alongside third-party packages |

The choice between source-on-PYTHONPATH (fast iteration, instant feedback) and wheel-in-venv (test the built artifact) is made by the _consumer_, not the package. A package with compiled extensions uses the `.wheel` target because there's no pure-source option.

Third-party deps are never in BUILD `deps`. They come from `pyproject.toml`, parsed by `install_packages.py` at build time. The script does three-way classification: match a wheel from `@pypi` (install it), match a first-party package name (skip it — handled via PYTHONPATH), or fail with an actionable error message.

### The nvidia namespace problem (and why it disappears)

`pip.parse()` downloads `nvidia-cudnn-cu12` and `nvidia-cublas-cu12` into separate Bazel repos, each with its own `nvidia/` directory. Making `nvidia.cudnn` and `nvidia.cublas` both importable requires merging these directories at runtime — complex, fragile, and unique to Bazel.

With `uv pip install` into flat `site-packages/`, both packages install their files under a single `nvidia/` directory. Python's implicit namespace package mechanism (PEP 420, stable since Python 3.3) handles the rest. Verified at full CUDA scale: all 10 nvidia subpackages (cudnn, cublas, cuda_runtime, cuda_nvrtc, nvjitlink, cufft, cusparse, cusolver, nccl, nvtx) import correctly. No `LD_LIBRARY_PATH`, no `__init__.py`, no merge logic.

The harder case also works: namespace packages split across _multiple_ PYTHONPATH directories (first-party `nvidia.custom` on one path, third-party `nvidia.cudnn` on another). Python's `_NamespacePath` aggregates both roots automatically.

### When things go wrong

The design prioritizes clear error messages over silent degradation:

**Missing dependency.** If `pyproject.toml` lists a package that isn't in `@pypi` and isn't a first-party dep, `install_packages.py` fails at build time:

```
ERROR: package "requests" required by pyproject.toml but not found in @pypi wheels
       and not a first-party dep.
       Add it to requirements.txt or to deps = [...] in BUILD.
```

**Broken hardlinks.** If `UV_CACHE_DIR` and the output directory are on different filesystems, `install_packages.py` detects `nlink=1` after install and fails immediately:

```
ERROR: hardlinks not working — installed files have nlink=1.
  UV_CACHE_DIR=/path/to/uv/cache
  output_dir=/path/to/output

  Ensure both directories are on the same filesystem and that
  the sandbox can access the cache. Add to your .bazelrc:

    build --sandbox_writable_path=/path/to/uv/cache
```

**Wrong Python version.** If the toolchain Python doesn't satisfy `requires-python` from `pyproject.toml`, the build fails before any installation:

```
ERROR: packages/attic/pyproject.toml requires python >=3.11, but building with 3.10
```

**Import failure at test time.** `sys.path` shows exactly where Python looked — standard debugging. No runfiles trees, no `.pth` escaping, no shim resolution to trace through.

---

## Rule API

### pythonic_package

Replaces `py_library` + `py_wheel` + rules_pycross integration.

```starlark
pythonic_package(
    name = "attic",
    pyproject = "pyproject.toml",      # real, hand-written, committed to source
    src_root = "src",                   # directory added to PYTHONPATH
    srcs = glob(["src/**/*.py"]),
    data = glob(["src/**/*.mlir"]),     # non-Python files needed at runtime
    deps = ["//packages/attic-rt:attic-rt"],  # first-party cross-package deps only
)
```

Creates two targets: `:attic` (source dep for fast iteration) and `:attic.wheel` (built `.whl` for testing the artifact or deployment).

The `pyproject.toml` is standard Python:

```toml
[project]
name = "attic"
dynamic = ["version"]
dependencies = ["torch>=2.1", "numpy", "attic-rt"]

[project.optional-dependencies]
test = ["pytest>=7.0"]
gpu = ["triton"]

[tool.setuptools.dynamic]
version = {file = "VERSION"}

[tool.mypy]
strict = true

[tool.ruff]
line-length = 100
```

The provider is deliberately simple:

```starlark
PythonicPackageInfo = provider(fields = {
    "src_root",           # string: PYTHONPATH entry (e.g., "packages/attic/src")
    "srcs",               # depset[File]: source files
    "pyproject",          # File or None: the pyproject.toml (None for pythonic_files)
    "wheel",              # File or None: built .whl
    "first_party_deps",   # depset[PythonicPackageInfo]: transitive first-party deps
})
```

Five fields. No `imports` depsets, no transitive source collection, no `.pth` generation. Compare to `PyInfo`'s 13 fields and 704 lines.

### pythonic_test

```starlark
pythonic_test(
    name = "test_compiler",
    srcs = ["tests/test_compiler.py"],
    deps = [":attic"],
    extras = ["gpu"],                      # auto-includes [test]; add more groups here
    env = {"PYTHONDEVMODE": "1"},          # Python's own env var interface
    interpreter_args = ["-X", "importtime"],  # flags without env var equivalents
    shard_count = 4,                       # file-level sharding, no pytest-shard plugin
)
```

The default test runner is pytest. A 25-line bridge (`pythonic_pytest_runner.py`) translates Bazel's environment variables to pytest arguments: `TEST_SHARD_INDEX`/`TEST_TOTAL_SHARDS` for sharding, `TESTBRIDGE_TEST_ONLY` for `-k` filtering, `XML_OUTPUT_FILE` for JUnit XML. No external dependencies — the runner splits test files across shards directly.

For tests that can't use pytest:

```starlark
# File-based: full control via a Python script
pythonic_test(name = "test_distributed", main = "tests/run_distributed.py", ...)

# Module-based: python -m sets __package__ correctly for relative imports
pythonic_test(name = "test_distributed", main_module = "torch.distributed.run", ...)
```

Test discovery uses glob instead of Gazelle:

```starlark
[pythonic_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(["tests/test_*.py"])]
```

Add a test file, glob picks it up. Add a third-party dep, edit pyproject.toml. No `bazel run //:gazelle`.

### pythonic_binary

Same architecture as `pythonic_test` but `main` or `main_module` is required (no default runner):

```starlark
pythonic_binary(name = "serve", main_module = "attic.serve", deps = [":attic"])
```

### pythonic_files

For importable code that isn't a package — test utilities, config modules, generated protobuf stubs, compiled extension wrappers. These have no `pyproject.toml`, no version, no third-party deps, and will never be published as a wheel.

```starlark
pythonic_files(
    name = "testing_helpers",
    srcs = glob(["**/*.py"]),
    src_root = ".",
)
```

It's a leaf node: no `deps`, no `pyproject`, no `.wheel` target. Returns `PythonicPackageInfo` with `pyproject = None` and `wheel = None`. Downstream rules consume it identically to a package — the `src_root` goes on PYTHONPATH, the `srcs` go into runfiles.

No file type filter on `srcs` — Python packages contain `.py`, `.so`, `.pyi`, `.json`, and more. The user controls inclusion via `glob()` patterns.

If code eventually needs dependencies or a wheel, the upgrade path is: add a 3-line `pyproject.toml` and switch to `pythonic_package`. Code with dependencies is a package.

### pythonic_devenv

Creates a Python venv for IDE completion, type checking, and interactive development. `bazel run` the target to create or update the venv.

```starlark
pythonic_devenv(
    name = "ide",
    deps = [":attic", "//packages/search:search"],
    wheels = ["//:all_wheels"],       # hermetic: third-party from @pypi
    extras = ["dev", "test"],
)
```

Two modes depending on whether `wheels` is provided:

|                    | **Hermetic** (`wheels` set)                                           | **Resolving** (`wheels` omitted)         |
| ------------------ | --------------------------------------------------------------------- | ---------------------------------------- |
| Third-party source | `@pypi` wheels, validated with `--no-index`                           | PyPI, optionally pinned by `constraints` |
| Install order      | Step 1: all wheels `--no-deps`. Step 2: editables with `--find-links` | Single `uv pip install -e` call          |
| When to use        | CI, reproducible envs, matching Bazel exactly                         | Quick local dev setup                    |

First-party packages are classified by their target type:

- **Source targets** (`:attic`) get editable installs via `stage_symlink_tree` — the same staging mechanism used by wheel building. Edits to source files are visible to the IDE immediately.
- **`.wheel` targets** (`:attic.wheel`) get installed as built wheels. Use this for assembled packages whose source is produced by Bazel (e.g. `copy_to_directory` output with C extensions).

The staging approach is uniform: every editable package — whether vanilla or assembled — goes through `stage_symlink_tree`. For vanilla packages, the staging dir symlinks back to workspace source. For assembled packages, it symlinks to the TreeArtifact contents. The build backend (hatchling, setuptools) sees the same layout in both cases.

Staging directories live inside the venv at `.pythonic_staging/` so they persist across reboots and get cleaned up when the venv is recreated.

### Conftest.py discovery in the sandbox

pytest discovers `conftest.py` by walking up from the test file toward `rootdir`. In Bazel's runfiles sandbox, conftest files outside the test's declared dependencies are invisible. The solution has three parts:

1. **The runner always sets `--rootdir=$RUNFILES_DIR/_main`.** This anchors conftest discovery at the repo root, so pytest walks the full hierarchy.

2. **`conftest` filegroup chains get conftest files into runfiles.** Each directory with a conftest.py defines a filegroup that includes its own conftest and chains to its parent:

```starlark
# /BUILD.bazel (repo root — chain ends here)
filegroup(name = "conftest", srcs = ["conftest.py", "pyproject.toml"], visibility = ["//visibility:public"])

# packages/ml/BUILD.bazel (chains to parent)
filegroup(name = "conftest", srcs = ["conftest.py", "//packages:conftest"], visibility = ["//visibility:public"])
```

3. **The `conftest` attribute on `pythonic_test` passes the chain.** `pythonic_test(conftest = ":conftest")` adds the filegroup to runfiles so pytest discovers the full conftest hierarchy.

A side effect: with `--rootdir` at the repo root, pytest reads the root `pyproject.toml` for `[tool.pytest.ini_options]`, giving global pytest configuration. This is desirable.

**Validated** with pytest 9.0.2 across 5 experiments: `--rootdir` anchoring, symlink traversal, root config discovery, 5-level conftest chains, and graceful degradation when no conftest exists at root. All passed.

---

## Multi-Version Python

The Pythonic approach to multi-version testing is tox: same code, different interpreter, the system figures out the right wheels. rules_pythonic follows this model.

```bash
bazel test //packages/...                                  # default (3.12)
bazel test //packages/... --@rules_pythonic//pythonic:version=3.11  # alternate version
```

BUILD files don't change. A `string_flag` selects the Python version globally. The module extension generates version-aware aliases that route to the correct `pip.parse()` hub repo via `select()`. The venv rule, macros, launcher, and `install_packages.py` require zero changes — the version flows through Bazel's existing mechanisms (toolchain resolution + `select()`).

For migration (3.11 -> 3.12), individual targets can be pinned with `python_version = "3.12"`. This applies the only transition in the system — opt-in, fires only when explicitly set. `requires-python` from `pyproject.toml` is validated at build time: building with Python 3.10 against a package requiring `>=3.11` fails immediately with a clear message, not a cryptic import error minutes later.

Three levels of adoption: (1) one Python version, don't set the flag, zero overhead; (2) CI matrix runs the flag twice, tox model; (3) per-target `python_version` during version migration. Each is a strict superset. Total implementation: ~35 lines.

---

## Caching Strategy

Three layers work together:

**uv extraction cache** (within a build job). `uv pip install --target` extracts wheels into its internal cache, then hardlinks into the target directory. Overlapping packages across builds are extracted once. The cache MUST be on the same filesystem as the output — hardlinks cannot cross device boundaries. uv silently falls back to full copies on cross-device, wasting 7+ GB with no error or warning. `install_packages.py` checks `nlink > 1` after install and hard-fails if hardlinks didn't work.

**Bazel action cache** (across builds). The `PythonicInstall` action's cache key is pyproject.toml content + all wheel files from `@pypi`. Conservative — any wheel change invalidates all package directories — but acceptable because wheels change when `requirements.txt` changes (rare), and rebuilds take ~2-5s with the uv cache.

**Bazel remote cache** (across machines). TreeArtifacts are uploaded as Merkle trees. On cache hit, the action is skipped entirely. Only ~5-10 unique package directories exist across a typical project, limiting storage costs.

### Rebuild costs (measured)

| Change                    | What rebuilds                           | Time                        |
| ------------------------- | --------------------------------------- | --------------------------- |
| Edit first-party source   | Nothing (PYTHONPATH points to runfiles) | 0s                          |
| Change @pypi dep version  | All package TreeArtifacts               | ~2-4s each                  |
| Cached build (no changes) | Nothing                                 | 0s                          |
| Clean build (no uv cache) | Everything                              | ~46s (macOS) / ~17s (Linux) |

### Hermeticity trade-offs

Standard Bazel actions run in a sandbox where everything outside the declared inputs and outputs is read-only or invisible. `PythonicInstall` and `PythonicWheel` relax this: `--sandbox_writable_path` grants the action write access to the uv cache directory on the host filesystem, and uv reads from and writes to that cache during installation.

What this means in practice:

- **The uv cache is shared mutable state outside Bazel's dependency graph.** Bazel does not track its contents as an input or output. If the cache is corrupted or deleted between builds, the action re-extracts from wheels (slower but correct). If the cache is modified by a process outside Bazel, the action may produce different hardlinked output — but since wheels are content-addressed by version, this only matters if the cache is actively tampered with.
- **`sandbox_writable_path` is a local sandbox concept.** On Linux it adds a writable mount to the namespace; on macOS it adds an `(allow file-write* (subpath ...))` rule to the sandbox-exec profile. It has no effect on remote execution — the `RemoteExecutionService` does not read `SandboxOptions` at all. A remotely executed `PythonicInstall` would not have access to the host's uv cache and would need wheels provided through other means.
- **`--action_env=UV_CACHE_DIR` is resolved on the Bazel client.** `ActionEnvironment.resolve()` evaluates inherited and fixed env vars against the client's environment before the spawn is created. For remote execution, the remote worker receives the resolved value (e.g., `/home/ci/.cache/uv`), but that path may not exist on the remote machine. The action would fail with uv's "UV_CACHE_DIR not set" error or a filesystem error if the path doesn't exist remotely.
- **Remote execution requires a different strategy.** Since neither `sandbox_writable_path` nor the local uv cache are available remotely, `PythonicInstall` on RBE would need one of: (a) a pre-populated uv cache on workers at a well-known path, (b) falling back to `--link-mode=copy` with no cache, or (c) relying entirely on Bazel's remote action cache to avoid re-running the action. Option (c) is the most practical — once the `PythonicInstall` TreeArtifact is in the remote cache, the action is never re-executed and the uv cache is irrelevant.

None of these trade-offs affect correctness for local or CI builds where `UV_CACHE_DIR` and `sandbox_writable_path` are configured as documented. The relaxation is purely a performance optimization — hardlinks avoid copying gigabytes of wheel content into each TreeArtifact.

---

## Monorepo pyproject.toml Layout

A rules_pythonic monorepo has multiple `pyproject.toml` files — one per package plus a root that ties them together via a uv workspace. Understanding how these files relate to each other, to the lock file, and to Bazel's `pip.parse()` is essential.

### The basic structure

```
monorepo/
  MODULE.bazel
  pyproject.toml                    # (1) uv workspace root — NOT a Python package
  uv.lock                           # (2) single lock file for all packages
  requirements-linux.txt            # (3) per-platform requirements, checked in
  requirements-darwin.txt
  packages/
    attic/
      pyproject.toml                # (4) real package — dependencies = ["torch", "numpy"]
      src/attic/...
      BUILD.bazel
    attic-rt/
      pyproject.toml                # (5) real package — dependencies = ["numpy"]
      src/attic_rt/...
      BUILD.bazel
    search/
      pyproject.toml                # (6) real package — dependencies = ["torch", "faiss-cpu"]
      src/search/...
      BUILD.bazel
```

Each file has a distinct role:

**(1) Root `pyproject.toml` — the workspace definition.** This is NOT a Python package. It declares which directories are part of the uv workspace and optionally holds shared tool configuration:

```toml
# pyproject.toml (root)
[tool.uv.workspace]
members = ["packages/*"]

[tool.pytest.ini_options]
addopts = "-v --tb=short"

[tool.ruff]
line-length = 100
```

The `[tool.uv.workspace] members` glob tells uv "resolve all packages under `packages/` together." There is no `[project]` table — this file doesn't represent installable code.

**(4-6) Per-package `pyproject.toml` — the dependency declarations.** Each package has a standard `pyproject.toml` declaring its own dependencies (see the example in the [Rule API](#pythonic_package) section). These are real, hand-written, committed files — the same files that `uv pip install -e .` reads for local dev, that `uv build` reads to produce wheels, and that `ruff`/`mypy` read for tool config.

Note that first-party deps like `attic-rt` appear in `dependencies` alongside third-party packages like `torch`. This is standard Python — `pyproject.toml` doesn't distinguish. The distinction happens at build time: `install_packages.py` classifies each dep as either "matches a wheel from @pypi" (install it) or "matches a first-party package name" (skip it, handled via PYTHONPATH).

**(2) `uv.lock` — the resolved dependency graph.** Generated by `uv lock`. Contains exact versions for every transitive dependency across all packages in the workspace. One lock file for the entire workspace. Checked in to source control.

**(3) Per-platform requirements files — the bridge to Bazel.** Generated from the lock file and checked in:

```bash
# Generate once, check in, regenerate when deps change
uv lock
uv export --all-packages --all-extras --no-hashes --no-emit-workspace \
    -o requirements-universal.txt
uv pip compile requirements-universal.txt \
    --python-platform x86_64-unknown-linux-gnu -o requirements-linux.txt
uv pip compile requirements-universal.txt \
    --python-platform aarch64-apple-darwin -o requirements-darwin.txt
```

`uv export` produces a universal file with environment markers (e.g., `colorama==0.4.6 ; sys_platform == 'win32'`). `uv pip compile --python-platform` resolves those markers into per-platform files with no markers left — just package==version lines. These are what `pip.parse()` consumes:

```starlark
# MODULE.bazel
pip.parse(
    hub_name = "pypi",
    python_version = "3.11",
    requirements_by_platform = {
        "//:requirements-linux.txt": "linux_*",
        "//:requirements-darwin.txt": "osx_*",
    },
)
```

### How the pieces connect at build time

```
pyproject.toml (per package)
    |
    v
uv lock (per workspace — resolves all packages together)
    |
    v
uv export + uv pip compile (generates per-platform requirements)
    |
    v
requirements-*.txt (checked in)
    |
    v
pip.parse() in MODULE.bazel (downloads wheels into @pypi)
    |
    v
@pypi hub repo (select() picks right wheel per platform)
    |
    v
PythonicInstall action (receives all wheels)
    |
    v
install_packages.py (reads per-package pyproject.toml files,
                     validates dep names against wheels,
                     runs: uv pip install --target --no-deps --no-index)
```

The key insight: the per-package `pyproject.toml` is read **twice** in different contexts. uv reads it during `uv lock` to build the dependency graph. Then `install_packages.py` reads it again at Bazel build time to validate that declared dependencies are satisfiable. The requirements files are the bridge between these two worlds — they give `pip.parse()` the full transitive closure so Bazel can download everything upfront.

### First-party deps in pyproject.toml

When `attic/pyproject.toml` lists `dependencies = ["torch", "numpy", "attic-rt"]`, `install_packages.py` does three-way classification:

- `torch` — matches a wheel in `@pypi` -> install it
- `numpy` — matches a wheel in `@pypi` -> install it
- `attic-rt` — matches a first-party package name (passed via `--first-party-packages`) -> skip it

First-party packages are on PYTHONPATH via the `deps` attribute in BUILD files. They're never installed into the venv. The BUILD file only lists first-party Bazel targets; the pyproject.toml lists everything (first-party + third-party) as standard Python dependencies.

```starlark
# packages/attic/BUILD.bazel
pythonic_package(
    name = "attic",
    pyproject = "pyproject.toml",    # declares torch, numpy, attic-rt
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],  # only first-party Bazel deps
)
```

### Optional dependency groups and extras

Per-package `pyproject.toml` files declare optional dependency groups under `[project.optional-dependencies]`:

```toml
# packages/attic/pyproject.toml
[project.optional-dependencies]
test = ["pytest>=7.0", "pytest-cov"]
gpu = ["triton", "pycuda"]
dev = ["ruff", "mypy"]
```

`pythonic_test` automatically includes `[test]`. Additional groups are requested via `extras`:

```starlark
# Standard test — gets [test] extras (pytest, pytest-cov)
pythonic_test(name = "test_compiler", srcs = [...], deps = [":attic"])

# GPU test — gets [test] + [gpu] extras
pythonic_test(name = "test_gpu", srcs = [...], deps = [":attic"], extras = ["gpu"])
```

`install_packages.py` receives `--extras test gpu` and unions the deps from `[project.dependencies]` + each requested group. Overlapping deps across groups are deduplicated by normalized name.

### Scaling patterns

The basic structure covers most monorepos. Five patterns handle increasing complexity, all validated with uv 0.9.22:

| Pattern              | When to use                                                                          | Lock files | Complexity |
| -------------------- | ------------------------------------------------------------------------------------ | ---------- | ---------- |
| 1. Single product    | Default. Start here.                                                                 | 1          | Minimal    |
| 2. Platform variants | GPU/CUDA variants via `[tool.uv] conflicts`                                          | 1          | Low        |
| 3. Test folder deps  | Extra test-only packages (locust, moto) join workspace                               | 1          | Low        |
| 4. Incompatible deps | Genuine version conflicts (pydantic 2.x vs 1.x) get separate workspaces + lock files | N          | Medium     |
| 5. Combined          | Patterns 2 + 4 together (rare)                                                       | N          | High       |

Pattern 2 uses `[tool.uv] conflicts` for mutually exclusive extras (CPU vs CUDA); `uv lock` resolves each branch in one lock file, and `select()` in the `@pypi` hub repo picks the right wheel. Pattern 4 uses separate `pip.parse()` calls with different `hub_name` values. Full MODULE.bazel and BUILD examples for all five patterns are available on request.

---

## Migration Roadmap

A Bazel `constraint_setting` makes old and new rules mutually exclusive — they cannot coexist in the same build invocation. During migration, both targets live in the same BUILD file:

```starlark
# Old target — skipped when building with pythonic platform
py_library(
    name = "attic_legacy",
    target_compatible_with = ["//build_tools/python:legacy"],
    ...
)

# New target — skipped when building with legacy platform
pythonic_package(
    name = "attic",
    target_compatible_with = ["//build_tools/python:pythonic"],
    pyproject = "pyproject.toml",
    ...
)
```

```bash
bazel test //packages/... --platforms=//config:dev_pythonic  # new rules
bazel test //packages/... --platforms=//config:dev_legacy    # old rules
```

This forces bottom-up migration: a `pythonic_test` cannot depend on a legacy `py_library`. Leaf packages migrate first, then their dependents. Each phase is independently testable. Rollback = remove the pythonic platform from CI.

**Phase 0: Constraint mechanism + one leaf package.** Create the constraint setting, platform definitions, and the four core files (`pythonic_package`, `pythonic_test`, `install_packages.py`, `pythonic_pytest_runner.py`, `pythonic_run.tmpl.sh`). Add `rules_uv` to MODULE.bazel. Configure `sandbox_writable_path` on the same filesystem as output base (NOT `/tmp`). Migrate one leaf package end-to-end. Both platforms passing in CI.

**Phase 1: Leaf packages.** All packages with no first-party deps migrated. Hand-written `pyproject.toml` for each. Convert test macros. Benchmark aggregate test time between platforms.

**Phase 2: Mid-tier and top-level packages.** All packages migrated. Remove all `@pypi//` references from BUILD files. Convert to glob + list comprehension for test discovery.

**Phase 3: Delete legacy.** Remove the old rules, constraint mechanism, Rust toolchains, Gazelle config. Single platform.

Each phase is independently shippable.

---

## Validation

Every design decision was validated via prototype or benchmark before being committed to.

### Performance (macOS ARM — Python 3.11, uv 0.9.22, torch 2.10)

| Metric                                    | Value                       |
| ----------------------------------------- | --------------------------- |
| Venv creation (`uv venv`)                 | 28ms                        |
| Package install (warm cache, hardlink)    | 3.5s                        |
| Files in site-packages                    | 16,386                      |
| Apparent size                             | 431MB                       |
| Test startup (reusing cached venv)        | 0s (vs ~87ms with rules_py) |
| TreeArtifact copy (simulated remote exec) | 4.7s                        |

### Performance (Linux CUDA — Python 3.11, uv 0.10.3, torch 2.10+cu128)

| Metric                                 | Value                   |
| -------------------------------------- | ----------------------- |
| Wheels downloaded                      | 34 (4.18 GB compressed) |
| Package install (warm cache, hardlink) | 4.3s                    |
| Incremental rebuild (warm cache)       | 1.73s                   |
| Files in venv                          | 18,192                  |
| Apparent size                          | 7.42 GB                 |
| TreeArtifact copy                      | 3.72s                   |
| Tar+zstd                               | 4.76s (3.47 GB)         |
| torch import time                      | 1.35s                   |

The feared 50-100K file count didn't materialize — growth was modest (16K -> 18K). The 17x byte size increase is driven by nvidia `.so` libraries (4,589 MB), not file count. Split-venv was evaluated and rejected: torch is only 25% of bytes, splitting adds complexity, and all operations are already fast.

### Correctness

Verified across macOS ARM and Linux x86_64:

- **Imports and metadata.** Toolchain Python + PYTHONPATH imports all packages correctly. `importlib.metadata.version()` works. `__file__` points to real hardlinked files. First-party source roots shadow third-party packages as expected.
- **Namespace packages.** Work natively in flat `site-packages` (all 10 nvidia CUDA subpackages) and across multiple PYTHONPATH directories. Zero merge logic.
- **Wheel builds and platform selection.** `uv build --wheel` works from symlinked sandbox with `--no-build-isolation` and dynamic versioning. `uv` handles platform wheel filtering automatically — no Starlark `select()` needed.
- **Dep classification and scaling.** Three-way classification (wheel / first-party / missing) catches real errors. Name normalization handles case, dots, hyphens, PEP 508 extras, markers. PYTHONPATH at 10 entries = 200us/import (real projects have 5-10 roots). Extras group union works across multiple pyproject.toml files with dedup.

### Hardlink dedup

uv's `--link-mode=hardlink` silently falls back to full copies when cache and venv are on different filesystems. No error, no warning — just 7+ GB wasted per venv. This is a kernel constraint (`EXDEV`), not a uv bug. Common in containers where `/tmp` is tmpfs/overlay on a separate device.

Verified across four scenarios: same-device = 99% hardlink ratio, cross-device = 0%. Cross-venv dedup also verified: three identical venvs on the same filesystem, `nlink` climbs 2->3->4, total disk 0.28 GB instead of 0.70 GB (60% savings).

Mitigation: `UV_CACHE_DIR` and `sandbox_writable_path` must point to the same filesystem as Bazel's output base. `install_packages.py` verifies hardlinks after install and hard-fails if they didn't work.

---

## Design Trade-offs

| Alternative                        | Why not                                                                                                                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Improve the existing rules**     | The differences are architectural, not incremental: PYTHONPATH vs `.pth` files, build-time cached vs runtime-created venvs, pyproject.toml vs BUILD attributes. Can't be layered on top.                                 |
| **Switch to Pants**                | Excellent Python support, but we also build C++, MLIR dialects, and other non-Python artifacts. Switching build systems is a multi-quarter migration. rules_pythonic brings Pythonic conventions to Bazel incrementally. |
| **Support arbitrary test runners** | pytest covers ~90% of tests. The remaining 10% use `main` or `main_module` — Python scripts, not Starlark configuration. Generality would add complexity for the majority to serve the minority.                         |

---

## Risk Analysis

All 12 identified risks were prototyped or benchmarked before this doc was written. None remain as blockers. Three shaped the design:

| Risk                                          | What we learned                                                                         | Design impact                                                                                                             |
| --------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| **CUDA package scale** (feared 50-100K files) | Only 18K files, all ops < 5s                                                            | Single TreeArtifact design confirmed.                                                                                     |
| **Hardlink cross-device silent fallback**     | uv silently copies instead of hardlinking across filesystems — 7+ GB wasted, no warning | `install_packages.py` checks `nlink > 1` after install and warns. `sandbox_writable_path` must be same-fs as output base. |
| **Remote cache size**                         | 3.47 GB zstd per package dir, only ~5-10 unique dirs                                    | Acceptable. Bazel deduplicates at file level. Monitor storage costs.                                                      |

The remaining risks (namespace packages, LD_LIBRARY_PATH, PYTHONPATH scaling, platform wheel selection, sandbox wheel builds, conservative cache key, VERSION file escaping, Python < 3.11) were all verified with no design changes needed.

---

## Open Questions

All blockers were resolved via prototyping. These remain as nice-to-resolve during implementation:

1. **Venv dedup hash input.** Probably: hash of sorted dep labels + sorted extras list.
2. **Test name collisions with nested directories.** Need a naming convention like `src.replace("/", "_").removesuffix(".py")`, or adopt flat test directories as a project convention.
3. **RBE and uv cache.** Each remote machine has no shared uv cache — cold extraction per action. Slower but correct. Bazel action cache still avoids re-runs on cache hit.
4. **Circular first-party deps.** Would surface as a Bazel-level circular dependency error — caught early with a clear message.
5. **Conftest.py discovery in sandbox.** The `--rootdir` + `conftest` chain design is described in the Rule API section. All five derisking experiments passed (pytest 9.0.2). Remaining gap: experiments simulated runfiles with local symlinks rather than running inside an actual Bazel sandbox — verify with a real `bazel test` invocation during Phase 0.

---

## What Stays

- **rules_python toolchain** — hermetic interpreter management works well
- **rules_python `pip.parse()`** — wheel download mechanism is solid; we replace everything _after_ download
- **Per-platform requirements files** — pragmatic for multi-platform resolution
- **rules_uv** — new dependency for hermetic `uv` binary

## What's Deferred

**Windows support (v2).** The architecture is platform-agnostic. Windows needs a `pythonic_run.tmpl.bat` (~10 lines), `select()` for path separators (~15 lines Starlark), and CI testing. No architectural changes.

**Precompilation.** Deliberately unsupported. rules_python's 6-state precompilation matrix adds significant complexity for a feature most projects don't use. `-B` is correct for dev/test. Production deploys via `pip install` of the built wheel, which generates `.pyc` normally.

---

## Appendix: Compiled Artifacts

Packages that assemble files from multiple sources (cc_binary outputs, pre-built `.so` files, Python files from external repos) use `copy_to_directory` from `@aspect_bazel_lib` to merge everything into a single TreeArtifact with path remapping. Then `pythonic_package` wraps the assembled tree. The assembly step doesn't know it's building a Python package; the Python rule doesn't know how the files were assembled.
