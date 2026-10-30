#!/usr/bin/env python3
"""Tests for Scripts/normalize-foodkeeper.py against small synthetic sources."""
import hashlib
import importlib.util
import json
import pathlib
import random
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "normalize-foodkeeper.py"
spec = importlib.util.spec_from_file_location("normalize_foodkeeper", SCRIPT)
nf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nf)

PRODUCT_FIELDS = [
    "ID", "Category_ID", "Name", "Name_subtitle", "Keywords",
    "Pantry_Min", "Pantry_Max", "Pantry_Metric",
    "DOP_Pantry_Min", "DOP_Pantry_Max", "DOP_Pantry_Metric",
    "Pantry_After_Opening_Min", "Pantry_After_Opening_Max", "Pantry_After_Opening_Metric",
    "Refrigerate_Min", "Refrigerate_Max", "Refrigerate_Metric",
    "DOP_Refrigerate_Min", "DOP_Refrigerate_Max", "DOP_Refrigerate_Metric",
    "Refrigerate_After_Opening_Min", "Refrigerate_After_Opening_Max", "Refrigerate_After_Opening_Metric",
    "Refrigerate_After_Thawing_Min", "Refrigerate_After_Thawing_Max", "Refrigerate_After_Thawing_Metric",
    "Freeze_Min", "Freeze_Max", "Freeze_Metric",
    "DOP_Freeze_Min", "DOP_Freeze_Max", "DOP_Freeze_Metric",
]


def product(**values):
    values.setdefault("ID", "1.0")
    values.setdefault("Category_ID", "1.0")
    values.setdefault("Name", "Thing")
    row = {field: values.get(field) for field in PRODUCT_FIELDS}
    return [{k: v} for k, v in row.items()]


def source(products, versions=None, categories=None):
    versions = versions if versions is not None else [
        {"Data_Version_Number": "127.0", "Current_Version": None, "Modified_Date": "12-06-2017"},
        {"Data_Version_Number": "128.0", "Current_Version": "Yes", "Modified_Date": "09-06-2018"},
    ]
    categories = categories if categories is not None else [
        {"ID": "1.0", "Category_Name": "Dairy", "Subcategory_Name": None}
    ]
    def sheet(name, rows):
        return {"name": name, "data": [[{k: v} for k, v in r.items()] for r in rows]}
    return {
        "fileName": "foodkeeper.json",
        "sheets": [
            sheet("Version", versions),
            sheet("Category", categories),
            {"name": "Product", "data": products},
        ],
    }


def convert(products, **kwargs):
    raw = json.dumps(source(products, **kwargs)).encode()
    return nf.normalize(raw)


def windows(products):
    return convert(products)["records"][0]["windows"]


def window(storage, anchor, days):
    return {"storageType": storage, "anchor": anchor, "days": days}


class UnitTests(unittest.TestCase):
    def test_days_weeks_months_years(self):
        for metric, count, days in [("Days", "3.0", 3), ("Weeks", "2.0", 14), ("Months", "1.0", 30),
                                    ("Years", "2.0", 730), ("Year", "1.0", 365)]:
            with self.subTest(metric=metric):
                got = windows([product(Refrigerate_Min=count, Refrigerate_Max=count, Refrigerate_Metric=metric)])
                self.assertEqual(got, [window("refrigerated", "added", days)])

    def test_the_minimum_is_used_not_the_maximum(self):
        got = windows([product(DOP_Refrigerate_Min="3.0", DOP_Refrigerate_Max="5.0", DOP_Refrigerate_Metric="Weeks")])
        self.assertEqual(got, [window("refrigerated", "added", 21)])

    def test_units_without_a_day_count_are_skipped(self):
        for metric in ["Hours", "Indefinitely", "When Ripe", "Not Recommended", "Package use-by date", "Fortnights", None]:
            with self.subTest(metric=metric):
                got = windows([product(Pantry_Min="5.0", Pantry_Max="5.0", Pantry_Metric=metric)])
                self.assertEqual(got, [])

    def test_text_where_a_number_belongs_is_skipped(self):
        for text in ["Depending on conditions.", "Or until best-by date.", "", "  "]:
            with self.subTest(text=text):
                got = windows([product(Pantry_Min=text, Pantry_Max="3.0", Pantry_Metric="Days")])
                self.assertEqual(got, [])

    def test_a_missing_minimum_is_skipped_even_with_a_maximum(self):
        got = windows([product(Pantry_Max="3.0", Pantry_Metric="Days")])
        self.assertEqual(got, [])

    def test_zero_negative_and_boolean_counts_are_skipped(self):
        for count in ["0.0", "-2.0", True, 0]:
            with self.subTest(count=count):
                got = windows([product(Pantry_Min=count, Pantry_Metric="Days")])
                self.assertEqual(got, [])

    def test_a_fraction_of_a_day_is_skipped_instead_of_rounded_up(self):
        self.assertEqual(windows([product(Pantry_Min="0.5", Pantry_Metric="Days")]), [])

    def test_a_fractional_count_rounds_down(self):
        got = windows([product(Pantry_Min="1.5", Pantry_Metric="Weeks")])
        self.assertEqual(got, [window("roomTemperature", "added", 10)])

    def test_numbers_may_be_numbers_or_numeric_strings(self):
        got = windows([product(Pantry_Min=4, Pantry_Metric="Days")])
        self.assertEqual(got, [window("roomTemperature", "added", 4)])


class MappingTests(unittest.TestCase):
    def test_every_column_group_maps_to_a_storage_type_and_anchor(self):
        expected = {
            "Pantry": ("roomTemperature", "added"),
            "DOP_Pantry": ("roomTemperature", "added"),
            "Pantry_After_Opening": ("roomTemperature", "opened"),
            "Refrigerate": ("refrigerated", "added"),
            "DOP_Refrigerate": ("refrigerated", "added"),
            "Refrigerate_After_Opening": ("refrigerated", "opened"),
            "Refrigerate_After_Thawing": ("refrigerated", "thawed"),
            "Freeze": ("frozen", "added"),
            "DOP_Freeze": ("frozen", "added"),
        }
        for group, (storage, anchor) in expected.items():
            with self.subTest(group=group):
                got = windows([product(**{f"{group}_Min": "2.0", f"{group}_Metric": "Days"})])
                self.assertEqual(got, [window(storage, anchor, 2)])

    def test_the_purchase_and_plain_column_for_one_storage_keep_the_shorter(self):
        got = windows([product(
            DOP_Refrigerate_Min="2.0", DOP_Refrigerate_Metric="Weeks",
            Refrigerate_Min="3.0", Refrigerate_Metric="Days",
        )])
        self.assertEqual(got, [window("refrigerated", "added", 3)])

    def test_windows_are_ordered_the_same_way_every_time(self):
        got = windows([product(
            Freeze_Min="1.0", Freeze_Metric="Months", Pantry_Min="1.0", Pantry_Metric="Days",
            Refrigerate_After_Thawing_Min="1.0", Refrigerate_After_Thawing_Metric="Days",
            Refrigerate_Min="1.0", Refrigerate_Metric="Days",
        )])
        self.assertEqual(got, sorted(got, key=lambda w: (w["storageType"], w["anchor"])))


class RecordTests(unittest.TestCase):
    def test_a_record_with_no_usable_window_is_kept(self):
        data = convert([product(ID="27.0", Name="Milk", Name_subtitle="plain or flavored", Refrigerate_Metric="Package use-by date")])
        self.assertEqual([r["id"] for r in data["records"]], [27])
        self.assertEqual(data["records"][0]["windows"], [])

    def test_name_qualifier_category_and_keywords(self):
        data = convert([product(
            ID="116.0", Category_ID="1.0", Name=" Chicken parts ", Name_subtitle="breast halves, bone-in",
            Keywords="Chicken parts,breast halves,bone-in,chicken, chicken ,breast",
        )])
        record = data["records"][0]
        self.assertEqual(record["name"], "Chicken parts")
        self.assertEqual(record["qualifier"], "breast halves, bone-in")
        self.assertEqual(record["category"], "Dairy")
        self.assertEqual(record["keywords"], ["breast halves", "bone-in", "chicken", "breast"])

    def test_a_blank_qualifier_and_an_unknown_category_are_null(self):
        data = convert([product(Category_ID="99.0", Name_subtitle="  ")])
        record = data["records"][0]
        self.assertIsNone(record["qualifier"])
        self.assertIsNone(record["category"])

    def test_records_are_sorted_by_id_whatever_the_source_order(self):
        rows = [product(ID=f"{i}.0", Name=f"Food {i}") for i in (30, 4, 17, 2)]
        random.Random(1).shuffle(rows)
        self.assertEqual([r["id"] for r in convert(rows)["records"]], [2, 4, 17, 30])

    def test_a_duplicate_id_is_an_error(self):
        with self.assertRaises(nf.SourceError):
            convert([product(ID="1.0"), product(ID="1.0", Name="Other")])

    def test_a_product_without_a_name_is_an_error(self):
        with self.assertRaises(nf.SourceError):
            convert([product(Name="  ")])

    def test_a_source_without_a_product_sheet_is_an_error(self):
        with self.assertRaises(nf.SourceError):
            nf.normalize(json.dumps({"sheets": []}).encode())

    def test_input_that_is_not_json_is_an_error(self):
        with self.assertRaises(nf.SourceError):
            nf.normalize(b"not json")


class ProvenanceTests(unittest.TestCase):
    def test_the_current_version_and_its_date_are_recorded(self):
        provenance = convert([product()])["provenance"]
        self.assertEqual(provenance["source"], "USDA FSIS FoodKeeper")
        self.assertEqual(provenance["sourceVersion"], "128.0 (modified 2018-09-06)")
        self.assertEqual(provenance["normalizationVersion"], nf.NORMALIZATION_VERSION)

    def test_without_a_current_marker_the_highest_version_is_used(self):
        versions = [
            {"Data_Version_Number": "9.0", "Current_Version": None, "Modified_Date": "01-02-2010"},
            {"Data_Version_Number": "10.0", "Current_Version": None, "Modified_Date": "03-04-2011"},
        ]
        provenance = convert([product()], versions=versions)["provenance"]
        self.assertEqual(provenance["sourceVersion"], "10.0 (modified 2011-03-04)")

    def test_a_missing_or_malformed_version_is_unknown(self):
        self.assertIsNone(convert([product()], versions=[])["provenance"]["sourceVersion"])
        bad = [{"Data_Version_Number": "1.0", "Current_Version": "Yes", "Modified_Date": "someday"}]
        self.assertEqual(convert([product()], versions=bad)["provenance"]["sourceVersion"], "1.0")

    def test_the_checksum_is_the_sha256_of_the_source_bytes(self):
        raw = json.dumps(source([product()])).encode()
        self.assertEqual(nf.normalize(raw)["provenance"]["sourceChecksum"], hashlib.sha256(raw).hexdigest())


class OutputTests(unittest.TestCase):
    def test_the_same_source_gives_identical_bytes(self):
        raw = json.dumps(source([product(ID="2.0", Refrigerate_Min="1.0", Refrigerate_Metric="Days"), product(ID="1.0")])).encode()
        self.assertEqual(nf.render(nf.normalize(raw)), nf.render(nf.normalize(raw)))

    def test_every_day_count_is_a_positive_integer(self):
        data = convert([product(
            Pantry_Min="1.0", Pantry_Metric="Months", Freeze_Min="2.0", Freeze_Metric="Years",
            Refrigerate_Min="3.0", Refrigerate_Metric="Weeks",
        )])
        for w in data["records"][0]["windows"]:
            self.assertIsInstance(w["days"], int)
            self.assertGreater(w["days"], 0)

    def test_the_report_counts_what_was_skipped_and_why(self):
        raw = json.dumps(source([
            product(ID="1.0", Pantry_Min="1.0", Pantry_Metric="Days"),
            product(ID="2.0", Pantry_Metric="Not Recommended"),
            product(ID="3.0", Pantry_Min="Depending on conditions.", Pantry_Metric="Days"),
        ])).encode()
        report = nf.normalize(raw, with_report=True)[1]
        self.assertEqual(report["records"], 3)
        self.assertEqual(report["recordsWithWindows"], 1)
        self.assertEqual(report["skipped"], {"Not Recommended": 1, "text in the count": 1})


if __name__ == "__main__":
    unittest.main()
