# Multi-project patterns with roof_py

How to structure Python projects in Bazel depending on your dependency landscape. Each pattern shows a project layout, when to use it, and the full configuration from resolution to build.

---

## Pattern 1: Single product, shared dependencies

### When to use this

- One team, one product (or tightly coupled products)
- All packages can agree on dependency versions
- One deployment target (or multiple platforms with the same package versions)

This is the default. Start here. Move to a more complex pattern only when forced.

### Project layout

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
    attic-rt/
      pyproject.toml                # dependencies = ["numpy"]
      src/attic_rt/...
      BUILD.bazel
    search/
      pyproject.toml                # dependencies = ["torch", "faiss-cpu"]
      src/search/...
      BUILD.bazel
```

### uv workspace

```toml
# pyproject.toml (root)
[tool.uv.workspace]
members = ["packages/*"]
```

### Resolution

```bash
uv lock

# Universal export (includes environment markers like ; sys_platform == 'win32')
uv export --all-packages --all-extras --no-hashes --no-emit-workspace -o requirements-universal.txt

# Per-platform files (markers resolved, platform-only deps filtered)
uv pip compile requirements-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux.txt
uv pip compile requirements-universal.txt --python-platform aarch64-apple-darwin -o requirements-darwin.txt
```

One `uv lock`. All packages resolved together. `uv export` produces a universal file with environment markers; `uv pip compile --python-platform` resolves those markers into per-platform files. Alternatively, skip the compile step and let `pip.parse()` handle markers directly from the universal export.

### MODULE.bazel

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

### BUILD files

```starlark
# packages/attic/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_package", "roof_py_test")

roof_py_package(
    name = "attic",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/attic-rt:attic-rt"],
)

[roof_py_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":attic"],
) for src in glob(["tests/test_*.py"])]
```

No platform awareness in BUILD files. No flags. `@pypi` handles platform selection internally via `select()`.

---

## Pattern 2: Single product, platform variants (GPU/CUDA)

### When to use this

- Same product deployed to different hardware configurations
- Some configurations need different package builds (CUDA 11 vs CUDA 12) or additional packages (triton, pycuda)
- The variants are mutually exclusive at deployment time (a server runs CUDA 12 OR CUDA 11, never both)

### Project layout

```
monorepo/
  MODULE.bazel
  pyproject.toml                    # uv workspace root
  uv.lock
  requirements-linux-cpu.txt
  requirements-linux-cuda12.txt
  requirements-darwin.txt
  config/
    BUILD.bazel                     # platform definitions
  packages/
    trainer/
      pyproject.toml                # see below
      src/trainer/...
      BUILD.bazel
    inference/
      pyproject.toml
      src/inference/...
      BUILD.bazel
```

### pyproject.toml with conflicting extras

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

The `[tool.uv] conflicts` declaration tells uv that `cpu` and `cuda12` are mutually exclusive. `uv lock` resolves each branch separately within one lock file.

### Resolution

```bash
uv lock

# Export per-variant (universal, with markers)
uv export --package trainer --extra cpu --no-hashes --no-emit-workspace -o requirements-cpu-universal.txt
uv export --package trainer --extra cuda12 --no-hashes --no-emit-workspace -o requirements-cuda12-universal.txt

# Compile to per-platform files (markers resolved)
uv pip compile requirements-cpu-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cpu.txt
uv pip compile requirements-cuda12-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cuda12.txt
uv pip compile requirements-cpu-universal.txt --python-platform aarch64-apple-darwin -o requirements-darwin.txt
```

One `uv lock`, per-variant exports, then per-platform compile. The lock file holds all branches. As with Pattern 1, the compile step is optional if `pip.parse()` handles markers directly.

### Bazel platform definitions

```starlark
# config/BUILD.bazel
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")

string_flag(
    name = "accelerator",
    build_setting_default = "cpu",
)

config_setting(
    name = "is_cuda12",
    flag_values = {":accelerator": "cuda12"},
)
```

### MODULE.bazel

```starlark
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")

# Register CUDA 12 as a custom platform dimension
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

use_repo(pip, "pypi")
```

### BUILD files

```starlark
# packages/trainer/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_package", "roof_py_test")

roof_py_package(
    name = "trainer",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
)

[roof_py_test(
    name = src.removesuffix(".py"),
    srcs = [src],
    deps = [":trainer"],
) for src in glob(["tests/test_*.py"])]
```

BUILD files are identical to Pattern 1. No platform awareness. The `@pypi` hub repo's `select()` picks the right torch wheel based on the flag.

### Building

```bash
bazel test //packages/trainer/...                              # CPU (default)
bazel test //packages/trainer/... --//config:accelerator=cuda12  # CUDA 12
```

---

## Pattern 3: Multiple products, additional test dependencies

### When to use this

- Multiple products or test suites in one repo
- Products share the same core dependency versions (no conflicts)
- Some test suites need extra packages (load testing tools, mock services, contract testing) that don't belong in any production package

### Project layout

```
monorepo/
  MODULE.bazel
  pyproject.toml                    # uv workspace root
  uv.lock
  requirements-linux.txt
  requirements-darwin.txt
  packages/
    core/
      pyproject.toml                # dependencies = ["numpy", "pydantic"]
      src/core/...
      BUILD.bazel
    api/
      pyproject.toml                # dependencies = ["core", "fastapi"]
      src/api/...
      BUILD.bazel
  integration-tests/
    pyproject.toml                  # test-only deps: locust, moto, httpx
    tests/
      test_load.py
      test_s3.py
      BUILD.bazel
  contract-tests/
    pyproject.toml                  # test-only deps: schemathesis
    tests/
      test_api_contract.py
      BUILD.bazel
```

### Test folder pyproject.toml (minimal, not a real package)

Using `[dependency-groups]` (recommended — deps are excludable from production exports via `--no-dev`):

```toml
# integration-tests/pyproject.toml
[project]
name = "integration-tests"
version = "0.0.0"
requires-python = ">=3.11"

[dependency-groups]
test = ["locust", "moto", "httpx"]
```

The `[project]` stub is required — uv workspace members must have a `[project]` table. A bare `[dependency-groups]`-only file will fail with `error: No project table found`.

Alternatively, deps can go in `[project].dependencies` directly, but note that `uv export --no-dev` will NOT exclude them (only `[dependency-groups]` deps are excluded by `--no-dev`):

```toml
# integration-tests/pyproject.toml
[project]
name = "integration-tests"
version = "0.0.0"
requires-python = ">=3.11"
dependencies = ["locust", "moto", "httpx"]
```

### uv workspace

```toml
# pyproject.toml (root)
[tool.uv.workspace]
members = ["packages/*", "integration-tests", "contract-tests"]
```

All test folders participate in resolution. Their deps are in the lock file alongside production deps.

### Resolution

Same as Pattern 1 — one `uv lock`, exports per platform. The test-only packages (locust, moto) are in the superset requirements file. They're only installed in venvs that need them.

### BUILD files

```starlark
# integration-tests/tests/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_test")

roof_py_test(
    name = "test_load",
    srcs = ["test_load.py"],
    pyproject = "//integration-tests:pyproject.toml",
    deps = ["//packages/api"],
)

roof_py_test(
    name = "test_s3",
    srcs = ["test_s3.py"],
    pyproject = "//integration-tests:pyproject.toml",
    deps = ["//packages/core"],
)
```

The test target's `pyproject` attribute adds locust and moto to the venv alongside core's and api's deps. `install_venv.py` unions all pyproject.toml files.

Packages that don't need the extra test deps are unaffected:

```starlark
# packages/core/BUILD.bazel — no integration test deps here
roof_py_test(
    name = "test_core",
    srcs = ["tests/test_core.py"],
    deps = [":core"],
)
```

---

## Pattern 4: Multiple products, incompatible dependencies

### When to use this

- Multiple products in one repo that are deployed independently
- Products need genuinely different versions of the same package (numpy 1.x vs 2.x, different torch builds on the same platform)
- Alignment has been attempted and is not feasible (e.g., a legacy product can't upgrade)

This is the escape hatch. It adds real maintenance cost (multiple lock files, multiple resolutions). Only use it when version conflicts are genuine and unavoidable.

### Project layout

```
monorepo/
  MODULE.bazel
  pyproject.toml                    # uv workspace for the main product line
  uv.lock
  requirements-linux.txt
  requirements-darwin.txt
  packages/
    core/
      pyproject.toml                # dependencies = ["numpy>=2.0"]
      src/core/...
    search/
      pyproject.toml                # dependencies = ["core", "torch>=2.1"]
      src/search/...
  legacy/
    pyproject.toml                  # separate uv workspace root
    uv.lock                         # separate lock file
    requirements-linux.txt          # separate requirements
    packages/
      pipeline/
        pyproject.toml              # dependencies = ["numpy<2.0", "torch==1.13"]
        src/pipeline/...
```

### Two uv workspaces

```toml
# pyproject.toml (root — main product)
[tool.uv.workspace]
members = ["packages/*"]
```

```toml
# legacy/pyproject.toml (legacy product)
[tool.uv.workspace]
members = ["packages/*"]
```

### Resolution

```bash
# Main product
uv lock
uv export --all-packages --all-extras --no-hashes --no-emit-workspace -o requirements-universal.txt
uv pip compile requirements-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux.txt

# Legacy product (separate resolution)
cd legacy
uv lock
uv export --all-packages --all-extras --no-hashes --no-emit-workspace -o requirements-universal.txt
uv pip compile requirements-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux.txt
```

Two lock files. Two independent resolutions. numpy 2.x in main, numpy 1.x in legacy. As with Pattern 1, the `pip compile` step is optional if `pip.parse()` handles markers directly.

### MODULE.bazel

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

pip.parse(
    hub_name = "pypi_legacy",
    python_version = "3.11",
    requirements_by_platform = {
        "//legacy:requirements-linux.txt": "linux_*",
    },
)

use_repo(pip, "pypi", "pypi_legacy")
```

### BUILD files

Main product — unchanged, uses default `@pypi`:

```starlark
# packages/search/BUILD.bazel
roof_py_package(
    name = "search",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = ["//packages/core"],
)
```

Legacy product — specifies a different wheel source:

```starlark
# legacy/packages/pipeline/BUILD.bazel
roof_py_package(
    name = "pipeline",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
)

roof_py_test(
    name = "test_pipeline",
    srcs = glob(["tests/test_*.py"]),
    deps = [":pipeline"],
    pypi = "@pypi_legacy",
)
```

The `pypi` attribute on the test target points to the legacy wheel pool. Only targets that need the legacy resolve specify it. Everything else uses the default.

### Shared libraries between products

If `core` is used by both main and legacy, it must work with both numpy versions. Test it against both:

```starlark
# packages/core/BUILD.bazel
roof_py_test(
    name = "test_core",
    srcs = glob(["tests/test_*.py"]),
    deps = [":core"],
    # tested against main resolve (numpy 2.x)
)

roof_py_test(
    name = "test_core_legacy",
    srcs = glob(["tests/test_*.py"]),
    deps = [":core"],
    pypi = "@pypi_legacy",
    # tested against legacy resolve (numpy 1.x)
)
```

---

## Pattern 5: Combining platform variants with multiple products

### When to use this

- Multiple products with different platform targets AND different dependency versions
- Example: main product runs on Linux with CUDA 12, legacy runs on Linux with CUDA 11, both develop on macOS

This combines Pattern 2 (custom platforms) with Pattern 4 (separate resolves).

### Project layout

```
monorepo/
  MODULE.bazel
  pyproject.toml
  uv.lock
  requirements-linux-cuda12.txt
  requirements-darwin.txt
  config/
    BUILD.bazel
  packages/
    trainer/
      pyproject.toml
      src/trainer/...
  legacy/
    pyproject.toml
    uv.lock
    requirements-linux-cuda11.txt
    packages/
      old-model/
        pyproject.toml
        src/old_model/...
```

### Resolution

```bash
# Main product
uv lock
uv export --all-packages --extra cuda12 --no-hashes --no-emit-workspace -o requirements-cuda12-universal.txt
uv export --all-packages --extra cpu --no-hashes --no-emit-workspace -o requirements-cpu-universal.txt
uv pip compile requirements-cuda12-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cuda12.txt
uv pip compile requirements-cpu-universal.txt --python-platform aarch64-apple-darwin -o requirements-darwin.txt

# Legacy product
cd legacy
uv lock
uv export --all-packages --extra cuda11 --no-hashes --no-emit-workspace -o requirements-cuda11-universal.txt
uv pip compile requirements-cuda11-universal.txt --python-platform x86_64-unknown-linux-gnu -o requirements-linux-cuda11.txt
```

### MODULE.bazel

```starlark
pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")

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
        "//:requirements-linux-cuda12.txt": "linux_x86_64_cuda12",
        "//:requirements-darwin.txt": "osx_*",
    },
)

pip.default(
    platform = "linux_x86_64_cuda11",
    os_name = "linux",
    arch_name = "x86_64",
    config_settings = ["@//config:is_cuda11"],
)

pip.parse(
    hub_name = "pypi_legacy",
    python_version = "3.11",
    requirements_by_platform = {
        "//legacy:requirements-linux-cuda11.txt": "linux_x86_64_cuda11",
    },
)

use_repo(pip, "pypi", "pypi_legacy")
```

### Building

```bash
# Main product, CUDA 12
bazel test //packages/trainer/... --//config:accelerator=cuda12

# Legacy product, CUDA 11
bazel test //legacy/... --//config:accelerator=cuda11
```

---

## Summary: choosing a pattern

| Pattern | Products | Dep conflicts | Platform variants | Lock files | Complexity |
|---------|----------|---------------|-------------------|------------|------------|
| 1. Single product | 1 | None | OS/arch only | 1 | Minimal |
| 2. Platform variants | 1 | Platform-only (same pkg, different builds) | GPU/CUDA/custom | 1 | Low |
| 3. Additional test deps | Multiple test suites | None (additive only) | Any | 1 | Low |
| 4. Incompatible products | Multiple | Genuine version conflicts | Any | N (one per product) | Medium |
| 5. Combined | Multiple | Conflicts + platform variants | Custom per product | N | High |

**Start with Pattern 1.** Move to Pattern 2 when you need GPU/CUDA variants. Use Pattern 3 freely for test-only deps. Only reach for Pattern 4 when you've confirmed that version alignment is truly impossible. Pattern 5 is rare — most repos never need it.

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
roof_py _roof_py_venv (receives wheels, builds venv — platform-unaware)
    |
    v
install_venv.py (matches pyproject.toml names against wheels — platform-unaware)
```

roof_py itself is the same in every pattern. The complexity lives in the resolution layer (uv) and the platform layer (pip.parse + pip.default). These are independent of roof_py and would apply to any Python-in-Bazel approach.
