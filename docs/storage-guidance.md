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

- A food matches the record the person chose for it. Without a choice, it matches when its normalized
  name equals one record's normalized name. The matcher also accepts links the person confirmed from a
  name to a record, but nothing stores those; a choice belongs to one package (below).
- A name that several records share is ambiguous: 103 names are shared by 298 records, among them
  "ham" (20), "lamb" and "pork" (12 each), "cheese", "cream" and "milk". An ambiguous food gets no
  guidance until the person chooses a record.
- The source's keywords never decide a match. They are loose search terms, often fragments of a longer
  description, and a match on one would give the wrong food's window. They and a partial overlap of
  words only suggest candidates for the person to choose from.
- A matched record with no window gives no guidance, and the attention engine then uses printed dates
  and package instructions alone.

## Choosing a record

A food's detail screen says which FoodKeeper food its guidance comes from, and lets the person choose.

- **When it asks.** A food whose name several records share, or whose name matches none but shares
  words with some, gets a "Which FoodKeeper food is this?" row. A food whose name matches one record
  shows that record with a Change button, since the name can be right and the record still wrong. A
  food that shares no word with any record shows nothing.
- **Candidates.** `GuidanceMatcher.candidates(for:)` is deterministic. Every record whose normalized
  name is the food's own comes first, by identifier, and is never cut, since any of them could be the
  right one; ham's 20 is the most. Then come records whose name shares words with the food's, most
  shared words first, then fewest words the two do not share, then by identifier; then records that
  share words only through their keywords. These suggestions stop at 8. Suggestions ignore case,
  accents, letter width, invisible characters and joining words such as "and", "or" and "with". Only
  the first 256 Unicode scalars and then the first 12 distinct words of a name are read, so a very long
  or hostile name costs no more than a short one. Every candidate is a record of the snapshot.
- **The picker** lists each candidate by name and qualifier, such as "Milk, lactose-free", with its
  category, marks the one in use, and adds "None of these". Once the person has chosen, it also offers
  "Clear my choice", which matches the food by its name again. Its footer, like the guidance section's,
  says the times are from FoodKeeper and are guidance, not an expiration date.
- **What is stored.** A choice is the person's correction of the package field `guidanceRecord`, an
  ordinary `corrected` event (`sync-design.md`). It names the source, the record's identifier, its name
  and its qualifier, or says none of these, or, to clear, holds nothing. It is written, undone and
  synchronized like a name correction: one history entry with one undo, kept across launches in the
  package's records. Recognition never proposes a record, and a proposed value would not count: only
  the person's correction decides.
- **Renaming.** The choice stays when the food is renamed, because it names the record for this
  package whatever the package is called.
- **A record a later snapshot lacks.** A choice applies only when the snapshot holds a record with the
  same source, identifier, name and qualifier. Otherwise the food gets no guidance, without falling
  back to its name, which could give the record the person turned down. The detail screen asks again
  and says the earlier choice is not in this version of the guidance. A later snapshot that only
  corrects a record's spelling therefore asks again too.
- **Older versions.** A version from before this choice skips the correction, as it skips any
  correction of a field it does not know, and matches the food by its name. For an ambiguous name it
  shows no guidance, as it did before the choice. For a name that matches one record, where the person
  chose another record or None of these, it shows that one record's guidance.

## Limits

- The data is 2018's. A newer USDA file replaces it through the converter and a release.
- A choice belongs to one package. A new package with an ambiguous name asks again; nothing carries
  a choice to later packages of the same name.
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

Defaults chosen with the record choice, each changeable:

4. **A choice beats an exact name match.** A food whose name matches one record can be changed to
   another record or to None of these, and the choice wins until it is cleared.
5. **A chosen record that a newer snapshot lacks gives no guidance** until the person chooses again,
   instead of falling back to the name.
6. **A choice is per package.** Remembering it for later packages of the same name is open.
