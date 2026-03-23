"pythonic_files — declare importable Python files without a pyproject.toml."

load(":providers.bzl", "PythonicPackageInfo")

def _pythonic_files_impl(ctx):
    src_root = ctx.label.package
    if ctx.attr.src_root and ctx.attr.src_root != ".":
        src_root = src_root + "/" + ctx.attr.src_root if src_root else ctx.attr.src_root

    runfiles = ctx.runfiles(files = ctx.files.srcs + ctx.files.data)

    return [
        PythonicPackageInfo(
            package_name = ctx.label.name,
            src_root = src_root,
            srcs = depset(ctx.files.srcs),
            pyproject = None,
            wheel = None,
            first_party_deps = depset(),
        ),
        DefaultInfo(
            files = depset(ctx.files.srcs),
            runfiles = runfiles,
        ),
    ]

pythonic_files = rule(
    implementation = _pythonic_files_impl,
    attrs = {
        "src_root": attr.string(
            mandatory = True,
            doc = "Directory added to PYTHONPATH, relative to this package.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Source files (no file type filter — .py, .so, .pyi, .json, etc.).",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Non-Python runtime files.",
        ),
    },
    doc = "Declare importable Python files that have no pyproject.toml or third-party deps.",
)
