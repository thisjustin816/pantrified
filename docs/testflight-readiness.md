# TestFlight readiness

What is in place for an upload, what only the owner can decide, and what data leaves the device.

## In place

- **Privacy manifest:** `App/PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected
  data types and no accessed API types. That is true of the code today: it has no network code and calls no
  required-reason API.
- **Manifest lint:** `Scripts/verify-privacy-manifest.py` checks the manifest's structure, such as a
  purpose on each collected data type and a reason on each accessed API type, and that tracking and
  tracking domains agree.
- **Code against manifest:** `Scripts/verify-required-reason-apis.py` scans the Swift sources for the
  symbols Apple lists for each required-reason category and fails when the code uses a category the
  manifest does not declare, or the manifest declares one the code does not use. Comments and string
  literals are ignored.
- **Shipped manifest:** CI checks that each archived app carries the manifest unchanged.
- **Limits:** the scan reads Swift source, so it cannot see what a binary dependency calls. The archived
  app's privacy report remains the last check before a release.
- **Local store:** the app links SwiftData for its local store. The store's own code calls no
  required-reason API; what SwiftData and Core Data call internally is not covered by the scan
  (`docs/persistence.md`).

## Decided by the owner before an upload

1. **Export compliance.** The app uses only the encryption the operating system provides: HTTPS to
   services, iCloud and the Keychain, and no cryptography of its own. `ITSAppUsesNonExemptEncryption` is not
   set, so App Store Connect asks for the answer on each build. The answer is the owner's.
2. **App icon.** `App/Assets.xcassets/AppIcon.appiconset` holds one 1024 by 1024 PNG with no transparency,
   chosen by the owner. `Scripts/verify-app-icon.py` checks the size and the absence of an alpha channel in
   the source, and that each archived app carries the compiled catalog and the icon name. It cannot show how
   the icon looks in the tinted and dark home screen styles, so check those on a device or simulator.
3. **Privacy policy and App Privacy answers.** The [privacy policy](../PRIVACY.md) describes the current
   beta. Use `https://github.com/thisjustin816/pantrified/blob/main/PRIVACY.md` as the privacy policy URL
   and `https://github.com/thisjustin816/pantrified/blob/main/SUPPORT.md` as the support URL once these
   pages are published on main. Complete App Privacy for the actual uploaded build. Update the policy
   and disclosures before distributing a build with new data flows. The table below lists those flows.
4. **Usage descriptions.** Camera and photo access need purpose strings when capture is added.

Read App Store Connect's current requirements when preparing these; they change.

## Data flows

Today nothing leaves the device: there is no network code, analytics or account.

The accepted product decisions add these flows. Each row's privacy answers and the manifest's collected
data types change when the flow is built.

| Flow | What leaves the device | To whom | Status |
|---|---|---|---|
| Household sync | Inventory, shopping list, consumer profiles and approved evidence crops | Apple iCloud, and the participants of a shared Space | Engine built against a fake transport; no CloudKit code |
| Product lookup | A barcode or product name | USDA FoodData Central | Not built |
| Recipe discovery | To be decided when built | Edamam | Not built |
| Generation on the device | Nothing | Nobody | Built; the on-device model needs a device with Apple Intelligence |
| Generation in the cloud | The Make Something request context: selected foods, restrictions and preferences | Apple Private Cloud Compute | Not built |
| Purchases | Purchase and entitlement state | Apple StoreKit | Not built |
| Reminders export | The shopping selection | The person's own Reminders | Not built |
| Camera and photos | Nothing; a capture stays on the device, and only an approved crop may sync | Nobody, or iCloud for a crop | Not built |
