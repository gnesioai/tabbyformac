# Releasing Tabby (auto-update via Sparkle)

Users get updates through Sparkle, which reads `appcast.xml` from
`https://raw.githubusercontent.com/gnesioai/tabbyformac/main/appcast.xml`.
Shipping an update = build → notarize → sign → add an `<item>` to the appcast → push.

## One-time setup

1. **Developer ID Application cert** must be in your login keychain (NOT just "Apple
   Development"). Without it `build.sh` warns and you cannot notarize. Get it from
   developer.apple.com → Certificates → "Developer ID Application".
2. **Notary credentials** (app-specific password from appleid.apple.com):
   ```
   xcrun notarytool store-credentials "tabby-notary" \
     --apple-id "<your-apple-id>" --team-id 6XBN9MV839 --password "<app-specific-pw>"
   ```
3. The Sparkle **EdDSA private key** is already in your login keychain (generated once).
   The matching public key lives in `Info.plist` as `SUPublicEDKey`. Don't regenerate it
   or existing installs can't verify updates.

## Per release

1. Bump versions in `Resources/Info.plist`:
   - `CFBundleVersion` — integer, must increase every release (Sparkle compares this).
   - `CFBundleShortVersionString` — human version, e.g. `1.1`.
2. Build: `./build.sh`
3. Notarize + staple the DMG:
   ```
   xcrun notarytool submit build/Tabby.dmg --keychain-profile "tabby-notary" --wait
   xcrun stapler staple build/Tabby.dmg
   ```
4. Sign the DMG for Sparkle (copy the printed values):
   ```
   .build/artifacts/sparkle/Sparkle/bin/sign_update build/Tabby.dmg
   ```
5. Create a GitHub release tagged `vX.Y`, upload `build/Tabby.dmg` as an asset.
6. Add a new `<item>` to `appcast.xml` (newest first) with the bumped
   `sparkle:version` / `sparkle:shortVersionString`, the release-asset `url`, and the
   `sparkle:edSignature` + `length` from step 4.
7. Commit and push `appcast.xml` to `main`. Done — installed apps pick it up on next check.

## Notes
- `appcast.xml` enclosure `url` must point at the **GitHub release asset**, not the raw repo.
- Keep old `<item>` entries; Sparkle just needs the newest to be the highest version.
- Test before announcing: install the previous version, bump, publish, then use
  **menu → Check for Updates…**.
