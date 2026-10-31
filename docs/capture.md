# Barcode capture

The first capture slice: scan one barcode with the camera, open Add food with the barcode attached, and
suggest the product's name from USDA FoodData Central when the build has a key. The person reviews the form
and adds the food as they do by hand. The scanner keeps no photos. Taking or picking photos of many
packages at once, reading their labels and dates, and grouping them for review is batch intake, a
separate screen described in `batch-intake.md`; it shares the GTIN rules and the lookup below.

Code: `App/Capture/` (camera, scan screen), `App/Pantry/AddFoodView.swift` (barcode and lookup on the
form), `Sources/PantrifiedDomain/GTIN.swift` (normalization), `Sources/PantrifiedApplication/BarcodeScan.swift`
(reads to events), `Sources/PantrifiedApplication/ProductLookup.swift` (the capability),
`Sources/PantrifiedApplication/PacedProductLookup.swift` (rate limits), `Sources/PantrifiedFoodDataCentral/`
(the adapter), `Sources/PantrifiedPersistence/LookupPauseFile.swift` (a rate limit pause kept across
launches) and `PersistentProductEvidence` in `Sources/PantrifiedPersistence/LocalRepositories.swift` (where
the barcode is kept).

## Flow

```text
Today or Food → Scan
  → camera state (below)
  → barcode read in two frames → success haptic → camera stops
  → Add food, in the same sheet, with the barcode shown
      → lookup on: "Looking up this barcode with USDA FoodData Central", then a suggested name,
        "No product found for this barcode", "Name lookups are paused" or "Couldn't look this up"
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
back starts it. The usage description (`NSCameraUsageDescription`, set in `project.yml`) covers both camera
screens: "Pantrified uses the camera to scan barcodes and to take photos of the food you add, so it can read
their labels on this iPhone. Photos stay on this iPhone and are never saved to your photo library. While
Pantrified is open, it deletes them a day after reading them or two days after they were added, whichever
comes first. What it read stays with a batch until you add or discard it." The scanner itself takes no photos; the photos are batch intake's
(`batch-intake.md`). The Asking state's own text, "Pantrified uses the camera only to read barcodes", is
still the scanner's wording and is an open owner decision in `batch-intake.md`.

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
EAN-13 or GTIN-14), which is what the form shows. Lookup searches more lengths than this (Product lookup,
below).

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
found, or failed with a reason (offline, timed out, rate limited, key refused, provider error, cancelled). A
rate-limited result carries when lookups resume, when that is known. It never throws.
`FoodDataCentralLookup` (the `PantrifiedFoodDataCentral` target) is the only adapter; the app wraps it in
`PacedProductLookup` (Rate limits, below).

**Request.** One HTTPS GET to `https://api.nal.usda.gov/fdc/v1/foods/search` with `query` set to the
barcode's search forms (below), separated by single spaces, and two constants, `dataType=Branded` and
`pageSize=10`. The key goes in the `X-Api-Key` header, so it is never part of a URL. The User-Agent is the
fixed text `Pantrified` and Accept-Language is `en`, so the request does not carry the OS version or the
device's language. The session is ephemeral (no cookies, cache or credential storage), times out after 8
seconds, does not wait for a network, and requires TLS 1.2 or later. The transport sends only to
`https://api.nal.usda.gov` and follows no redirect, so the key header cannot be carried to another host; a
3xx answer is a provider error. It reads the body as it arrives and stops once more than 1 MB has arrived
after decompression, and refuses an answer that announces a larger length before reading any of it. Like any
network request, it reveals the device's IP address to the service. Nothing is logged: not the key, not the
barcode, not the answer.

**Search forms.** FoodData Central records hold their barcode (`gtinUpc`) in different lengths, such as 12,
13 or 14 digits, and its search finds a barcode only as the exact string stored. So the query holds the one
scanned number written in each GTIN length that drops nothing but leading zeros, shortest first
(`GTIN.foodDataCentralForms`), and nothing else:

| Scanned | Lengths searched | Example |
|---|---|---|
| UPC-A, UPC-E (by the UPC-A it expands to), EAN-13 starting 0 | 12, 13, 14 | `049000006346 0049000006346 00049000006346` |
| EAN-13 starting 1 to 9 | 13, 14 | `4006381333931 04006381333931` |
| EAN-8, or a UPC-A starting 0000 (the same 14 digits) | 8, 12, 13, 14 | `96385074 000096385074 0000096385074 00000096385074` |

A GTIN-14 read from text is searched like the shorter code it pads to; one with a packaging indicator is
refused before lookup. A UPC-E's own eight digits are not searched, since they would read as a different
GTIN-8. No other length is searched, because `GTIN` reads no other length as a barcode, so a record stored
that way could never be accepted. Every form is ASCII digits only and normalizes to the scanned GTIN.

FoodData Central behavior this relies on, observed against the live service on 2026-10-31 with the owner's
key: `query=0044700361146` found a record stored in 13 digits, while the same number in 12 or 14 digits
found nothing; `query=049000006346` found nothing although the product is stored as `00049000006346`; one
query holding several space-separated forms returned each record stored in any of them and nothing more,
and forms that matched nothing added nothing. The service may change this. The tests do not call the live
service: they check the forms and the request, and search a fake catalog stored in mixed lengths that
follows the behavior above.

**Answer.** A record counts only when its own `gtinUpc`, normalized, equals the scanned GTIN; a search that
returns other products is a miss. The first matching record with a usable description gives the name; a
record with a brand but a blank description gives none, so a later record can. The name is the brand
followed by the description, or the description alone when it already names the brand as whole words
(ignoring case and punctuation). The brand is `brandName`; when that is missing or unusable, `brandOwner`
stands in only if it is at most three words and 24 characters with no company word such as Inc, LLC or
Company, since it is usually the company's legal name. Both are optional: a missing, null or non-text brand
leaves the description's name. Each part has control characters (format and bidi characters included)
removed and spaces collapsed. An all-capitals description is put in sentence case, or kept lowercase after
a brand; an all-capitals brand has each word capitalized, also after a hyphen, ampersand, slash or full stop
("Coca-Cola", "M&M's"), and a mixed-case brand is kept as written. A brand of one character, without a
letter, or over 30 characters or 120 bytes of UTF-8 is left out rather than cut. A name over 60 characters,
or over 400 bytes of UTF-8, has its description cut back to the last space that fits, with trailing
separators such as "&" or "," dropped, and ends in "…", so the brand is kept; a description with no space
in reach is cut between characters. A final guard of 100 characters and 400 bytes applies to the whole
name. Cuts fall between characters, never inside a grapheme cluster or a scalar. 401 and 403 are a refused
key, 429 is a rate limit, other non-2xx statuses (redirects included) and anything that cannot be read as
the search response, or is over 1 MB, are a provider error. URL loading errors are grouped into offline,
timed out, cancelled and other. The transport also reads two headers of any answer, under Rate limits below.

**On the form.** A found name fills the Name field only when it is empty, with the note "Name suggested by
USDA FoodData Central. Check it before adding." If the person edits it the note goes away. A name added as
suggested is saved as a recognized proposal, not a confirmed field (`NewFood.NameSource.lookup`), so it
carries the same provenance as other recognition. Not found shows "No product found for this barcode. Enter
a name." A paused lookup shows "Name lookups are paused for about 40 minutes. Enter a name to add it now, or
scan it again later.", with the time left in whole minutes under 10 minutes, to the nearest 5 minutes under
55, "about an hour" under 90 minutes and in whole hours past that. Every other failure shows "Couldn't look
this up. Enter a name." A cancelled lookup shows nothing. The notes are plain footer text, so they follow
Dynamic Type and VoiceOver like the rest of the form.

Lookup runs automatically after a scan when the build has a key. Screenshot runs never look anything up.

## Rate limits

**What is limited.** FoodData Central's API guide says a registered api.data.gov key gets a default of
1,000 requests an hour per IP address, that going over returns HTTP 429 and blocks the key for an hour, that
every answer carries `X-RateLimit-Limit` and `X-RateLimit-Remaining`, and that a higher limit can be asked
for. The public `DEMO_KEY` gets 30 an hour and 50 a day per IP address. The limit is counted per IP address,
so the installs of the app do not share one allowance: each network address has its own, shared only by
devices behind it, such as a household's router or a carrier's shared address. One owner key showed
`X-RateLimit-Remaining` 3593 after its first request, so a key's real limit can be above 1,000. The app
never assumes a figure; it reads the headers. Each lookup is one request.

**Headers.** The transport reads two headers from every answer, matching names without regard to case. A
header that is missing, repeated or not text is ignored. Neither is logged.

- `Retry-After`: a whole number of seconds in ASCII digits, or an HTTP date in the IMF-fixdate form
  (`Sun, 06 Nov 1994 08:49:37 GMT`). A date is measured from the answer's own `Date` header when that is
  readable, so a wrong device clock does not stretch it, and from the device's clock otherwise; a date
  already past is no wait. The wait is held between 1 second and 24 hours. Anything else is ignored: a
  sign, a fraction, an exponent, NaN or infinity, non-ASCII digits, trailing text, a list, the obsolete
  date forms, or a wait over 7 days.
- `X-RateLimit-Remaining`: a whole number from 0 to 10,000,000 in ASCII digits, or ignored.

**Pacing.** `PacedProductLookup` wraps the adapter. Its numbers are in `LookupPacing`:

| Rule | Value | Why |
|---|---|---|
| Pause after a 429 | `Retry-After` when usable, otherwise 1 hour | FoodData Central documents a one-hour block |
| Pause when an answer reports 0 remaining | 10 minutes | The next request would be refused and block the key for an hour; how the allowance refills is not documented, so the pause is shorter than the block |
| Time between request starts | 1 second | A person scanning by hand never notices it; a batch cannot fire requests back to back |
| At 100 or fewer remaining | 6 seconds | 600 an hour, under the documented default of 1,000 |
| At 20 or fewer remaining | 30 seconds | Spreads the last 20 requests over about 10 minutes |
| Lookups in flight | 3 | More wait their turn, in order |

During a pause no request is sent: every lookup answers at once with `rateLimited` and the time lookups
resume, and the first lookup at or after that time is sent. A lookup that failed for any other reason starts
no pause. The saved pause is deleted at the first found or not-found answer after it ends; an answer to a
request sent before a pause began does not end it. Spacing uses the last `X-RateLimit-Remaining` reported; with
none it is 1 second. A lookup for a barcode that is already being looked up shares that request. A caller
cancelled while waiting for its turn or its spacing gets `cancelled` at once and sends nothing; a shared
request is cancelled only when every caller waiting for it has gone. A caller that looks up many barcodes
goes through the same service, so the same limits apply; the barcode stays with the caller, which can look
it up again once the resume time has passed.

**Persistence.** A pause is saved as one number, its end in whole seconds since 1970, in
`Library/Caches/Pantrified/lookup-resumes-at` (`LookupPauseFile`), so closing and reopening the app does not
send a request the provider will refuse. Nothing else about lookups is saved. Caches are not backed up, and
iOS may purge them, which only ends a pause early. A file that is missing, unreadable, longer than 11
characters or not ASCII digits only is no pause; so is a time already past or more than 24 hours ahead,
which is then deleted. A bad file can never stop lookups for longer than 24 hours or stop the app. It uses
no file date APIs and no `UserDefaults`, so the privacy manifest's required-reason APIs are unchanged.

## The FoodData Central key

The app reads `FoodDataCentralAPIKey` from its Info.plist. `App/Info.plist` holds only that key, set to
`$(FDC_API_KEY)`; Xcode merges the generated keys into it. `FDC_API_KEY` is a project-level build setting in
`project.yml`, empty by default. Empty means lookup is off, which is the state of every CI build.

The key ships inside the app, so anyone with the app can read it. It is a free, rate-limited api.data.gov
key that grants nothing but these public lookups: treat it as low value, not as a secret. FoodData Central
counts the limit per IP address, so someone who extracts the key can spend only their own address's
allowance, not the allowance of other installs. The API guide also says a key that goes over is blocked for
an hour without saying whether that block covers only the address that went over; that has not been
tested. A device that shares an address with heavy use of the key, such as one behind the same router, can
see its lookups paused; adding food still works. If the key is abused, register a new key and ship a build
with it.

**For a local build:** set `FDC_API_KEY = your-key` in `Config/Signing.local.xcconfig` (the example file lists
it), which is git-ignored and included by the target's configuration, so it overrides the project-level empty
value. Do not commit a key.

**For TestFlight builds.** Register a key at <https://api.data.gov/signup/> and add it as an Environment
secret `FDC_API_KEY` of the `testflight` Environment (**Settings > Environments > testflight**). The upload
workflow passes it to `Scripts/upload-testflight.sh`, which writes it into `Config/Signing.local.xcconfig`
for the archive, checks that the archived app carries it, and removes the file on exit. `docs/testflight.md`
describes the secret.

A build without the secret still works; lookup is simply off.

## Screenshots

`-pantrified-screen scan` opens the scanner over Today in a Debug screenshot run. A simulator has no camera,
so `Scripts/capture-screenshots.sh` photographs the "Camera not available" state, in light and dark mode at
the default and largest accessibility text sizes.

## Verified where

| Level | What runs |
|---|---|
| Linux `swift test` | GTIN normalization and every refusal, UPC-E expansion, coding; two-frame confirmation, repeat and refusal suppression, the forget window; barcodes through `Pantry` and `PutAway`, including failure, retry and order; suggested names saved as proposals; the device-local row and its refusal of a stored value that is not a GTIN; the FoodData Central search forms for every symbology, the request shape, matching, a fake catalog stored in mixed lengths, every status and transport failure, malformed and oversized answers, names with their brand, word-boundary cut and byte limit, hostile brand text, and cancellation, with a fake transport; and the URLSession transport against a local HTTP server: a body growing past 1 MB is cut off early, an announced oversize length and a redirect are refused, the key reaches no second server, other origins are never contacted, and a 429 with and without `Retry-After`, `X-RateLimit-Remaining` in either case, and hostile or repeated headers are read as above. Tables of header values, valid and hostile. Pacing with a fake clock and sleeper, never waiting in real time: the pause on a 429 with each kind of `Retry-After`, no request during it and one exactly at its end, no pause after other failures, a pause kept by a new instance through a fake store and through the file, unusable and corrupt saved values, a clock that moved back, the spacing thresholds, three in flight, sharing one barcode, and cancellation while queued, spacing or sharing. Never the real network |
| macOS `make test-package` | The same against Apple's Foundation, including the transport tests against URLSession on macOS |
| `make build` and `make test` | The camera and scan code compile against the iOS SDK; the hosted tests check the usage description and the empty key in the merged Info.plist, the scan screen's start state, and the paused lookup wording |
| Screenshots | The no-camera state's layout |
| Device | Nothing yet |

Not verified: live scanning, the permission prompt, torch, low light, close focus, real packaging, real
UPC-E reads (AVFoundation is expected to report UPC-E as eight digits with the number system and check
digit), and the real FoodData Central response for real barcodes in any automated test. The search
behavior under Search forms and the brand fields were checked by hand against the live service on
2026-10-31: `brandName` is present on branded search results but null on some, the same brand appears in
capitals and in mixed case, and a description can end in a space. FoodData Central's published API
specification lists `brandOwner` on search results but not `brandName`, so both stay optional.
The body limit and redirect refusal are tested on Linux and macOS against a local server with uncompressed
bodies only; that iOS hands the delegate decompressed bytes as they arrive, so a compressed bomb is stopped
at 1 MB, is Apple's documented behavior but untested here.

The rate limit handling rests on FoodData Central's API guide and one observed `X-RateLimit-Remaining`
value, not on a test against the live service: no test has seen a real 429, so whether FoodData Central
sends `Retry-After` with one, and in which form, is unknown, and both its presence and its absence are
handled. How the hourly allowance refills is not documented either.

## Not built

- **Lookup later.** A lookup that fails offline or is paused by a rate limit is not queued and retried from
  Add food; the barcode is kept, so a later retry can be added.
- **Reusing earlier scans.** A barcode scanned before does not suggest the name used last time, which would
  work offline and send nothing.
- Date recognition in the live scanner, evidence crops, and syncing or exporting barcodes. Photo capture,
  photo import and date reading from photos are batch intake (`batch-intake.md`).
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
   The barcode goes in up to four lengths in one request, so that a record stored with or without leading
   zeros is found.

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
