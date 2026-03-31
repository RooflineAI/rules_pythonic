"""Bazel <-> pytest bridge for rules_pythonic.

Translates Bazel test protocol environment variables into pytest arguments.
No external dependencies beyond pytest (which is in the installed packages).
"""

import os
import pathlib
import sys


def main():
    """Run pytest with Bazel test protocol support.

    Handles the env vars Bazel sets for test execution:
    - TEST_SHARD_STATUS_FILE: touch to signal sharding support
    - TEST_SHARD_INDEX / TEST_TOTAL_SHARDS: file-level sharding
    - TESTBRIDGE_TEST_ONLY: test filter (maps to pytest -k)
    - XML_OUTPUT_FILE: JUnit XML output path (maps to --junitxml)
    - RUNFILES_DIR: used to anchor --rootdir for conftest.py discovery

    See https://bazel.build/reference/test-encyclopedia for the full protocol.
    """
    test_files = sys.argv[1:]

    shard_status = os.environ.get("TEST_SHARD_STATUS_FILE")
    if shard_status:
        pathlib.Path(shard_status).touch()

    shard_index = os.environ.get("TEST_SHARD_INDEX")
    total_shards = os.environ.get("TEST_TOTAL_SHARDS")
    if shard_index is not None and total_shards is not None:
        i, n = int(shard_index), int(total_shards)
        test_files = [f for idx, f in enumerate(sorted(test_files)) if idx % n == i]
        if not test_files:
            sys.exit(0)

    args = list(test_files)

    test_filter = os.environ.get("TESTBRIDGE_TEST_ONLY")
    if test_filter:
        args.extend(["-k", test_filter])

    xml_output = os.environ.get("XML_OUTPUT_FILE")
    if xml_output:
        args.extend(["--junitxml", xml_output])

    runfiles_dir = os.environ.get("RUNFILES_DIR", "")
    repo_root = os.path.join(runfiles_dir, "_main")
    if os.path.isdir(repo_root):
        args.extend(["--rootdir", repo_root])

    import pytest

    sys.exit(pytest.main(args))


if __name__ == "__main__":
    main()
