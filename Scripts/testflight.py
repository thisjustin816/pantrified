#!/usr/bin/env python3
"""Steps of the signed TestFlight build in .github/workflows/testflight.yml that need no Mac.

Usage: testflight.py COMMAND [ARGS]

  check                  fail unless the run is on main, the inputs are valid and every required
                         secret is set and well formed, naming each problem and never a value
  build-info             work out the variant, marketing version and build number, print them and
                         write them to GITHUB_OUTPUT
  prepare DIR            write the distribution certificate and private key into DIR, a new
                         directory, and install the provisioning profile
  xcconfig PATH          write the app target's manual signing settings to PATH, a new file
  export-options PATH    write the ExportOptions.plist for the variant
  verify-app APP --version V --build N [--entitlements FILE --codesign FILE]
                         check a built app's identifiers, versions, profile and, given the files
                         codesign printed, its signature
  write-api-key DIR      write the App Store Connect key into DIR/private_keys for altool
  cleanup DIR [--xcconfig PATH]
                         remove what prepare, write-api-key and xcconfig wrote
  record PATH            write the build record and the job summary

Secrets are read from environment variables named like the secrets. The identifiers and the secret
names are in Config/testflight.json and described in docs/testflight-upload.md. Nothing here prints a
secret: messages name the setting and the rule it breaks, and an unexpected error prints only its type.
"""
import argparse
import base64
import binascii
import datetime
import json
import os
import pathlib
import plistlib
import re
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "Config" / "testflight.json"
PROJECT_PATH = ROOT / "project.yml"

MAIN_REF = "refs/heads/main"
VARIANTS = {"release": "Release", "evaluation": "Evaluation"}
UPLOAD_VALUES = {"true", "false"}

CERTIFICATE = "APPLE_DISTRIBUTION_CERTIFICATE_BASE64"
SIGNING_KEY = "APPLE_DISTRIBUTION_PRIVATE_KEY"
PROFILE = "APPLE_PROVISIONING_PROFILE_BASE64"
API_KEY = "APP_STORE_CONNECT_PRIVATE_KEY"
API_KEY_ID = "APP_STORE_CONNECT_KEY_ID"
API_ISSUER_ID = "APP_STORE_CONNECT_ISSUER_ID"

# Built from parts so that this file does not hold the text the repository hygiene check rejects.
DASHES = "-" * 5
PEM_BEGIN = re.compile("^" + DASHES + r"BEGIN ([A-Z0-9 ]+)" + DASHES + r"\s*$", re.M)
PEM_END = re.compile("^" + DASHES + r"END ([A-Z0-9 ]+)" + DASHES + r"\s*$", re.M)
SIGNING_KEY_KINDS = {"PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"}
KEY_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")
ISSUER_ID_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
VERSION_PATTERN = re.compile(r"[0-9]+(\.[0-9]+){0,2}")
RUN_NUMBER_PATTERN = re.compile(r"[1-9][0-9]*")

PROFILE_DIRECTORIES = (
    pathlib.Path("Library/MobileDevice/Provisioning Profiles"),
    pathlib.Path("Library/Developer/Xcode/UserData/Provisioning Profiles"),
)
INSTALLED_PROFILES = "installed-profiles"
XCCONFIG_MARKER = "// Written by Scripts/testflight.py for a signed TestFlight build."
EXPIRY_WARNING_DAYS = 30


class Failure(Exception):
    """A failure whose message is safe to print: it names settings and rules, never secret values."""


def load_config(path=CONFIG_PATH):
    return json.loads(pathlib.Path(path).read_text())


def _secret(environ, name):
    value = environ.get(name, "")
    return value if value.strip() else None


def _decode_base64(value):
    return base64.b64decode("".join(value.split()), validate=True)


def _pem_problems(name, text, kinds):
    begins = PEM_BEGIN.findall(text)
    ends = PEM_END.findall(text)
    if begins == ["ENCRYPTED PRIVATE KEY"]:
        return [f"{name} is an encrypted key; store the key without a passphrase"]
    if len(begins) != 1 or begins[0] not in kinds:
        return [f"{name} is not the PEM text of one private key (expected a BEGIN line for "
                + " or ".join(sorted(kinds)) + ")"]
    if ends != begins:
        return [f"{name} has no matching END line"]
    return []


def parse_profile(data):
    """Returns the property list inside a provisioning profile's CMS envelope."""
    start = data.find(b"<?xml")
    end = data.find(b"</plist>")
    if start < 0 or end < start:
        raise Failure(f"{PROFILE} does not contain a provisioning profile property list")
    try:
        profile = plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception:
        raise Failure(f"{PROFILE} holds a property list that cannot be read") from None
    if not isinstance(profile, dict):
        raise Failure(f"{PROFILE} holds a property list that is not a dictionary")
    return profile


def profile_problems(profile, config, certificate=None, now=None):
    """Checks a decoded profile against Config/testflight.json and the distribution certificate."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    problems = []
    entitlements = profile.get("Entitlements") if isinstance(profile.get("Entitlements"), dict) else {}
    if str(profile.get("UUID", "")).lower() != config["profile_uuid"].lower():
        problems.append(f"{PROFILE} is not the profile whose UUID is in Config/testflight.json")
    if profile.get("Name") != config["profile_name"]:
        problems.append(f"{PROFILE} is not named {config['profile_name']!r}")
    if config["team_id"] not in (profile.get("TeamIdentifier") or []):
        problems.append(f"{PROFILE} is not for team {config['team_id']}")
    if entitlements.get("application-identifier") != f"{config['team_id']}.{config['bundle_id']}":
        problems.append(f"{PROFILE} is not for the bundle identifier {config['bundle_id']}")
    if "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices"):
        problems.append(f"{PROFILE} lists devices, so it is a development, ad hoc or enterprise profile, "
                        "not an App Store profile")
    if entitlements.get("get-task-allow") is not False:
        problems.append(f"{PROFILE} allows a debugger to attach (get-task-allow), which App Store builds must not")
    if entitlements.get("beta-reports-active") is not True:
        problems.append(f"{PROFILE} does not allow TestFlight (beta-reports-active)")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        problems.append(f"{PROFILE} has no expiration date")
    else:
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=datetime.timezone.utc)
        if expiry <= now:
            problems.append(f"{PROFILE} expired on {expiry:%Y-%m-%d}; renew the certificate and profile "
                            "(docs/testflight-upload.md)")
    if certificate is not None and certificate not in (profile.get("DeveloperCertificates") or []):
        problems.append(f"{PROFILE} does not include the certificate in {CERTIFICATE}")
    return problems


def profile_expiry_warning(profile, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        return None
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if now < expiry <= now + datetime.timedelta(days=EXPIRY_WARNING_DAYS):
        return f"the provisioning profile expires on {expiry:%Y-%m-%d}; renew it and the certificate"
    return None


def signing_material(environ, config, now=None):
    """Checks the certificate, signing key and profile secrets and returns (problems, decoded)."""
    problems = []
    decoded = {}
    for name in (CERTIFICATE, SIGNING_KEY, PROFILE):
        if _secret(environ, name) is None:
            problems.append(f"{name} is not set or is empty")
    if problems:
        return problems, decoded

    try:
        certificate = _decode_base64(environ[CERTIFICATE])
    except (binascii.Error, ValueError):
        problems.append(f"{CERTIFICATE} is not base64")
        certificate = None
    if certificate is not None:
        if certificate[:1] != b"\x30" or len(certificate) < 64:
            problems.append(f"{CERTIFICATE} does not decode to a DER certificate (the .cer file Apple issues)")
            certificate = None
        else:
            decoded["certificate"] = certificate

    problems += _pem_problems(SIGNING_KEY, environ[SIGNING_KEY], SIGNING_KEY_KINDS)

    try:
        profile_data = _decode_base64(environ[PROFILE])
    except (binascii.Error, ValueError):
        problems.append(f"{PROFILE} is not base64")
        profile_data = None
    if profile_data is not None:
        try:
            profile = parse_profile(profile_data)
        except Failure as failure:
            problems.append(str(failure))
        else:
            problems += profile_problems(profile, config, certificate, now)
            decoded["profile"] = profile
            decoded["profile_data"] = profile_data
    return problems, decoded


def api_key_problems(environ):
    problems = []
    for name in (API_KEY, API_KEY_ID, API_ISSUER_ID):
        if _secret(environ, name) is None:
            problems.append(f"{name} is not set or is empty")
    if problems:
        return problems
    problems += _pem_problems(API_KEY, environ[API_KEY], {"PRIVATE KEY"})
    if not KEY_ID_PATTERN.fullmatch(environ[API_KEY_ID].strip()):
        problems.append(f"{API_KEY_ID} is not a 10-character key ID of capital letters and digits")
    if not ISSUER_ID_PATTERN.fullmatch(environ[API_ISSUER_ID].strip()):
        problems.append(f"{API_ISSUER_ID} is not a UUID")
    return problems


def input_problems(environ):
    problems = []
    if environ.get("GITHUB_REF") != MAIN_REF:
        problems.append("TestFlight builds run only from main; dispatch the workflow on main")
    if environ.get("VARIANT") not in VARIANTS:
        problems.append("the variant input must be release or evaluation")
    if environ.get("UPLOAD") not in UPLOAD_VALUES:
        problems.append("the upload input must be true or false")
    return problems


def check(environ, config, now=None):
    """Returns every problem with the run's ref, inputs and secrets; an empty list means ready."""
    problems = input_problems(environ)
    missing = [name for name in config["required_secrets"] if _secret(environ, name) is None]
    problems += [f"{name} is not set or is empty" for name in missing]
    if not set(missing) & {CERTIFICATE, SIGNING_KEY, PROFILE}:
        problems += signing_material(environ, config, now)[0]
    if not set(missing) & {API_KEY, API_KEY_ID, API_ISSUER_ID}:
        problems += api_key_problems(environ)
    return problems


def marketing_version(project_text):
    values = re.findall(r'^\s*MARKETING_VERSION:\s*["\']?([^"\'\s#]+)["\']?\s*(?:#.*)?$', project_text, re.M)
    if len(values) != 1:
        raise Failure(f"project.yml must set MARKETING_VERSION exactly once (found {len(values)})")
    if not VERSION_PATTERN.fullmatch(values[0]):
        raise Failure(f"MARKETING_VERSION {values[0]!r} is not one to three numbers separated by periods")
    return values[0]


def build_number(run_number, run_attempt):
    """The run number and attempt, so a new run and a re-run each upload a build number not used before."""
    if not RUN_NUMBER_PATTERN.fullmatch(run_number or "") or not RUN_NUMBER_PATTERN.fullmatch(run_attempt or ""):
        raise Failure("GITHUB_RUN_NUMBER and GITHUB_RUN_ATTEMPT must be positive whole numbers")
    return f"{run_number}.{run_attempt}"


def build_info(environ, config, project_text):
    variant = environ.get("VARIANT")
    if variant not in VARIANTS:
        raise Failure("the variant input must be release or evaluation")
    version = marketing_version(project_text)
    number = build_number(environ.get("GITHUB_RUN_NUMBER"), environ.get("GITHUB_RUN_ATTEMPT"))
    label = VARIANTS[variant]
    return {
        "variant": variant,
        "label": label,
        "marketing_version": version,
        "build_number": number,
        "archive_name": f"Pantrified-{label}",
        "artifact_name": f"testflight-{variant}-{version}-build-{number}",
        "evaluation_tab": "present" if variant == "evaluation" else "absent",
        "internal_only": "true" if variant == "evaluation" else "false",
        "bundle_id": config["bundle_id"],
        "team_id": config["team_id"],
        "app_apple_id": config["app_apple_id"],
        "signing_identity": config["signing_identity"],
    }


def export_options(variant, config):
    if variant not in VARIANTS:
        raise Failure("the variant input must be release or evaluation")
    return {
        "method": "app-store-connect",
        "destination": "export",
        "signingStyle": "manual",
        "teamID": config["team_id"],
        "signingCertificate": config["signing_identity"],
        "provisioningProfiles": {config["bundle_id"]: config["profile_uuid"]},
        # The build number comes from the workflow run; Xcode must not replace it.
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
        "stripSwiftSymbols": True,
        "testFlightInternalTestingOnly": variant == "evaluation",
    }


def xcconfig_text(config):
    return "\n".join([
        XCCONFIG_MARKER,
        "// It is removed when the run ends. The app target includes it from Signing.xcconfig.",
        f"DEVELOPMENT_TEAM = {config['team_id']}",
        "BUNDLE_ID_SUFFIX =",
        "CODE_SIGN_STYLE = Manual",
        f"CODE_SIGN_IDENTITY = {config['signing_identity']}",
        f"PROVISIONING_PROFILE_SPECIFIER = {config['profile_name']}",
        "",
    ])


def _write_private(path, data):
    """Creates path with mode 0600, refusing to replace an existing file."""
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def _make_private_directory(path):
    path = pathlib.Path(path)
    if path.exists():
        raise Failure(f"{path} already exists; a previous run was not cleaned up")
    path.mkdir(mode=0o700)
    return path


def install_profile(profile_data, profile, home, record):
    """Installs the profile where each Xcode version looks, recording the files this run created."""
    installed = []
    for directory in PROFILE_DIRECTORIES:
        target_directory = pathlib.Path(home) / directory
        target_directory.mkdir(parents=True, exist_ok=True)
        target = target_directory / f"{profile['UUID']}.mobileprovision"
        if target.exists():
            if target.read_bytes() != profile_data:
                raise Failure(f"a different profile with the same UUID is already installed at {target}")
            continue
        _write_private(target, profile_data)
        installed.append(target)
        with open(record, "a") as handle:
            handle.write(f"{target}\n")
    return installed


def prepare(directory, environ, config, home, now=None):
    problems, decoded = signing_material(environ, config, now)
    if problems:
        raise Failure("\n".join(problems))
    directory = _make_private_directory(directory)
    _write_private(directory / "certificate.der", decoded["certificate"])
    _write_private(directory / "private-key.pem", environ[SIGNING_KEY].strip().encode() + b"\n")
    record = directory / INSTALLED_PROFILES
    record.touch(mode=0o600)
    install_profile(decoded["profile_data"], decoded["profile"], home, record)
    return decoded["profile"]


def write_api_key(directory, environ):
    problems = api_key_problems(environ)
    if problems:
        raise Failure("\n".join(problems))
    directory = pathlib.Path(directory)
    if not directory.is_dir():
        raise Failure(f"{directory} does not exist; run prepare first")
    keys = directory / "private_keys"
    keys.mkdir(mode=0o700)
    key_id = environ[API_KEY_ID].strip()
    _write_private(keys / f"AuthKey_{key_id}.p8", environ[API_KEY].strip().encode() + b"\n")
    return keys


def cleanup(directory, xcconfig=None):
    """Removes the installed profiles, DIR and the written xcconfig; returns what was removed."""
    removed = []
    directory = pathlib.Path(directory)
    record = directory / INSTALLED_PROFILES
    if record.is_file():
        for line in record.read_text().splitlines():
            path = pathlib.Path(line)
            if line and path.is_file():
                path.unlink()
                removed.append(str(path))
    if directory.exists():
        shutil.rmtree(directory)
        removed.append(str(directory))
    if xcconfig:
        path = pathlib.Path(xcconfig)
        if path.is_file() and path.read_text().startswith(XCCONFIG_MARKER):
            path.unlink()
            removed.append(str(path))
    return removed


def _read_plist(path, what):
    try:
        with open(path, "rb") as handle:
            value = plistlib.load(handle)
    except Exception:
        raise Failure(f"cannot read {what} at {path}") from None
    if not isinstance(value, dict):
        raise Failure(f"{what} at {path} is not a dictionary")
    return value


def verify_app(app, config, version, build, entitlements_path=None, codesign_path=None):
    """Checks a built app; returns a list of problems."""
    app = pathlib.Path(app)
    problems = []
    info = _read_plist(app / "Info.plist", "the app's Info.plist")
    expected = {
        "CFBundleIdentifier": config["bundle_id"],
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            problems.append(f"{key} is {info.get(key)!r}, expected {value!r}")
    profile_path = app / "embedded.mobileprovision"
    if not profile_path.is_file():
        problems.append("the app has no embedded provisioning profile")
    else:
        try:
            embedded = parse_profile(profile_path.read_bytes())
        except Failure:
            problems.append("the app's embedded provisioning profile cannot be read")
        else:
            if str(embedded.get("UUID", "")).lower() != config["profile_uuid"].lower():
                problems.append("the app embeds a provisioning profile other than the one in Config/testflight.json")
    if entitlements_path:
        entitlements = _read_plist(entitlements_path, "the signed entitlements")
        application_id = f"{config['team_id']}.{config['bundle_id']}"
        if entitlements.get("application-identifier") != application_id:
            problems.append(f"the signed application-identifier is not {application_id}")
        if entitlements.get("com.apple.developer.team-identifier") != config["team_id"]:
            problems.append(f"the signed team identifier is not {config['team_id']}")
        if entitlements.get("get-task-allow", False) is not False:
            problems.append("the app is signed with get-task-allow, which App Store Connect rejects")
        if entitlements.get("beta-reports-active") is not True:
            problems.append("the app is not signed for TestFlight (beta-reports-active)")
    if codesign_path:
        details = pathlib.Path(codesign_path).read_text(errors="replace").splitlines()
        authorities = [line.split("=", 1)[1] for line in details if line.startswith("Authority=")]
        if not authorities or not authorities[0].startswith(config["signing_identity"] + ":"):
            problems.append(f"the app is not signed with an {config['signing_identity']} certificate")
        teams = [line.split("=", 1)[1].strip() for line in details if line.startswith("TeamIdentifier=")]
        if teams != [config["team_id"]]:
            problems.append(f"the signature's team is not {config['team_id']}")
    return problems


def write_outputs(values, environ):
    path = environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as handle:
        for key, value in values.items():
            handle.write(f"{key}={value}\n")


def record(path, environ):
    fields = {
        "variant": environ.get("VARIANT", ""),
        "internal_only": environ.get("INTERNAL_ONLY", ""),
        "marketing_version": environ.get("MARKETING_VERSION", ""),
        "build_number": environ.get("BUILD_NUMBER", ""),
        "upload_requested": environ.get("UPLOAD", ""),
        "upload": environ.get("UPLOAD_OUTCOME", "") or "not run",
        "commit": environ.get("GITHUB_SHA", ""),
        "run_id": environ.get("GITHUB_RUN_ID", ""),
    }
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(fields, indent=2) + "\n")
    summary = environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("### TestFlight build\n\n| Field | Value |\n|---|---|\n")
            for key, value in fields.items():
                handle.write(f"| {key} | {value} |\n")
    return fields


def _parser():
    parser = argparse.ArgumentParser(description="Steps of the signed TestFlight build.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("build-info")
    commands.add_parser("prepare").add_argument("directory")
    commands.add_parser("xcconfig").add_argument("path")
    commands.add_parser("export-options").add_argument("path")
    verify = commands.add_parser("verify-app")
    verify.add_argument("app")
    verify.add_argument("--version", required=True)
    verify.add_argument("--build", required=True)
    verify.add_argument("--entitlements")
    verify.add_argument("--codesign")
    commands.add_parser("write-api-key").add_argument("directory")
    clean = commands.add_parser("cleanup")
    clean.add_argument("directory")
    clean.add_argument("--xcconfig")
    commands.add_parser("record").add_argument("path")
    return parser


def run(argv, environ, config=None):
    arguments = _parser().parse_args(argv)
    config = config or load_config()
    command = arguments.command
    if command == "check":
        problems = check(environ, config)
        if problems:
            raise Failure("\n".join(problems))
        print("The ref, the inputs and every required secret are in order.")
    elif command == "build-info":
        info = build_info(environ, config, PROJECT_PATH.read_text())
        print(f"Variant: {info['label']} (Evaluation tab {info['evaluation_tab']})")
        print(f"Version {info['marketing_version']}, build {info['build_number']}")
        write_outputs(info, environ)
    elif command == "prepare":
        profile = prepare(arguments.directory, environ, config, pathlib.Path.home())
        print(f"Installed the provisioning profile {config['profile_name']!r} and wrote the signing identity.")
        warning = profile_expiry_warning(profile)
        if warning:
            print(f"::warning::{warning}")
    elif command == "xcconfig":
        path = pathlib.Path(arguments.path)
        if path.exists():
            raise Failure(f"{path} already exists; it holds per-developer settings this build would replace")
        path.write_text(xcconfig_text(config))
        print(f"Wrote the manual signing settings to {path}")
    elif command == "export-options":
        with open(arguments.path, "wb") as handle:
            plistlib.dump(export_options(environ.get("VARIANT"), config), handle)
        print(f"Wrote {arguments.path}")
    elif command == "verify-app":
        problems = verify_app(arguments.app, config, arguments.version, arguments.build,
                              arguments.entitlements, arguments.codesign)
        if problems:
            raise Failure("\n".join(problems))
        print(f"{arguments.app}: identifiers, versions and profile are as expected"
              + (", and it is signed for App Store distribution" if arguments.codesign else ""))
    elif command == "write-api-key":
        write_api_key(arguments.directory, environ)
        print("Wrote the App Store Connect key where altool looks for it.")
    elif command == "cleanup":
        for path in cleanup(arguments.directory, arguments.xcconfig):
            print(f"Removed {path}")
    elif command == "record":
        record(arguments.path, environ)


def main(argv=None, environ=None):
    environ = os.environ if environ is None else environ
    try:
        run(sys.argv[1:] if argv is None else argv, environ)
    except Failure as failure:
        for line in str(failure).splitlines():
            print(f"error: {line}", file=sys.stderr)
        return 1
    except Exception as error:
        # The message of an unexpected error could quote the data it failed on, which may be a secret.
        print(f"error: unexpected {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
