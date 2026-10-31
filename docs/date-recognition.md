# Printed date recognition

`PrintedDateParser` reads printed dates and their labels out of recognized text, such as the output
of OCR. It is pure Swift and takes text, so it is tested without a camera. Recognition only proposes:
the result is a reading, and a draft applies it as a proposal that the person can correct.

## Labels

A date takes the label whose phrase ends directly before it, with only spaces, colons, dots or dashes
between. A date with no such label is unlabeled.

| Printed | Label |
|---|---|
| BEST BY, BEST BEFORE, BEST IF USED BY, BEST IF USED BEFORE, BB | best by |
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
- A month and a four digit year: `DEC 2026`, `12/2026`.

A two digit year is 20xx, and only years 2000 to 2099 are accepted. A date that is not a real calendar
date is rejected, and a rejected match claims its text, so part of it, such as `04/2026` inside
`31/04/2026`, is not read as another date. `DEC 26` is not read at all, because it could be a day or a
year. A month and year pattern is not read as the tail of a longer part or reference number.

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

Inside a token shaped like a numeric date that has at least one real digit, `O` is read as `0` and `I`
or `L` as `1`. A word is never turned into digits.

## Choosing a date to propose

When text holds several dates, a use-by date is preferred, then best-by, sell-by, freeze-by, an
unlabeled date and a packed date. Among equal labels the earliest wins.

## Owner decisions

1. **A month and year is the last day of that month**, and the reading is marked as month precision.
   The earlier reading, the first of the month, would flag food a month early.
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
