#!/usr/bin/env python3
"""Checks the app icon in the asset catalog and, optionally, that a built app carries it.

Usage: verify-app-icon.py APPICONSET [APP_BUNDLE]

App Store Connect rejects an upload whose icon is not a 1024 by 1024 PNG without transparency, and a
catalog entry that names no file builds without an icon and fails only at upload. The source is
linted first. With an app bundle, the compiled catalog and the icon name in its Info.plist (at the
top level or as the primary icon in CFBundleIcons) are checked too, because a valid source does not show that the icon ships.
"""
import argparse
import json
import pathlib
import plistlib
import struct
import sys

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ALPHA_COLOR_TYPES = {4, 6}
ICON_SIZE = 1024


def _png_problems(data):
    if not data.startswith(PNG_SIGNATURE):
        return ["is not a PNG file"]
    problems = []
    position = len(PNG_SIGNATURE)
    header = None
    while position + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if kind == b"IHDR" and length >= 13:
            header = struct.unpack(">IIBBBBB", body[:13])
        elif kind == b"tRNS":
            problems.append("has a transparency chunk")
        position += 12 + length
    if header is None:
        return ["has no readable header"]
    width, height, _, color_type, *_ = header
    if (width, height) != (ICON_SIZE, ICON_SIZE):
        problems.append(f"is {width} by {height}, not {ICON_SIZE} by {ICON_SIZE}")
    if color_type in ALPHA_COLOR_TYPES:
        problems.append("has an alpha channel")
    return problems


def lint(iconset):
    iconset = pathlib.Path(iconset)
    try:
        contents = json.loads((iconset / "Contents.json").read_text())
    except (OSError, ValueError) as error:
        return [f"cannot read {iconset}/Contents.json: {error}"]
    images = contents.get("images") if isinstance(contents, dict) else None
    if not isinstance(images, list):
        return ["Contents.json has no images list"]
    named = [image for image in images if isinstance(image, dict) and image.get("filename")]
    if not named:
        return ["Contents.json names no icon file"]
    errors = []
    for image in named:
        name = image["filename"]
        path = iconset / name
        if not path.is_file():
            errors.append(f"{name} is named in Contents.json but missing")
            continue
        errors.extend(f"{name} {problem}" for problem in _png_problems(path.read_bytes()))
    return errors


def check(iconset, bundle):
    errors = lint(iconset)
    if bundle is None:
        return errors
    bundle = pathlib.Path(bundle)
    if not bundle.is_dir():
        return errors + [f"no such app bundle: {bundle}"]
    name = pathlib.Path(iconset).stem
    if not (bundle / "Assets.car").is_file():
        errors.append(f"{bundle} has no compiled asset catalog (Assets.car)")
    try:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return errors + [f"cannot read the Info.plist in {bundle}: {error}"]
    declared = _declared_icon_names(info)
    if name not in declared:
        found = {key: info[key] for key in sorted(info) if "Icon" in key}
        errors.append(f"Info.plist does not name the icon {name!r}; its icon keys are {found!r}")
    return errors


def _declared_icon_names(info):
    """The icon names an Info.plist declares: at the top level, or as the primary icon of CFBundleIcons."""
    names = set()
    if isinstance(info.get("CFBundleIconName"), str):
        names.add(info["CFBundleIconName"])
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icons = info.get(key)
        primary = icons.get("CFBundlePrimaryIcon") if isinstance(icons, dict) else None
        if isinstance(primary, dict) and isinstance(primary.get("CFBundleIconName"), str):
            names.add(primary["CFBundleIconName"])
    return names


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("iconset", type=pathlib.Path)
    parser.add_argument("app", nargs="?", type=pathlib.Path)
    args = parser.parse_args(argv)
    errors = check(args.iconset, args.app)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
