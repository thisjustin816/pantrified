# Batch intake

The core capture flow. Take a photo of each thing you brought home, or pick photos you already took,
tap Done, check the list Pantrified made, and tap Add all. Nothing is recognized live: photos are read
after Done, on the device, and grouped into one candidate per package. Barcodes and QR codes are
shortcuts for information that needs no image reading; the dedicated barcode scanner (`capture.md`)
stays as it is beside this.

Code: `Sources/PantrifiedDomain/Intake/` (observations, label text, grouping, the review),
`Sources/PantrifiedApplication/Intake/` (staging store, pipeline, adding),
`Sources/PantrifiedPersistence/StagingDirectory.swift` (the folder), `App/Intake/` (camera, Vision
recognizer, screens) and `App/Recognition/TextRecognizer.swift` (the shared text request).

## Flow

```text
Today or Food → Add a batch
  → camera: tap the shutter for each photo (front, barcode, date), as fast as you like;
    a strip shows what was taken; the photo button adds photos from the library
  → Done
  → "Reading photo 3 of 12" (on the device; closing keeps everything)
  → review: one card per package, each proposed field saying where it came from
  → Add all (or select some and Add)
  → "Added 9 foods", with Undo while the batch is open
```

A typical batch of ten packages, each photographed front and back, takes 24 taps from opening the
screen to a usable list: Add a batch, 20 shutter taps, Done, Add all, and Done to close. The first
time, the camera permission prompt adds one. Nothing on a card must be filled in before Add all:
quantity and date may stay unknown and every place starts at a proposal. A candidate without a name
is the one exception, because a package needs a name; it stays in the review, marked "No name found.
Add one.", and the rest are added. Every correction is one tap from the card: a date that reads two
ways shows both as buttons, a place is a menu, a possible duplicate has Merge and Not the same, and the
name opens the editor.

## What is read from a photo

`VisionPhotoRecognizer` reads each staged photo once, two at a time, off the main thread, scaled to at
most 3,000 pixels on its longest side:

- **Text**, with `TextRecognizer.makeRequest()`: accurate level, language correction off, English.
  Each line keeps its box and Vision's confidence.
- **Barcodes**: EAN-13, EAN-8, UPC-E (UPC-A arrives as EAN-13), normalized by `GTIN` exactly as the
  scanner does, with the same refusals for store, coupon, publication and receipt codes.
- **QR codes**: a QR code holding a GS1 Digital Link (`https://id.gs1.org/01/09506000134352`, or the
  same path on a brand's own domain) gives its GTIN. Any other link is recorded only as "a QR code with a
  link was seen"; it is never opened, fetched or kept. Other QR text is ignored.
- **An image feature print** (Vision's revision 2), used to tell whether two photos look alike.

`PhotoObservation` bounds everything before it is used: 120 photos a batch, 150 lines and 12,000 bytes
of text a photo, 160 characters and 640 UTF-8 bytes a line, 12 codes a photo, 512 bytes a code payload,
4,096 feature print values. Control and format characters, including bidirectional overrides, are
removed. Recognized text and lookup answers are untrusted; none of it is logged or printed in test
failures.

Dates are read by `PrintedDateRecognition` (`date-recognition.md`) over each photo's lines in reading
order, so a label above its date is read with it. An ambiguous date stays a pending choice.

## Grouping

`PhotoGrouper` scores every pair of photos and groups pairs that score high enough. It is deterministic:
the same photos in any order give the same groups. All weights and thresholds are in `GroupingPolicy`
(`PhotoGrouping.swift`), in one place, so they can be tuned after trying the app on real groceries.
**None of these values has been checked against real photos.**

| Signal | Points | Why |
|---|---|---|
| Same product barcode | 100 | A GTIN names one product. Enough alone. |
| Same bytes (SHA-256 of the file) | 100 | The same photo added twice. |
| Feature prints within 0.25 | 50 | Near duplicate. Not enough alone: two flavours of one brand look alike. |
| Feature prints within 0.5 | 25 | Looks alike. Supporting evidence only. |
| Three or more shared label words, covering half the shorter label | 50 | Front and back of one package usually repeat the brand and product name. |
| Two shared words, or one of five letters or more | 25 | A brand alone. Supporting evidence only. |
| Taken one straight after the other, within 20 seconds | 15 | People photograph one package at a time. Never enough alone. |
| A photo of only a date, taken straight after | 45 | The usual order is front, then date. With the 15 above, it groups. |
| A photo of only a date, taken straight before | 15 | Less usual; with the 15 above it is only a suggestion. |

A pair at **60** or more is grouped; a pair from **30** up to 60 is shown on both cards as "Might be the
same as …" with Merge and Not the same. Pairs join strongest first.

Label words are lower case, without accents, at least three letters, with no digits, and not in a list
of words printed on most packages (units, nutrition panel words, date labels, months, storage
instructions, legal and marketing filler). A word on more than four photos and more than 30% of the
batch, such as a store brand, is ignored for that batch.

**What keeps two products apart.** Two photos are never grouped, directly or through a third photo,
when:

- they show **different barcodes**: two products, however alike (no suggestion either);
- their **names differ by a distinguishing word**: the two prominent names share a word but each has a
  word that appears nowhere on the other photo, such as baking soda and baking powder, whole milk and
  skim milk, vanilla and strawberry yogurt (shown as a suggestion when they are otherwise alike);
- they show **different prominent percentages or net contents**: 2% and 1% milk, 16 oz and 32 oz.
  Percentages count only on large lines that hold a real word, so nutrition panels do not count.

A barcode or identical bytes settle a pair, so these differences are not checked then.

**Several products in one photo.** A photo showing two or more product barcodes joins each product's
candidate, or starts one per barcode, and is marked "One photo shows more than one product". Its text is
not used for any name or date, since it cannot say which product it belongs to.

**Alternatives not taken.** Clustering by time gaps alone (fast, but one slow shot splits a package and
two quick packages merge); a single text similarity score with one threshold (merges near-identical
products, the failure the owner's research names); average or complete linkage (more cautious than
needed once barcodes and differing names already block merges, and harder to explain); and an on-device
model to judge pairs (not explainable, not testable on Linux, and model confidence is not calibrated).

## Candidates and proposals

Each candidate proposes, and says where each proposal came from:

- **Name**: the barcode lookup's name ("From USDA FoodData Central") when there is one; otherwise the
  tallest line of words on its photos, joined to a brand printed right above it ("Read from the label.
  Check it."); otherwise nothing, marked "No name found". A name is never invented. Lines Vision was
  less than 30% sure of are not used.
- **Date**: the preferred printed date, or a pending choice when it reads two ways. "The photos show
  different dates" when they disagree.
- **Place**: the location of the stated type when a label says "Keep frozen" or "Keep refrigerated";
  otherwise the first location (Fridge). "Refrigerate after opening" is not read as a place.
- **Barcode** and **how many**: one package, unless the person says more. A barcode seen in photos taken
  apart asks "More than one?".

What the person sets wins: a name, date or place they set is never replaced by a lookup or a re-read,
and a name or date left as proposed is saved as a proposal, not as a confirmed field, as Add food does
with a lookup's name. Merge, split a photo out, delete, keep apart, set count, bulk location, and every
edit are undoable (`IntakeReview`, last 40 changes). Merging keeps decisions from all the merged cards and
refuses two different barcodes. Lookup answers are not changes and survive an undo.

**Adding** puts the ready candidates away through `Pantry.putAway`, all or none, each with its barcode
and printed date. The list is usable at once; nothing waits for reading or lookups. **Undo** after Add
discards the packages (a package's history is never deleted, so they stay in it as discarded with no
reason) and returns the candidates to the review with new package identities.

**Receipts later.** `PhotoObservation.kind` exists for a receipt kind. A receipt would be read by its own
step, skipped by grouping, and make several candidates that share the one photo, as a photo of several
barcodes already does.

## Keeping photos, and never losing a batch

New photos and copies of picked photos are written only to `Application Support/Pantrified/Intake`,
never to the photo library. The folder and each file are protected until the iPhone is first unlocked
after a restart and are excluded from backups. Originals in Photos are never touched: the picker hands
the app a copy, and the store only removes names it made itself (an upper-case UUID and `.jpg`, `.heic`
or `.png`).

`StagingStore` writes every change before returning, so a crash or kill loses at most the change in
progress:

| When | What happens |
|---|---|
| Killed while taking photos | The batch opens again in the camera with every photo kept |
| Killed while reading | Photos already read are kept; the next launch, or opening the batch, reads the rest |
| Killed during review | Every edit is kept; the batch opens again in the review |
| Killed during Add or its Undo | Recorded before it starts and finished on the next launch, without adding twice |
| Add fails | Nothing is saved and nothing is left to finish; the candidates stay |

**Deleting.** Photo files are deleted about a day (24 hours) after they were read. The review, with
what was read from the photos (text lines, codes and feature prints) and the person's edits, stays until
everything in it is added or deleted, then for one more day, so a batch is never lost before the person
finishes it. A batch still in the camera a day after its last photo is read anyway, so abandoned photos
do not stay indefinitely. **Discard** deletes the photos and the batch at once. Photo files no batch
names, left by a crash between writing a file and recording it, are removed. Times come from the store's
own records, never from file dates, so no required-reason API is used.

A copy of a photo picked from the library keeps whatever its file holds, such as where it was taken,
until it is deleted with the batch. Nothing in it is read except the image and the time it was taken.

## What leaves the device

Only a barcode, in the FoodData Central lookup, exactly as for the scanner (`capture.md`), in a build
with a key. Every lookup goes through the injected `ProductLookupService`, so a rate-limit decorator
around it applies here too. Lookups run after reading, one at a time, at most 40 a pass, and each
distinct barcode is asked once. A miss is final. When the device is offline or the service answers
"rate limited", the rest of the pass is deferred, not failed: cards say "Barcode lookups are paused
for now", the barcodes stay on their candidates, and the next pass (opening the batch, or the next
launch) asks again. Other failures are tried again up to three times. None of this blocks review or
adding. Photos, recognized text and feature prints never leave the device, and nothing about a batch
syncs.

## Verified where

| Level | What runs |
|---|---|
| Linux `swift test` | Bounds and hostile text; code classification and Digital Links; label words, names, amounts and stated storage; grouping: same product twice, similar products with different barcodes, front without barcode then barcode, a photo of several products, no text, duplicates, date photos, near-identical products (baking soda and powder, whole and skim milk, 2% and 1%, sizes, flavours), chaining, a common brand, order independence, a 140-photo batch; the review's proposals, provenance, merge, split, delete, bulk location, counts, undo and coding; the staging lifecycle and its deletion rules; reading, idempotent reprocessing, bounded concurrency, unreadable photos and lookups; Add all, Undo and partial adds; and kill and resume while capturing, reading, reviewing, adding and undoing |
| macOS `make test-package` | The same against Apple's Foundation |
| Hosted app tests | The usage description; the review sample on the real local store, with Add all and Undo; staged files' protection class and backup exclusion; Vision reading drawn text and a QR code's Digital Link, and noting another link |
| Screenshots | The review screen on synthetic readings with placeholder photos, light and dark, default and largest text |
| Device | Nothing yet |

**Not verified:** recognition on real packaging, lighting and curved labels; whether the thresholds group
real photos well; feature print distances on real photos (the 0.25 and 0.5 values assume revision 2's
unit vectors and are a guess); the camera itself, rapid shots, focus and memory on a device; the Photos
picker with real libraries; and how long reading takes on a phone.

## Owner decisions

1. **Thresholds.** Tune `GroupingPolicy` after trying real groceries. Raising `mergeAt` or lowering the
   text weights makes grouping more cautious.
2. **Unfinished batches stay until finished.** The review, with what was read from the photos, is kept
   until the person adds or discards everything. Photos still go after a day. The alternative is to
   delete the whole batch a few days after reading.
3. **Undo after Add records a discard.** The sync format has no way to retract an add, so Undo discards
   the packages with no reason. A future waste report should not count those; marking them needs a record
   format change.
4. **A name is required to add.** Candidates without one stay in the review rather than being added as
   "Unnamed".
5. **The scanner's own text.** The scan screen's prompt still says "Pantrified uses the camera only to
   read barcodes. No photos or video are recorded." That is true of the scanner, but "only" now reads as a
   claim about the app. The scanner was left untouched as instructed; changing it to "The scanner uses the
   camera only to read barcodes…" is a one-line wording change for the owner to approve.
