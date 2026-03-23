"pythonic_binary — macro + rule for executable Python targets with third-party packages."

load(":common.bzl", "build_env_exports", "build_pythonpath", "collect_dep_info", "rlocation_path")
load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _build_exec_cmd(ctx):
    """Build the shell command that the launcher will exec.

    Two modes:
    1. main = "src/serve.py" -> "$(rlocation _main/pkg/src/serve.py)"
    2. main_module = "mypackage.serve" -> -m mypackage.serve

    Args:
        ctx: Rule context.

    Returns:
        A string to substitute into {{EXEC_CMD}} in the launcher template.
    """
    if ctx.attr.main:
        return '"$(rlocation {path})"'.format(
            path = rlocation_path(ctx, ctx.file.main),
        )
    else:
        return "-m " + ctx.attr.main_module

def _pythonic_binary_impl(ctx):
    py_toolchain = ctx.toolchains[_PY_TOOLCHAIN]
    py_runtime = py_toolchain.py3_runtime
    python = py_runtime.interpreter
    uv = ctx.executable._uv

    dep_info = collect_dep_info(ctx.attr.deps)

    wheels = []
    for whl_target in ctx.attr.wheels:
        wheels.extend(whl_target.files.to_list())

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
        use_default_shell_env = True,
    )

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = launcher,
        substitutions = {
            "{{PYTHON_TOOLCHAIN}}": rlocation_path(ctx, python),
            "{{PACKAGES_DIR}}": rlocation_path(ctx, packages_dir),
            "{{FIRST_PARTY_PYTHONPATH}}": build_pythonpath(ctx, dep_info.src_roots),
            "{{PYTHON_ENV}}": build_env_exports(ctx.attr.env),
            "{{INTERPRETER_ARGS}}": " ".join(ctx.attr.interpreter_args),
            "{{EXEC_CMD}}": _build_exec_cmd(ctx),
        },
        is_executable = True,
    )

    runfiles_files = [packages_dir] + ctx.files.srcs + ctx.files.data
    if ctx.attr.main:
        runfiles_files.append(ctx.file.main)

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

_pythonic_inner_binary = rule(
    implementation = _pythonic_binary_impl,
    executable = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".py"], doc = "Additional Python source files."),
        "deps": attr.label_list(providers = [PythonicPackageInfo], doc = "pythonic_package or pythonic_files targets."),
        "wheels": attr.label_list(allow_files = True, doc = "Filegroup(s) of @pypi wheel targets."),
        "extras": attr.string_list(doc = "Optional dependency groups from pyproject.toml."),
        "main": attr.label(allow_single_file = [".py"], doc = "Python file to run as entry point."),
        "main_module": attr.string(doc = "Python module to run via -m."),
        "env": attr.string_dict(doc = "Environment variables passed to the binary."),
        "interpreter_args": attr.string_list(doc = "Extra flags for the Python interpreter."),
        "data": attr.label_list(allow_files = True, doc = "Additional runtime data files."),
        "_uv": attr.label(
            default = "@multitool//tools/uv",
            executable = True,
            cfg = "exec",
        ),
        "_install_packages": attr.label(
            default = "//pythonic/private:install_packages.py",
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

def pythonic_binary(name, main = None, main_module = None, wheels = ["//:all_wheels"], extras = [], env = {}, **kwargs):
    """Create an executable Python target with third-party packages installed via uv.

    Exactly one of main or main_module must be provided.

    Args:
        name: Target name.
        main: Python file to run as entry point.
        main_module: Python module to run via -m.
        wheels: Labels to @pypi wheel filegroups. Defaults to ["//:all_wheels"].
        extras: Optional dependency groups from pyproject.toml.
        env: Environment variables passed to the binary.
        **kwargs: All other attrs forwarded to the rule (srcs, deps,
            interpreter_args, data, size, timeout, tags).
    """
    if not main and not main_module:
        fail("pythonic_binary requires either main or main_module")
    if main and main_module:
        fail("pythonic_binary accepts main or main_module, not both")

    _pythonic_inner_binary(
        name = name,
        main = main,
        main_module = main_module,
        wheels = wheels,
        extras = extras,
        env = env,
        **kwargs
    )
