# Barcode capture

The first capture slice: scan one barcode with the camera, open Add food with the barcode attached, and
suggest the product's name from USDA FoodData Central when the build has a key. The person reviews the form
and adds the food as they do by hand. Date recognition, photo import, the continuous multi-package stream
and evidence crops are not part of it (see Not built).

Code: `App/Capture/` (camera, scan screen), `App/Pantry/AddFoodView.swift` (barcode and lookup on the
form), `Sources/PantrifiedDomain/GTIN.swift` (normalization), `Sources/PantrifiedApplication/BarcodeScan.swift`
(reads to events), `Sources/PantrifiedApplication/ProductLookup.swift` (the capability),
`Sources/PantrifiedFoodDataCentral/` (the adapter) and `PersistentProductEvidence` in
`Sources/PantrifiedPersistence/LocalRepositories.swift` (where the barcode is kept).

## Flow

```text
Today or Food → Scan
  → camera state (below)
  → barcode read in two frames → success haptic → camera stops
  → Add food, in the same sheet, with the barcode shown
      → lookup on: "Looking up this barcode with USDA FoodData Central", then a suggested name,
        "No product found for this barcode" or "Couldn't look this up"
      → lookup off: nothing about lookup
  → the person checks the form and taps Add, as for food added by hand
Add by hand (on every scan screen) → Add food without a barcode
```

Lookup never blocks the form. The person can type a name and add the food before the lookup answers;
closing the form cancels the lookup.

## Camera states

| State | When | What the screen shows |
|---|---|---|
| No camera | No back camera, such as the simulator | "Camera not available" and Add by hand |
| Asking | Access not decided yet | "Pantrified uses the camera only to read barcodes. No photos or video are recorded.", while the system prompt is up. The prompt shows the usage description |
| Running | Access allowed | The camera with a frame, "Point the camera at the barcode on a package", Add by hand, and a light button when the camera has a torch |
| Denied | The person said no, or turned it off later | "Camera access is off", Open Settings and Add by hand |
| Restricted | Screen Time or device management blocks the camera | "Camera access is restricted" and Add by hand |
| Couldn't start | The session did not start, for example while another app holds the camera | Try again and Add by hand |

Access is read again when the app returns to the foreground, so turning the camera on in Settings and coming
back starts it. The usage description (`NSCameraUsageDescription`, set in `project.yml`) is: "Pantrified uses
the camera to scan barcodes on food packages. Only the barcode number is read; no photos are taken or saved."

## Reading barcodes

- **AVCaptureMetadataOutput, not Vision.** The product decisions name Vision as the deterministic recognition
  baseline. For live barcodes alone, AVFoundation's metadata output decodes inside the framework and hands the
  app only the decoded text: no video data output is attached and no pixel buffer reaches app code, so no
  frame can be kept, even by mistake. It is also cheaper on battery than running Vision on every frame. Date
  recognition will need frames and Vision; when that is built, barcode reading can move to the same Vision
  pass if one pipeline is simpler.
- **Symbologies.** EAN-13, EAN-8 and UPC-E. AVFoundation reports UPC-A as EAN-13 with a leading zero, and the
  normalization below makes both one GTIN.
- **Two frames.** A product is accepted only when the same GTIN is read in two frames within two seconds
  (`BarcodeScan`), so one misread frame cannot name a product. Two barcodes of the same product in one frame
  count as one frame. At camera frame rates this adds a few hundredths of a second.
- **Repeats.** After a product is accepted the scan ignores everything and the camera stops. A barcode that is
  refused (below) is announced once, with a warning haptic and a line of text, and again only after it has
  been out of view for two seconds.
- **Lifecycle.** The camera starts when the scan screen appears and stops when it disappears, when a product
  is read, and when the app leaves the foreground. The torch is turned off whenever the camera stops.
- **Close focus.** The back camera is the triple or dual wide virtual device when the phone has one, zoomed to
  the wide camera's field of view, so it can switch to the ultra wide camera for close focus. Otherwise it is
  the wide camera, with focus restricted to near range where supported.
- **Whole frame.** Any barcode in the frame is read; there is no region of interest. With two products in
  view, the first read twice wins, and the form shows its number for the person to compare.

## GTIN normalization

`GTIN` (domain) turns a scanned payload and its symbology, or text of 8, 12, 13 or 14 digits, into one
canonical form: the 14-digit GTIN, zero padded. UPC-E is expanded to its UPC-A by the standard
zero-suppression rules before padding. `issuedForm` gives the length the code was issued in (GTIN-8, UPC-A,
EAN-13 or GTIN-14), which is what the form shows and what lookup searches.

A code is refused, with a reason, when it:

| Refusal | Rule |
|---|---|
| Malformed | Not ASCII digits, the wrong length for its symbology, or a UPC-E whose number system is not 0 or 1 |
| Check digit | The GS1 mod 10 check digit does not match |
| Not a consumer unit | A GTIN-14 whose packaging indicator is not 0 (a case or pack) |
| Store internal | GS1 prefixes 020 to 029, 040 to 049 and 200 to 299 (UPC number systems 2 and 4 and EAN prefix 2: weighed items and store codes), and GTIN-8s starting 0 or 2 |
| Coupon | GS1 prefixes 050 to 059, 981 to 984 and 990 to 999 |
| Publication | 977, 978 and 979 (ISSN, ISBN, ISMN) |
| Refund receipt | 980 |

Store codes are refused because the same number names different things in different stores and often holds
the price; kept as evidence they would be wrong more often than right. A refused code never blocks anything:
the screen says what it is and the person adds the food by hand. The GTIN-8 ranges are a simplification of
GS1's GTIN-8 allocation and may need adjusting if a real EAN-8 food product is refused.

## Where the barcode is kept

`Pantry.add` puts the barcode on the draft, and `PutAway` keeps each draft's barcode after the packages are
saved, through the `ProductEvidenceStore` capability. The app's store keeps it in a device-local row
(`packageBarcode`, keyed by the package ID, holding the 14 digits), beside storage locations and ingredient
links. It is product evidence only: two packages with one barcode are two packages, each with the barcode.

It is **not synchronized**. The package's sync records have no barcode field, and adding one, or a product
record kind, is a change to the record format and an owner decision (Owner decisions, below). Until then a
barcode stays on the device that scanned it, is not in any household member's other devices, and is not
removed when the package leaves active inventory.

A barcode that cannot be stored does not fail the add: the food is saved, and `PutAwayResult.barcodesNotKept`
names it. A retry of the same draft writes the barcode again.

## Product lookup

`ProductLookupService` (application layer) takes a GTIN and returns found with a name and its source, not
found, or failed with a reason (offline, timed out, rate limited, key refused, provider error, cancelled). It
never throws. `FoodDataCentralLookup` (the `PantrifiedFoodDataCentral` target) is the only adapter.

**Request.** One HTTPS GET to `https://api.nal.usda.gov/fdc/v1/foods/search` with `query` set to the
barcode's issued form and two constants, `dataType=Branded` and `pageSize=10`. The key goes in the
`X-Api-Key` header, so it is never part of a URL. The User-Agent is the fixed text `Pantrified` and
Accept-Language is `en`, so the request does not carry the OS version or the device's language. The session
is ephemeral (no cookies, cache or credential storage), times out after 8 seconds, does not wait for a
network, and requires TLS 1.2 or later. The transport sends only to `https://api.nal.usda.gov` and follows
no redirect, so the key header cannot be carried to another host; a 3xx answer is a provider error. It reads
the body as it arrives and stops once more than 1 MB has arrived after decompression, and refuses an answer
that announces a larger length before reading any of it. Like any network request, it reveals the device's
IP address to the service. Nothing is logged: not the key, not the barcode, not the answer.

**Answer.** A record counts only when its own `gtinUpc`, normalized, equals the scanned GTIN; a search that
returns other products is a miss. The first matching record with a usable description gives the name, with
control characters removed, spaces collapsed, all-capitals text put in sentence case, and limits of 100
characters and 400 bytes of UTF-8, cut between characters. 401 and 403 are a refused key, 429 is a rate
limit, other non-2xx statuses (redirects included) and anything that cannot be read as the search response,
or is over 1 MB, are a provider error. URL loading errors are grouped into offline, timed out, cancelled and
other.

**On the form.** A found name fills the Name field only when it is empty, with the note "Name suggested by
USDA FoodData Central. Check it before adding." If the person edits it the note goes away. A name added as
suggested is saved as a recognized proposal, not a confirmed field (`NewFood.NameSource.lookup`), so it
carries the same provenance as other recognition. Not found shows "No product found for this barcode. Enter
a name." Every failure shows "Couldn't look this up. Enter a name." A cancelled lookup shows nothing.

Lookup runs automatically after a scan when the build has a key. Screenshot runs never look anything up.

## The FoodData Central key

The app reads `FoodDataCentralAPIKey` from its Info.plist. `App/Info.plist` holds only that key, set to
`$(FDC_API_KEY)`; Xcode merges the generated keys into it. `FDC_API_KEY` is a project-level build setting in
`project.yml`, empty by default. Empty means lookup is off, which is the state of every CI build.

The key ships inside the app, so anyone with the app can read it. It is a free, rate-limited api.data.gov
key that grants nothing but these public lookups: treat it as low value, not as a secret. Every install
shares that one key and its hourly request limit, so one person who extracts it and uses it up can turn
lookup off for everyone until the limit resets. Lookup then fails quietly ("Couldn't look this up") and
adding food still works. If it is abused, register a new key and ship a build with it.

**For a local build:** set `FDC_API_KEY = your-key` in `Config/Signing.local.xcconfig` (the example file lists
it), which is git-ignored and included by the target's configuration, so it overrides the project-level empty
value. Do not commit a key.

**For TestFlight builds.** These files belong to the TestFlight pipeline and are left for that work:

1. The owner registers a key at <https://api.data.gov/signup/> and adds it as an Environment secret
   `FDC_API_KEY` of the `testflight` Environment (**Settings > Environments > testflight**).
2. In `.github/workflows/testflight.yml`, the **Sign, archive and upload** step's `env` gains
   `FDC_API_KEY: ${{ secrets.FDC_API_KEY }}`.
3. In `Scripts/upload-testflight.sh`, after `archive_settings=(CURRENT_PROJECT_VERSION="$version")`:

   ```bash
   # The FoodData Central key the app reads from its Info.plist; without it, lookup is off.
   if [[ -n ${FDC_API_KEY:-} ]]; then
     archive_settings+=("FDC_API_KEY=$FDC_API_KEY")
   fi
   ```

   xcodebuild prints command-line build settings in its log; GitHub masks secret values there.
4. `docs/testflight.md` lists the seventh secret, and `Scripts/tests/test_upload_testflight.sh` covers the
   setting being passed when present and absent when empty.

A build without the secret still works; lookup is simply off.

## Screenshots

`-pantrified-screen scan` opens the scanner over Today in a Debug screenshot run. A simulator has no camera,
so `Scripts/capture-screenshots.sh` photographs the "Camera not available" state, in light and dark mode at
the default and largest accessibility text sizes.

## Verified where

| Level | What runs |
|---|---|
| Linux `swift test` | GTIN normalization and every refusal, UPC-E expansion, coding; two-frame confirmation, repeat and refusal suppression, the forget window; barcodes through `Pantry` and `PutAway`, including failure, retry and order; suggested names saved as proposals; the device-local row and its refusal of a stored value that is not a GTIN; the FoodData Central request shape, matching, every status and transport failure, malformed and oversized answers, names and their byte limit, and cancellation, with a fake transport; and the URLSession transport against a local HTTP server: a body growing past 1 MB is cut off early, an announced oversize length and a redirect are refused, the key reaches no second server, and other origins are never contacted. Never the real network |
| macOS `make test-package` | The same against Apple's Foundation, including the transport tests against URLSession on macOS |
| `make build` and `make test` | The camera and scan code compile against the iOS SDK; the hosted tests check the usage description and the empty key in the merged Info.plist and the scan screen's start state |
| Screenshots | The no-camera state's layout |
| Device | Nothing yet |

Not verified: live scanning, the permission prompt, torch, low light, close focus, real packaging, real
UPC-E reads (AVFoundation is expected to report UPC-E as eight digits with the number system and check
digit), and the real FoodData Central response for real barcodes, including whether its search finds a
barcode stored in a different length. The body limit and redirect refusal are tested on Linux and macOS
against a local server with uncompressed bodies only; that iOS hands the delegate decompressed bytes as
they arrive, so a compressed bomb is stopped at 1 MB, is Apple's documented behavior but untested here.

## Not built

- **Lookup later.** A lookup that fails offline is not queued and retried; the barcode is kept, so a later
  retry can be added.
- **Reusing earlier scans.** A barcode scanned before does not suggest the name used last time, which would
  work offline and send nothing.
- Date recognition from the camera, photo import, evidence crops, the continuous multi-package stream, and
  syncing or exporting barcodes.
- Removing a barcode row when its package leaves active inventory, and deleting barcode rows with the
  rest of a Space's local data.

## Decisions for review

1. **AVCaptureMetadataOutput instead of Vision** for live barcodes, for the privacy and battery reasons above.
2. **Two frames before accepting a product**, at the cost of a few hundredths of a second.
3. **Store, coupon, publication and receipt codes are refused**, with a line saying so, rather than kept as
   evidence.
4. **Barcodes are kept on the device only**, in a local row, so nothing about the sync format changed.
5. **Lookup is automatic after a scan** when the build has a key, with the note on the form saying it is
   happening. The more private choice is a Look up button the person taps each time.
6. **A suggested name the person keeps is a proposal**, so a later correction or recognition treats it like
   other recognized names.
7. **Only the barcode and the key are sent**, plus the fixed search options, a fixed User-Agent and language.

## Owner decisions

1. **Should barcodes sync?** Options:
   - Keep them on the scanning device (built). No format change; other devices never see them.
   - Add a `barcode` field to the package header record. An older reader ignores an unknown field, so
     `minimumReaderVersion` stays at 1, but it is a new synced field and the barcode reaches iCloud and every
     member of a shared Space.
   - Add a product record kind holding the GTIN (and later a name and lookup provenance), referenced by the
     header's existing `productID`. Also ignorable by older readers, and the start of a product catalog the
     household shares.
2. **Automatic lookup or a button** (decision 5 above).
3. **App Privacy answers for lookup.** The barcode goes to USDA at api.nal.usda.gov with the device's IP address,
   only to answer the request, and is not linked to the person by the app. Whether App Store Connect's App
   Privacy answers should list it, and under which data type, is the owner's call when the first build with a
   key is uploaded. The privacy manifest declares no collected data types, which matches the app's own code.
