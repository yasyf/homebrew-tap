# homebrew-tap

Homebrew tap for yasyf's tools.

```sh
brew install yasyf/tap/<name>
```

`Formula/` and `Casks/` are **generated** — they're pushed here by each tool's release
pipeline, never hand-edited. This repo is also the single home of the shared Go, Python,
Swift, and Bun release infrastructure that every tool reuses (`.github/`), so the release
logic lives in one place instead of being copy-pasted across repos.

## Shared release infrastructure (`.github/`)

**Reusable workflows** — the common pure-Go path (one ubuntu runner; goreleaser builds,
quill-signs, and publishes a cask or formula natively):

```yaml
# a repo's entire .github/workflows/release.yml:
name: Release
on: { push: { tags: ["v*"] } }
permissions: { contents: write }
jobs:
  release:
    uses: yasyf/homebrew-tap/.github/workflows/release-go.yml@v1
    secrets: inherit
    with: { setup-bun: true }   # optional, for a go:embed prebuild hook
```

and the Swift CLI path (one macOS runner; a universal `swift build`, native
codesign + notarytool, a rendered binary cask — goreleaser has no Swift builder, so
`release-swift.yml` hand-rolls the whole job from the same composite actions).
Zero-config: the SPM executable product just has to be named after the repo:

```yaml
# a Swift repo's entire .github/workflows/release.yml:
name: Release
on: { push: { tags: ["v*"] } }
permissions: { contents: write }
jobs:
  release:
    uses: yasyf/homebrew-tap/.github/workflows/release-swift.yml@swift-v1
    secrets: inherit
```

and the bun path (a 4-leg native-runner matrix — platform-native deps rule out
cross-compiling, and goreleaser has no bun builder either — producing one
`bun build --compile` single-file binary per platform, codesign + notarytool on the
darwin legs, one GitHub release, and a rendered 4-platform binary cask).
Zero-config: entry point `src/index.ts`, the binary named after the repo, and a
`.bun-version` file pinning the toolchain:

```yaml
# a bun repo's entire .github/workflows/release.yml:
name: Release
on: { push: { tags: ["v*"] } }
permissions: { contents: write }
jobs:
  release:
    uses: yasyf/homebrew-tap/.github/workflows/release-bun.yml@bun-v1
    secrets: inherit
```

**Composite actions** — for repos that need a macOS runner (cgo native clang, `lipo`, an
Xcode `.app`) and compose their own workflow:

| Action | Purpose |
|---|---|
| `actions/verify-tag-on-main@v1` | refuse a tag not reachable from `origin/main` (needs a prior `checkout` with `fetch-depth: 0`) |
| `actions/import-developer-id@v1` | import the Developer ID cert into a throwaway keychain; export the signing env + `$MACOS_CODESIGN_SCRIPT` (the canonical `macos-codesign.sh`) — the single home of the keychain dance |
| `actions/render-formula@v1` | fill a repo `.rb` template (`__VERSION__` / `__SHA_*__` / custom tokens) into a staging dir |
| `actions/sign-notarize-app@v1` | sign + notarize + staple a built `.app`, zip it, attach to the release, output the zip's sha256 (pair with `render-formula` for its cask) |
| `actions/wrap-daemon-bundle@v1` | wrap a bare Mach-O daemon in a minimal signed + notarized + stapled `.app` (with an embedded provisioning profile) so its TCC grant is keyed by `CFBundleIdentifier` and survives `brew upgrade` instead of re-prompting every release |
| `actions/publish@v1` | merge a staging dir's `Formula/`/`Casks/` into this tap and push (idempotent) |
| `actions/build-swift-universal@swift-v1` | build an SPM executable as a universal (arm64 + x86_64) release binary and assert both slices |
| `actions/sign-notarize-binary@swift-v1` | codesign + notarize a bare Mach-O CLI via `$MACOS_CODESIGN_SCRIPT`, zip + checksum it, attach to the release (the `.app`-less sibling of `sign-notarize-app`); an optional `platform` input names a per-arch zip (how `@bun-v1` uses it), defaulting to the swift `darwin-universal` |
| `actions/build-bun-binary@bun-v1` | compile a bun project into a single-file executable for one explicit `bun-<platform>` target (frozen install with retries, `file`-based Mach-O/ELF format assert) |

Distribution choice: a pure-binary Go CLI ships as a **cask** (goreleaser
`homebrew_casks:`, published natively — no render/publish step); a Swift CLI ships as a
**cask** too (one universal zip, rendered + published by `release-swift.yml`); so does a
bun TUI/CLI (four per-platform zips, rendered + published by `release-bun.yml`). A tool
that needs `brew services` or runtime `depends_on` ships as a **formula** (goreleaser
`brews:`). Only an irreducible conditional formula or an externally-built artifact
(`.app`, non-goreleaser toolchains) uses `render-formula` + `publish`.

Signing: pure-Go repos sign with goreleaser's **quill** on ubuntu (full-chain p12 required);
repos already on a macOS runner — cgo, `.app` builds, and every Swift and bun release —
sign with native **codesign + notarytool** via `import-developer-id` +
`$MACOS_CODESIGN_SCRIPT` (quill's arm64 signatures are SIGKILLed — anchore/quill#566).
The canonical recipe + credential setup lives in `repo-bootstrap`'s
`reference/go-ci-and-release.md` (Go), `reference/swift-ci-and-release.md` (Swift), and
`reference/bun-ci-and-release.md` (Bun).

## Versioning

Four independent tag families version the shared infrastructure:

- **`v1`** — Go: the composite actions + `release-go.yml`.
- **`pypi-v1`** — Python: `release-pypi-build.yml` (which doesn't exist at `v1`
  — Python callers must pin `@pypi-v1`).
- **`swift-v1`** — Swift: `release-swift.yml` + the `build-swift-universal` and
  `sign-notarize-binary` actions (none of which exist at `v1` — Swift callers,
  and every `uses:` inside `release-swift.yml` itself, pin `@swift-v1`).
- **`bun-v1`** — Bun: `release-bun.yml` + the `build-bun-binary` action (neither
  exists at `v1` — bun callers, and every `uses:` inside `release-bun.yml`
  itself, pin `@bun-v1`).

Consumers pin the floating major (`@v1` / `@pypi-v1` / `@swift-v1` / `@bun-v1`) and
pick up fixes when it moves. Each move is anchored by an immutable point tag (`v1.0.0`,
`pypi-v1.0.0`, `swift-v1.0.0`, `bun-v1.0.0`, …), protected by a repository ruleset. To ship a
change: land it on `main` with CI green, cut the next point tag, then force-move the
floating major onto it (`git tag -f v1 vX.Y.Z && git push -f origin v1`). History
lives in [CHANGELOG.md](CHANGELOG.md).
