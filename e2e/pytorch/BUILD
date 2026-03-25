load("@pypi//:requirements.bzl", "all_whl_requirements")
load("@rules_pythonic//pythonic:defs.bzl", "pythonic_devenv")

filegroup(
    name = "all_wheels",
    srcs = all_whl_requirements,
    visibility = ["//visibility:public"],
)

# Hermetic devenv with platform-specific wheels from @pypi.
pythonic_devenv(
    name = "devenv",
    wheels = ["//:all_wheels"],
    deps = [
        "//model",
    ],
)
