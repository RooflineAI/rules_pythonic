# Pattern 5: Combining Platform Variants with Multiple Products — Findings

**Validated:** 2026-02-16 | **uv:** 0.9.22 | **Python:** 3.13.5

## Results: 23/23 CHECKS PASSED

### What was tested

Two separate uv workspaces (main + legacy) where the main workspace uses `[tool.uv] conflicts` for mutually exclusive extras (cpu vs cuda12) and the legacy workspace uses a simple extra (cuda11). This is the combination of Pattern 2 + Pattern 4.

### Separate workspace locking
- Main workspace locks independently with conflicts declared
- Legacy workspace locks independently with no conflicts
- No cross-contamination between lock files

### Main workspace (Pattern 2 behavior)
- cpu variant: numpy + scipy + urllib3>=2.0, no colorama
- cuda12 variant: numpy + scipy + urllib3>=2.0 + colorama (proxy for CUDA-specific pkgs)
- Both conflicting extras together correctly rejected

### Legacy workspace (Pattern 4 behavior)
- cuda11 variant: numpy + scipy + urllib3<2.0

### Cross-workspace isolation
- Main urllib3: `urllib3==2.6.3`
- Legacy urllib3: `urllib3==1.26.20`
- Versions genuinely differ, proving independent resolution

### Two-step platform export
- `uv export` → `uv pip compile --python-platform` works per workspace per variant
- Main cuda12 → linux: numpy, colorama, urllib3 2.x present
- Main cpu → darwin: numpy, scipy present
- Legacy cuda11 → linux: numpy, urllib3 1.x present
- Version isolation maintained through the platform compile step

## Conclusion

Pattern 5 works as described. The combination of separate workspaces (Pattern 4) with conflicting extras (Pattern 2) introduces no new issues. Each workspace resolves independently, each variant exports correctly, and the two-step platform export works across both.
