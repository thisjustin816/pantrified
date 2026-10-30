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

## Decided by the owner before an upload

1. **Export compliance.** The app uses only the encryption the operating system provides: HTTPS to
   services, iCloud and the Keychain, and no cryptography of its own. `ITSAppUsesNonExemptEncryption` is not
   set, so App Store Connect asks for the answer on each build. The answer is the owner's.
2. **App icon.** The app has none. An upload needs one, and its design is the open branding decision.
3. **Privacy policy and App Privacy answers.** External TestFlight testing and an App Store listing ask for
   a privacy policy URL and for App Privacy answers. The table below lists the facts they depend on.
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
