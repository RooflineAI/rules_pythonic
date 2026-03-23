"pythonic_test — macro + rule for Python test targets with third-party packages."

load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

# --- Helper functions ---

def _collect_dep_info(deps):
    """Walk the dep graph and collect everything the install action needs.

    Args:
        deps: List of targets providing PythonicPackageInfo.

    Returns:
        A struct with:
            src_roots: list[str] — PYTHONPATH entries for first-party code.
            pyprojects: list[File] — pyproject.toml files for dep validation.
            first_party_names: list[str] — package names to skip in install_packages.py.
            dep_runfiles: list[runfiles] — runfiles from all deps for merging.
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

            first_party_names.append(info.package_name)

            # Transitive deps were already collected by each intermediate
            # pythonic_package via depset propagation. We flatten here to
            # gather all source roots and pyproject files for the install action.
            for trans in info.first_party_deps.to_list():
                if trans.src_root not in src_roots:
                    src_roots.append(trans.src_root)
                if trans.pyproject and trans.pyproject not in pyprojects:
                    pyprojects.append(trans.pyproject)
                if trans.package_name not in first_party_names:
                    first_party_names.append(trans.package_name)

        dep_runfiles.append(dep[DefaultInfo].default_runfiles)

    return struct(
        src_roots = src_roots,
        pyprojects = pyprojects,
        first_party_names = first_party_names,
        dep_runfiles = dep_runfiles,
    )

def _build_exec_cmd(ctx):
    """Build the shell command that the launcher will exec.

    Three modes depending on user input:

    1. main = "tests/run_distributed.py"
       -> "$(rlocation _main/pkg/tests/run_distributed.py)"

    2. main_module = "torch.distributed.run"
       -> -m torch.distributed.run

    3. Neither (default) — pytest runner with test files as positional args:
       -> "$(rlocation _main/.../pythonic_pytest_runner.py)" "$(rlocation _main/pkg/tests/test_foo.py)"

    Args:
        ctx: Rule context.

    Returns:
        A string to substitute into {{EXEC_CMD}} in the launcher template.
    """
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

def _build_pythonpath(ctx, package_src_roots):
    """Build PYTHONPATH from first-party source roots using rlocation.

    Source roots are placed before the packages directory in the launcher,
    so first-party code shadows third-party packages of the same name.

    Args:
        ctx: Rule context (for workspace_name).
        package_src_roots: list[str] — workspace-relative paths like "packages/attic/src".

    Returns:
        A colon-separated string of rlocation calls, e.g.:
        "$(rlocation _main/packages/attic/src)":"$(rlocation _main/packages/core/src)"
    """
    entries = []
    for sr in package_src_roots:
        entries.append('"$(rlocation {workspace}/{sr})"'.format(
            workspace = ctx.workspace_name,
            sr = sr,
        ))
    return ":".join(entries)

def _build_env_exports(env_dict):
    """Build shell export lines from a string dict.

    TODO(rules_pythonic-jq9): needs a .bat equivalent for Windows support.

    Args:
        env_dict: dict[str, str] — environment variable name-value pairs.

    Returns:
        A string of shell export lines, e.g.: 'export FOO="bar"\nexport BAZ="qux"\n'
    """
    lines = ""
    for k, v in env_dict.items():
        lines += 'export {key}="{value}"\n'.format(key = k, value = v)
    return lines

# --- Rule implementation ---

def _pythonic_test_impl(ctx):
    """Implementation for _pythonic_inner_test.

    1. Collects provider info from deps (source roots, pyprojects, names).
    2. Runs install_packages.py to create a flat packages directory (TreeArtifact).
    3. Generates a launcher script from the template.
    4. Assembles runfiles for test execution.
    """
    py_toolchain = ctx.toolchains[_PY_TOOLCHAIN]
    py_runtime = py_toolchain.py3_runtime
    python = py_runtime.interpreter
    uv = ctx.executable._uv

    dep_info = _collect_dep_info(ctx.attr.deps)

    wheels = []
    for whl_target in ctx.attr.wheels:
        wheels.extend(whl_target.files.to_list())

    # TreeArtifact — Bazel treats this directory as a single cacheable output.
    # If none of the inputs (wheels, pyprojects) change, Bazel skips the
    # ctx.actions.run entirely and reuses the cached directory.
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
            "{{PYTHON_TOOLCHAIN}}": ctx.workspace_name + "/" + python.short_path,
            "{{PACKAGES_DIR}}": ctx.workspace_name + "/" + packages_dir.short_path,
            "{{FIRST_PARTY_PYTHONPATH}}": _build_pythonpath(ctx, dep_info.src_roots),
            "{{PYTHON_ENV}}": _build_env_exports(ctx.attr.test_env),
            "{{INTERPRETER_ARGS}}": " ".join(ctx.attr.interpreter_args),
            "{{EXEC_CMD}}": _build_exec_cmd(ctx),
        },
        is_executable = True,
    )

    # Runfiles = everything that must be available in the sandbox at test time:
    # the installed packages dir, the pytest runner, test sources, data files,
    # the Python toolchain, and all transitive dep runfiles (first-party sources).
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

# --- Rule definition (internal, not exported) ---

_pythonic_inner_test = rule(
    implementation = _pythonic_test_impl,
    test = True,
    attrs = {
        "srcs": attr.label_list(allow_files = [".py"], doc = "Test source files."),
        "deps": attr.label_list(providers = [PythonicPackageInfo], doc = "pythonic_package or pythonic_files targets."),
        "wheels": attr.label_list(allow_files = True, doc = "Filegroup(s) of @pypi wheel targets."),
        "extras": attr.string_list(doc = "Optional dependency groups from pyproject.toml."),
        "main": attr.label(allow_single_file = [".py"], doc = "Python file to run instead of pytest."),
        "main_module": attr.string(doc = "Python module to run via -m instead of pytest."),
        "test_env": attr.string_dict(doc = "Environment variables passed to the test."),
        "interpreter_args": attr.string_list(doc = "Extra flags for the Python interpreter."),
        "data": attr.label_list(allow_files = True, doc = "Additional runtime data files."),
        "pytest_root": attr.label(allow_files = True, doc = "Filegroup with conftest.py chain for pytest discovery."),
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

# --- Public API (legacy macro) ---

# Legacy macro is necessary because label defaults in both rules AND symbolic
# macros resolve in the defining module's repo, not the consumer's.
# "//:all_wheels" must resolve in the consumer's workspace, which only works
# when the string literal lives in a def that's expanded in the consumer's BUILD file.
def pythonic_test(name, wheels = ["//:all_wheels"], extras = ["test"], env = {}, **kwargs):
    """Create a Python test target with third-party packages installed via uv.

    By default runs pytest. Use main= or main_module= for other runners.

    Requires //:all_wheels filegroup in your root BUILD — create it once:
    ```
    load("@pypi//:requirements.bzl", "all_whl_requirements")
    filegroup(name = "all_wheels", srcs = all_whl_requirements, visibility = ["//visibility:public"])
    ```

    Args:
        name: Target name.
        wheels: Labels to @pypi wheel filegroups. Defaults to ["//:all_wheels"].
        extras: Optional dependency groups from pyproject.toml. Defaults to ["test"].
        env: Environment variables. Remapped to test_env because Bazel auto-adds
            an 'env' attr on test rules.
        **kwargs: All other attrs forwarded to the rule (srcs, deps, main,
            main_module, interpreter_args, data, pytest_root, size, timeout, tags).
    """
    _pythonic_inner_test(
        name = name,
        wheels = wheels,
        extras = extras,
        test_env = env,
        **kwargs
    )
