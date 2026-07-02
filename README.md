# homebrew-tap

Homebrew tap for yasyf's tools.

```sh
brew install yasyf/tap/<name>
```

`Formula/` and `Casks/` are **generated** — they're pushed here by each tool's release
pipeline, never hand-edited. This repo is also the single home of the shared Go release
infrastructure that every tool reuses (`.github/`), so the release logic lives in one place
instead of being copy-pasted across repos.

## Shared release infrastructure (`.github/`), pinned `@v1`

**Reusable workflow** — the common pure-Go path (one ubuntu runner; goreleaser builds,
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

**Composite actions** — for repos that need a macOS runner (cgo native clang, `lipo`, an
Xcode `.app`) and compose their own workflow:

| Action | Purpose |
|---|---|
| `actions/verify-tag-on-main@v1` | refuse a tag not reachable from `origin/main` (needs a prior `checkout` with `fetch-depth: 0`) |
| `actions/import-developer-id@v1` | import the Developer ID cert into a throwaway keychain; export the signing env + `$MACOS_CODESIGN_SCRIPT` (the canonical `macos-codesign.sh`) — the single home of the keychain dance |
| `actions/render-formula@v1` | fill a repo `.rb` template (`__VERSION__` / `__SHA_*__` / custom tokens) into a staging dir |
| `actions/sign-notarize-app@v1` | sign + notarize + staple a built `.app`, zip it, attach to the release, output the zip's sha256 (pair with `render-formula` for its cask) |
| `actions/publish@v1` | merge a staging dir's `Formula/`/`Casks/` into this tap and push (idempotent) |

Distribution choice: a pure-binary CLI ships as a **cask** (goreleaser `homebrew_casks:`,
published natively — no render/publish step). A tool that needs `brew services` or runtime
`depends_on` ships as a **formula** (goreleaser `brews:`). Only an irreducible conditional
formula or a non-Go artifact (`.app`) uses `render-formula` + `publish`.

Signing: pure-Go repos sign with goreleaser's **quill** on ubuntu (full-chain p12 required);
repos already on a macOS runner sign with native **codesign + notarytool** via
`import-developer-id` + `$MACOS_CODESIGN_SCRIPT` (quill's arm64 signatures are SIGKILLed —
anchore/quill#566). The canonical recipe + credential setup lives in `repo-bootstrap`'s
`reference/go-ci-and-release.md`.

## Versioning

Two independent tag families version the shared infrastructure:

- **`v1`** — Go: the composite actions + `release-go.yml`.
- **`pypi-v1`** — Python: `release-pypi-build.yml` (which doesn't exist at `v1`
  — Python callers must pin `@pypi-v1`).

Consumers pin the floating major (`@v1` / `@pypi-v1`) and pick up fixes when it
moves. Each move is anchored by an immutable point tag (`v1.0.0`,
`pypi-v1.0.0`, …), protected by a repository ruleset. To ship a change: land it
on `main` with CI green, cut the next point tag, then force-move the floating
major onto it (`git tag -f v1 vX.Y.Z && git push -f origin v1`). History lives
in [CHANGELOG.md](CHANGELOG.md).
