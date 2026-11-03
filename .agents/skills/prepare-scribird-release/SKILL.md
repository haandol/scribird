---
name: prepare-scribird-release
description: Prepare, audit or publish a Scribird release from verified shipped changes, with Korean release notes, synchronized versions, signed ZIP assets and confirmed GitHub state. Use for release preparation, release-note work, readiness checks or requested publication; ordinary feature development uses its own workflow.
---

# Prepare Scribird Release

Keep the release commit, public description and downloadable app consistent. Use
the repository's existing build/check scripts and GitHub CLI; do not create a
per-release replacement pipeline.

## Scope and authorization

- A preparation-only or audit request ends at the requested local artifacts or
  findings. An explicit push/release request authorizes publication after the
  required checks. Honor authorization already established in the session; do not
  ask again solely because a later stage is remote. Follow the caller's version
  preference, defaulting to patch unless minor/major or an exact version is requested.
- Preserve unrelated work and existing public releases. Do not overwrite published
  tags/assets or include recorded meetings, generated transcripts, credentials or
  personal paths in commits, notes or assets.
- Respect branch protection, required reviews and CI. Report a real signing,
  review, permission or verification blocker; never bypass it or describe an
  unperformed check as passed. An applicable hardware check remains required.
- Versioning, notes and packaging do not themselves need an ADR. Follow the
  repository's ADR-first rules if preparation requires a product behavior change.

## Resolve the working paths

Use the actual checkout as the working directory and read its `AGENTS.md`,
`CONTRIBUTING.md`, `README.md`, `Resources/Info.plist` and `build.sh`. Read affected
ADRs and troubleshooting guidance when assessing release impact.

`SKILL_DIR` means the absolute directory containing this file; it is not a
pre-existing environment variable. Invoke its bundled facts collector by that
absolute path from the checkout. Keep generated notes, logs and packages under
ignored `build/` unless the user chooses another output location.

## Load the current stage

| Stage | Reference and result |
| --- | --- |
| Candidate and version | [release-candidate.md](references/release-candidate.md): fixed target, preceding public release and synchronized versions. |
| Public explanation | [release-notes.md](references/release-notes.md): Korean notes grounded in shipped changes and real checks. |
| Validation and packaging | [release-validation.md](references/release-validation.md): relevant tests, signed app, verified ZIP and checksum. |
| Push and publication | [release-publication.md](references/release-publication.md): required merge/CI path, immutable tag, draft asset verification and publication. |

Read only the stages the request needs. Continue an authorized publication to a
verified public release; a local bump, draft or successful push alone is not completion.
