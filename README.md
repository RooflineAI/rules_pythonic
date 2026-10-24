# rules_pythonic

Bazel rules for Python that delegate to `uv` and `pyproject.toml` instead of
reimplementing packaging in Starlark.

Python packaging has grown increasingly capable — `uv` handles platform wheel
selection, dependency resolution, and installation faster than any prior tool.
Meanwhile, `pyproject.toml` has become the universal standard for declaring
project metadata and dependencies. The existing Bazel Python ecosystem
(rules_python, rules_py, rules_pycross) predates these developments and
necessarily reimplemented much of this functionality in Starlark and Rust.

rules_pythonic builds on their foundation but takes a different approach:
use standard Python tooling directly. Third-party dependencies stay in
`pyproject.toml` where every Python tool already knows how to find them.
`uv` handles installation and wheel building as Bazel actions. BUILD files
declare only first-party relationships. A Python developer who has never
used Bazel can read a rules_pythonic BUILD file and understand what it does.

## What it looks like

```starlark
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_devenv", "pythonic_package", "pythonic_test")

pythonic_package(
    name = "mypackage",
    pyproject = "pyproject.toml",
    src_root = "src",
    srcs = glob(["src/**/*.py"]),
    deps = [":other_package"],
)

# Fast iteration: source directly on PYTHONPATH
pythonic_test(
    name = "test_greeting",
    srcs = ["tests/test_greeting.py"],
    deps = [":mypackage"],
)

# Artifact testing: install the built .whl, catch packaging bugs before deploy
pythonic_test(
    name = "test_greeting_wheel",
    srcs = ["tests/test_greeting.py"],
    deps = [":mypackage.wheel"],
)

# IDE dev environment: `bazel run //:ide` creates a venv with all deps
pythonic_devenv(
    name = "ide",
    deps = [":mypackage"],
    wheels = ["//:all_wheels"],
)
```

Third-party deps (`six`, `torch`, `pytest`) go in `pyproject.toml`.
First-party deps (your own packages) go in BUILD `deps`. `uv` handles
wheel installation and platform selection at build time. There is no
Starlark reimplementation of packaging.

The [e2e/smoke](e2e/smoke/) directory is a complete working example you can
clone and run.

## How it works

Five rules, one provider:

- **`pythonic_package`** — declares a Python package. Creates `:name` (source
  on PYTHONPATH) and `:name.wheel` (built `.whl` via `uv build`).
- **`pythonic_test`** — runs pytest by default. Override with `main` or
  `main_module`.
- **`pythonic_binary`** — executable target. Exactly one of `main` or
  `main_module` required.
- **`pythonic_files`** — importable Python files without a `pyproject.toml`.
  Leaf node, no third-party deps.
- **`pythonic_devenv`** — creates a Python venv for IDE completion and type
  checking. `bazel run` the target to create or update the venv.
- **`PythonicPackageInfo`** — provider with `package_name`, `src_root`, `srcs`,
  `pyproject`, `wheel`, `first_party_deps`.

All loaded from `@rules_pythonic//pythonic:defs.bzl`.

See [docs/DESIGN.md](docs/DESIGN.md) for the full rationale and
[docs/TECHNICAL_REFERENCE.md](docs/TECHNICAL_REFERENCE.md) for attribute
details.

## Dependency model

Third-party dependencies flow through two layers:

1. **`pyproject.toml`** declares _what_ each package needs (`[project].dependencies`
   and `[project.optional-dependencies]`).
2. **`requirements.txt`** pins _which versions_ get installed. It is fed to
   `pip.parse()` in `MODULE.bazel`, which creates the `@pypi` hub repo containing
   pre-resolved, platform-specific wheels.

At build time, `install_packages.py` runs `uv pip install --no-deps --no-index` —
it installs only what is already in `@pypi`, never contacts PyPI, and never
resolves versions. The `pyproject.toml` entries are used only for **validation**:
every declared dependency must exist either as a wheel in `@pypi` or as a
first-party dep in `BUILD`.

When these two layers diverge:

- A dependency in `pyproject.toml` but not in `requirements.txt` fails the build
  with a clear error.
- A dependency in `requirements.txt` but not in `pyproject.toml` is silently
  installed (all `@pypi` wheels are available to the action).

To add a new third-party dependency: add it to `pyproject.toml`, then
regenerate the lockfile (e.g. `uv pip compile --all-packages -o requirements.txt`).
Bazel picks up the change on next build — `pip.parse` re-evaluates the
repo rule when `requirements.txt` changes.

## Compared with other rulesets

Every Bazel Python ruleset answers the same four questions: where the lock
comes from, where a target declares its third-party deps, who installs the
wheels, and what the interpreter sees at run time. Status as of October 2026.

|                              | rules_python                                                  | aspect_rules_py 1.x                          | aspect_rules_py 2.0 `//uv`                        | rules_pycross                                                                          | rules_uv                                        | rules_pythonic                                                                         |
| ---------------------------- | ------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------- |
| Version                      | 2.4.5                                                         | 1.13.0                                       | 2.0.0-alpha.10                                    | 2.0.1                                                                                  | 0.89.2 (Dec 2025)                               | 0.0.2                                                                                  |
| Scope                        | Toolchains, `pip.parse`, `py_*` rules                         | `py_*` and venvs on top of rules_python deps | `pip.parse` replacement plus `py_*`               | Third-party deps only (`pycross_wheel_library`)                                        | Lock and venv helpers only                      | `py_*` equivalents plus an install layer on top of `pip.parse`                         |
| Lock input                   | `requirements.txt`; `uv.lock` via `lockfiles` since 2.4       | Inherited from rules_python                  | `uv.lock`                                         | uv, PDM, Poetry, `pylock.toml`                                                         | Writes `requirements.txt` with `uv pip compile` | `requirements.txt` through `pip.parse`, validated against `pyproject.toml`             |
| Third-party deps declared in | BUILD (`@pypi//pkg`)                                          | BUILD                                        | BUILD, PEP 735 dependency groups                  | BUILD                                                                                  | n/a                                             | `pyproject.toml` only                                                                  |
| Wheel fetch and install      | One repository rule per wheel                                 | Inherited                                    | Bazel downloader, lazy `whl_install` build action | `http_file` plus build action                                                          | n/a                                             | `pip.parse` repos, then `uv pip install --target` into one flat TreeArtifact           |
| sdist builds                 | Repository time, not hermetic                                 | Inherited                                    | Build action with hermetic toolchains             | Build action: setuptools, meson, cmake, maturin, PEP 517                               | None                                            | None, wheels from `@pypi` only                                                         |
| Run-time layout              | venv by default since 2.0, else runfiles and `PyInfo.imports` | venv assembled at run time by a Rust tool    | venv built at build time                          | `py_library` consumed by rules_python                                                  | venv for IDE use                                | `PYTHONPATH` with first-party roots before one flat package dir, no venv               |
| Cross-build                  | Per-platform requirements files and `select()`                | Inherited                                    | `--platforms`, libc and version flags             | `@platforms` constraints mapped to PEP 508 markers, uv conflicts for torch CPU vs CUDA | One `pip_compile` per platform                  | Host platform only                                                                     |
| Remote execution             | Yes                                                           | Yes                                          | Yes                                               | Yes                                                                                    | n/a                                             | Install action is `no-remote-exec`, needs a writable uv cache on the output filesystem |
| Namespace packages           | Shims generated by `pip.parse`                                | Merge at venv creation                       | venv                                              | venv or `.pth`                                                                         | n/a                                             | Flat directory, PEP 420                                                                |

rules_pythonic shares the thesis of `aspect_rules_py//uv` (let uv decide) but
applies it one layer lower: uv runs at install time inside a build action,
not at lock time inside a module extension. That keeps the rules small and
BUILD files readable, and it costs cross-builds, sdists and remote execution
of the install step. Pick `//uv` or rules_pycross when those matter; pick
rules_pythonic when the host-only, wheels-only case is the whole problem.

## Setup

Requires Bazel 8+. Add to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_pythonic", version = "0.0.2")
bazel_dep(name = "rules_python", version = "1.9.0")

python = use_extension("@rules_python//python/extensions:python.bzl", "python")
python.toolchain(python_version = "3.11")

pip = use_extension("@rules_python//python/extensions:pip.bzl", "pip")
pip.parse(
    hub_name = "pypi",
    python_version = "3.11",
    requirements_lock = "//:requirements.txt",
)
use_repo(pip, "pypi")
```

Add the wheel filegroup to your root `BUILD`:

```starlark
load("@pypi//:requirements.bzl", "all_whl_requirements")

filegroup(
    name = "all_wheels",
    srcs = all_whl_requirements,
    visibility = ["//visibility:public"],
)
```

Configure your uv cache in `.bazelrc` (both lines required):

```
build --action_env=UV_CACHE_DIR=/absolute/path/to/uv/cache
build --sandbox_writable_path=/absolute/path/to/uv/cache
```

The cache must be on the same filesystem as Bazel's output base so `uv` can
hardlink wheels instead of copying them. Without this, the build fails with
setup instructions.

## License

Apache 2.0
