# Changelog

Two independent tag families version the shared release infrastructure in
`.github/`. Consumers pin a floating major (`@v1` or `@pypi-v1`); each move of a
floating major is anchored by an immutable point tag (`v1.0.0`, `pypi-v1.0.0`, …).

- **`v1` family** — Go: the composite actions (`verify-tag-on-main`,
  `import-developer-id` + `macos-codesign.sh`, `render-formula`,
  `sign-notarize-app`, `publish`) and the `release-go.yml` reusable workflow.
- **`pypi-v1` family** — Python: the `release-pypi-build.yml` reusable workflow.

## v1.0.0 — 2026-07-01 (`07ab3a8`; `v1` points here)

First pinned point release of the Go family, covering the series to date:

- Initial shared infrastructure: the five composite actions and `release-go.yml`,
  the one parameterized release workflow every Go repo's `release.yml` collapses
  to (quill or codesign signing, optional auto-tag, optional
  `render-formula` + `publish` for the rich formulae goreleaser's `brews` block
  can't express).
- bash-3.2-safe empty-array expansion in `macos-codesign.sh` (macOS runners
  invoke it under `/bin/bash` 3.2).
- Notarization retry: `notarytool submit` retried up to 3x with backoff in both
  `macos-codesign.sh` and `sign-notarize-app`; a non-`Accepted` verdict stays
  terminal (fail loud, never retried).

## pypi-v1.0.0 — 2026-07-01 (`193e039`; `pypi-v1` points here)

First pinned point release of the Python family:

- At `v1` the Python path was a monolithic `release-pypi.yml` (build + publish
  in one workflow). PyPI trusted publishing authenticates the *caller's*
  `job_workflow_ref`, so a reusable workflow can never hold the OIDC publish —
  the monolith was split and renamed into the build-only
  `release-pypi-build.yml`, and each caller runs its own OIDC publish job
  against the workflow's `tag` output.
- Because of the rename, `release-pypi-build.yml@v1` does not exist: Python
  callers pin `@pypi-v1`, Go callers pin `@v1`.

## Cutting a release (tag-move procedure)

1. Land the change on `main` (CI in `test.yml` must be green — a floating-major
   move ships to every fleet repo at once).
2. Cut the next immutable point tag:
   `git tag vX.Y.Z && git push origin vX.Y.Z` (or `pypi-vX.Y.Z`). Point tags
   are protected by a repository ruleset and never move.
3. Force-move the floating major consumers pin:
   `git tag -f v1 vX.Y.Z && git push -f origin v1` (or `pypi-v1`).
