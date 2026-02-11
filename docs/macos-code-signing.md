# macOS Code Signing & Permissions

## The Problem
macOS tracks Accessibility permissions by **code signing identity (CDHash)**. Ad-hoc signed binaries (`codesign --sign -`) get a new CDHash on every rebuild, which **invalidates the accessibility permission** each time. The user sees Liuyu enabled in System Settings but `AXIsProcessTrusted()` returns `false`.

Microphone permissions (TCC/AVFoundation) track by **bundle identifier**, so they persist across rebuilds even with ad-hoc signing.

## The Solution: Self-Signed Certificate

### One-Time Setup (already done)
1. Created certificate with openssl (proper code signing extensions):
   ```bash
   openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
     -days 3650 -nodes -config codesign.cfg
   ```
   Config requires: `keyUsage=critical,digitalSignature` + `extendedKeyUsage=critical,codeSigning` + `basicConstraints=critical,CA:false`

2. Exported as PKCS12 with **legacy algorithms** (macOS can't read modern PKCS12):
   ```bash
   openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
   ```

3. Imported to login keychain:
   ```bash
   security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P password -T /usr/bin/codesign -A
   ```

4. **Critical step**: Trust for code signing via **Keychain Access GUI** (CLI `security add-trusted-cert -p codeSign` fails with "invalid parameters"):
   - Keychain Access > login > find "Liuyu Dev" > double-click > Trust > Code Signing: "Always Trust"

### bundle.sh Signs With Certificate
```bash
codesign --force --sign "Liuyu Dev" --entitlements "..." --identifier "com.liuyu.app" "${BUNDLE_DIR}"
```

### If Accessibility Permission Gets Stale
```bash
tccutil reset Accessibility com.liuyu.app
# Then re-launch app and re-grant
```

## Permission Checking in SwiftUI
- `AXIsProcessTrusted()` for accessibility (returns Bool synchronously)
- `AVCaptureDevice.authorizationStatus(for: .audio)` for microphone
- Use `Timer.publish(every: 2)` + `.onReceive()` for polling (reliable in NavigationSplitView)
- Also use `NSApplication.didBecomeActiveNotification` for immediate refresh on app switch
- Microphone: trigger native dialog via `AVCaptureDevice.requestAccess(for: .audio)` (not deep link)
- Accessibility: trigger system dialog via `AXIsProcessTrustedWithOptions` with prompt flag

## Key Gotchas
- `@State` initializers in SwiftUI structs may evaluate before view lifecycle — initialize to `false` and set real values in `.onAppear`
- `Timer.scheduledTimer` closures don't reliably capture `@State` in structs — use `Timer.publish().autoconnect()` with `.onReceive()` instead
- macOS `security` CLI can import certificates but CANNOT trust them for code signing without Keychain Access GUI
- OpenSSL 3.x PKCS12 defaults are incompatible with macOS — must use `-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`
