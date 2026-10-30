#!/usr/bin/env python3
"""Checks the app's privacy manifest and, optionally, that a built app carries it unchanged.

Usage: verify-privacy-manifest.py MANIFEST [APP_BUNDLE]

Lints the manifest's structure, then compares it with the PrivacyInfo.xcprivacy at the root of the
built .app, which Xcode may have converted to a binary property list. A valid source file alone does
not show that the manifest ships.
"""
import argparse
import pathlib
import plistlib
import sys

REQUIRED = {
    "NSPrivacyTracking": bool,
    "NSPrivacyTrackingDomains": list,
    "NSPrivacyCollectedDataTypes": list,
    "NSPrivacyAccessedAPITypes": list,
}
COLLECTED_FIELDS = {
    "NSPrivacyCollectedDataType": str,
    "NSPrivacyCollectedDataTypeLinked": bool,
    "NSPrivacyCollectedDataTypeTracking": bool,
    "NSPrivacyCollectedDataTypePurposes": list,
}


def _load(path):
    return plistlib.loads(pathlib.Path(path).read_bytes())


def lint(manifest):
    errors = []
    for key, kind in REQUIRED.items():
        if key not in manifest:
            errors.append(f"{key} is missing")
        elif not isinstance(manifest[key], kind):
            errors.append(f"{key} must be a {kind.__name__}")
    if errors:
        return errors

    domains = manifest["NSPrivacyTrackingDomains"]
    if manifest["NSPrivacyTracking"] and not domains:
        errors.append("NSPrivacyTracking is true but NSPrivacyTrackingDomains is empty")
    if domains and not manifest["NSPrivacyTracking"]:
        errors.append("NSPrivacyTrackingDomains is not empty but NSPrivacyTracking is false")
    if not all(isinstance(domain, str) and domain for domain in domains):
        errors.append("NSPrivacyTrackingDomains must hold domain names")

    for index, entry in enumerate(manifest["NSPrivacyCollectedDataTypes"]):
        if not isinstance(entry, dict):
            errors.append(f"collected data type {index} must be a dictionary")
            continue
        for field, kind in COLLECTED_FIELDS.items():
            if field not in entry:
                errors.append(f"collected data type {index} is missing {field}")
            elif not isinstance(entry[field], kind):
                errors.append(f"collected data type {index}: {field} must be a {kind.__name__}")
        if isinstance(entry.get("NSPrivacyCollectedDataTypePurposes"), list) and not entry["NSPrivacyCollectedDataTypePurposes"]:
            errors.append(f"collected data type {index} lists no purpose")

    for index, entry in enumerate(manifest["NSPrivacyAccessedAPITypes"]):
        if not isinstance(entry, dict) or not entry.get("NSPrivacyAccessedAPIType"):
            errors.append(f"accessed API type {index} has no NSPrivacyAccessedAPIType")
        elif not entry.get("NSPrivacyAccessedAPITypeReasons"):
            errors.append(f"accessed API type {index} ({entry['NSPrivacyAccessedAPIType']}) lists no reason")
    return errors


def check(source, bundle):
    try:
        manifest = _load(source)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return [f"cannot read the manifest {source}: {error}"]
    errors = lint(manifest)

    if bundle is not None:
        shipped = pathlib.Path(bundle) / "PrivacyInfo.xcprivacy"
        if not pathlib.Path(bundle).is_dir():
            errors.append(f"no such app bundle: {bundle}")
        elif not shipped.is_file():
            errors.append(f"{bundle} does not contain PrivacyInfo.xcprivacy")
        else:
            try:
                if _load(shipped) != manifest:
                    errors.append(f"the manifest in {bundle} differs from {source}")
            except (OSError, plistlib.InvalidFileException, ValueError) as error:
                errors.append(f"cannot read the manifest in {bundle}: {error}")
    return errors


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("app", nargs="?", type=pathlib.Path)
    args = parser.parse_args(argv)
    errors = check(args.manifest, args.app)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
