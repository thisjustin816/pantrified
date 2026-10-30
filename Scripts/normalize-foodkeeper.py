#!/usr/bin/env python3
"""Normalizes the USDA FSIS FoodKeeper JSON into Pantrified's storage guidance snapshot.

Usage: normalize-foodkeeper.py SOURCE OUTPUT [--check]

With --check, OUTPUT is not written; the script fails when it differs from what SOURCE produces.

Rules, each chosen so guidance errs toward the shorter window and never invents one:
  - Only the minimum of a range is used. A window needs a numeric minimum in a unit with a day count.
  - Days count 1, weeks 7, months 30 and years 365 days. A fraction rounds down, and less than a day
    is skipped.
  - Units without a day count (Hours, Indefinitely, When Ripe, Not Recommended, Package use-by date)
    and cells holding text where a number belongs produce no window.
  - Columns with a purchase-date prefix and the plain columns for the same storage both start at
    "added"; when both give a window the shorter wins.
  - Every product is kept, including those with no window, so a name shared by several products
    stays ambiguous and is never narrowed by dropping the ones with nothing to say.
"""
import argparse
import hashlib
import json
import pathlib
import sys
from collections import Counter

NORMALIZATION_VERSION = "1"
SOURCE_NAME = "USDA FSIS FoodKeeper"

DAYS_PER_UNIT = {"Days": 1, "Weeks": 7, "Months": 30, "Years": 365, "Year": 365}

# (column prefix, storage type, anchor)
GROUPS = [
    ("Pantry", "roomTemperature", "added"),
    ("DOP_Pantry", "roomTemperature", "added"),
    ("Pantry_After_Opening", "roomTemperature", "opened"),
    ("Refrigerate", "refrigerated", "added"),
    ("DOP_Refrigerate", "refrigerated", "added"),
    ("Refrigerate_After_Opening", "refrigerated", "opened"),
    ("Refrigerate_After_Thawing", "refrigerated", "thawed"),
    ("Freeze", "frozen", "added"),
    ("DOP_Freeze", "frozen", "added"),
]


class SourceError(Exception):
    """The source is not a FoodKeeper file this script understands."""


def _rows(sheet):
    return [{key: value for cell in row for key, value in cell.items()} for row in sheet.get("data", [])]


def _text(value):
    if value is None:
        return None
    stripped = str(value).strip()
    return stripped or None


def _count(value):
    """Returns (number, reason). The reason names why there is no usable number."""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None, "no count"
    if isinstance(value, bool):
        return None, "count not positive"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None, "text in the count"
    if number != number or number <= 0:
        return None, "count not positive"
    return number, None


def _window_days(group, product):
    """Returns (days, reason); reason is None when there is a window or nothing was stated."""
    metric = _text(product.get(group + "_Metric"))
    raw_min = product.get(group + "_Min")
    stated = metric is not None or _text(raw_min) is not None
    if not stated:
        return None, None
    if metric is None:
        return None, "no unit"
    if metric not in DAYS_PER_UNIT:
        return None, metric
    number, reason = _count(raw_min)
    if number is None:
        return None, reason if reason != "no count" else "no minimum"
    days = int(number * DAYS_PER_UNIT[metric])
    if days < 1:
        return None, "less than a day"
    return days, None


def _windows(product, skipped):
    best = {}
    for group, storage, anchor in GROUPS:
        days, reason = _window_days(group, product)
        if reason:
            skipped[reason] += 1
        if days is not None:
            key = (storage, anchor)
            best[key] = min(days, best.get(key, days))
    return [
        {"storageType": storage, "anchor": anchor, "days": days}
        for (storage, anchor), days in sorted(best.items())
    ]


def _keywords(product, name):
    seen = {name.lower()}
    keywords = []
    for part in (product.get("Keywords") or "").split(","):
        keyword = part.strip()
        if keyword and keyword.lower() not in seen:
            seen.add(keyword.lower())
            keywords.append(keyword)
    return keywords


def _source_version(version_rows):
    if not version_rows:
        return None
    current = [r for r in version_rows if str(r.get("Current_Version") or "").strip().lower() == "yes"]

    def number(row):
        try:
            return float(row.get("Data_Version_Number"))
        except (TypeError, ValueError):
            return float("-inf")

    row = current[0] if current else max(version_rows, key=number)
    label = _text(row.get("Data_Version_Number"))
    if label is None:
        return None
    modified = _text(row.get("Modified_Date"))
    parts = modified.split("-") if modified else []
    if len(parts) == 3 and all(p.isdigit() for p in parts) and len(parts[2]) == 4:
        return f"{label} (modified {parts[2]}-{int(parts[0]):02d}-{int(parts[1]):02d})"
    return label


def normalize(raw, with_report=False):
    """Converts the bytes of a FoodKeeper JSON file to the snapshot, and optionally a report."""
    try:
        source = json.loads(raw)
        sheets = {sheet["name"]: sheet for sheet in source["sheets"]}
    except (ValueError, KeyError, TypeError) as error:
        raise SourceError(f"not a FoodKeeper file: {error}") from error
    if "Product" not in sheets:
        raise SourceError("the file has no Product sheet")

    categories = {}
    for row in _rows(sheets.get("Category", {})):
        try:
            categories[int(float(row["ID"]))] = _text(row.get("Category_Name"))
        except (KeyError, TypeError, ValueError):
            continue

    skipped = Counter()
    records = []
    seen = set()
    for product in _rows(sheets["Product"]):
        try:
            record_id = int(float(product["ID"]))
        except (KeyError, TypeError, ValueError) as error:
            raise SourceError(f"a product has no usable ID: {product.get('Name')!r}") from error
        if record_id in seen:
            raise SourceError(f"duplicate product ID {record_id}")
        seen.add(record_id)
        name = _text(product.get("Name"))
        if name is None:
            raise SourceError(f"product {record_id} has no name")
        try:
            category = categories.get(int(float(product.get("Category_ID"))))
        except (TypeError, ValueError):
            category = None
        records.append({
            "id": record_id,
            "name": name,
            "qualifier": _text(product.get("Name_subtitle")),
            "category": category,
            "keywords": _keywords(product, name),
            "windows": _windows(product, skipped),
        })
    records.sort(key=lambda record: record["id"])

    data = {
        "provenance": {
            "source": SOURCE_NAME,
            "sourceVersion": _source_version(_rows(sheets.get("Version", {}))),
            "sourceChecksum": hashlib.sha256(raw).hexdigest(),
            "normalizationVersion": NORMALIZATION_VERSION,
        },
        "records": records,
    }
    if not with_report:
        return data
    report = {
        "records": len(records),
        "recordsWithWindows": sum(1 for record in records if record["windows"]),
        "windows": sum(len(record["windows"]) for record in records),
        "skipped": dict(skipped),
    }
    return data, report


def render(data):
    return json.dumps(data, sort_keys=True, indent=1, ensure_ascii=False) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--check", action="store_true", help="fail if OUTPUT differs instead of writing it")
    args = parser.parse_args(argv)

    try:
        data, report = normalize(args.source.read_bytes(), with_report=True)
    except (OSError, SourceError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    text = render(data)

    if args.check:
        current = args.output.read_text(encoding="utf-8") if args.output.exists() else None
        if current != text:
            print(f"error: {args.output} does not match what {args.source} produces; run without --check", file=sys.stderr)
            return 1
        return 0

    args.output.write_text(text, encoding="utf-8")
    print(
        f"{report['records']} records, {report['recordsWithWindows']} with at least one window, "
        f"{report['windows']} windows; skipped {report['skipped']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
