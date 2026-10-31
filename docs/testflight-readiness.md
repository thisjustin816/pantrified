# TestFlight readiness

What is in place for an upload, what only the owner can decide, and what data leaves the device.

## In place

- **Privacy manifest:** `App/PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected
  data types and no accessed API types. The code calls no required-reason API; the time a rate-limited
  lookup may resume is kept in a small file read without file date APIs or `UserDefaults`. Its only network
  code is the FoodData Central product lookup (`docs/capture.md`), which sends a scanned barcode and the
  app's key to answer that one request and is not linked to the person by the app; whether App Store
  Connect's App Privacy answers list it is decided below.
- **Manifest lint:** `Scripts/verify-privacy-manifest.py` checks the manifest's structure, such as a
  purpose on each collected data type and a reason on each accessed API type, and that tracking and
  tracking domains agree.
- **Code against manifest:** `Scripts/verify-required-reason-apis.py` scans the Swift sources for the
  symbols Apple lists for each required-reason category and fails when the code uses a category the
  manifest does not declare, or the manifest declares one the code does not use. Comments and string
  literals are ignored.
- **Shipped manifest:** CI checks that each archived app carries the manifest unchanged.
- **Signed upload:** `.github/workflows/testflight.yml` signs the app with the Apple Distribution
  certificate and the App Store profile and uploads it, automatically from `main` and by hand from any
  branch. `docs/testflight.md` lists the secrets and the first run.
- **Limits:** the scan reads Swift source, so it cannot see what a binary dependency calls. The archived
  app's privacy report remains the last check before a release.
- **Local store:** the app links SwiftData for its local store. The store's own code calls no
  required-reason API; what SwiftData and Core Data call internally is not covered by the scan
  (`docs/persistence.md`).

## Decided by the owner before an upload

1. **Export compliance (answered).** The app uses only the encryption the operating system provides: HTTPS
   to services, iCloud and the Keychain, and no cryptography of its own. The owner's answer is that it uses
   no non-exempt encryption, so the app target sets `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO` in
   `project.yml`, the generated Info.plist carries `ITSAppUsesNonExemptEncryption` as false, and App Store
   Connect does not ask on each build. `Scripts/verify-export-compliance.py` fails when the setting is
   missing or holds anything else: in `ci.yml` against `project.yml`, and in `ios-build.yml` and
   `testflight.yml` against each archived app. Review the answer before the app adds cryptography of its own.
2. **App icon.** `App/Assets.xcassets/AppIcon.appiconset` holds one 1024 by 1024 PNG with no transparency,
   chosen by the owner. `Scripts/verify-app-icon.py` checks the size and the absence of an alpha channel in
   the source, and that each archived app carries the compiled catalog and the icon name. It cannot show how
   the icon looks in the tinted and dark home screen styles, so check those on a device or simulator.
3. **Privacy policy and App Privacy answers.** The [privacy policy](../PRIVACY.md) describes the current
   beta. Use `https://github.com/thisjustin816/pantrified/blob/main/PRIVACY.md` as the privacy policy URL
   and `https://github.com/thisjustin816/pantrified/blob/main/SUPPORT.md` as the support URL once these
   pages are published on main. Complete App Privacy for the actual uploaded build. Update the policy
   and disclosures before distributing a build with new data flows. The table below lists those flows.
4. **Usage descriptions.** `NSCameraUsageDescription`, set in `project.yml`: "Pantrified uses the camera to
   scan barcodes and to take photos of the food you add, so it can read their labels on this iPhone. Photos
   stay on this iPhone and are never saved to your photo library. While Pantrified is open, it deletes them a
   day after reading them or two days after they were added, whichever comes first. What it read stays with
   a batch until you add or discard it." Photo
   import uses the system Photos picker, which runs outside the app and needs no photo library permission
   or usage string.
5. **Product lookup key and App Privacy.** A build looks products up only when it carries a FoodData Central
   key (`FDC_API_KEY`, `docs/capture.md`). The upload workflow passes the `FDC_API_KEY` Environment secret
   when it is set. Before adding that secret, decide how App Privacy
   describes the barcode sent to api.nal.usda.gov with the device's IP address (owner decision 3 in
   `docs/capture.md`).

Read App Store Connect's current requirements when preparing these; they change.

## Data flows

There are no analytics and no account. The only thing that can leave the device is a barcode, scanned or
read from a batch photo, sent for product lookup in a build that carries a FoodData Central key.

The accepted product decisions add these flows. Each row's privacy answers and the manifest's collected
data types change when the flow is built.

| Flow | What leaves the device | To whom | Status |
|---|---|---|---|
| Household sync | Inventory, shopping list, consumer profiles and approved evidence crops | Apple iCloud, and the participants of a shared Space | Engine built against a fake transport; no CloudKit code |
| Product lookup | A barcode number, scanned or read from a batch photo, in up to four lengths with leading zeros, and the app's api.data.gov key, with the device's IP address as for any request. No name, household data or device details. One request per lookup, paced to the service's per-IP rate limit and paused after it refuses one | USDA FoodData Central at api.nal.usda.gov, keyed through api.data.gov | Built; on only in a build with a key, which the upload workflow passes when the `FDC_API_KEY` Environment secret is set |
| Recipe discovery | To be decided when built | Edamam | Not built |
| Generation on the device | Nothing | Nobody | Built; the on-device model needs a device with Apple Intelligence |
| Generation in the cloud | The Make Something request context: selected foods, restrictions and preferences | Apple Private Cloud Compute | Not built |
| Purchases | Purchase and entitlement state | Apple StoreKit | Not built |
| Reminders export | The shopping selection | The person's own Reminders | Not built |
| Camera: Scan | Nothing. Only the decoded barcode number reaches the app, and it is kept on the device | Nobody | Built |
| Camera and picked photos: Add a batch | Nothing. Photos are kept in the app's storage on the device and deleted, while the app is open, a day after they are read or two days after they were added, whichever comes first; what was read from them stays with an unfinished batch, on the device only. Only a barcode read from them may go to the product lookup above | Nobody | Built (`batch-intake.md`) |
| Evidence crops | Nothing; only an approved crop may sync | Nobody, or iCloud for a crop | Not built |
