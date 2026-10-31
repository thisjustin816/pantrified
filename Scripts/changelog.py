"""The change list the TestFlight scripts write: one line per change on main, from git history.
Standard library only."""

import re
import subprocess

# Apple's limit for What to Test.
MAX_NOTES = 4000


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def nearest_tag(revision, pattern, exclude=None):
    """The nearest tag matching `pattern`, and not `exclude`, at or before `revision`, or None when
    there's none."""
    excluding = ["--exclude", exclude] if exclude else []
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", pattern, *excluding, revision).strip()
    except subprocess.CalledProcessError:
        return None


def change_titles(revisions):
    """One line per first-parent commit, newest first. A merged pull request is listed by its
    title, which GitHub puts in the merge commit's body."""
    log = git("log", "--first-parent", "--format=%s%x1f%b%x1e", *revisions)
    titles = []
    for entry in filter(None, (e.strip("\n") for e in log.split("\x1e"))):
        subject, _, body = entry.partition("\x1f")
        merge = re.match(r"Merge pull request #(\d+) ", subject)
        if merge:
            title = next((line.strip() for line in body.splitlines() if line.strip()), subject)
            titles.append(f"{title} (#{merge.group(1)})")
        else:
            titles.append(subject)
    return titles


def fit(header, titles, limit=MAX_NOTES):
    lines = [header]
    for index, title in enumerate(titles):
        more = f"- ...and {len(titles) - index} more"
        if len("\n".join(lines + [f"- {title}", more])) > limit:
            lines.append(more)
            break
        lines.append(f"- {title}")
    return "\n".join(lines)
