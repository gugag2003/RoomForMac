# Release hooks

A release hook is an executable file in this folder that a release runs at a fixed point. `scripts/release-hook.sh` is the only thing that runs one:

```bash
scripts/release-hook.sh [--required] <name> [args...]
```

- The hook exists and is executable: it runs in the caller's working directory (`release.yml` sets the repository root) with `args...`, and its exit status is returned.
- The hook does not exist: the script prints `skipped: no release hook <name>` to stderr and exits 0, or exits 1 with `--required`.
- The hook exists but is not executable: exit 1, with or without `--required`.
- A name is lower-case words joined by hyphens, so a hook file has no extension. `README.md` is not a hook.

There is one hook, `token-fixture`, and it is implemented by the licensing work (Plan 5). Until it adds the file, the release skips it.

## `token-fixture`

```
scripts/release-hooks/token-fixture <version> <published-tags-file> <paths-out-file>
```

- `<version>` is `X.Y.Z`, without a `v`.
- `<published-tags-file>` lists the tags of the published releases (drafts excluded), one `vX.Y.Z` per line. It may be empty.
- `<paths-out-file>` is where the hook writes its result.

Environment it may read, both empty until the licensing work sets them:

- `RFM_FIXTURE_TOKEN_URL` (a repository variable);
- `RFM_FIXTURE_TOKEN_KEY` (a secret of the `release` environment).

The hook must:

- fail when any tag in `<published-tags-file>` lacks its committed fixture;
- fetch this version's fixture from the live server into the working tree;
- run the legacy-token tests, including the new fixture;
- write the repository-relative paths of the new files to `<paths-out-file>`, one per line;
- print no secret. Never `set -x`, and never echo `RFM_FIXTURE_TOKEN_KEY` or a response that contains a token key.

The hook may write nothing to `<paths-out-file>`. That means "no fixture this release", and `release.yml`'s `fixture` job is skipped. When the file lists paths, the `build` job uploads them as the `token-fixture` artifact, and the `fixture` job commits them on the branch `release/token-fixture-X.Y.Z` and opens a pull request.

## How `release.yml` runs it

The step `Token fixture (release hook)` of the `build` job runs `scripts/release-hook.sh token-fixture "$VERSION" "$RUNNER_TEMP/published-tags.txt" "$paths"` (`$paths` is `$RUNNER_TEMP/fixture-paths.txt`) without `--required`, so a release never waits for the licensing work. When Plan 5 adds the hook file it also:

- adds `--required` to that one step, so a missing hook fails the release from then on;
- changes the test in `scripts/tests/release_preflight.bats` that pins this folder to `README.md` alone;
- changes the check in `scripts/tests/workflows.bats` that forbids `--required`.

Other release steps that the licensing work needs, such as the price check of spec section 16, are steps of its own in `release.yml`. They are not hooks.
