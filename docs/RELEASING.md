# Releasing

Cutting a release is one command — push a tag:

```bash
# 1. Move items from "Unreleased" into a new version section in CHANGELOG.md,
#    commit that on a PR, and merge to main.
# 2. Tag and push:
git tag v0.1.0
git push origin v0.1.0
```

The **Release** workflow (`.github/workflows/release.yml`) then builds the app,
packages a `.zip` + `.dmg`, pulls the notes for that version out of `CHANGELOG.md`,
and publishes a GitHub Release with both assets attached.

Everything below is **optional and additive** — with no secrets set you still get a
working ad-hoc-signed release. Add secrets to unlock each capability.

---

## Tier 1 — Developer ID signing + notarization

Removes the Gatekeeper "right-click → Open" friction; required for Sparkle updates.

### One-time: create the certificate

1. **Keychain Access → Certificate Assistant → Request a Certificate from a
   Certificate Authority.** Enter your email, choose **Saved to disk**, save the
   `.certSigningRequest`.
2. At **developer.apple.com/account → Certificates → +**, choose **Developer ID
   Application**, upload the CSR, and download the `.cer`.
3. Double-click the `.cer` to install it into your login keychain.
4. In Keychain Access, expand the cert, select **both** the cert and its private
   key, right-click → **Export 2 items…**, save as `certs.p12` and set a password.

### Find your identity + team

```bash
security find-identity -v -p codesigning     # → "Developer ID Application: Name (TEAMID)"
```

The quoted string is `APPLE_SIGN_IDENTITY`; the `TEAMID` in parens is `APPLE_TEAM_ID`.

### App-specific password

At **appleid.apple.com → Sign-In and Security → App-Specific Passwords**, create one
for notarization. That value is `APPLE_APP_PASSWORD`.

### Set the GitHub secrets

Run these yourself (they hold private material — never paste secrets into chat):

```bash
gh secret set APPLE_CERT_P12_BASE64 < <(base64 -i certs.p12)
gh secret set APPLE_CERT_PASSWORD          # the .p12 export password
gh secret set APPLE_SIGN_IDENTITY          # Developer ID Application: Name (TEAMID)
gh secret set APPLE_ID                     # your Apple ID email
gh secret set APPLE_APP_PASSWORD           # the app-specific password
gh secret set APPLE_TEAM_ID                # TEAMID
```

Once `APPLE_CERT_P12_BASE64` exists, the next tagged release is Developer-ID signed,
hardened-runtime, notarized, and stapled automatically.

---

## Tier 2 — Sparkle auto-update

### One-time: generate the EdDSA key pair

```bash
# From a checkout that has resolved Sparkle:
./.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It stores the **private** key in your login keychain and prints the **public** key
(a base64 string). Then:

```bash
gh secret set SPARKLE_PUBLIC_KEY           # the printed public key (baked into Info.plist at build)
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_priv.key   # export the private key
gh secret set SPARKLE_PRIVATE_KEY < sparkle_priv.key
rm sparkle_priv.key
```

> Keep the private key safe — losing it means users can't verify future updates.

### The appcast feed

The app reads its feed from `SUFeedURL` in `Info.plist`, currently:
`https://balanced02.github.io/ai-usage-bar/appcast.xml`.

1. **Enable GitHub Pages**: repo Settings → Pages → Source = **Deploy from a branch**,
   branch **main**, folder **/docs**. That serves `docs/appcast.xml` at the URL above.
2. On each signed release, the workflow's **Sign update for Sparkle** step prints an
   `sparkle:edSignature` + length for the `.zip`. Add a new `<item>` to
   `docs/appcast.xml` (via a PR) using that signature, the version, and the release
   `.zip` download URL. See the template already in that file.

(Fully automating the appcast commit is a nice follow-up; it's kept manual for now so
a release never force-pushes to a protected `main`.)

---

## Homebrew

The repo doubles as a tap (it has a `Casks/` dir):

```bash
brew tap balanced02/ai-usage-bar https://github.com/Balanced02/ai-usage-bar
brew install --cask ai-usage-bar
```

On each tagged release the workflow opens a **PR** bumping the cask's `version` +
`sha256`. Merge it and `brew upgrade` picks up the new build.

---

## Branch protection

`main` requires a pull request + green CI; direct pushes are disabled (see the repo's
branch-protection settings). Automated bumps (cask) therefore arrive as PRs, not pushes.
