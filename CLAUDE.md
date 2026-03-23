# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

rules_pythonic is a Bazel ruleset for Python that replaces ~7,000 lines of Starlark+Rust (rules_python, rules_py, rules_pycross) with ~665 lines. It delegates to standard Python tooling (`uv`, pytest, `pyproject.toml`) instead of reimplementing packaging in Starlark.

## Build Commands

```bash
bazel test //pythonic/tests:*         # Starlark unit tests
bazel test //e2e/smoke:*              # End-to-end smoke test
bazel run //:gazelle                  # Regenerate bzl_library targets
bazel mod tidy --lockfile_mode=refresh  # Update MODULE.bazel.lock
```

Bazel 8.6.0 is pinned in `.bazelversion`. bzlmod is enabled; there is no legacy WORKSPACE usage.

## Architecture

Three-layer design:

1. **Source of truth**: `pyproject.toml` declares third-party deps (never BUILD files)
2. **Build time**: `install_packages.py` reads pyproject.toml via tomllib, matches deps against pre-downloaded wheels, runs `uv pip install --target --hardlink` to produce a flat TreeArtifact
3. **Runtime**: `pythonic_run.tmpl.sh` launcher sets PYTHONPATH (first-party src roots before third-party site-packages) and execs Python

Key files:
- `pythonic/defs.bzl` — Public API (exports `pythonic_package`, `pythonic_test`, `PythonicPackageInfo`)
- `pythonic/private/package.bzl` — `pythonic_package` rule: declares packages, builds transitive dep closure
- `pythonic/private/test.bzl` — `pythonic_test` rule+macro: orchestrates install, builds launcher, runs tests
- `pythonic/private/providers.bzl` — `PythonicPackageInfo` provider (src_root, srcs, pyproject, wheel, first_party_deps)
- `pythonic/private/install_packages.py` — Build action: reads pyproject.toml, runs uv
- `pythonic/private/pythonic_pytest_runner.py` — Bridges Bazel test protocol to pytest
- `pythonic/private/pythonic_run.tmpl.sh` — Bash launcher template

## Key Design Decisions

- **First-party deps** go in BUILD `deps = [...]`; **third-party deps** go in `pyproject.toml` `[project].dependencies`
- Package names normalized per PEP 503: `[-_.]` → `-`, lowercased
- `uv` handles platform wheel selection automatically (no Starlark `select()`)
- Namespace packages work implicitly via flat site-packages
- PYTHONPATH ordering: first-party shadows third-party

## Development

- Pre-commit hooks: `buildifier` (Starlark formatting), `typos`, conventional commits linting. Run `pre-commit install` after cloning.
- Releases automated via conventional commits → GitHub Actions cron/manual trigger.
- To use local checkout as override: `echo "common --override_repository=rules_pythonic=$(pwd)" >> ~/.bazelrc`
