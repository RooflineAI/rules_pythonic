# Pattern 4: Incompatible Dependencies Resolved Separately

## Objective

Validate that two separate uv workspaces in the same repository can resolve independently, pinning different versions of the same package (pydantic), and that a shared library can participate in both resolutions.

## Setup

```
pattern4_incompatible/
  main/                             # uv workspace for modern product
    pyproject.toml                  # [tool.uv.workspace] members = ["packages/*", "../shared/core"]
    packages/
      core/pyproject.toml           # dependencies = ["pydantic>=2.0"]
      search/pyproject.toml         # dependencies = ["core", "pydantic>=2.0", "httpx"]
  legacy/                           # separate uv workspace for legacy product
    pyproject.toml                  # [tool.uv.workspace] members = ["packages/*", "../shared/core"]
    packages/
      pipeline/pyproject.toml       # dependencies = ["pydantic<2.0", "requests"]
  shared/
    core/pyproject.toml             # dependencies = ["pydantic"]  (no version pin)
```

## Results

### Finding 1: Separate workspaces resolve independently -- CONFIRMED

Running `uv lock` in `main/` and `legacy/` produces completely independent lockfiles:

- `main/uv.lock`: resolves **pydantic 2.12.5** (+ pydantic-core, annotated-types, typing-inspection)
- `legacy/uv.lock`: resolves **pydantic 1.10.26** (no pydantic-core needed)

These are fundamentally incompatible dependency trees (pydantic v1 vs v2) that cannot coexist in a single resolution. Separate workspaces handle this cleanly.

### Finding 2: Exported requirements have different pinned versions -- CONFIRMED

- `main/requirements.txt`: `pydantic==2.12.5`
- `legacy/requirements.txt`: `pydantic==1.10.26`

Each requirements file is self-consistent and installable. The `--all-packages` flag is needed to include workspace member dependencies in the export.

### Finding 3: Shared library works as workspace member in BOTH workspaces -- CONFIRMED

**This was the most surprising finding.** Despite the uv documentation suggesting workspace members must be within the workspace root, `uv` (v0.9.22) successfully resolves workspace members at relative paths outside the workspace root (e.g., `"../shared/core"`).

The `shared/core` package declares `dependencies = ["pydantic"]` with **no version constraint**. When included as a workspace member:

- In `main/`: shared-core's pydantic resolves to **2.12.5** (constrained by core and search requiring `>=2.0`)
- In `legacy/`: shared-core's pydantic resolves to **1.10.26** (constrained by pipeline requiring `<2.0`)

This means the same source code directory participates in two different lockfile resolutions with different dependency versions.

### Finding 4: No lockfile conflicts between workspaces

Each workspace has its own `uv.lock` file. There is no cross-contamination:

- `main/uv.lock` knows nothing about the legacy workspace
- `legacy/uv.lock` knows nothing about the main workspace
- The `shared/core` directory has no lockfile of its own; it inherits the resolution from whichever workspace references it

### Finding 5: Resolution is fast

Both `uv lock` operations completed in under 400ms, even with network resolution of new packages.

## Key Takeaway

**Pattern 4 is fully validated.** For repositories with products that have incompatible dependency requirements:

1. Create a separate `pyproject.toml` workspace root per product.
2. Each workspace gets its own `uv.lock` with independent dependency resolution.
3. Shared libraries can be included as workspace members in multiple workspaces using relative paths (`../shared/lib`), even outside the workspace root directory.
4. A shared library declaring loose version constraints (e.g., `"pydantic"` with no pin) will inherit the appropriate version from each workspace's resolution.
5. Use `uv export --all-packages` to generate per-workspace requirements files for deployment.

## Commands Used

```bash
# Lock each workspace independently
uv lock --directory main/
uv lock --directory legacy/

# Export pinned requirements
uv export --all-extras --no-hashes --all-packages --directory main/ -o main/requirements.txt
uv export --all-extras --no-hashes --all-packages --directory legacy/ -o legacy/requirements.txt
```

## Environment

- uv 0.9.22 (Homebrew 2026-01-06)
- Python 3.13.5
- macOS (Darwin 25.2.0, arm64)
