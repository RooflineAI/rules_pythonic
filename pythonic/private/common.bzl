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

def build_pythonpath(ctx, package_src_roots):
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
