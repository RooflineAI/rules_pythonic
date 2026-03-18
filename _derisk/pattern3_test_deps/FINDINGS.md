# Pattern 3: Test Folders with Their Own Dependency Declarations

## Prototype validated with uv 0.9.22 on 2026-02-16

---

## Goal

Validate that test folders (integration-tests, load-tests) can declare their own
dependencies via minimal `pyproject.toml` files and participate in uv workspace
resolution -- without polluting production dependency exports.

---

## Directory Structure

```
pattern3_test_deps/
  pyproject.toml                    # workspace root
  packages/
    core/
      pyproject.toml                # [project] name="core", deps=["requests"]
      src/core/__init__.py
  integration-tests/
    pyproject.toml                  # [project] name="integration-tests", deps=["httpx","respx"]
    tests/test_integration.py
  load-tests/
    pyproject.toml                  # [project] stub + [dependency-groups] test=["locust"]
    tests/test_load.py
```

---

## Finding 1: Minimal `[project]` pyproject.toml works as a workspace member

**VALIDATED.** A pyproject.toml with just `[project]` name + dependencies (no
version, no build-system, no src layout) works perfectly as a uv workspace member.

In the lock file, such members appear with `source = { virtual = "..." }` rather
than `source = { editable = "..." }`, which is correct -- they are not installable
packages, just dependency containers.

Lock file entries:
- `core`: `source = { editable = "packages/core" }` (real package with build-system)
- `integration-tests`: `source = { virtual = "integration-tests" }` (virtual member)
- `load-tests`: `source = { virtual = "load-tests" }` (virtual member)

---

## Finding 2: PEP 735 `[dependency-groups]` alone does NOT work as a workspace member

**FAILED without workaround.** A pyproject.toml with ONLY `[dependency-groups]` and
no `[project]` table causes `uv lock` to fail:

```
error: No `project` table found in: .../load-tests/pyproject.toml
```

### Workaround

Add a minimal `[project]` stub alongside the `[dependency-groups]`:

```toml
[project]
name = "load-tests"
version = "0.0.0"
requires-python = ">=3.12"

[dependency-groups]
test = ["locust"]
```

With this workaround, `uv lock` succeeds and the dependency group is correctly
tracked in the lock file under `[package.dev-dependencies]`.

---

## Finding 3: Test-only deps appear in lock file without polluting production exports

**VALIDATED.** The `uv export` command provides fine-grained control:

### Export everything (all packages, all groups):
```bash
uv export --all-packages --all-extras --all-groups --no-hashes --no-emit-workspace
```
Result: requests, httpx, respx, locust + all transitive deps (50 packages total).

### Export production only (no dev groups):
```bash
uv export --all-packages --all-extras --no-dev --no-hashes --no-emit-workspace
```
Result: requests, httpx, respx + transitive deps. **locust excluded.**

**Important nuance:** httpx and respx still appear because they are in
`[project].dependencies` of integration-tests, NOT in a dependency-group.
To make them excludable with `--no-dev`, they should be in `[dependency-groups]`
instead.

### Export only a specific package's production deps:
```bash
uv export --package core --no-dev --no-hashes --no-emit-workspace
```
Result: Only requests + transitive deps (certifi, charset-normalizer, idna, urllib3).
**Cleanest production export.**

### Export only a specific dependency group:
```bash
uv export --all-packages --only-group test --no-hashes --no-emit-workspace
```
Result: Only locust + transitive deps.

---

## Finding 4: `[project].dependencies` vs `[dependency-groups]` -- key difference

| Approach | Where deps declared | Appears with `--no-dev`? | Appears with `--only-group test`? |
|---|---|---|---|
| integration-tests | `[project].dependencies` | YES (always included) | NO |
| load-tests | `[dependency-groups].test` | NO (excluded) | YES |

**Recommendation:** For test-only deps that should NEVER appear in production exports,
use `[dependency-groups]` (PEP 735). For deps that are fine to include broadly, use
`[project].dependencies`.

---

## Finding 5: Workspace members are correctly excluded from exports

With `--no-emit-workspace`, the workspace member names (core, integration-tests,
load-tests, pattern3-workspace-root) do NOT appear in requirements.txt. Only their
transitive third-party dependencies appear.

---

## Summary of Validated Patterns

| Pattern | Works? | Notes |
|---|---|---|
| Minimal `[project]`-only pyproject.toml as workspace member | YES | Tracked as `virtual` source in lock file |
| `[dependency-groups]`-only pyproject.toml (no `[project]`) | NO | Requires `[project]` stub as workaround |
| `[dependency-groups]` alongside `[project]` stub | YES | Deps tracked under `[package.dev-dependencies]` |
| Selective export with `--no-dev` | YES | Excludes `[dependency-groups]` but keeps `[project].dependencies` |
| Selective export with `--only-group <name>` | YES | Exports only that group's deps |
| Selective export with `--package <name>` | YES | Exports only that package's dep tree |
| `--no-emit-workspace` excludes workspace members | YES | Only third-party deps in output |

---

## Recommended Pattern for Test Folders

```toml
# integration-tests/pyproject.toml
[project]
name = "integration-tests"
version = "0.0.0"
requires-python = ">=3.12"

[dependency-groups]
test = ["httpx", "respx", "pytest"]
```

This puts ALL test deps in `[dependency-groups]` so they can be cleanly excluded from
production exports via `--no-dev`, while the `[project]` stub satisfies uv's workspace
membership requirement.
