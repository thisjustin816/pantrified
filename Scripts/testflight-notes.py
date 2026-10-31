#!/usr/bin/env python3
"""TestFlight "What to Test" notes, written from the commits since the previous upload.

`notes` writes the notes for a commit and reports whether the app changed since the last
upload. `publish` sets them on the uploaded build through the App Store Connect API
(appstoreconnect.py).

Each main upload is tagged `testflight/<build>` (.github/workflows/testflight.yml), so the
nearest such tag is where the next build's notes start. Standard library only.
"""

import argparse
import os
import re
import sys
import time
import urllib.error

# Run with python3 -I, which leaves the script's own directory off the import path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from appstoreconnect import client_from_environment  # noqa: E402
from changelog import change_titles, fit, git, nearest_tag  # noqa: E402

TAG_PREFIX = "testflight/"
# Paths that never change the app, so a push touching only these needs no new build.
NON_APP = re.compile(r"^(docs/|\.github/|LICENSE$)|\.md$")


def previous_tag(sha):
    """The nearest upload tag at or before `sha`, or None before the first."""
    return nearest_tag(sha, f"{TAG_PREFIX}*")


def notes_command(args):
    short = git("rev-parse", "--short", args.sha).strip()
    if args.branch == "main":
        previous = previous_tag(args.sha)
        if previous:
            app_changed = any(
                not NON_APP.search(path)
                for path in git("diff", "--name-only", previous, args.sha).split()
            )
            titles = change_titles([f"{previous}..{args.sha}"])
            since = f"build {previous.removeprefix(TAG_PREFIX)}"
        else:
            app_changed = True
            titles = change_titles(["-20", args.sha])
            since = None
        header = f"main at {short}."
        if titles:
            header += f"\n\nChanges since {since}:" if since else "\n\nRecent changes:"
        else:
            header += f"\n\nNo changes since {since}." if since else ""
    else:
        app_changed = True
        titles = change_titles([f"origin/main..{args.sha}"])
        header = f"Branch {args.branch} at {short}, not yet on main."
        if titles:
            header += "\n\nChanges on the branch:"

    if args.variant == "evaluation":
        header = "Evaluation build: the Evaluation tab is compiled in. Internal testers only.\n\n" + header
    text = fit(header, titles)
    with open(args.output, "w", encoding="utf-8") as output:
        output.write(text + "\n")
    print(text)
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"app_changed={'true' if app_changed else 'false'}\n")


def publish_command(args):
    with open(args.notes, encoding="utf-8") as source:
        text = source.read().strip()
    with client_from_environment() as client:
        publish_build_notes(client, args, text)


def publish_build_notes(client, args, text):
    app_id = client.app_id()

    # The build appears some minutes after the upload, and may refuse notes while it processes.
    deadline = time.monotonic() + args.wait_minutes * 60
    while True:
        try:
            builds = client.request(
                "GET",
                f"/builds?filter[app]={app_id}&filter[version]={args.build}"
                f"&filter[preReleaseVersion.version]={args.version}&fields[builds]=version",
            )["data"]
            if builds:
                client.set_whats_new(builds[0]["id"], text)
                print(f"Set What to Test on {args.version} ({args.build}).")
                return
            reason = "the build has not appeared yet"
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise
            reason = f"App Store Connect answered {error.code}"
        if time.monotonic() > deadline:
            sys.exit(f"Gave up after {args.wait_minutes} minutes: {reason}.")
        print(f"Waiting: {reason}.")
        time.sleep(30)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(required=True)

    notes = commands.add_parser("notes", help="write the notes for a commit")
    notes.add_argument("--sha", required=True)
    notes.add_argument("--branch", required=True)
    notes.add_argument("--output", required=True)
    notes.add_argument("--variant", choices=["release", "evaluation"], default="release")
    notes.set_defaults(run=notes_command)

    publish = commands.add_parser("publish", help="set the notes on an uploaded build")
    publish.add_argument("--version", required=True, help="marketing version, such as 0.1")
    publish.add_argument("--build", required=True, help="build number, such as 57")
    publish.add_argument("--notes", required=True)
    publish.add_argument("--wait-minutes", type=int, default=25)
    publish.set_defaults(run=publish_command)

    args = parser.parse_args(argv)
    args.run(args)


if __name__ == "__main__":
    main()
