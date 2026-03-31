# roof_py_files: importable non-package files on PYTHONPATH

**Status:** Draft
**Depends on:** `python-in-bazel-design.md` (roof_py core design)
**Last updated:** 2026-02-17

## Problem

roof_py has exactly one way to get files onto PYTHONPATH: `roof_py_package`, which requires a `pyproject.toml`. But many Bazel repos have importable code that isn't a package:

- **Shared test utilities.** `//lib/testing/helpers.py` used by many test targets across the repo. Not a package — just a module.
- **Config/constants modules.** `//config/settings.py` imported everywhere. No deps, no metadata.
- **Generated code.** `py_proto_library` outputs, gRPC stubs, OpenAPI clients. Need to be importable but have no pyproject.toml, no version, no third-party deps.
- **Compiled extension wrappers.** `wrapper.py` next to a `_native.so` produced by `cc_binary`. Both need to be importable.

In rules_python, all of these use `py_library`. In roof_py as currently designed, they have no home. You'd have to create a pyproject.toml for each one — even though they have no third-party deps, no version, and will never be published as a wheel.

## Proposed solution

A new rule, `roof_py_files`, that declares a source root without requiring package metadata:

```starlark
roof_py_files(
    name = "testing_helpers",
    srcs = glob(["**/*.py"]),
    src_root = ".",
)
```

It returns `RoofPyPackageInfo` with `pyproject = None` and `wheel = None`. Downstream rules (`roof_py_test`, `roof_py_binary`) consume it the same way they consume a package — the src_root goes on PYTHONPATH, the srcs go into runfiles.

### Mental model

`roof_py_files` is a bag of files with a PYTHONPATH entry. That's all it does:

- **Consumable by tests/binaries** via PYTHONPATH
- **Never participates in wheel builds** — if you need files in a wheel, arrange the correct package layout yourself (e.g., `copy_to_directory`), then use `roof_py_package`
- **No deps, no pyproject, no wheel** — the consuming package owns the dependency graph
- **No file type restrictions** — the user controls what goes in via `glob()` patterns. Python packages contain `.py`, `.so`, `.pyi`, `.json`, and more — the rule doesn't second-guess this.

## API

```starlark
roof_py_files(
    name,
    srcs,
    src_root,
    data = [],
    visibility = None,
)
```

| Attribute  | Type                           | Required | Description                                                                                                                                                                                                           |
| ---------- | ------------------------------ | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`     | string                         | yes      | Target name                                                                                                                                                                                                           |
| `srcs`     | label_list(allow_files = True) | yes      | Files to place on PYTHONPATH. Accepts any file type — `.py`, `.so`, `.pyi`, `.json`, etc. The user controls what's included via `glob()` patterns. Also accepts rule outputs (e.g., `py_proto_library`, `cc_binary`). |
| `src_root` | string                         | yes      | Relative path to the directory added to PYTHONPATH. Same semantics as `roof_py_package.src_root`. Must not contain `..` — use a BUILD file in the parent directory instead.                                           |
| `data`     | label_list(allow_files = True) | no       | Additional files needed at runtime that are NOT on the PYTHONPATH import path (e.g., golden test data, config files loaded by explicit path).                                                                         |

### Why no file type filter on srcs

Python packages are directories with stuff in them. A single package directory can contain `.py` modules, `.so` compiled extensions (importable via `import _native`), `.pyi` type stubs, `.json` data files (accessed via `importlib.resources`), and more. All of these live side-by-side in the same directory, and all are part of the package.

Filtering `srcs` to `.py`-only would fight this convention. The user already controls what goes in via `glob()` patterns — `glob(["**/*.py"])` for Python-only, `glob(["**/*"])` for everything. The rule doesn't need to second-guess the user's glob.

### What it does NOT have

- **No `deps`.** `roof_py_files` is a leaf. It cannot depend on other `roof_py_files` or `roof_py_package` targets. If you need transitive composition across source roots, use `roof_py_package` with a minimal pyproject.toml.
- **No `pyproject`.** No third-party dependency declaration. Third-party deps are always the responsibility of the consuming `roof_py_package`.
- **No `.wheel` target.** `roof_py_files` never builds wheels. If you need files in a wheel, arrange them into the correct package layout first (e.g., `copy_to_directory`), then include them in `roof_py_package`. The rules don't do layout — the user is responsible for correct package structure.
- **No `extras`.** No pyproject.toml means no optional-dependency groups.

### Why no deps

`roof_py_files` targets are leaves — they provide files, they don't compose dependency graphs:

| Use case                 | Depends on other Python?                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| Shared test utilities    | Rarely — usually standalone helpers                                                                |
| Config/constants modules | No — these are imported, they don't import                                                         |
| Generated code           | No — dependency chains are handled at the generator level (proto deps proto), not the output level |
| Extension wrappers       | No — they wrap C, not Python                                                                       |

The dependency graph belongs to the package that consumes the files. If generated proto A imports generated proto B at the Python level, the consuming `roof_py_test` lists both as deps. The proto-level dep chain ensures both exist; the Bazel-level dep list ensures both are on PYTHONPATH.

The upgrade path for the rare case that needs composition: add a 3-line pyproject.toml and use `roof_py_package`. That's not a workaround — it's the correct model. Code that has dependencies is a package.

### Wheel builds: not roof_py_files' job

If you need generated or utility code in a wheel, that's a layout problem — not a `roof_py_files` problem. The flow:

1. Generate/write the code wherever it lives
2. Arrange it into the correct package layout (e.g., `copy_to_directory`)
3. Include the correctly-laid-out files in `roof_py_package.srcs`
4. `roof_py_package` builds the wheel

`roof_py_files` is for the PYTHONPATH-only case: test helpers, internal config, standalone generated code consumed at test/dev time.

## Provider changes

Current `RoofPyPackageInfo`:

```starlark
RoofPyPackageInfo = provider(
    fields = {
        "src_root": "string",
        "srcs": "depset[File]",
        "pyproject": "File",                        # always a File today
        "wheel": "File or None",
        "first_party_deps": "depset[RoofPyPackageInfo]",
    },
)
```

Required change:

```starlark
"pyproject": "File or None: the pyproject.toml file (None for roof_py_files targets)",
```

One field type change. That's it.

### Downstream impact — `pyproject = None` guard checklist

Every code path that touches `pyproject` must handle `None`:

| Code path                                           | Change needed                                                     |
| --------------------------------------------------- | ----------------------------------------------------------------- |
| `venv.bzl` — pyproject collection                   | `if info.pyproject:` guard                                        |
| `defs.bzl` — first-party-packages list              | Skip targets with `pyproject = None`                              |
| `defs.bzl` — venv dedup hash                        | See "Venv deduplication" section below                            |
| `install_venv.py` — receives pyproject paths        | No change (filtered upstream in Starlark)                         |
| `launcher.bzl` — src_root collection                | No change (works regardless of pyproject)                         |
| `test_rule.bzl` / `binary_rule.bzl` — dep iteration | No change (collects src_root from all deps, pyproject irrelevant) |

```starlark
# Before (assumes pyproject always exists):
pyprojects.append(info.pyproject)

# After:
if info.pyproject:
    pyprojects.append(info.pyproject)
```

**`install_venv.py`:** No change. It receives the filtered list of pyproject.toml paths. If a dep contributes no pyproject, it simply isn't in the list.

**`defs.bzl` macros:** Add `roof_py_files` to exports. No other change.

## Implementation

### Rule implementation (~20 lines)

```starlark
# roof/python/private/files_rule.bzl

load("//python:providers.bzl", "RoofPyPackageInfo")

def _roof_py_files_impl(ctx):
    # Validate src_root
    if ".." in ctx.attr.src_root:
        fail("src_root must not contain '..' — use a BUILD file in the parent directory instead")

    full_src_root = ctx.label.package
    if ctx.attr.src_root and ctx.attr.src_root != ".":
        full_src_root = full_src_root + "/" + ctx.attr.src_root

    srcs_depset = depset(ctx.files.srcs)

    return [
        RoofPyPackageInfo(
            src_root = full_src_root,
            srcs = srcs_depset,
            pyproject = None,
            wheel = None,
            first_party_deps = depset(),  # leaf — no transitive deps
        ),
        DefaultInfo(
            files = srcs_depset,
            runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.data),
        ),
    ]

_roof_py_files = rule(
    implementation = _roof_py_files_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Files to make importable via PYTHONPATH. Accepts any file type — "
                  ".py, .so, .pyi, .json, etc. Also accepts rule outputs.",
            allow_files = True,
            mandatory = True,
        ),
        "src_root": attr.string(
            doc = "Relative path to the directory added to PYTHONPATH. "
                  "Must not contain '..'.",
            mandatory = True,
        ),
        "data": attr.label_list(
            doc = "Additional files needed at runtime, not on the import path.",
            allow_files = True,
        ),
    },
)
```

### Macro (in defs.bzl)

```starlark
def roof_py_files(name, srcs, src_root, data = [], visibility = None, **kwargs):
    """Declare importable files without package metadata.

    Use this for shared utilities, config modules, and generated code
    that need to be on PYTHONPATH but don't have a pyproject.toml.

    The user controls what file types are included via glob() patterns.
    Third-party deps are NOT declared here — they come from the
    consuming roof_py_package's pyproject.toml.

    Args:
        name: Target name.
        srcs: Files to place on PYTHONPATH (any type — .py, .so, .pyi, etc.).
        src_root: Relative path to add to PYTHONPATH (e.g., ".").
        data: Additional files needed at runtime, not on the import path.
        visibility: Standard Bazel visibility.
    """
    _roof_py_files(
        name = name,
        srcs = srcs,
        src_root = src_root,
        data = data,
        visibility = visibility,
        **kwargs
    )
```

## Use cases

### 1. Shared test utilities

```
lib/
  testing/
    __init__.py
    helpers.py
    fixtures.py
    BUILD.bazel
```

```starlark
# lib/testing/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_files")

roof_py_files(
    name = "testing",
    srcs = glob(["**/*.py"]),
    src_root = ".",
    visibility = ["//visibility:public"],
)
```

```starlark
# packages/attic/BUILD.bazel
roof_py_test(
    name = "test_compiler",
    srcs = ["tests/test_compiler.py"],
    deps = [":attic", "//lib/testing"],
)
```

```python
# packages/attic/tests/test_compiler.py
from testing import helpers  # shared utilities on PYTHONPATH
```

**Import path note:** With `src_root = "."` and the BUILD file at `lib/testing/`, the PYTHONPATH entry is `lib/testing/`. So imports are `from testing import helpers` (not `from lib.testing import helpers`). If the intent is `from lib.testing import helpers`, move the BUILD file to `lib/` and use `src_root = "."` there.

### 2. Config/constants module

```
config/
  settings.py
  constants.py
  BUILD.bazel
```

```starlark
# config/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_files")

roof_py_files(
    name = "config",
    srcs = glob(["*.py"]),
    src_root = ".",
    visibility = ["//visibility:public"],
)
```

```python
# anywhere in the repo
from config import settings
```

### 3. Compiled extension with wrapper

```
bindings/
  _native.so        # built by cc_binary
  wrapper.py         # thin Python interface
  BUILD.bazel
```

```starlark
# bindings/BUILD.bazel
load("@roof//python:defs.bzl", "roof_py_files")

cc_binary(
    name = "_native.so",
    srcs = ["native.cc"],
    linkshared = True,
)

roof_py_files(
    name = "bindings",
    srcs = ["wrapper.py", ":_native.so"],  # both importable, both on PYTHONPATH
    src_root = ".",
    visibility = ["//visibility:public"],
)
```

```python
# wrapper.py
import ctypes, pathlib
_lib = ctypes.CDLL(str(pathlib.Path(__file__).parent / "_native.so"))
```

Note: the `.so` is in `srcs` (not `data`) because it's importable — Python's import system can load `.so` files directly. Both `wrapper.py` and `_native.so` need to be on PYTHONPATH.

### 4. Generated protobuf code

```
protos/
  myservice.proto
  BUILD.bazel
```

```starlark
# protos/BUILD.bazel
load("@rules_proto//proto:defs.bzl", "proto_library")
load("@rules_python//python:proto.bzl", "py_proto_library")
load("@roof//python:defs.bzl", "roof_py_files")

proto_library(
    name = "myservice_proto",
    srcs = ["myservice.proto"],
)

py_proto_library(
    name = "myservice_py_proto",
    deps = [":myservice_proto"],
)

roof_py_files(
    name = "myservice_py",
    srcs = [":myservice_py_proto"],
    src_root = ".",
    visibility = ["//visibility:public"],
)
```

```starlark
# app/BUILD.bazel
roof_py_test(
    name = "test_service",
    srcs = ["test_service.py"],
    deps = [":app", "//protos:myservice_py"],
)
```

```python
# app/test_service.py
import myservice_pb2  # generated code on PYTHONPATH via roof_py_files
```

If the generated code needs to ship in a wheel, it's the user's responsibility to arrange it into the correct package layout (e.g., `copy_to_directory` into the package's source tree) and include it in `roof_py_package.srcs`. `roof_py_files` is for the PYTHONPATH-only case.

## How it differs from py_library

|                           | `py_library` (rules_python)                                        | `roof_py_files`                                                                                          |
| ------------------------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| **Role in the system**    | Core building block — everything flows through it                  | Escape hatch — for code that isn't a package                                                             |
| **Third-party deps**      | Yes: `deps = ["@pypi//torch"]`                                     | Never. Third-party deps are the consuming package's job.                                                 |
| **File types**            | `.py` only in `srcs`                                               | Any file type — `.py`, `.so`, `.pyi`, `.json`, etc. User controls via `glob()`.                          |
| **Provider**              | `PyInfo` (13 fields, transitive source depsets, import path lists) | `RoofPyPackageInfo` with `pyproject=None` (same 5-field provider as packages)                            |
| **Import mechanism**      | `imports` attribute → `.pth` files / `PyInfo.imports` depsets      | `src_root` → PYTHONPATH entry                                                                            |
| **Composition**           | Arbitrary dep chains of py_library → py_library → py_library       | Leaf only. No deps on other roof_py_files.                                                               |
| **How deps are consumed** | Direct: `py_test(deps = [":mylib", "@pypi//torch"])`               | Same provider: `roof_py_test(deps = [":mypackage", ":myfiles"])`                                         |
| **Typical size**          | 1-200+ per repo (every Python target)                              | 5-20 per repo (generated code, utilities, config)                                                        |
| **When to upgrade**       | N/A                                                                | When you need third-party deps or transitive composition → `roof_py_package` with minimal pyproject.toml |
| **Wheel builds**          | Part of py_wheel                                                   | Never. Arrange layout yourself, then use `roof_py_package`.                                              |

The philosophical difference: in rules_python, `py_library` carries the dependency graph. In roof_py, `pyproject.toml` carries the dependency graph. `roof_py_files` deliberately stays out of the dependency graph — it's just "files on a path."

## What roof_py_files is NOT for

### Running scripts

If you want to execute a Python file, use `roof_py_binary`:

```starlark
# Correct — roof_py_binary for executable scripts
roof_py_binary(
    name = "run_migration",
    main = "run_migration.py",
    deps = [":myapp"],  # provides the venv with third-party deps
)
```

`roof_py_files` targets are not executable. They are consumed as deps.

### Declaring third-party dependencies

If your code needs third-party packages, it's a package — use `roof_py_package` with a pyproject.toml:

```toml
# 3-line pyproject.toml — the "upgrade path" from roof_py_files
[project]
name = "my-utils"
dependencies = ["pydantic"]
```

This isn't overhead. It's Python metadata that every tool in the ecosystem understands.

### Building wheels

`roof_py_files` never builds wheels. If you need to distribute code as a wheel:

1. Arrange the files into the correct package layout (e.g., `copy_to_directory`)
2. Include them in `roof_py_package.srcs`
3. `roof_py_package` builds the `.wheel` target

The rules don't do layout. The user is responsible for correct package structure.

## Integration with the venv rule

`roof_py_files` targets contribute to the test/binary in two ways:

1. **PYTHONPATH:** `src_root` is added to the PYTHONPATH entries in the launcher. Same as a `roof_py_package`.
2. **Runfiles:** `srcs` and `data` are added to the runfiles tree. Same as a `roof_py_package`.

They do NOT contribute to the venv:

3. **No pyproject.toml** → no third-party deps parsed → no wheels installed. The venv contains only what the `roof_py_package` deps contribute.

This means: if your `roof_py_files` code does `import numpy`, numpy must come from a `roof_py_package` in the same target's dep closure. If no package provides numpy, the import fails at runtime with `ModuleNotFoundError`. This is correct — the files don't own their deps, the consuming package does.

### Venv deduplication

`roof_py_files` targets contribute `pyproject = None` — they don't affect venv contents. Ideally, two tests with the same `roof_py_package` deps but different `roof_py_files` deps would share one venv.

However, the venv dedup hash in `defs.bzl` hashes dep labels, and macros cannot inspect providers at analysis time to distinguish package deps from file deps. Options:

- **Accept minor duplication (v1).** Extra venvs cost ~2-4MB with hardlinks. This is the simplest approach.
- **Split the API (v2 if needed).** Separate `deps` (packages, hashed) from a `file_deps` attribute (files, not hashed). This is explicit but changes the user-facing API.

For v1, accept the minor duplication. Revisit if users report excessive venv counts.

## Derisking needed

### 1. Generated file runfiles paths and src_root

**Question:** Where do generated files land in the runfiles tree, and does `src_root` correctly compute the PYTHONPATH entry?

For source files at `protos/myservice.py`, the runfiles path is `_main/protos/myservice.py`. With `src_root = "."` in `protos/BUILD.bazel`, PYTHONPATH gets `_main/protos/`, and `import myservice` works.

For generated files from `py_proto_library` at `protos/BUILD.bazel`, the generated `myservice_pb2.py` should appear at `_main/protos/myservice_pb2.py` in runfiles. Same PYTHONPATH, same import path.

**But:** generated files may land under a different runfiles prefix if they come from a different output root (e.g., `bazel-out/k8-fastbuild/bin/protos/` vs `protos/`). Bazel's runfiles mapping should handle this, but it needs verification.

**How to test:** Create a rule that generates a `.py` file, wrap it in `roof_py_files`, add it as a dep of a test, print `sys.path` and attempt import.

### 2. Rule outputs as siblings in runfiles

**Question:** When `srcs` contains both a source file (`wrapper.py`) and a rule output (`:_native.so` from `cc_binary`), do they end up as siblings in the runfiles tree?

If `wrapper.py` does `pathlib.Path(__file__).parent / "_native.so"`, the `.so` must be a sibling. Source files and rule outputs from the same package should land at the same relative path in runfiles, but this needs verification — especially for `cc_binary` outputs which may have a different output root.

**How to test:** Create a `cc_binary` producing a `.so`, a `wrapper.py` in the same package, put both in `roof_py_files.srcs`, and verify they're siblings in the runfiles tree.

## Implementation plan

| Step | What                                                          | Lines | Depends on |
| ---- | ------------------------------------------------------------- | ----- | ---------- |
| 1    | Change `pyproject` field to `File or None` in `providers.bzl` | 1     | —          |
| 2    | Add `pyproject = None` guards (see checklist above)           | ~5    | Step 1     |
| 3    | Create `files_rule.bzl` with `_roof_py_files`                 | ~25   | Step 1     |
| 4    | Add `roof_py_files` macro to `defs.bzl`                       | ~15   | Step 3     |
| 5    | Add `bzl_library` target in `python/private/BUILD.bazel`      | ~5    | Step 3     |
| 6    | Derisk: generated file runfiles paths                         | —     | Step 4     |
| 7    | Derisk: rule outputs as runfiles siblings                     | —     | Step 4     |
| 8    | Example: shared test utilities                                | ~20   | Step 4     |

Total new code: ~50 lines of Starlark. ~5 lines of changes to existing files.

## Resolved questions

1. **Should `srcs` accept non-`.py` files?** Yes. `allow_files = True` — no filter. Python packages contain `.py`, `.so`, `.pyi`, `.json`, and more. The user controls what goes in via `glob()` patterns. The rule doesn't second-guess this.

2. **Should `roof_py_files` accept a `deps` attribute?** No. `roof_py_files` is a leaf. The consuming package or test owns the dependency graph. Generated code dependency chains (e.g., proto A imports proto B) are handled at the generator level; the consumer lists all needed targets. If a target needs transitive composition, it's a package — use `roof_py_package` with a minimal pyproject.toml.

3. **Should `roof_py_files` participate in wheel builds?** No. It never builds wheels. If files need to be in a wheel, the user arranges them into the correct package layout first (e.g., `copy_to_directory`), then includes them in `roof_py_package.srcs`. The rules don't do layout.

4. **Should `src_root` allow `..`?** No. Validated in the rule implementation. Use a BUILD file in the parent directory instead.

## Open questions

1. **Name: `roof_py_files` vs `roof_py_sources`?** Both are honest names. `files` is more concrete and matches the "bag of files" mental model. `sources` implies "source code" which may feel wrong for generated code or `.so` files. Leaning toward `roof_py_files`.

2. **Does this replace the need for a Gazelle plugin?** The main RFC argues no Gazelle needed because third-party deps are in pyproject.toml. With `roof_py_files` for generated code, the only remaining Gazelle use case would be auto-discovering which generated outputs need `roof_py_files` wrappers. That's marginal — most repos have stable generated code targets that change rarely.
