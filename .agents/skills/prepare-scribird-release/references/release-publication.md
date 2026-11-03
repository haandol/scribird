# Push and publish

Use this stage only for an authorized publication request. Before the first remote
write, show the prepared version, target SHA, release title, final notes path and
asset checksum in a concise progress update. Existing authorization for this
release remains valid; another routine permission question is not required.

Follow the repository's allowed branch path. When a PR/review is required, push the
candidate branch, create or reuse the PR, satisfy the required checks/reviews and
merge normally. Otherwise push through the allowed branch path. Never use an
administrator bypass, force push, disabled hook or weakened protection.

Verify the merged/pushed commit contains the intended source and versions. Wait
for CI on that exact commit to finish successfully, then create and push an
annotated `vX.Y.Z` tag pointing to it. Do not tag a stale local head or an unmerged
branch. Check existing remote tags/releases before retrying; a conflicting public
tag is not something to move silently.

Create a draft with the signed ZIP and checksum, using a notes file so the content
retains real newlines:

```bash
gh release create "v${release_version}" \
  "build/Scribird-${release_version}.zip" \
  "build/Scribird-${release_version}.zip.sha256" \
  --repo haandol/scribird --draft --verify-tag --fail-on-no-commits \
  --title "Scribird ${release_version}" \
  --notes-file "build/release-notes-v${release_version}.md"
```

Inspect the draft's tag commit, title, body, asset names and digests. Publish it
under the existing release authorization and confirm its public/Latest state.
Do not use `--clobber` to replace a public asset. Download the published ZIP to a
new temporary directory when possible, then compare its checksum and extracted
signature with the verified local artifact.

Finish with the released version, public URL and actual validation result. For a
preparation-only request, report the local result and scope instead. If a real
blocker prevents publication, retain the prepared work and identify that blocker;
do not report a draft or successful push as a published release.
