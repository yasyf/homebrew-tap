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
| `actions/macos-app-cask@v1` | sign + notarize + staple an Xcode `.app` and render its `Casks/<app>.rb` |
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
