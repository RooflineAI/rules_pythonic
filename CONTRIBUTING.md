# How to Contribute

## Formatting

Starlark files should be formatted by buildifier.
We suggest using a pre-commit hook to automate this.
First [install pre-commit](https://pre-commit.com/#installation),
then run

```shell
pre-commit install
```

Otherwise later tooling on CI will yell at you about formatting/linting violations.

## Updating BUILD files

BUILD files are maintained manually. Do not use gazelle.

## Using this as a development dependency of other rules

To always tell Bazel to use this directory rather than some release
artifact or a version fetched from the internet, run this from the
repo root:

```sh
echo "common --override_repository=rules_pythonic=$(pwd)" >> ~/.bazelrc
```

This means that any usage of `@rules_pythonic` on your system will point to this folder.

## Running tests

```sh
uv run pytest pythonic/private/tests/    # Python unit tests (fast, no Bazel)
bazel test //e2e/smoke:*                 # End-to-end smoke tests
```

E2e smoke tests require a `user.bazelrc` with `UV_CACHE_DIR` and
`sandbox_writable_path` configured. See the Consumer Setup section
in CLAUDE.md.

## Releasing

Releases are automated on a cron trigger.
The new version is determined automatically from the commit history, assuming the commit messages follow conventions, using
https://github.com/marketplace/actions/conventional-commits-versioner-action.
If you do nothing, eventually the newest commits will be released automatically as a patch or minor release.
This automation is defined in .github/workflows/tag.yaml.

Rather than wait for the cron event, you can trigger manually. Navigate to
https://github.com/RooflineAI/rules_pythonic/actions/workflows/tag.yaml
and press the "Run workflow" button.

If you need control over the next release version, for example when making a release candidate for a new major,
then: tag the repo and push the tag, for example

```sh
% git fetch
% git tag v1.0.0-rc0 origin/main
% git push origin v1.0.0-rc0
```

Then watch the automation run on GitHub actions which creates the release.
