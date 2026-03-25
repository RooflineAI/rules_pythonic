"pythonic_devenv — executable rule that creates a Python venv for IDE use."

load(":common.bzl", "rlocation_path")
load(":providers.bzl", "PythonicPackageInfo")

_PY_TOOLCHAIN = "@bazel_tools//tools/python:toolchain_type"

def _collect_devenv_info(ctx, deps):
    """Walk deps and partition into editable packages vs wheel installs.

    Source deps (wheel=None, pyproject set) become editable installs via
    stage_symlink_tree — the same staging mechanism used by build_wheel.py.
    Wheel deps (wheel set) get installed as built wheels.
    When the same package_name appears as both, wheel wins.

    Args:
        ctx: Rule context (for rlocation_path).
        deps: List of targets providing PythonicPackageInfo.

    Returns:
        A struct with:
            editables: list[dict] — packages for editable install (pyproject + srcs).
            runfiles_inputs: list[File] — all files needed in runfiles for staging.
            first_party_wheel_dirs: list[File] — TreeArtifact dirs containing .whl.
            dep_runfiles: list[runfiles] — runfiles from all deps.
    """
    editables = []
    runfiles_inputs = []
    first_party_wheel_dirs = []
    dep_runfiles = []

    all_infos = []
    wheel_packages = {}

    for dep in deps:
        if PythonicPackageInfo in dep:
            info = dep[PythonicPackageInfo]
            all_infos.append(info)
            if info.wheel:
                wheel_packages[info.package_name] = info.wheel

            for trans in info.first_party_deps.to_list():
                all_infos.append(trans)
                if trans.wheel:
                    wheel_packages[trans.package_name] = trans.wheel

        dep_runfiles.append(dep[DefaultInfo].default_runfiles)

    seen_names = {}
    for info in all_infos:
        if info.package_name in seen_names:
            continue
        seen_names[info.package_name] = True

        if info.package_name in wheel_packages:
            first_party_wheel_dirs.append(struct(
                name = info.package_name,
                dir = wheel_packages[info.package_name],
            ))
        elif info.pyproject:
            srcs = info.srcs.to_list()
            editables.append({
                "pyproject": rlocation_path(ctx, info.pyproject),
                "srcs": [rlocation_path(ctx, f) for f in srcs],
            })

            # Include the actual File objects in runfiles so they're
            # available at the rlocation paths written above.
            runfiles_inputs.append(info.pyproject)
            runfiles_inputs.extend(srcs)

    return struct(
        editables = editables,
        runfiles_inputs = runfiles_inputs,
        first_party_wheel_dirs = first_party_wheel_dirs,
        dep_runfiles = dep_runfiles,
    )

def _pythonic_devenv_impl(ctx):
    py_toolchain = ctx.toolchains[_PY_TOOLCHAIN]
    py_runtime = py_toolchain.py3_runtime
    python = py_runtime.interpreter
    uv = ctx.executable._uv

    dep_info = _collect_devenv_info(ctx, ctx.attr.deps)

    # Collect third-party wheel files.
    wheels = []
    for whl_target in ctx.attr.wheels:
        wheels.extend(whl_target.files.to_list())

    # Write JSON manifest. All paths are rlocation keys resolved at run time
    # against $RUNFILES_DIR, except constraints which is workspace-relative.
    manifest = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    manifest_content = {
        "venv_path": ctx.attr.venv_path,
        "editables": dep_info.editables,
        "first_party_wheels": [
            {"name": fp.name, "dir": rlocation_path(ctx, fp.dir)}
            for fp in dep_info.first_party_wheel_dirs
        ],
        "extras": ctx.attr.extras,
        "third_party_wheels": [
            rlocation_path(ctx, w)
            for w in wheels
        ],
    }
    if ctx.attr.constraints:
        manifest_content["constraints"] = ctx.file.constraints.short_path

    ctx.actions.write(
        output = manifest,
        content = json.encode(manifest_content),
    )

    # Generate launcher from template.
    launcher = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._launcher_template,
        output = launcher,
        substitutions = {
            "{{PYTHON_TOOLCHAIN}}": rlocation_path(ctx, python),
            "{{UV_TOOLCHAIN}}": rlocation_path(ctx, uv),
            "{{MANIFEST}}": rlocation_path(ctx, manifest),
            "{{SETUP_SCRIPT}}": rlocation_path(ctx, ctx.file._setup_devenv),
        },
        is_executable = True,
    )

    # Assemble runfiles.
    runfiles_files = [manifest, ctx.file._setup_devenv, ctx.file._staging] + wheels
    runfiles_files.extend([fp.dir for fp in dep_info.first_party_wheel_dirs])
    runfiles_files.extend(dep_info.runfiles_inputs)

    runfiles = ctx.runfiles(
        files = runfiles_files,
        transitive_files = py_runtime.files,
    )
    for dr in dep_info.dep_runfiles:
        runfiles = runfiles.merge(dr)
    runfiles = runfiles.merge(ctx.attr._uv[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr._bash_runfiles[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = launcher,
        runfiles = runfiles,
    )]

_pythonic_inner_devenv = rule(
    implementation = _pythonic_devenv_impl,
    executable = True,
    attrs = {
        "deps": attr.label_list(
            providers = [PythonicPackageInfo],
            doc = "First-party packages. Source targets get editable installs; " +
                  ".wheel targets get wheel installs.",
        ),
        "wheels": attr.label_list(
            allow_files = True,
            doc = "Filegroup(s) of @pypi wheel targets. Enables hermetic mode.",
        ),
        "constraints": attr.label(
            allow_single_file = True,
            doc = "Requirements file used as --constraint in resolving mode.",
        ),
        "extras": attr.string_list(
            doc = "Optional dependency groups to install (e.g., dev, test).",
        ),
        "venv_path": attr.string(
            default = ".venv",
            doc = "Venv location relative to workspace root.",
        ),
        "_uv": attr.label(
            default = "@multitool//tools/uv",
            executable = True,
            cfg = "target",
        ),
        "_setup_devenv": attr.label(
            default = "//pythonic/private:setup_devenv.py",
            allow_single_file = True,
        ),
        "_staging": attr.label(
            default = "//pythonic/private:staging.py",
            allow_single_file = True,
        ),
        "_launcher_template": attr.label(
            default = "//pythonic/private:pythonic_devenv.tmpl.sh",
            allow_single_file = True,
        ),
        "_bash_runfiles": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
    },
    toolchains = [_PY_TOOLCHAIN],
    doc = "Create a Python venv with third-party and first-party packages for IDE use.",
)

def pythonic_devenv(name, wheels = [], constraints = None, extras = [], venv_path = ".venv", **kwargs):
    """Create a dev environment target for IDE completion and type checking.

    Run with `bazel run //:devenv` to create or update the venv.

    Two modes:
    - Hermetic (wheels provided): installs @pypi wheels first, then
      editable-installs first-party with --no-index --find-links to validate
      all declared deps are satisfiable.
    - Resolving (no wheels): editable-installs first-party packages, uv
      resolves third-party from PyPI. Use constraints= for version pinning.

    Args:
        name: Target name.
        wheels: Labels to @pypi wheel filegroups. Enables hermetic mode.
        constraints: Requirements file for --constraint in resolving mode.
        extras: Optional dependency groups (e.g., ["dev", "test"]).
        venv_path: Venv location relative to workspace root. Defaults to ".venv".
        **kwargs: Forwarded attrs (deps, tags, visibility).
    """
    _pythonic_inner_devenv(
        name = name,
        wheels = wheels,
        constraints = constraints,
        extras = extras,
        venv_path = venv_path,
        **kwargs
    )
