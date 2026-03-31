# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

rules_pythonic is a Bazel ruleset for Python that delegates to standard Python tooling (`uv`, pytest, `pyproject.toml`) instead of reimplementing packaging in Starlark.

## Build Commands

```bash
uv run pytest pythonic/private/tests/  # Python unit tests (fast, no Bazel)
bazel test //e2e/smoke:*              # End-to-end smoke test (requires user.bazelrc)
bazel mod tidy --lockfile_mode=refresh  # Update MODULE.bazel.lock
```

E2e smoke tests run from `e2e/smoke/` which is a separate Bazel module. Requires `user.bazelrc` with `UV_CACHE_DIR` and `sandbox_writable_path` (see Consumer Setup below).

Bazel 8.6.0 is pinned in `.bazelversion`. bzlmod is enabled; there is no legacy WORKSPACE usage.

## Public API

All exported from `pythonic/defs.bzl`:

- **`pythonic_package(name, pyproject, src_root, srcs, ...)`** — Declares a Python package. Creates two targets: `:name` (source on PYTHONPATH) and `:name.wheel` (built .whl via `uv build`, tagged `manual`).
- **`pythonic_test(name, srcs, deps, ...)`** — Python test target. Runs pytest by default. Installs third-party deps via `uv pip install --target`.
- **`pythonic_binary(name, main/main_module, deps, ...)`** — Executable Python target. Exactly one of `main` or `main_module` required.
- **`pythonic_files(name, srcs, src_root)`** — Importable Python files without a pyproject.toml. Leaf node, no deps.
- **`pythonic_devenv(name, deps, wheels, constraints, extras, venv_path)`** — Creates a Python venv for IDE use. `bazel run` the target to create or update the venv. Hermetic mode (wheels provided) or resolving mode (uv resolves from PyPI).
- **`PythonicPackageInfo`** — Provider with fields: `package_name`, `src_root`, `srcs`, `pyproject`, `wheel`, `first_party_deps`.

## Architecture

Three-layer design:

1. **Source of truth**: `pyproject.toml` declares third-party deps and build backend (never BUILD files)
2. **Build time**: `install_packages.py` reads pyproject.toml, runs `uv pip install --target --hardlink` to produce a flat TreeArtifact. `build_wheel.py` stages a symlink tree and runs `uv build --wheel`.
3. **Runtime**: `pythonic_run.tmpl.sh` launcher sets PYTHONPATH (first-party src roots before third-party site-packages) and execs Python

Key files:

- `pythonic/defs.bzl` — Public API
- `pythonic/private/common.bzl` — Shared helpers: `rlocation_path`, `collect_dep_info`, `build_pythonpath`, `build_env_exports`
- `pythonic/private/package.bzl` — `pythonic_package` rule + `.wheel` sub-target
- `pythonic/private/binary.bzl` — `pythonic_binary` rule
- `pythonic/private/files.bzl` — `pythonic_files` rule
- `pythonic/private/test.bzl` — `pythonic_test` rule
- `pythonic/private/providers.bzl` — `PythonicPackageInfo` provider
- `pythonic/private/install_packages.py` — Build action: installs third-party wheels
- `pythonic/private/build_wheel.py` — Build action: delegates to `uv build --wheel`
- `pythonic/private/staging.py` — Shared utility: stages pyproject.toml + source into a symlink tree (used by wheel building and devenv)
- `pythonic/private/devenv.bzl` — `pythonic_devenv` rule
- `pythonic/private/setup_devenv.py` — Run-time action: creates venv, installs wheels and editable packages
- `pythonic/private/pythonic_pytest_runner.py` — Bridges Bazel test protocol to pytest
- `pythonic/private/pythonic_run.tmpl.sh` — Bash launcher template (shared by test and binary)
- `pythonic/private/pythonic_devenv.tmpl.sh` — Bash launcher template for devenv

## Key Design Decisions

- **First-party deps** go in BUILD `deps = [...]`; **third-party deps** go in `pyproject.toml` `[project].dependencies`
- Package names normalized per PEP 503: `[-_.]` → `-`, lowercased
- `uv` handles platform wheel selection automatically (no Starlark `select()`)
- Namespace packages work implicitly via flat site-packages
- PYTHONPATH ordering: first-party shadows third-party
- `PythonicInstall` and `PythonicWheel` pass only `UV_CACHE_DIR` via explicit `env` dict (read from `ctx.configuration.default_shell_env`), avoiding `use_default_shell_env = True` which leaks the host environment when `--incompatible_strict_action_env` is not set
- Wheel building is backend-agnostic: whatever `[build-system]` the pyproject.toml declares, `uv build` invokes it. Build backend wheels come from `@pypi` via `--no-index --find-links`.
- For assembled packages (e.g. `copy_to_directory` output), `src_prefix` tells the wheel staging script what path to strip
- External repo rlocation paths strip the `../` prefix (same pattern as rules_python and rules_cc)

## Consumer Setup

Consumers must configure their uv cache path in `.bazelrc`:

```
build --action_env=UV_CACHE_DIR=/absolute/path/to/uv/cache
build --sandbox_writable_path=/absolute/path/to/uv/cache
```

Without this, `PythonicInstall` fails with setup instructions. Both lines are needed: `action_env` passes the path to the action, `sandbox_writable_path` lets the sandbox access it. The cache must be on the same filesystem as Bazel's output base for hardlinks to work.

## Development

- Dev tooling via uv: `uv sync` installs pytest. `uv run pytest` runs unit tests.
- Pre-commit hooks: `buildifier` (Starlark formatting), `typos`, conventional commits linting. Run `pre-commit install` after cloning.
- Releases automated via conventional commits → GitHub Actions cron/manual trigger.
- To use local checkout as override: `echo "common --override_repository=rules_pythonic=$(pwd)" >> ~/.bazelrc`
- Do not use gazelle. BUILD files are maintained manually.
