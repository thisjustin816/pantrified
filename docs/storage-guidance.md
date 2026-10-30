# Storage guidance

Use-soon guidance for food without a printed date comes from a bundled snapshot of the USDA
FoodKeeper. The snapshot is data the app ships with; it changes only in a release.

## Source and snapshot

- **Source file:** `Data/FoodKeeper/foodkeeper.json`, the USDA FSIS FoodKeeper data. The dataset's
  catalog page (data.gov) states a CC0 1.0 license. The file's own version history ends at version
  128.0, modified 2018-09-06, and the snapshot records that version, not the catalog page's date.
  SHA-256: `037df0d301126acd8a48824506f04d49d8be1a1144b81fa69e4170228dc2e91a`.
- **Snapshot:** `Sources/PantrifiedGuidanceData/Resources/foodkeeper.normalized.json`, written by
  `Scripts/normalize-foodkeeper.py`. CI regenerates it from the source and fails on any difference, and
  runs the converter's tests. The snapshot names its source, the source version, the source checksum and
  its normalization version, and a window reported by the attention engine carries the first and last
  of these.
- **Contents:** 661 products, 646 with at least one window, 1,213 windows. Every product is kept, including
  the 15 with no window, because dropping one would make a shared name look unambiguous.

## Conversion rules

Each rule errs toward the shorter window and never supplies one the source lacks.

- Only the minimum of a range is used.
- A day counts 1, a week 7, a month 30 and a year 365 days. A fractional count rounds down, and less
  than a day produces no window.
- A window needs a numeric minimum and a unit with a day count. These produce no window, with the
  number of storage columns affected: Hours (5), Indefinitely (13), When Ripe (12), Not Recommended
  (66), Package use-by date (36), a unit with no count or a count with no unit (4), and text where a
  number belongs.
- The columns for purchased food and the plain columns for the same storage both start at "added".
  When both give a window, the shorter wins.
- A window after opening starts at "opened", and one after thawing at "thawed".
- The source's subtitle is kept as the record's qualifier, such as "plain or flavored", so records that
  share a name can be told apart.

## Matching

`GuidanceMatcher` is deterministic and uses no model.

- A food matches when its normalized name equals one record's normalized name, or when the person has
  confirmed a link to a record.
- A name that several records share is ambiguous: 103 names are shared by 298 records, among them
  "ham" (20), "lamb" and "pork" (12 each), "cheese", "cream" and "milk". An ambiguous food gets no
  guidance until the person chooses a record.
- The source's keywords never decide a match. They are loose search terms, often fragments of a longer
  description, and a match on one would give the wrong food's window. They and a partial overlap of
  words only suggest candidates, names first and then by identifier, at most ten.
- A matched record with no window gives no guidance, and the attention engine then uses printed dates
  and package instructions alone.

## Limits

- The data is 2018's. A newer USDA file replaces it through the converter and a release.
- Confirmed links are accepted by the matcher, but nothing stores them yet, so an ambiguous food stays
  without guidance in the app.
- The source does not say, window by window, whether a time is about safety or quality; some of its
  tips speak of quality and others of safety. A window is guidance, not an expiration date.

## Owner decisions

1. **The shorter end of a range is used**, with 30-day months, so food is surfaced earlier rather than later.
2. **Freezer windows are included as the source gives them.** A package frozen longer than its window is
   reported as past guidance, although frozen food is generally safe to eat after that time. Whether to
   surface freezer windows at all is open.
3. **An ambiguous name gets no guidance until the person confirms a record**, instead of using the
   shortest of the candidates, which would flag a carton of eggs after two days because of the raw egg
   whites record.
