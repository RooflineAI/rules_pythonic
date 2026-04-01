"pythonic_test — macro + rule for Python test targets with third-party packages."

load(":common.bzl", "build_env_exports", "build_pythonpath", "collect_dep_info", "rlocation_path", "uv_action_env")
load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

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
        return '"$(rlocation {path})"'.format(
            path = rlocation_path(ctx, ctx.file.main),
        )
    elif ctx.attr.main_module:
        return "-m " + ctx.attr.main_module
    else:
        parts = ['"$(rlocation {path})"'.format(
            path = rlocation_path(ctx, ctx.file._pytest_runner),
        )]
        for f in ctx.files.srcs:
            parts.append('"$(rlocation {path})"'.format(
                path = rlocation_path(ctx, f),
            ))
        return " ".join(parts)

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

    dep_info = collect_dep_info(ctx.attr.deps)

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
    for fp_wheel_dir in dep_info.first_party_wheel_dirs:
        args.add("--first-party-wheel-dirs", fp_wheel_dir.path)
    args.add_all("--extras", ctx.attr.extras)
    if ctx.attr.install_all_wheels:
        args.add("--install-all")

    # Pass source package info for dist-info generation.
    # Each --source-package is a JSON object with pyproject and srcs paths
    # that install_packages.py uses to stage an editable install and extract
    # the dist-info directory (METADATA, entry_points.txt).
    for sp in dep_info.source_packages:
        args.add("--source-package", json.encode({
            "pyproject": sp.pyproject.path,
            "srcs": [f.path for f in sp.srcs],
        }))

    ctx.actions.run(
        executable = python,
        arguments = [args],
        inputs = depset(
            direct = dep_info.pyprojects + wheels + dep_info.first_party_wheel_dirs + dep_info.source_inputs + [ctx.file._install_packages, ctx.file._staging],
            transitive = [py_runtime.files],
        ),
        outputs = [packages_dir],
        tools = [uv],
        mnemonic = "PythonicInstall",
        progress_message = "Installing packages for %{label}",
        env = uv_action_env(ctx),
        execution_requirements = {"no-remote-exec": ""},
    )

    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = launcher,
        substitutions = {
            "{{PYTHON_TOOLCHAIN}}": rlocation_path(ctx, python),
            "{{PACKAGES_DIR}}": rlocation_path(ctx, packages_dir),
            "{{FIRST_PARTY_PYTHONPATH}}": build_pythonpath(ctx, dep_info.src_roots),
            "{{PYTHON_ENV}}": build_env_exports(ctx.attr.test_env),
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
    if ctx.attr.conftest:
        runfiles_files.extend(ctx.files.conftest)

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
        "install_all_wheels": attr.bool(default = False, doc = "Install all provided wheels instead of resolving the minimal set."),
        "main": attr.label(allow_single_file = [".py"], doc = "Python file to run instead of pytest."),
        "main_module": attr.string(doc = "Python module to run via -m instead of pytest."),
        "test_env": attr.string_dict(doc = "Environment variables passed to the test."),
        "interpreter_args": attr.string_list(doc = "Extra flags for the Python interpreter."),
        "data": attr.label_list(allow_files = True, doc = "Additional runtime data files."),
        "conftest": attr.label(allow_files = True, doc = "Filegroup with conftest.py chain for pytest discovery."),
        "_uv": attr.label(
            default = "@multitool//tools/uv",
            executable = True,
            cfg = "exec",
        ),
        "_install_packages": attr.label(
            default = "//pythonic/private:install_packages.py",
            allow_single_file = True,
        ),
        "_staging": attr.label(
            default = "//pythonic/private:staging.py",
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
def pythonic_test(name, wheels = ["//:all_wheels"], extras = ["test"], env = {}, install_all_wheels = False, **kwargs):
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
        install_all_wheels: Install all provided wheels instead of resolving the
            minimal transitive set. Useful for integration tests that need the
            full environment.
        **kwargs: All other attrs forwarded to the rule (srcs, deps, main,
            main_module, interpreter_args, data, conftest, size, timeout, tags).
    """
    if kwargs.get("main") and kwargs.get("main_module"):
        fail("pythonic_test accepts main or main_module, not both")

    _pythonic_inner_test(
        name = name,
        wheels = wheels,
        extras = extras,
        test_env = env,
        install_all_wheels = install_all_wheels,
        **kwargs
    )
