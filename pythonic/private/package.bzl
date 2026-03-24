"pythonic_package rule — declares a Python package for rules_pythonic."

load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _workspace_src_root(ctx):
    """Compute workspace-relative src_root from BUILD directory and src_root attr.

    For a BUILD at packages/attic/ with src_root="src", this produces
    "packages/attic/src". For a BUILD at the workspace root with
    src_root="src", ctx.label.package is "" so we use src_root directly.
    """
    src_root = ctx.label.package
    if ctx.attr.src_root and ctx.attr.src_root != ".":
        src_root = src_root + "/" + ctx.attr.src_root if src_root else ctx.attr.src_root
    return src_root

# --- Package rule (source-dep path) ---

def _pythonic_package_impl(ctx):
    src_root = _workspace_src_root(ctx)

    direct_deps = []
    transitive_dep_sets = []
    for dep in ctx.attr.deps:
        info = dep[PythonicPackageInfo]
        direct_deps.append(info)
        transitive_dep_sets.append(info.first_party_deps)

    transitive_deps = depset(
        direct = direct_deps,
        transitive = transitive_dep_sets,
    )

    runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.data)
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    return [
        PythonicPackageInfo(
            package_name = ctx.label.name,
            src_root = src_root,
            srcs = depset(ctx.files.srcs),
            pyproject = ctx.file.pyproject,
            wheel = None,
            first_party_deps = transitive_deps,
        ),
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = runfiles,
        ),
    ]

_pythonic_inner_package = rule(
    implementation = _pythonic_package_impl,
    attrs = {
        "pyproject": attr.label(
            allow_single_file = [".toml"],
            mandatory = True,
            doc = "The pyproject.toml for this package.",
        ),
        "src_root": attr.string(
            mandatory = True,
            doc = "Directory added to PYTHONPATH, relative to this package.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Non-Python runtime files.",
        ),
        "deps": attr.label_list(
            providers = [PythonicPackageInfo],
            doc = "First-party cross-package deps only.",
        ),
    },
    doc = "Declare a Python package for rules_pythonic.",
)

# --- Wheel rule ---

def _pythonic_wheel_impl(ctx):
    py_toolchain = ctx.toolchains[_PY_TOOLCHAIN]
    py_runtime = py_toolchain.py3_runtime
    python = py_runtime.interpreter
    uv = ctx.executable._uv

    wheel_dir = ctx.actions.declare_directory(ctx.label.name)

    wheels = []
    for whl_target in ctx.attr.wheels:
        wheels.extend(whl_target.files.to_list())

    # Collect directories containing wheels for --find-links.
    # Dedup because many wheels share the same directory.
    wheel_dir_paths = {}
    for w in wheels:
        d = w.path.rsplit("/", 1)[0] if "/" in w.path else "."
        wheel_dir_paths[d] = True

    args = ctx.actions.args()
    args.add(ctx.file._build_wheel)
    args.add("--uv-bin", uv)
    args.add("--python-bin", python)
    args.add("--pyproject", ctx.file.pyproject)
    args.add("--output-dir", wheel_dir.path)
    args.add_all("--src-files", ctx.files.srcs)
    if ctx.attr.src_prefix:
        args.add("--src-prefix", ctx.file.src_prefix.path)
    args.add_all("--wheel-dirs", wheel_dir_paths.keys())

    ctx.actions.run(
        executable = python,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file.pyproject, ctx.file._build_wheel] + ctx.files.srcs + wheels,
            transitive = [py_runtime.files],
        ),
        outputs = [wheel_dir],
        tools = [uv],
        mnemonic = "PythonicWheel",
        progress_message = "Building wheel for %{label}",
        use_default_shell_env = True,
    )

    # Build first_party_deps from deps, mirroring _pythonic_package_impl.
    direct_deps = []
    transitive_dep_sets = []
    for dep in ctx.attr.deps:
        info = dep[PythonicPackageInfo]
        direct_deps.append(info)
        transitive_dep_sets.append(info.first_party_deps)

    transitive_deps = depset(
        direct = direct_deps,
        transitive = transitive_dep_sets,
    )

    return [
        PythonicPackageInfo(
            package_name = ctx.label.name.removesuffix(".wheel"),
            src_root = _workspace_src_root(ctx),
            srcs = depset(ctx.files.srcs),
            pyproject = ctx.file.pyproject,
            wheel = wheel_dir,
            first_party_deps = transitive_deps,
        ),
        DefaultInfo(files = depset([wheel_dir])),
    ]

_pythonic_wheel = rule(
    implementation = _pythonic_wheel_impl,
    attrs = {
        "pyproject": attr.label(
            allow_single_file = [".toml"],
            mandatory = True,
        ),
        "src_root": attr.string(
            mandatory = True,
            doc = "Source root relative to this package. Must match the source " +
                  "target so both variants produce the same PythonicPackageInfo.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "deps": attr.label_list(
            providers = [PythonicPackageInfo],
            doc = "First-party cross-package deps. Must match the source target.",
        ),
        "src_prefix": attr.label(
            allow_single_file = True,
            doc = "Directory target whose path is stripped from src file paths " +
                  "when staging the wheel build. Use for assembled packages where " +
                  "srcs come from copy_to_directory or similar.",
        ),
        "wheels": attr.label_list(
            allow_files = True,
            doc = "Filegroup(s) containing build backend wheels (hatchling, setuptools, etc.).",
        ),
        "_uv": attr.label(
            default = "@multitool//tools/uv",
            executable = True,
            cfg = "exec",
        ),
        "_build_wheel": attr.label(
            default = "//pythonic/private:build_wheel.py",
            allow_single_file = True,
        ),
    },
    toolchains = [_PY_TOOLCHAIN],
    doc = "Build a .whl file via uv build.",
)

# --- Public API (macro) ---

def pythonic_package(name, wheels = ["//:all_wheels"], src_prefix = None, **kwargs):
    """Declare a Python package with source-dep and wheel targets.

    Creates two targets:
    - :name — source on PYTHONPATH (fast iteration, used as a dep)
    - :name.wheel — built .whl file (deployment, artifact testing)

    The .wheel target is tagged "manual" so it is excluded from wildcard
    builds (//...). It only builds when explicitly requested or pulled
    in as a dependency.

    Args:
        name: Target name.
        wheels: Labels to @pypi wheel filegroups providing the build backend.
            Defaults to ["//:all_wheels"].
        src_prefix: Prefix to strip from src file paths when staging the wheel
            build. Only needed for assembled packages where srcs come from a
            different directory tree (e.g. copy_to_directory output).
        **kwargs: All other attrs forwarded to the rule (pyproject, src_root,
            srcs, data, deps).
    """
    _pythonic_inner_package(
        name = name,
        **kwargs
    )

    wheel_kwargs = {
        "name": name + ".wheel",
        "pyproject": kwargs.get("pyproject"),
        "src_root": kwargs.get("src_root", "."),
        "srcs": kwargs.get("srcs", []),
        "deps": kwargs.get("deps", []),
        "wheels": wheels,
        "tags": ["manual"],
    }
    if src_prefix:
        wheel_kwargs["src_prefix"] = src_prefix
    _pythonic_wheel(**wheel_kwargs)
