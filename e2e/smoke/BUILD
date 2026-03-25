load("@pypi//:requirements.bzl", "all_whl_requirements")
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_devenv")

# pythonic_test needs all @pypi wheels as inputs so install_packages.py can
# install the full transitive closure. This filegroup collects them into a
# single target that pythonic_test references via wheels = ["//:all_wheels"].
filegroup(
    name = "all_wheels",
    srcs = all_whl_requirements,
    visibility = ["//visibility:public"],
)

# Hermetic devenv: third-party from @pypi wheels, validated with --no-index.
# assembled_pkg uses .wheel because its source is assembled by Bazel.
pythonic_devenv(
    name = "devenv",
    deps = [
        "//assembled_pkg:assembled_pkg.wheel",
        "//mypackage",
    ],
    extras = ["test"],
    wheels = ["//:all_wheels"],
)

# Resolving devenv: uv resolves third-party from PyPI, pinned by constraints.
pythonic_devenv(
    name = "devenv_constrained",
    deps = [
        "//assembled_pkg:assembled_pkg.wheel",
        "//mypackage",
    ],
    constraints = "requirements.txt",
    extras = ["test"],
    venv_path = ".venv-constrained",
)

# Unconstrained devenv: uv resolves freely from PyPI. Quickest to set up,
# but versions may drift from what Bazel uses.
pythonic_devenv(
    name = "devenv_unconstrained",
    deps = [
        "//assembled_pkg:assembled_pkg.wheel",
        "//mypackage",
    ],
    extras = ["test"],
    venv_path = ".venv-unconstrained",
)

# Editable devenv for assembled_pkg: uses the source target (not .wheel),
# so uv pip install -e points at the bazel-bin assembled tree. Edits to
# input files propagate through the copy_to_directory symlinks.
pythonic_devenv(
    name = "devenv_editable_assembled",
    deps = [
        "//assembled_pkg",
        "//mypackage",
    ],
    extras = ["test"],
    venv_path = ".venv-editable-assembled",
    wheels = ["//:all_wheels"],
)
