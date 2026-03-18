"pythonic_test macro — creates a test target with a cached package directory."

load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def pythonic_test(
        name,
        srcs,
        deps = [],
        wheels = "//:all_wheels",
        extras = [],
        main = None,
        main_module = None,
        env = {},
        interpreter_args = [],
        shard_count = None,
        data = [],
        pytest_root = None,
        tags = [],
        size = "small",
        timeout = None,
        **kwargs):
    """Create a Python test target with third-party packages installed via uv.

    By default runs pytest. Use main= or main_module= for other runners.

    Args:
        name: Target name.
        srcs: Test source files.
        deps: pythonic_package or pythonic_files targets.
        wheels: Filegroup containing all @pypi wheel targets. Defaults to
            //:all_wheels — create it once in your root BUILD:
            ```
            load("@pypi//:requirements.bzl", "all_whl_requirements")
            filegroup(name = "all_wheels", srcs = all_whl_requirements, visibility = ["//visibility:public"])
            ```
        extras: Optional dependency groups from pyproject.toml (beyond "test").
        main: Python file to run instead of pytest.
        main_module: Python module to run via -m instead of pytest.
        env: Environment variables passed to the test.
        interpreter_args: Extra flags for the Python interpreter.
        shard_count: Number of test shards (file-level).
        data: Additional runtime data files.
        pytest_root: Filegroup with conftest.py chain for pytest discovery.
        tags: Bazel tags.
        size: Test size.
        timeout: Test timeout.
        **kwargs: Passed through to the underlying test rule.
    """
    # Allow passing a single label string (the default) or a list of labels.
    if type(wheels) == "string":
        wheels = [wheels]

    _pythonic_test(
        name = name,
        srcs = srcs,
        deps = deps,
        wheels = wheels,
        extras = ["test"] + extras,
        main = main,
        main_module = main_module,
        test_env = env,
        interpreter_args = interpreter_args,
        shard_count = shard_count,
        data = data,
        pytest_root = pytest_root,
        tags = tags,
        size = size,
        timeout = timeout,
        **kwargs
    )

def _collect_dep_info(deps):
    """Extract source roots, pyproject files, and package names from deps.

    Returns a struct with src_roots, pyprojects, first_party_names, and
    dep_runfiles lists.
    """
    src_roots = []
    pyprojects = []
    first_party_names = []
    dep_runfiles = []

    for dep in deps:
        if PythonicPackageInfo in dep:
            info = dep[PythonicPackageInfo]
            src_roots.append(info.src_root)
            if info.pyproject:
                pyprojects.append(info.pyproject)

            # TODO(rules_pythonic-n7h): extract name from pyproject.toml
            # instead of inferring from src_root path component
            first_party_names.append(
                info.src_root.split("/")[-1] if "/" in info.src_root else info.src_root,
            )

            for trans in info.first_party_deps.to_list():
                if trans.src_root not in src_roots:
                    src_roots.append(trans.src_root)
                if trans.pyproject and trans.pyproject not in pyprojects:
                    pyprojects.append(trans.pyproject)
                trans_name = trans.src_root.split("/")[-1] if "/" in trans.src_root else trans.src_root
                if trans_name not in first_party_names:
                    first_party_names.append(trans_name)

        dep_runfiles.append(dep[DefaultInfo].default_runfiles)

    return struct(
        src_roots = src_roots,
        pyprojects = pyprojects,
        first_party_names = first_party_names,
        dep_runfiles = dep_runfiles,
    )

def _build_exec_cmd(ctx):
    """Build the exec command string for the launcher template."""
    if ctx.attr.main:
        return '"$(rlocation {workspace}/{path})"'.format(
            workspace = ctx.workspace_name,
            path = ctx.file.main.short_path,
        )
    elif ctx.attr.main_module:
        return "-m " + ctx.attr.main_module
    else:
        parts = ['"$(rlocation {workspace}/{path})"'.format(
            workspace = ctx.workspace_name,
            path = ctx.file._pytest_runner.short_path,
        )]
        for f in ctx.files.srcs:
            parts.append('"$(rlocation {workspace}/{path})"'.format(
                workspace = ctx.workspace_name,
                path = f.short_path,
            ))
        return " ".join(parts)

def _build_pythonpath(ctx, src_roots):
    """Build the PYTHONPATH string from source roots using rlocation calls."""
    entries = []
    for sr in src_roots:
        entries.append('"$(rlocation {workspace}/{sr})"'.format(
            workspace = ctx.workspace_name,
            sr = sr,
        ))
    return ":".join(entries)

def _build_env_exports(env_dict):
    """Build shell export lines from a string dict."""
    lines = ""
    for k, v in env_dict.items():
        lines += 'export {key}="{value}"\n'.format(key = k, value = v)
    return lines

def _pythonic_test_impl(ctx):
    py_toolchain = ctx.toolchains[_PY_TOOLCHAIN]
    py_runtime = py_toolchain.py3_runtime
    python = py_runtime.interpreter
    uv = ctx.executable._uv

    dep_info = _collect_dep_info(ctx.attr.deps)

    wheels = []
    for whl_target in ctx.attr.wheels:
        wheels.extend(whl_target.files.to_list())

    # TreeArtifact — Bazel tracks this as a single cacheable output.
    # install_packages.py populates it via uv pip install --target.
    packages_dir = ctx.actions.declare_directory(ctx.label.name + "_packages")

    args = ctx.actions.args()
    args.add(ctx.file._install_packages)
    args.add("--uv-bin", uv)
    args.add("--python-bin", python)
    args.add("--output-dir", packages_dir.path)
    args.add_all("--wheel-files", wheels)
    args.add_all("--pyprojects", dep_info.pyprojects)
    args.add_all("--first-party-packages", dep_info.first_party_names)
    args.add_all("--extras", ctx.attr.extras)

    ctx.actions.run(
        executable = python,
        arguments = [args],
        inputs = depset(
            direct = dep_info.pyprojects + wheels + [ctx.file._install_packages],
            transitive = [py_runtime.files],
        ),
        outputs = [packages_dir],
        tools = [uv],
        mnemonic = "PythonicInstall",
        progress_message = "Installing packages for %{label}",
    )

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = launcher,
        substitutions = {
            "{{PYTHON_TOOLCHAIN}}": ctx.workspace_name + "/" + python.short_path,
            "{{PACKAGES_DIR}}": ctx.workspace_name + "/" + packages_dir.short_path,
            "{{FIRST_PARTY_PYTHONPATH}}": _build_pythonpath(ctx, dep_info.src_roots),
            "{{PYTHON_ENV}}": _build_env_exports(ctx.attr.test_env),
            "{{INTERPRETER_ARGS}}": " ".join(ctx.attr.interpreter_args),
            "{{EXEC_CMD}}": _build_exec_cmd(ctx),
        },
        is_executable = True,
    )

    runfiles_files = [packages_dir, ctx.file._pytest_runner] + ctx.files.srcs + ctx.files.data
    if ctx.attr.main:
        runfiles_files.append(ctx.file.main)
    if ctx.attr.pytest_root:
        runfiles_files.extend(ctx.files.pytest_root)

    runfiles = ctx.runfiles(
        files = runfiles_files,
        transitive_files = py_runtime.files,
    )
    for dr in dep_info.dep_runfiles:
        runfiles = runfiles.merge(dr)
    runfiles = runfiles.merge(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = launcher,
        runfiles = runfiles,
    )]

_pythonic_test = rule(
    implementation = _pythonic_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".py"]),
        "deps": attr.label_list(providers = [PythonicPackageInfo]),
        "wheels": attr.label_list(allow_files = True),
        "extras": attr.string_list(),
        "main": attr.label(allow_single_file = [".py"]),
        "main_module": attr.string(),
        "test_env": attr.string_dict(),
        "interpreter_args": attr.string_list(),
        "data": attr.label_list(allow_files = True),
        "pytest_root": attr.label(allow_files = True),
        "_uv": attr.label(
            default = "@multitool//tools/uv",
            executable = True,
            cfg = "exec",
        ),
        "_install_packages": attr.label(
            default = "//pythonic/private:install_packages.py",
            allow_single_file = True,
        ),
        "_pytest_runner": attr.label(
            default = "//pythonic/private:pythonic_pytest_runner.py",
            allow_single_file = True,
        ),
        "_launcher_template": attr.label(
            default = "//pythonic/private:pythonic_run.tmpl.sh",
            allow_single_file = True,
        ),
        "_bash_runfiles": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
    },
    toolchains = [_PY_TOOLCHAIN],
)
