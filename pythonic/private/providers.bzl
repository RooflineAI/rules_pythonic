"Provider definitions for rules_pythonic."

PythonicPackageInfo = provider(
    doc = "Information about a Python package for rules_pythonic.",
    fields = {
        "package_name": "String. Distribution name used to identify this package (e.g., 'mypackage'). Defaults to the Bazel target name.",
        "src_root": "String. Path relative to workspace root added to PYTHONPATH (e.g., 'packages/attic/src').",
        "srcs": "Depset of Files. Source files that make up this package.",
        "pyproject": "File or None. The pyproject.toml for this package. None for pythonic_files targets.",
        "wheel": "File or None. TreeArtifact directory containing a built .whl. Set by .wheel targets, None for source targets and pythonic_files.",
        "first_party_deps": "Depset of PythonicPackageInfo. Transitive closure of first-party dependencies.",
    },
)
