"Provider definitions for rules_pythonic."

PythonicPackageInfo = provider(
    doc = "Information about a Python package for rules_pythonic.",
    fields = {
        "src_root": "String. Path relative to workspace root added to PYTHONPATH (e.g., 'packages/attic/src').",
        "srcs": "Depset of Files. Source files that make up this package.",
        "pyproject": "File or None. The pyproject.toml for this package. None for pythonic_files targets.",
        "wheel": "File or None. A built .whl file. None until wheel building is implemented.",
        "first_party_deps": "Depset of PythonicPackageInfo. Transitive closure of first-party dependencies.",
    },
)
