load("@pypi//:requirements.bzl", "all_whl_requirements")

# pythonic_test needs all @pypi wheels as inputs so install_packages.py can
# install the full transitive closure. This filegroup collects them into a
# single target that pythonic_test references via wheels = ["//:all_wheels"].
filegroup(
    name = "all_wheels",
    srcs = all_whl_requirements,
    visibility = ["//visibility:public"],
)
