# Pattern 2: Platform Variants via Conflicting Extras — Findings

**Validated:** 2026-02-16 | **uv:** 0.9.22 | **Python:** 3.13.5

## Results: 25/25 CHECKS PASSED

### What was tested

uv's `[tool.uv] conflicts` feature with mutually exclusive extras (variant_a: urllib3>=2.0, variant_b: urllib3<2.0) on a trainer package with base deps (numpy, scipy). Also tested combining conflicting extras with non-conflicting extras (test: pytest) and producing per-platform files.

### Conflicting extras
- `uv lock` succeeds with conflicts declared (17 packages, ~500ms)
- variant_a: `urllib3==2.6.3`, variant_b: `urllib3==1.26.20` — genuinely different versions
- Base export (no extras): urllib3 entirely absent, only numpy + scipy

### Composability
- variant_a + test: both urllib3 2.x AND pytest present
- variant_b + test: both urllib3 1.x AND pytest present
- urllib3 versions still differ when test extra is active alongside a variant

### Negative test
- `uv export --extra variant_a --extra variant_b` correctly fails:
  `error: Extras 'variant-a' and 'variant-b' are incompatible with the declared conflicts`

### Per-platform files (uv pip compile)
- `uv pip compile --python-platform x86_64-unknown-linux-gnu` works on variant export files
- Platform file has no python_full_version markers (fully resolved)
- urllib3 versions still differ between variants on linux platform files

### Shared base deps
- numpy version identical across both variants

## README fix needed

Same as Pattern 1: **`uv export` does NOT support `--python-platform`.**

The readme shows:
```bash
uv export --extra cpu --python-platform x86_64-linux -o requirements-linux-cpu.txt
```

Working alternative: `uv export --extra cpu` → `uv pip compile --python-platform x86_64-unknown-linux-gnu`

## Build-backend typo fixed

The original `packages/trainer/pyproject.toml` had `build-backend = "hatchling.backends"` — corrected to `hatchling.build`. This doesn't affect lock/export but would fail a `uv build`.
