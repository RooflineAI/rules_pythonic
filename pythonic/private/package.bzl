"pythonic_package rule — declares a Python package for rules_pythonic."

load(":providers.bzl", "PythonicPackageInfo")

def _pythonic_package_impl(ctx):
    # Combine the BUILD file's directory with the user's src_root to get
    # the full workspace-relative path. For a BUILD at packages/attic/ with
    # src_root="src", this produces "packages/attic/src". For a BUILD at the
    # workspace root with src_root="src", ctx.label.package is "" so we
    # use src_root directly.
    src_root = ctx.label.package
    if ctx.attr.src_root and ctx.attr.src_root != ".":
        src_root = src_root + "/" + ctx.attr.src_root if src_root else ctx.attr.src_root

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

pythonic_package = rule(
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
