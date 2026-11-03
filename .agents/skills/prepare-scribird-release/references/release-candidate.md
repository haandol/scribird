# Candidate and version

Inspect the working tree, branch and remote, then fetch the history and tags needed
to compare the candidate with the preceding release. From the checkout, run:

```bash
"$SKILL_DIR/scripts/collect_release_facts.sh" --online
```

Use `--target <ref>` for a specific candidate and omit `--online` only when GitHub
access is unavailable. The collector is read-only. Its commit range excludes
uncommitted files; review and commit authorized changes before fixing a new target.
Do not package an ambiguous mixture of the candidate and unrelated local edits.

Confirm the collected base is a stable `vX.Y.Z` tag and compare it with the latest
published GitHub release. Read the complete commit messages and diff since that
base, including affected ADRs and user documentation. PRs/issues and automatically
generated notes can reveal omissions, but the target commit is the shipping evidence.
If target and published tag are identical with no new changes, do not invent an
empty next release. On a retry, inspect existing tags, releases and assets first.

Use the user's exact version or requested increment. Otherwise increment the patch
component; a `feat` label or a large diff does not authorize a minor bump. If a real
compatibility conflict requires a user decision, explain that conflict with the
prepared changes. Do not retain assumptions about an old `0.1.x` release series.

Keep these values consistent:

- `CFBundleShortVersionString`, annotated tag `vX.Y.Z` and title `Scribird X.Y.Z`.
- `CFBundleVersion`, a positive integer greater than the preceding public build.
- `build/Scribird-X.Y.Z.zip` and its `.sha256` companion.
- Independently versioned plugin manifests and their marketplace entries when that
  plugin changes; preserve agent-specific build metadata and unrelated pins.

Calculate increments with Python and use the project's version tooling, or `plutil`
for the two bundle fields. Inspect the resulting diff. A version-only commit follows
the repository convention `chore: bump version to X.Y.Z`. Keep the version fixed
across retries unless the existing published state requires a new release.
