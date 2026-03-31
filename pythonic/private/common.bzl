"Shared helpers for pythonic_test and pythonic_binary."

load(":providers.bzl", "PythonicPackageInfo")

def rlocation_path(ctx, file):
    """Return the rlocation key for a file.

    File.short_path for external repos starts with "../", e.g.
    "../rules_python++python+python_3_11/bin/python3". The runfiles manifest
    stores these under the repo name directly:
    "rules_python++python+python_3_11/bin/python3". Passing the "../" form
    to rlocation() fails because the bash runfiles helper rejects relative
    paths.

    This is the standard pattern used by rules_python (runfiles_root_path
    in python/private/common.bzl) and rules_cc (root_relative_path in
    cc/common/cc_helper_internal.bzl).
    """
    if file.short_path.startswith("../"):
        return file.short_path[3:]
    return ctx.workspace_name + "/" + file.short_path

def collect_dep_info(deps):
    """Walk the dep graph and collect everything the install action needs.

    Deps that provide a built wheel (PythonicPackageInfo.wheel != None) are
    routed to the install action as first-party wheels rather than placed on
    PYTHONPATH as source roots. When the same package_name appears both as a
    wheel (direct dep) and as source (transitive), wheel wins — the explicit
    choice dominates the implicit one.

    Args:
        deps: List of targets providing PythonicPackageInfo.

    Returns:
        A struct with:
            src_roots: list[str] — PYTHONPATH entries for first-party code.
            pyprojects: list[File] — pyproject.toml files for dep validation.
            first_party_names: list[str] — package names to skip in install_packages.py.
            first_party_wheel_dirs: list[File] — TreeArtifact dirs containing .whl files.
            dep_runfiles: list[runfiles] — runfiles from all deps for merging.
    """
    src_roots = []
    pyprojects = []
    first_party_names = []
    first_party_wheel_dirs = []
    dep_runfiles = []

    # First pass: collect all infos and identify which packages have wheels.
    # wheel_packages tracks package_name -> wheel File for dedup.
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

    # Second pass: partition into wheel deps vs source deps.
    # Wheel wins: if a package appears in wheel_packages, it gets installed
    # as a wheel regardless of whether it also appears as a source dep.
    seen_names = {}
    for info in all_infos:
        if info.package_name in seen_names:
            continue
        seen_names[info.package_name] = True

        if info.pyproject:
            pyprojects.append(info.pyproject)

        if info.package_name in wheel_packages:
            first_party_wheel_dirs.append(wheel_packages[info.package_name])
        else:
            src_roots.append(info.src_root)
            first_party_names.append(info.package_name)

    return struct(
        src_roots = src_roots,
        pyprojects = pyprojects,
        first_party_names = first_party_names,
        first_party_wheel_dirs = first_party_wheel_dirs,
        dep_runfiles = dep_runfiles,
    )

def build_pythonpath(ctx, package_src_roots):
    """Build PYTHONPATH from first-party source roots using rlocation.

    Source roots are placed before the packages directory in the launcher,
    so first-party code shadows third-party packages of the same name.

    Args:
        ctx: Rule context (for workspace_name).
        package_src_roots: list[str] — workspace-relative paths like "packages/attic/src".

    Returns:
        A colon-separated string of rlocation calls with a trailing colon
        separator, or empty string if no source roots. The trailing colon
        lets the launcher template concatenate PACKAGES_DIR without a
        leading colon when there are no first-party entries.
    """
    entries = []
    for sr in package_src_roots:
        entries.append('"$(rlocation {workspace}/{sr})"'.format(
            workspace = ctx.workspace_name,
            sr = sr,
        ))
    if not entries:
        return ""
    return ":".join(entries) + ":"

def uv_action_env(ctx):
    """Extract UV_CACHE_DIR from --action_env for use in ctx.actions.run(env=...).

    Reads the fixed action environment (populated by --action_env=K=V flags)
    and returns a dict containing only UV_CACHE_DIR.  This avoids
    use_default_shell_env=True, which leaks the full host environment into the
    action when --incompatible_strict_action_env is not set.

    Args:
        ctx: Rule context.

    Returns:
        dict[str, str] with UV_CACHE_DIR if present, empty dict otherwise.
    """
    shell_env = ctx.configuration.default_shell_env
    uv_cache = shell_env.get("UV_CACHE_DIR")
    if uv_cache:
        return {"UV_CACHE_DIR": uv_cache}
    return {}

def build_env_exports(env_dict):
    """Build shell export lines from a string dict.

    TODO(rules_pythonic-jq9): needs a .bat equivalent for Windows support.

    Args:
        env_dict: dict[str, str] — environment variable name-value pairs.

    Returns:
        A string of shell export lines, e.g.: 'export FOO="bar"\\nexport BAZ="qux"\\n'
    """
    lines = ""
    for k, v in env_dict.items():
        # Escape shell metacharacters that are special inside double quotes.
        escaped = v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
        lines += 'export {key}="{value}"\n'.format(key = k, value = escaped)
    return lines
