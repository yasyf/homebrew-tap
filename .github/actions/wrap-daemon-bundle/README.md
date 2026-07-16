# wrap-daemon-bundle

Wrap a universal Mach-O daemon in a minimal signed, notarized, stapled `.app` so it
earns a **durable** macOS TCC grant.

## Why this exists

macOS TCC (Transparency, Consent, and Control) keys a grant to a *client*, and how it
derives that client depends on how the executable is packaged:

- A **bare Mach-O** binary is a `client_type=1` client keyed by its **resolved path**.
  Homebrew installs each version under a new Cellar path, so every upgrade is a *fresh*
  TCC client — the grant does not carry over and the user is **re-prompted on every
  release**.
- A **bundled `.app`** is a `client_type=0` client keyed by its **`CFBundleIdentifier`**.
  The identifier is stable across upgrades, so the grant is asked once and **survives**.

Wrapping the daemon in a bundle is therefore the fix for consent-fatigue: one durable
identifier-keyed grant instead of a path-keyed one that resets each release.

An **entitlement-backed** service needs more. cc-pool's daemon binds a socket inside an
app-group container (`kTCCServiceSystemPolicyAppData`). Apple's no-prompt contract for
that, under Developer ID distribution, requires all of:

1. the `com.apple.security.application-groups` entitlement,
2. resolving the container via `containerURLForSecurityApplicationGroupIdentifier:`
   (never a raw path join) — the daemon's job, not this action's, and
3. an **embedded Developer ID provisioning profile** authorizing the group claim.

Only bundled executables are sanctioned app-group members; a bare Mach-O is not. This
action assembles the bundle, embeds the profile, signs with the entitlements, notarizes,
staples, and **asserts** the embedded profile actually authorizes the app-group claim —
so a misconfigured profile fails the release instead of shipping a bundle that silently
re-prompts.

## LSUIElement, not LSBackgroundOnly

The generated `Info.plist` sets `LSUIElement=true` (invisible agent: no Dock icon, no
menu-bar item) and deliberately does **not** set `LSBackgroundOnly`. A launchd-managed
daemon should be invisible, but a pure `LSBackgroundOnly` app is severed from the window
server and cannot present any UI. Since this bundle's entire purpose is a
consent-earning TCC identity, keeping it as an agent that can still participate in the
GUI / consent session is the safer choice; `LSBackgroundOnly` buys nothing here and
forecloses any future consent or notification surface.

## Signing credentials

Like `sign-notarize-app`, this action reads the signing identity and notary credentials
from the environment — `MACOS_SIGN_IDENTITY` and `MACOS_NOTARY_KEY_FILE` /
`MACOS_NOTARY_KEY_ID` / `MACOS_NOTARY_ISSUER` — which the **`import-developer-id`**
action exports into `$GITHUB_ENV`. Run `import-developer-id` first. Signing is required
(a daemon `.app` with no signature earns no grant); notarization is skipped with a
warning when no notary key is present (a Developer ID app-group grant needs it).

macOS runners only (`codesign` / `notarytool` / `stapler` are macOS tools).

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `binary` | yes | — | path to the built universal (arm64 + x86_64) Mach-O daemon |
| `bundle-id` | yes | — | `CFBundleIdentifier` and codesign `--identifier` (reverse-DNS); the TCC client key |
| `bundle-name` | yes | — | assembles `<bundle-name>.app`, sets `CFBundleName` (e.g. `CCPoolDaemon`) |
| `executable-name` | no | binary basename | `CFBundleExecutable` / `Contents/MacOS/<name>` |
| `version` | yes | — | stamps `CFBundleShortVersionString` + `CFBundleVersion` |
| `entitlements` | no | `""` | entitlements plist for codesign (e.g. the app-group claim) |
| `provisioning-profile-b64` | no | `""` | base64 Developer ID profile → `Contents/embedded.provisionprofile` |
| `info-plist-extras` | no | `""` | plist whose top-level entries merge additively (base keys win) into `Info.plist` |

## Output

| Output | Meaning |
|---|---|
| `bundle-path` | absolute path to the assembled, signed, notarized, stapled `.app` |

The caller zips it (`ditto -c -k --keepParent`) and pairs it with `render-formula` +
`publish` for its cask.

## Usage

```yaml
- uses: yasyf/homebrew-tap/.github/actions/import-developer-id@v1
  with:
    p12: ${{ secrets.MACOS_SIGN_P12 }}
    p12-password: ${{ secrets.MACOS_SIGN_PASSWORD }}
    notary-key: ${{ secrets.MACOS_NOTARY_KEY }}
    notary-key-id: ${{ secrets.MACOS_NOTARY_KEY_ID }}
    notary-issuer-id: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}

- id: wrap
  uses: yasyf/homebrew-tap/.github/actions/wrap-daemon-bundle@v1
  with:
    binary: dist/cc-pool-daemon-universal
    bundle-id: com.yasyf.cc-pool.daemon
    bundle-name: CCPoolDaemon
    version: ${{ steps.tag.outputs.version }}
    entitlements: .github/entitlements/daemon.plist
    provisioning-profile-b64: ${{ secrets.MACOS_DAEMON_PROVISION_PROFILE }}
```
