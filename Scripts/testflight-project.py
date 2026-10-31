#!/usr/bin/env python3
"""Moves the generated Xcode project from the job that runs XcodeGen to the signing job, and checks it.

Usage: testflight-project.py check PROJECT
       testflight-project.py pack PROJECT
       testflight-project.py unpack PROJECT

XcodeGen comes from Homebrew unpinned, so .github/workflows/testflight.yml runs it in a job that has no
secrets. That job packs the project into a job output with pack, which writes `project` (base64 of a
gzip tar) and `project_sha256` to GITHUB_OUTPUT. The signing job unpacks it with unpack, which reads
PROJECT_ARCHIVE and PROJECT_SHA256 from the environment, refuses anything but regular files and
directories under PROJECT, and then runs the check.

The check fails on the project constructs that run commands during a build: shell script build phases,
build rules, external build system targets, scheme pre- and post-actions, build settings that replace
the compiler, linker or Swift driver, and compiler plugin flags. project.yml uses none of them. The
check reduces what a tampered project could do in the signing job; it does not prove the project is the
one XcodeGen would generate from project.yml.
"""
import argparse
import base64
import binascii
import gzip
import hashlib
import io
import os
import pathlib
import re
import sys
import tarfile

MAX_ARCHIVE_BYTES = 900_000
MAX_UNPACKED_BYTES = 20_000_000

PBXPROJ_FORBIDDEN = {
    "PBXShellScriptBuildPhase": "a shell script build phase",
    "PBXBuildRule": "a build rule",
    "PBXLegacyTarget": "an external build system target",
}
SCHEME_FORBIDDEN = {
    "ShellScriptAction": "a scheme script action",
    "<PreActions": "scheme pre-actions",
    "<PostActions": "scheme post-actions",
}
TOOL_SETTING = re.compile(
    r'^\s*"?(CC|CPLUSPLUS|LD|LDPLUSPLUS|LIBTOOL|SWIFT_EXEC|SWIFT_EXEC_MANIFEST|[A-Z0-9_]*_EXEC|CLANG_[A-Z0-9_]*_PATH)'
    r'(\[[^\]]*\])?"?\s*=', re.M)
PLUGIN_FLAGS = ("-load-plugin", "-plugin-path", "-fpass-plugin", "-Xclang -load", "-external-plugin-path")


class Failure(Exception):
    pass


def check(project):
    """Returns the problems found in a generated project directory."""
    project = pathlib.Path(project)
    if not (project / "project.pbxproj").is_file():
        return [f"{project} has no project.pbxproj"]
    problems = []
    for path in sorted(project.rglob("*")):
        relative = path.relative_to(project)
        if path.is_symlink():
            problems.append(f"{relative} is a symbolic link")
            continue
        if path.suffix == ".xcconfig" or "xcuserdata" in relative.parts:
            problems.append(f"{relative} is not part of a generated project")
            continue
        if not path.is_file():
            continue
        text = path.read_text(errors="replace")
        if path.name == "project.pbxproj":
            for marker, what in PBXPROJ_FORBIDDEN.items():
                if marker in text:
                    problems.append(f"{relative} has {what}")
            for match in TOOL_SETTING.finditer(text):
                problems.append(f"{relative} replaces a build tool with {match.group(1)}")
        if path.suffix == ".xcscheme":
            for marker, what in SCHEME_FORBIDDEN.items():
                if marker in text:
                    problems.append(f"{relative} has {what}")
        for flag in PLUGIN_FLAGS:
            if flag in text:
                problems.append(f"{relative} passes the compiler plugin flag {flag}")
    return problems


def pack(project):
    """Returns (base64 text, sha256) of a reproducible gzip tar of the project directory."""
    project = pathlib.Path(project)
    if not project.is_dir():
        raise Failure(f"{project} is not a directory")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for path in [project] + sorted(project.rglob("*")):
            if path.is_symlink():
                raise Failure(f"{path} is a symbolic link")
            info = tarfile.TarInfo(str(pathlib.Path(project.name) / path.relative_to(project)))
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if path.is_dir():
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                archive.addfile(info)
            else:
                data = path.read_bytes()
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
    compressed = gzip.compress(buffer.getvalue(), mtime=0)
    if len(compressed) > MAX_ARCHIVE_BYTES:
        raise Failure(f"the packed project is {len(compressed)} bytes, more than a job output holds")
    return base64.b64encode(compressed).decode(), hashlib.sha256(compressed).hexdigest()


def unpack(project, encoded, digest):
    """Writes the archive's files under PROJECT, which must not exist, and returns the paths written."""
    project = pathlib.Path(project)
    if project.exists():
        raise Failure(f"{project} already exists")
    try:
        compressed = base64.b64decode(encoded or "", validate=True)
    except (binascii.Error, ValueError):
        raise Failure("the packed project is not base64") from None
    if not compressed or hashlib.sha256(compressed).hexdigest() != (digest or "").strip():
        raise Failure("the packed project does not match its SHA-256")
    written = []
    total = 0
    with tarfile.open(fileobj=io.BytesIO(gzip.decompress(compressed)), mode="r:") as archive:
        for member in archive.getmembers():
            parts = pathlib.PurePosixPath(member.name).parts
            if (not parts or parts[0] != project.name or ".." in parts or member.name.startswith("/")
                    or not (member.isfile() or member.isdir())):
                raise Failure(f"the packed project holds an entry outside {project.name}: {member.name!r}")
            target = project.parent.joinpath(*parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            total += member.size
            if total > MAX_UNPACKED_BYTES:
                raise Failure("the packed project is larger than a generated project can be")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.extractfile(member).read())
            written.append(target)
    return written


def _write_outputs(values):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        raise Failure("GITHUB_OUTPUT is not set")
    with open(path, "a") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["check", "pack", "unpack"])
    parser.add_argument("project")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "pack":
            problems = check(arguments.project)
            if not problems:
                encoded, digest = pack(arguments.project)
                _write_outputs({"project": encoded, "project_sha256": digest})
                print(f"Packed {arguments.project}: {len(encoded)} characters, SHA-256 {digest}")
        elif arguments.command == "unpack":
            written = unpack(arguments.project, os.environ.get("PROJECT_ARCHIVE"), os.environ.get("PROJECT_SHA256"))
            print(f"Unpacked {len(written)} files into {arguments.project}")
            problems = check(arguments.project)
        else:
            problems = check(arguments.project)
    except (Failure, OSError, tarfile.TarError, EOFError, gzip.BadGzipFile) as error:
        problems = [str(error)]
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if not problems and arguments.command == "check":
        print(f"{arguments.project}: runs no scripts or replacement build tools")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
