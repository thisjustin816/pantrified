# Batch intake

The core capture flow. Take a photo of each thing you brought home, or pick photos you already took,
tap Done, check the list Pantrified made, and tap Add all. Each photo is read on the device as soon as
it is kept, while the camera stays open, and grouped with the photos read so far; barcodes are looked
up as soon as they are read. At Done only the last one to three photos are usually left, so the list
shows at once. The camera preview itself is never analyzed. Barcodes and QR codes are
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
    a strip shows what was taken and whether each is read; "9 packages so far" counts
    what is read; the photo button adds photos from the library
      (behind it: each kept photo is read, one at a time at low priority; the photos read
       so far are grouped again; each new barcode is looked up, at most 2 at once)
  → Done
  → 1 to 3 photos left: the list so far at once, with "Reading 2 more photos",
      not changeable until they are read (a second or two, unmeasured)
    more left: "Reading photo 9 of 30" (closing keeps everything; reading goes on)
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

`VisionPhotoRecognizer` reads each staged photo once, off the main thread, scaled to at most 3,000
pixels on its longest side (when and how many at once is under "Timing and ordering"):

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

## Timing and ordering

`IntakePipeline` is one actor for the whole app, so the batch screen and the launch's resume never
read a batch twice at once. Its rules (`ReadingPolicy` and `LookupPolicy`, pure and tested):

| When | Reads at once | Why |
|---|---|---|
| Camera open | 1, at utility priority | The shutter and preview keep the processor. The person takes photos faster than they are read only in bursts, and the reading catches up between packages |
| Camera open, thermal state serious or critical, or Low Power Mode | 0 (waits) | Reading is optional work while the camera runs; it carries on when the state clears or at Done |
| After Done | 2, at user-initiated priority | The person is waiting. Each read holds one decoded photo, so 2 bounds memory |
| After Done, serious or critical | 1 | Finish without making the heat worse |
| After Done, Low Power Mode | 2 | The work is the same either way; finishing sooner lets the phone rest sooner |
| App in the background | 0 (waits) | iOS may stop the work, and a read stopped by the system would count against the photo |

A cancelled read keeps its slot until it ends, so the most decoded photos in memory for reading is the
number of slots. Every attempt is counted in the store before it starts; a read cancelled by closing the
batch is taken back.

**Grouping as photos arrive.** After each read, `LiveGrouping` runs `PhotoGrouper` again over every
observation read so far, unchanged. Grouping is a pure function of the set of observations, so the
review, made once when the last photo is read, is the one-shot grouping of the whole batch whatever
order the readings arrived in. Results before that are shown only as the tentative count. Two photos
with different barcodes, or whose labels differ in a distinguishing word or amount, are never in one
group at any step, because those refusals do not depend on the rest of the batch. Tests check both
over 300 seeded arrival orders of a batch with front, barcode and date photos, a duplicate, a photo of
two products, near-identical products and a doubtful pair, and through the pipeline over 12 orders. A
candidate whose newest photo is three shots or 15 seconds old (`SettlingPolicy`) gets a filled check on
its thumbnails, as a hint only.

**Cost.** Grouping 120 photos scores 7,140 pairs; grouping again after each of 120 arrivals scores
287,980 pairs in all. A test holds both counts, so a change that makes grouping costlier fails. On the
Linux CI machine the 120 arrivals took about 1.1 seconds in a release build and 2.3 to 3.3 seconds in a
debug build, about 23 ms for the last grouping. A phone has not been measured.

**Done.** With at most 3 photos left (`ReadingPolicy.fewLeft`) the list of what is read so far shows at
once with "Reading 2 more photos". It cannot be changed until the review exists: the store refuses every
review change before the review is made, and the screen disables the list, Undo, Select and Add all. The
review is made once, after the last read, and a batch that already has a review keeps it, so an edit
can never be lost to a regroup and the final grouping is always the one-shot grouping. Holding the list
for the last one to three reads was chosen over reconciling edits with a regroup, which would need
stable candidate identities across groupings and could still move an edited photo. With more photos
left, the reading screen shows "Reading photo 9 of 30"; closing it keeps the batch and the reading goes
on while the app runs, or resumes at the next launch.

**Measuring reading on a phone.** Per-photo Vision time has never been measured. A Debug build (run
from Xcode on the phone) shows a line under the camera controls, "Read 12 photos: last 0.84 s, mean
0.91 s, slowest 1.30 s", from `ReadTiming.swift`; Release builds compile none of it. Take 20 to 30
photos of real groceries at a normal pace and note whether the strip keeps up, then tap Done and note
how many photos are left. If reading falls behind while shooting, raising `ReadingPolicy.whileCapturing`
is the first thing to try, watching the shutter's responsiveness and the thermal state.

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
| A photo crashes the reader | Each read is counted before it starts, so the crash counts. After two reads that did not finish, the photo is kept as "could not read" and the rest go on; the reading screens also offer Discard |
| Killed during review | Every edit is kept; the batch opens again in the review |
| Killed during Add or its Undo | Recorded before it starts and finished on the next launch, without adding twice |
| Add fails | Nothing is saved and nothing is left to finish; the candidates stay |

**Deleting.** One clock for an unfinished batch: it is deleted entirely, photo files, what was read
from them and the review, 3 days (`StagingStore.unfinishedBatchLifetime`) after it was last used. Use is
opening the batch screen, taking, picking or removing a photo, changing the review, and adding or undoing
an add; reading on its own is not use. A finished batch, one with everything added or deleted, keeps its
photos for the one-day recovery window (`StagingStore.defaultRecoveryWindow`) so Add can be undone, then is
deleted with them. **Discard** deletes the photos and the batch at once. Deleting runs while the app is
open: at launch, whenever the app becomes active, and when the batch screen opens; an app that stays closed
deletes them the next time it opens. The next batch screen after an unfinished batch expired starts a new
batch and says once "An unfinished batch was deleted after 3 days without use." Photo files no batch
names, left by a crash between writing a file and recording it, are removed. Times come from the store's
own records, never from file dates, so no required-reason API is used.

**A batch list that cannot be used.** When the list cannot be read, such as before the first unlock
after a restart, nothing is written or deleted and it is read again on the next use. When it, or one
batch in it, cannot be understood, the file is set aside as `batches.unreadable.json`, the batches that
can be read are kept, and the batch screen says a batch could not be opened. The copy and the photos only
it named are deleted a day later. A list written by a newer version of the app is opened read only and
nothing in it is changed or deleted.

A copy of a photo picked from the library keeps whatever its file holds, such as where it was taken,
until it is deleted with the batch. Nothing in it is read except the image and the time it was taken.

## What leaves the device

Only a barcode, in the FoodData Central lookup, exactly as for the scanner (`capture.md`), in a build
with a key. Every lookup goes through the injected `ProductLookupService`, so the paced decorator
around it (`PacedProductLookup`) applies here too. A barcode is looked up as soon as a photo showing it
is read, while photos are still being taken, at most 2 at once (below the decorator's own 3) and at most
40 a pass; a pass starts when the batch opens and again at Done. Each distinct barcode is asked once a
pass, and a miss is final. Answers are kept by barcode on the batch, apart from grouping, so they attach
to whichever candidate shows that barcode. When the device is offline or the service answers "rate
limited", including the decorator's own pause, the rest of the pass is deferred, not failed: cards say
"Barcode lookups are paused for now", and the next pass asks again. Other failures are tried again on
later passes up to three times. Discarding or closing the camera cancels lookups in flight. None of
this blocks taking photos, review or adding. Photos, recognized text and feature prints never leave the device, and nothing about a batch
syncs.

## Verified where

| Level | What runs |
|---|---|
| Linux `swift test` | Bounds and hostile text; code classification and Digital Links; label words, names, amounts and stated storage; grouping: same product twice, similar products with different barcodes, front without barcode then barcode, a photo of several products, no text, duplicates, date photos, near-identical products (baking soda and powder, whole and skim milk, 2% and 1%, sizes, flavours), chaining, a common brand, order independence, a 140-photo batch; the review's proposals, provenance, merge, split, delete, bulk location, counts, undo and coding; the staging lifecycle and its deletion rules; reading while photos are taken, one at a time, and two at a time after Done; pausing for heat and Low Power Mode; never reading a photo twice; unreadable and crashing photos; incremental grouping equal to one-shot grouping over many arrival orders, and its cost for 120 photos; the list held until the last reads end, with edits kept; lookups started early, once per barcode, at most 2 at once, within the pass budget, deferred and retried; cancelling reads and lookups on discard and on closing the camera; Add all, Undo and partial adds; and kill and resume while capturing, during a read while capturing, during a lookup, reading, reviewing, adding and undoing |
| macOS `make test-package` | The same against Apple's Foundation |
| Hosted app tests | The usage description; the review sample on the real local store, with Add all and Undo; staged files' protection class and backup exclusion; Vision reading drawn text from a still. Vision's barcode and QR detection found nothing in the CI simulator, which logged a model load failure, so those tests only check that nothing wrong is read and mark the rest as a known simulator issue |
| Screenshots | The review screen on synthetic readings with placeholder photos, light and dark, default and largest text |
| Device | Nothing yet |

**Not verified:** Vision's barcode and QR detection at all (it found nothing in the simulator), recognition on real packaging, lighting and curved labels; whether the thresholds group
real photos well; feature print distances on real photos (the 0.25 and 0.5 values assume revision 2's
unit vectors and are a guess); the camera itself, rapid shots, focus and memory on a device; the Photos
picker with real libraries; how long reading takes on a phone, whether one read at a time keeps up
with real shooting, whether reading while the camera runs slows the shutter or preview, how warm the
phone gets, and memory with two reads at once. All of the timing and thermal numbers above are
reasoned, not measured on a device.

## Owner decisions

1. **Thresholds.** Tune `GroupingPolicy` after trying real groceries. Raising `mergeAt` or lowering the
   text weights makes grouping more cautious.
2. **Unfinished batches expire.** Decided: an unfinished batch is deleted entirely 3 days after it was
   last used (`StagingStore.unfinishedBatchLifetime`, one constant to change).
3. **Undo after Add records a discard.** The sync format has no way to retract an add, so Undo discards
   the packages with no reason. A future waste report should not count those; marking them needs a record
   format change.
4. **A name is required to add.** Candidates without one stay in the review rather than being added as
   "Unnamed".
5. **The scanner's own text.** The scan screen's prompt still says "Pantrified uses the camera only to
   read barcodes. No photos or video are recorded." That is true of the scanner, but "only" now reads as a
   claim about the app. The scanner was left untouched as instructed; changing it to "The scanner uses the
   camera only to read barcodes…" is a one-line wording change for the owner to approve.
