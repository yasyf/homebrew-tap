# Changelog

Four independent tag families version the shared release infrastructure in
`.github/`. Consumers pin a floating major (`@v1`, `@pypi-v1`, `@swift-v1`, or
`@bun-v1`); each move of a floating major is anchored by an immutable point tag
(`v1.0.0`, `pypi-v1.0.0`, `swift-v1.0.0`, `bun-v1.0.0`, …).

- **`v1` family** — Go: the composite actions (`verify-tag-on-main`,
  `import-developer-id` + `macos-codesign.sh`, `render-formula`,
  `sign-notarize-app`, `wrap-daemon-bundle`, `publish`) and the `release-go.yml`
  reusable workflow.
- **`pypi-v1` family** — Python: the `release-pypi-build.yml` reusable workflow.
- **`swift-v1` family** — Swift: the `release-swift.yml` reusable workflow and
  the `build-swift-universal` + `sign-notarize-binary` composite actions.
- **`bun-v1` family** — Bun: the `release-bun.yml` reusable workflow and the
  `build-bun-binary` composite action.

## Unreleased (`v1` family)

- New `wrap-daemon-bundle` composite action. It wraps a bare universal Mach-O
  daemon in a minimal signed + notarized + stapled `.app` so the service's macOS
  TCC grant is keyed by `CFBundleIdentifier` (`client_type=0`) and survives
  `brew upgrade`, instead of the path-keyed (`client_type=1`) grant a bare Mach-O
  earns — which resets to a fresh client every release and re-prompts the user.
  Assembles `Info.plist` (`LSUIElement=true`, not `LSBackgroundOnly`) +
  `Contents/MacOS/<exe>` + an optional embedded Developer ID provisioning profile,
  codesigns with the bundle id as identifier (+ optional entitlements), notarizes
  (fail-loud on non-Accepted), and staples. When a profile is embedded it asserts
  the profile's `Entitlements` authorize `com.apple.security.application-groups`,
  so an app-group service can't ship a bundle that silently re-prompts. Reads
  `MACOS_SIGN_IDENTITY` / `MACOS_NOTARY_*` from the env like `sign-notarize-app`
  (run `import-developer-id` first). Consumers pin `@v1` after the floating major
  is force-moved onto the point tag that ships this.

## Unreleased (`bun-v1` family)

Both found by cc-pane's `v0.1.0-rc.1` prerelease dry-run:

- Darwin legs sign with bun's documented codesign entitlements by default
  (allow-jit, allow-unsigned-executable-memory,
  disable-executable-page-protection, allow-dyld-environment-variables,
  disable-library-validation — bun.com/docs/bundler/executables § Code signing
  on macOS); the `entitlements` input now replaces the set instead of being the
  only way to get one. disable-library-validation is the load-bearing
  entitlement: a compiled bun binary extracts embedded native dylibs (FFI deps
  like OpenTUI) to `$TMPDIR` and dlopens them, and under the hardened runtime
  library validation rejects any dylib not signed with the process's Team ID —
  the rc.1 binary launched (`--version` fine) but died initializing the TUI
  with "mapping process and mapped file (non-platform) have different Team
  IDs".
- Darwin legs re-run `smoke-command` against the SIGNED binary after
  sign-notarize-binary. The pre-sign smoke proves the build; signing rewrites
  the Mach-O and the hardened runtime changes dyld behavior, so only a
  post-sign smoke proves the artifact that ships (codesigning a bun binary
  wrongly can break it outright — a bad local re-sign SIGTRAPs at launch).

## bun-v1.0.0 — 2026-07-18 (`1db2d14`; `bun-v1` points here)

First pinned point release of the Bun family:

- `release-bun.yml`, the one parameterized release workflow every bun-compiled
  CLI/TUI's `release.yml` collapses to. bun has no goreleaser builder, and a
  project with platform-native deps can't cross-compile (bun refuses to extract
  a platform-mismatched optional dep; `--target` inlines `process.platform`,
  making the target's platform package a hard build-time dep), so each target
  builds on its own native runner: verify-tag-on-main (or the idempotent
  go-style auto-tag), a 4-leg matrix (darwin-arm64/macos-15,
  darwin-x64/macos-15-intel, linux-x64/ubuntu-24.04,
  linux-arm64/ubuntu-24.04-arm) with `.bun-version` as the mandatory toolchain
  pin, codesign + notarytool on the darwin legs, one release-job softprops call
  owning the GitHub release (prerelease on hyphenated tags, which skip the
  cask), and a rendered 4-platform binary cask (on_macos/on_linux ×
  on_arm/on_intel, quarantine-strip postflight) published via `render-formula`
  custom tokens (the auto-sha path is goreleaser-naming-hardwired). Zero-config:
  every input defaults — entry point `src/index.ts`, binary/cask named after
  the repo. An `entitlements` input exports a codesign entitlements plist for
  JIT runtimes under the hardened runtime.
- `build-bun-binary`: frozen `bun install` retried 3x, `bun build --compile
  --target=bun-<platform>`, executable + `file`-keyed Mach-O/ELF format assert
  (the `lipo -archs` analogue; refuses targets outside the release matrix).
- `sign-notarize-binary` (swift-v1 family) gains an optional `platform` input
  defaulting to `darwin-universal` — the default path is behavior-identical, so
  swift callers are untouched; `release-bun.yml` passes the per-arch platform to
  name `<name>-<tag>-<platform>.zip` and the codesign slice label.
- actionlint bumped 1.7.7 → 1.7.12 in `test.yml` (1.7.7 predates the
  `macos-15-intel` runner label).
- None of this exists at `v1`: bun callers pin `@bun-v1`, and so does every
  `uses:` inside `release-bun.yml` itself, so the bun family repoints without
  ever moving `v1` or `swift-v1`.

## v1.1.1 — 2026-07-09 (`f010672`; `v1` points here)

- `release-go.yml` auto-tag is idempotent, so a release that fails after the tag
  is pushed can be rerun. The step tagged `v0.1.<run_number>` unconditionally, but
  a rerun keeps the same run_number, so `git tag` aborted with exit 128 ("tag
  already exists") and a release that died downstream (goreleaser on a missing
  secret, a notarize blip past the retries) was stuck. The step now reuses a tag
  already at the run's commit — checked against both the fetched clone and origin,
  annotated or lightweight — fails loud on a tag at a different commit, and never
  retags or forces. `GORELEASER_CURRENT_TAG` is exported on the reuse path too, so
  the reused tag reaches goreleaser exactly as a freshly cut one.

## v1.1.0 — 2026-07-07 (`849c947`)

- `macos-codesign.sh` gains an optional `MACOS_CODESIGN_IDENTIFIER` — an explicit
  `codesign --identifier` for a bare CLI Mach-O that holds a TCC privacy grant.
  tccd keys the grant by the signing identifier only when it is reverse-DNS-shaped
  (dotted); codesign otherwise defaults the identifier to the binary basename, and
  an undotted basename makes tccd key on the absolute executable path — so every
  `brew upgrade` (new Cellar path) is a fresh client and re-prompts. A stable dotted
  identifier is keyed once and the grant survives upgrades. Unset leaves the
  `codesign` command byte-identical (bash-3.2-safe empty-array expansion, like
  `MACOS_CODESIGN_ENTITLEMENTS`). `.app` bundles don't need it (they key on
  `CFBundleIdentifier`).

## v1.0.0 — 2026-07-01 (`07ab3a8`)

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

## swift-v1.0.1 — 2026-07-02 (`b584afc`; `swift-v1` points here)

Hardening from the adversarial review of the first release, all three
confirmed by reproduction:

- Cask metadata (`desc`/`homepage`) now escapes sed's replacement-string
  specials (`&`, `\`) in addition to stripping the delimiter — a repo
  description like "Search & replace CLI" previously rendered the token name
  into the cask and failed the leftover-token guard.
- The formula-collision guard fails closed: it switches on the explicit HTTP
  status (404 = clear, 200 = collision, anything else = refuse to release
  blind) instead of treating every curl failure as "no formula".
- Hyphenated tags (prereleases) skip the cask render/publish — brew has no
  prerelease channel, so the tap only advances on final tags (goreleaser
  `skip_upload: auto` parity).

## swift-v1.0.0 — 2026-07-02 (`4fc6a61`)

First pinned point release of the Swift family:

- `release-swift.yml`, the one parameterized release workflow every Swift CLI's
  `release.yml` collapses to. goreleaser has no Swift builder, so the workflow
  hand-rolls the job from the shared composite actions: verify-tag-on-main (or
  auto-tag), Xcode selection (`Xcode_26*` glob on a `macos-15` runner), Developer
  ID import, a universal `swift build`, native codesign + notarytool, the GitHub
  release, and a rendered binary cask published to this tap. Zero-config: every
  input defaults, and the SPM executable product is expected to carry the repo's
  name.
- `build-swift-universal`: one two-arch `swift build -c release`, product located
  via `--show-bin-path` (never a hardcoded `.build/...` path), `lipo -archs`
  slice assert, `swift package resolve` retried 3x.
- `sign-notarize-binary`: the bare-Mach-O sibling of `sign-notarize-app` —
  codesign + notarize via `$MACOS_CODESIGN_SCRIPT`, ditto-zip +
  `.sha256`/`checksums.txt`, release attach with an explicit `tag_name`
  (auto-tag-safe). No staple: a bare binary can't be stapled; Gatekeeper
  verifies the cdhash online, matching the Go quill path. Unsigned builds warn
  and ship, and the synthesized cask's postflight strips the quarantine xattr.
- None of this exists at `v1`: Swift callers pin `@swift-v1`, and so does every
  `uses:` inside `release-swift.yml` itself, so the Swift family repoints without
  ever moving `v1`.

## Cutting a release (tag-move procedure)

1. Land the change on `main` (CI in `test.yml` must be green — a floating-major
   move ships to every fleet repo at once).
2. Cut the next immutable point tag:
   `git tag vX.Y.Z && git push origin vX.Y.Z` (or `pypi-vX.Y.Z` /
   `swift-vX.Y.Z` / `bun-vX.Y.Z`). Point tags are protected by a repository
   ruleset and never move.
3. Force-move the floating major consumers pin:
   `git tag -f v1 vX.Y.Z && git push -f origin v1` (or `pypi-v1` / `swift-v1` /
   `bun-v1`).
