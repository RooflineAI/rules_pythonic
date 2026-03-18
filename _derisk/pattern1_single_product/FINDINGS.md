# Pattern 1: Single Product, Shared Dependencies — Findings

**Validated:** 2026-02-16 | **uv:** 0.9.22 | **Python:** 3.13.5

## Results: 27/27 CHECKS PASSED

### What was tested

A single uv workspace with 3 packages (core, cli, api) sharing dependencies. Validates the complete resolution-to-export pipeline described in multi-project-patterns.md.

### uv lock
- Single `uv lock` resolves all 3 packages together (22 packages, <10ms)

### Universal export
- `uv export --all-packages --all-extras` produces a universal requirements file with environment markers (e.g., `colorama==0.4.6 ; sys_platform == 'win32'`)

### Per-platform files (uv pip compile)
- `uv pip compile --python-platform x86_64-unknown-linux-gnu` strips markers: colorama absent on linux
- `uv pip compile --python-platform aarch64-apple-darwin` strips markers: colorama absent on macOS
- All core deps (requests, pydantic, fastapi, click) present on both platforms

### Per-package export
- `--package core` isolates only core's deps (requests, pydantic) — no fastapi, no click
- `--package cli` isolates cli's deps + core's transitives — no fastapi
- `--no-emit-workspace` correctly excludes first-party names from output

### Version consistency
- pydantic and requests versions identical across universal, per-package, and per-platform exports

## README fix needed

**`uv export` does NOT support `--python-platform`.**

The readme shows:
```bash
uv export --all-extras --python-platform x86_64-linux -o requirements-linux.txt
```

This flag does not exist on `uv export`. Two working alternatives:

1. **Universal export + markers** — `uv export` (universal) → `pip.parse()` handles markers via `select()`
2. **Two-step per-platform** — `uv export` → `uv pip compile --python-platform` → platform-specific files

Both achieve the goal. The readme's resolution commands need updating.
