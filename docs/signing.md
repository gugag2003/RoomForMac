# Signing RoomForMac builds

RoomForMac signs every build, local and release, with one self-signed code-signing identity: **RoomForMac Self-Signed**. This page covers why it exists, how to create and back it up, how to check a signed build, and what to do if Xcode refuses it.

## Why builds need a stable identity

macOS records each privacy grant against the app's bundle ID and its *designated requirement* (DR), a rule the app's signature must satisfy. The grants RoomForMac asks for are Full Disk Access and Automation of Finder and System Events. On every later launch, macOS checks the new build against the DR it recorded.

- **Ad-hoc signature** (`CODE_SIGN_IDENTITY = -`, Xcode's "Sign to Run Locally"): the DR is `cdhash H"…"`, the hash of that one build. The next build has another cdhash, so macOS treats it as a different app. Onboarding asks again, and System Settings keeps an old entry that never matches.
- **Stable identity**: the DR is `identifier "com.roomformac.RoomForMac" and certificate leaf = H"<SHA-1 of the certificate>"`. It stays the same across rebuilds and releases for as long as the certificate does.

The identity is self-signed, because RoomForMac has no Apple Developer account yet. It does not satisfy Gatekeeper, so users still need **Open Anyway** on first launch. It has no trust settings, and needs none:

- `codesign` signs with an untrusted self-signed identity;
- Xcode 27's validity check accepts any self-signed certificate (found by reading Xcode's code, not yet confirmed by a real build; see "If Xcode refuses the identity");
- a DR check compares the certificate's hash, not trust.

Local and release builds share this one identity. A grant made on a development build therefore also covers a release build on the same Mac.

## How the build chooses the identity

- `Config/Signing.xcconfig` is committed. It signs ad-hoc (`CODE_SIGN_IDENTITY = -`) and ends with `#include? "Local.xcconfig"`.
- `Config/Local.xcconfig` is git-ignored. The script below writes it with one setting, `CODE_SIGN_IDENTITY = RoomForMac Self-Signed`.
- Without `Local.xcconfig`, builds are ad-hoc.
- With `Local.xcconfig` but without the identity in the keychain, the build fails with `No certificate matching 'RoomForMac Self-Signed' found`. It never falls back silently. To build ad-hoc once anyway, add `CODE_SIGN_IDENTITY=-` to the `xcodebuild` command.
- The "Embed engine" build phase signs `Contents/Helpers/analyze-go` and `status-go` with the same identity as the app.
- Never set `CODE_SIGN_*` or `DEVELOPMENT_TEAM` in `project.yml`: those settings silently override the xcconfig files.

## Create the identity (once per Mac)

```bash
scripts/make-signing-identity.sh
```

During the run, macOS shows one dialog: *codesign wants to sign using key "RoomForMac Self-Signed" in your keychain*. Enter your login password and click **Always Allow**. If you click **Allow** instead, every build asks again, up to three times for a Debug build; click **Always Allow** the next time it appears. The terminal itself never asks for anything.

The script:

1. Refuses, and changes nothing, if the keychain already holds an identity with that name.
2. Creates `~/.roomformac/signing` (mode 700) with `/usr/bin/openssl`: a 2048-bit RSA key and a certificate valid for 20 years. The certificate's subject is only `CN=RoomForMac Self-Signed`, and its only use is code signing.
3. Exports `identity.p12` with 3DES and a SHA-1 MAC, which every macOS version can import. It also writes a base64 copy and a random password.
4. Imports the identity into the login keychain. The private key cannot be exported from the keychain again (`-x`), and only `codesign` may use it without asking (`-T`). No trust settings are added.
5. Signs a copy of `/usr/bin/true` and checks that its DR is `certificate leaf = H"<SHA-1>"`.
6. Writes `Config/Local.xcconfig` if that file does not exist yet, and warns if git does not ignore it.
7. Prints the identity, its SHA-1 and two `gh secret set` commands. It does not run those commands.

Check the result at any time. This is read-only:

```bash
scripts/make-signing-identity.sh --check
```

It prints `<SHA-1> "RoomForMac Self-Signed"` and exits 0. It exits 1 when there is no such identity, and 2 when there is more than one; `codesign` cannot choose between duplicates, so delete the extras in Keychain Access (login → My Certificates).

| Option | Use |
|---|---|
| `--name NAME` | another certificate name, for example a separate release identity |
| `--dir DIR` | another folder for the files; it must be outside the repository |
| `--keychain PATH` | another keychain, which must be on your keychain search list |
| `--no-import` | create the files only and leave the keychain alone |
| `--check` | print the identity, as above |

Exit status: 0 done; 1 no identity (`--check`) or a step failed; 2 bad usage, more than one identity, or a refusal.

## Back up `~/.roomformac/signing`

| File | What it is |
|---|---|
| `key.pem`, `cert.pem` | the private key and the certificate |
| `identity.p12`, `identity.p12.password` | both, as PKCS#12, and its password |
| `identity.p12.base64` | the PKCS#12 in base64, for the CI secret |
| `openssl.cnf` | the certificate request settings |

Store the whole folder in your password manager, or another encrypted place. It is the only copy: the key in the keychain cannot be exported. If it is lost, a new certificate means a new DR, and every user has to grant Full Disk Access and Automation again.

**On another Mac, or after reinstalling:** copy the folder back to `~/.roomformac/signing`, run `chmod 700 ~/.roomformac/signing`, then run `scripts/make-signing-identity.sh`. It prints `reusing the key and certificate`, imports the same identity, and the SHA-1 and the DR stay the same.

## Remove grants left by ad-hoc builds

Grants recorded for an ad-hoc build name that build's cdhash, and they never match again. After your first signed build, do this once:

1. In System Settings → Privacy & Security → Full Disk Access, select every RoomForMac entry and click **−**.
2. Reset RoomForMac's Automation grants: `tccutil reset AppleEvents com.roomformac.RoomForMac`.
3. Launch the signed build with `open` or from Xcode, and grant access again in onboarding. Never start it by its executable path from Terminal: macOS would then check Terminal's grants, not RoomForMac's.

## Verify a signed build

```bash
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Debug \
    -destination platform=macOS -derivedDataPath build/DerivedData build
APP=build/DerivedData/Build/Products/Debug/RoomForMac.app
dr() { codesign -d -r- "$1" 2> /dev/null | sed -n 's/^designated => //p'; }
cdh() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Signature)'
dr "$APP"
scripts/make-signing-identity.sh --check
codesign --verify --deep --strict -vv "$APP"
APP="$APP" bats scripts/tests/app_bundle.bats
```

Expected:

- `Authority=RoomForMac Self-Signed` and `TeamIdentifier=not set`, with no `Signature=adhoc` line.
- `dr` prints `identifier "com.roomformac.RoomForMac" and certificate leaf = H"<sha1>"`, and `<sha1>` is the `--check` SHA-1 in lower case. If `dr` prints nothing, the build is still ad-hoc: `codesign -d -r-` then shows `# designated => cdhash H"…"`.
- `codesign --verify` prints `valid on disk` and `satisfies its Designated Requirement`.
- Every `app_bundle.bats` test is `ok`. One of them checks that the engine helpers carry the same `Authority` as the app.

### Stability test

The DR must stay the same while the code changes:

```bash
before_dr="$(dr "$APP")" && before_cdh="$(cdh "$APP")"
# Change any visible string, for example a Text in
# RoomForMac/Features/Status/StatusPlaceholderView.swift, and rebuild with the
# xcodebuild command above.
after_dr="$(dr "$APP")" && after_cdh="$(cdh "$APP")"
[ -n "$before_dr" ] && [ "$before_dr" = "$after_dr" ] && [ "$before_cdh" != "$after_cdh" ] && echo "stable: same DR, new code"
git checkout -- RoomForMac/Features/Status/StatusPlaceholderView.swift
```

Then check that the grants survive:

1. `open "$APP"`, grant Full Disk Access in onboarding (relaunch if it asks), and check that Settings → Permissions shows it as granted.
2. Quit, change a visible string again, rebuild and `open "$APP"`. Full Disk Access is still granted without a visit to System Settings, and no new Automation prompt appears.
3. Repeat step 2 with Xcode's **Run** (⌘R).

If a grant does not survive, note the two DR lines, both CDHashes and which step failed.

## If Xcode refuses the identity

Xcode 27 should accept a self-signed identity; this was established by reading Xcode's code, not by a real build. If a build fails at the CodeSign step with *"RoomForMac Self-Signed" is not valid for code signing*, or with *No certificate matching* while `--check` finds the identity, use one of these fallbacks.

**(a) Sign again after the build.** `codesign` signs with untrusted identities. Let Xcode sign ad-hoc, then sign the nested code first and the app last, keeping each identifier:

```bash
ID="$(scripts/make-signing-identity.sh --check | cut -d' ' -f1)"
xcodebuild -project RoomForMac.xcodeproj -scheme RoomForMac -configuration Debug \
    -destination platform=macOS -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- build
APP=build/DerivedData/Build/Products/Debug/RoomForMac.app
resign() { codesign --force --timestamp=none --sign "$ID" --preserve-metadata=identifier,entitlements,flags "$@"; }
resign "$APP/Contents/Helpers/analyze-go" "$APP/Contents/Helpers/status-go"
find "$APP/Contents/MacOS" -name '*.dylib' -exec codesign --force --timestamp=none \
    --sign "$ID" --preserve-metadata=identifier,entitlements,flags {} +
resign "$APP"
codesign --verify --deep --strict -vv "$APP" && dr "$APP"
```

Every Xcode build signs ad-hoc again, so run this after each build; in the Xcode window, also move `Config/Local.xcconfig` aside first. Tell the plan owner if you need this fallback: the lasting fix is a build step that runs these commands.

**(b) Trust the certificate for code signing, for your user only.** This helps only if Xcode filters identities by trust. macOS asks for your password:

```bash
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db ~/.roomformac/signing/cert.pem
```

To undo it: `security remove-trusted-cert ~/.roomformac/signing/cert.pem`.

## CI secrets

Release builds on GitHub Actions will need the identity. The script prints these commands, and you run them only when a release workflow exists:

```bash
gh secret set RFM_SIGNING_P12_BASE64 < ~/.roomformac/signing/identity.p12.base64
gh secret set RFM_SIGNING_P12_PASSWORD < ~/.roomformac/signing/identity.p12.password
```

The workflow imports the PKCS#12 into a temporary keychain and deletes that keychain when the job ends.

## Security

- **Anyone with this key can sign code that inherits RoomForMac's grants.** With `key.pem`, or `identity.p12` and its password, anyone can sign a program with the bundle ID `com.roomformac.RoomForMac`. It satisfies the DR of every grant users gave RoomForMac: Full Disk Access, and Automation of Finder and System Events. Guard the folder like a password.
- Never commit these files, paste them anywhere or attach them to an issue. The script refuses a `--dir` inside the repository.
- In the keychain, the key cannot be exported, and only `codesign` may use it without asking.
- Keep the GitHub secrets in this repository only, and let only the release workflow read them.
- A self-signed certificate cannot be revoked. If the key leaks, the only remedy is a new identity, and every user has to grant access again.
- The certificate is valid for 20 years. To replace it, after a leak or before it expires:
  1. delete the identity in Keychain Access (login → My Certificates → RoomForMac Self-Signed → Delete);
  2. move `~/.roomformac/signing` aside;
  3. run the script again;
  4. update the CI secrets.

  Every user then grants access again.
- A safer setup uses two identities, which the script supports. You would sign local builds with `--name "RoomForMac Dev"`, and keep `--name "RoomForMac Release" --no-import --dir <offline folder>` only offline and in CI. RoomForMac uses one identity instead, because grants made on a development build would otherwise not carry over to release builds on the same Mac.
