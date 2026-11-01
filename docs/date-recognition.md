# Printed date recognition

`PrintedDateParser` reads printed dates and their labels out of recognized text, such as the output
of OCR. It is pure Swift and takes text, so it is tested without a camera. Recognition only proposes:
the result is a reading, and a draft applies it as a proposal that the person can correct.

## Labels

A date takes the label whose phrase ends directly before it, with only spaces, colons, dots or dashes
between. A date with no such label is unlabeled.

| Printed | Label |
|---|---|
| BEST BY, BEST BEFORE, BEST IF USED BY, BEST IF USED BEFORE, BB, BBD | best by |
| USE BY, USE BEFORE, EXP, EXPIRES, EXPIRATION DATE | use by |
| SELL BY | sell by |
| FREEZE BY | freeze by |
| PACKED, PACKED ON, PKD, MFG, MANUFACTURED, PKG DATE | packed |

A label inside a longer word is not a label.

## Date formats

- Year first: `2026-12-05`, `2026/12/05`, `2026.12.05`.
- Numeric with a four or two digit year: `12/25/2026`, `25/12/26`, with `/`, `-` or `.` as separators.
- With a month name, in either order, with or without spaces, ordinals and commas: `DEC 5, 2026`,
  `5DEC26`, `05 DEC 2026`, `Dec. 5th, 2026`.
- A month and a four digit year: `DEC 2026`, `12/2026`, `12.2026`, `12-2026`, and `12 2026` only when a
  date label comes right before it (`BEST BY 12 2026`), because two numbers apart are too often
  something else. `BEST IF USED BY: BB 11.2027` reads as best by November 2027.

A two digit year is 20xx, and only years 2000 to 2099 are accepted. A date that is not a real calendar
date is rejected, and a rejected match claims its text, so part of it, such as `04/2026` inside
`31/04/2026`, is not read as another date. `DEC 26` is not read at all, because it could be a day or a
year. A month and year pattern is not read as the tail or the start of a longer part or reference
number, such as `SKU.12.2026` or `1.2027.3`. A month and a two digit year (`11/27`) is not read, because
it could be a day and a month.

## Ambiguous dates

A numeric date whose first two parts are both 12 or less and differ, such as `05/06/26`, is May 6 or
June 5. The parser returns an ambiguous reading that holds both dates and chooses neither. It resolves
when:

- an order hint says which, from the package or locale;
- one reading is impossible, such as `31/04/2026`, `13/06/26` or `04/31/2026`;
- both parts are equal, or the year comes first.

A draft holds an ambiguous reading as a pending choice, proposes no date, and does not block put-away.
Choosing an order records the date as the person's own, so later recognition cannot replace it. A date
the person enters or clears also settles the question.

## OCR digit errors

Inside a token shaped like a numeric date, or like a numeric month and four digit year, that has at
least one real digit, `O` is read as `0` and `I` or `L` as `1`, so `BB 1I.2027` reads as November 2027.
A word is never turned into digits.

## Choosing a date to propose

When text holds several dates, a use-by date is preferred, then best-by, sell-by, freeze-by, an
unlabeled date and a packed date. Among equal labels the earliest wins.

## Reading dates from photos

`PrintedDateRecognition` (domain) is the engine a photo flow will use. It takes the text recognized
in one or more photos of the same package, as `RecognizedLines`, and returns the plausible readings,
or the one to propose. It knows nothing about cameras or images, and it is tested on Linux.

- **Bounded input.** Recognized text is untrusted. `RecognizedLines` takes at most 256 lines per photo,
  drops a line longer than 200 bytes of UTF-8 whole rather than cutting it (a cut could turn a date
  into a different one), and stops at 16,384 bytes per photo. At most 8 photos are read per package.
  Digits must be ASCII digits; other digits are not read as a date.
- **One photo or several.** Each photo's lines are joined with line breaks, so a label on one line
  labels a date on the next, and parsed on its own, so a label in one photo never labels a date in
  another. Readings from all the photos are pooled and the preferred one is chosen as above, so a
  use-by date in one photo wins over a best-by date in another.
- **Plausible dates only.** A date more than two years before, or ten years after, the time the
  photos were taken is not read. Both readings of an ambiguous date must be plausible, or neither is
  offered. This is checked before choosing, so an implausible use-by date does not hide a plausible
  best-by date.
- **Proposals only.** The readings go to `PackageDraft.apply(_:)`, which proposes the preferred date
  as recognized, holds an ambiguous one as a pending choice, and never replaces a date the person
  confirmed or cleared.

`TextRecognizer` (app target, `App/Recognition/`) runs Vision's `VNRecognizeTextRequest` on one still
image the caller owns, a `CGImage` or a `CVPixelBuffer`, and returns its lines as `RecognizedLines`,
bounded as they are taken from Vision's results. It uses the accurate level, because dates are
often small or dot-matrix print that the fast level misses, with language correction off, because
it turns codes such as `5DEC26` into words. Vision runs on the device; the recognizer keeps no
reference to the image, the request or the results after it returns, and writes, logs and sends
nothing. It blocks while Vision works, so a caller runs it off the main thread. Lines come back in
the order Vision returns them.

**Used by batch intake.** Batch intake (`batch-intake.md`) runs the recognizer's request, from
`TextRecognizer.makeRequest()`, in one Vision pass with its barcode and feature print requests, and
reads each photo's dates with `PrintedDateRecognition` over its lines in reading order. How its
photos are kept and deleted is described there and in the privacy policy.

**Verified where.** Linux `swift test` covers the engine: the bounds and that each fails without its
guard, labels across lines and photos, the photo limit, plausibility and its edges, ambiguity, the
order hint and the draft rules. The app's hosted tests run the recognizer on the simulator against
text the test draws, through a `CGImage` and a pixel buffer, and check that the engine proposes the
date. Real packaging, photos from a device, lighting, curved labels, embossed or dot-matrix print
and Vision's behavior on a device are not verified.

## Owner decisions

1. **A month and year is the last day of that month**, and the reading is marked as month precision.
   The earlier reading, the first of the month, would flag food a month early. This holds for every
   way of printing one, by name or by number with a slash, dot, dash or space: `BB 11.2027` is
   proposed as best by November 30, 2027. No day is chosen any other way.
2. **EXP and EXPIRES are use-by dates**, treated as a deadline, and a sell-by or packed date is never
   one.
3. **The parser does not choose the order of an ambiguous date.** The caller supplies a hint only when
   the package or locale settles it safely; the parser never defaults to the device's locale.

## Known limitation: time zones far ahead of UTC

A printed date is stored at noon UTC so that the device's time zone does not move its day. That holds
from UTC-11 to UTC+11. In a zone further ahead, such as New Zealand in summer, Tonga or Kiribati's Line
Islands, noon UTC is already the next morning, and the attention policy, which counts days in the
device's calendar, reads the date a day late. Dates the person enters by hand have the same limit.
Reading printed dates as calendar days, apart from any time zone, would remove it.

## Not built

GS1 2D barcode dates, a date printed after its label, and Julian or lot-code dates.
