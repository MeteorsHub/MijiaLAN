# Release packaging

`scripts/package_release.sh` builds a universal macOS 15+ app, signs it with
Developer ID and Hardened Runtime, notarizes and staples the app and DMG,
checks Gatekeeper acceptance, and produces a DMG, ZIP and SHA-256 checksums.
It runs Release tests before packaging and does not publish anything to GitHub.

Requirements:

- Xcode / command line tools providing Swift 6.4 or later.
- An installed Developer ID Application certificate with its private key.
- An existing `notarytool` Keychain credential profile for that certificate's team.

```bash
MIJIALAN_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
MIJIALAN_NOTARY_PROFILE='your-notary-profile' \
MIJIALAN_VERSION=0.1.0 \
MIJIALAN_BUILD_NUMBER=1 \
./scripts/package_release.sh
```

Artifacts are written to `build/releases/v<version>/dist/`. Build, test,
signature, notarization and Gatekeeper logs stay in the adjacent `logs/`
directory. Only the DMG, ZIP and `SHA256SUMS.txt` are intended as release
attachments. Real device registries, pairing data and diagnostic exports are
not part of the app bundle.

If packaging stops after the staging app has been built and signed, rerun with
`--package-existing` and the same environment to retry notarization without
rebuilding. This verifies the staging app's version, build number, architectures,
Developer ID signature, Hardened Runtime and timestamp. Use it only for the
unchanged app whose Release tests already passed.

After checking the packages, commit the release scripts and documentation,
tag the matching source commit, and upload the three artifacts to a GitHub
Release. Describe hardware validation limits in the release notes; passing
automated tests and Apple notarization do not verify every device or firmware.

For a local universal build without notarization:

```bash
MIJIALAN_UNIVERSAL=1 ./scripts/build_app.sh
```

`MIJIALAN_APP_OUTPUT` can select a staging `.app` path without replacing an
installed copy. The default local build uses ad hoc signing; setting
`MIJIALAN_SIGN_IDENTITY` enables timestamped Developer ID signing instead.
