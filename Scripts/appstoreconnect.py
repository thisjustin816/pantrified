"""A small App Store Connect API client, shared by the TestFlight scripts.

Signs requests with the team API key in APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and
APP_STORE_CONNECT_PRIVATE_KEY. Standard library and the openssl command only.
"""

import base64
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

# The app identifiers; Scripts/upload-testflight.sh holds the same, and a test keeps them equal.
BUNDLE_ID = "com.thisjustin816.Pantrified"
API = "https://api.appstoreconnect.apple.com/v1"


def base64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(signature):
    """openssl writes ECDSA signatures as DER; a JWT carries r and s as 32 bytes each."""
    if signature[0] != 0x30:
        raise ValueError("not a DER sequence")
    offset = 3 if signature[1] & 0x80 else 2
    raw = b""
    for _ in range(2):
        if signature[offset] != 0x02:
            raise ValueError("not a DER integer")
        length = signature[offset + 1]
        value = signature[offset + 2:offset + 2 + length].lstrip(b"\0")
        if len(value) > 32:
            raise ValueError("integer longer than 32 bytes")
        raw += value.rjust(32, b"\0")
        offset += 2 + length
    return raw


def token(key_id, issuer_id, key_path):
    now = int(time.time())
    header = base64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = base64url(json.dumps(
        {"iss": issuer_id, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    ).encode())
    signing_input = f"{header}.{claims}".encode()
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input, check=True, capture_output=True,
    ).stdout
    return f"{header}.{claims}.{base64url(der_to_raw(signature))}"


class Client:
    """Signs a new token for each request, since waiting on processing can outlast one."""

    def __init__(self, key_id, issuer_id, key_path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.key_path = key_path

    def request(self, method, path, body=None):
        bearer = token(self.key_id, self.issuer_id, self.key_path)
        request = urllib.request.Request(
            f"{API}{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = response.read()
            return json.loads(payload) if payload else {}

    def app_id(self):
        apps = self.request("GET", f"/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=bundleId")["data"]
        if not apps:
            sys.exit(f"No App Store Connect app has the bundle ID {BUNDLE_ID}.")
        return apps[0]["id"]

    def set_whats_new(self, build_id, text):
        """Sets the build's English What to Test, the text testers see."""
        localizations = self.request("GET", f"/builds/{build_id}/betaBuildLocalizations")["data"]
        existing = next((loc for loc in localizations if loc["attributes"]["locale"] == "en-US"), None)
        if existing:
            self.request("PATCH", f"/betaBuildLocalizations/{existing['id']}", {"data": {
                "type": "betaBuildLocalizations",
                "id": existing["id"],
                "attributes": {"whatsNew": text},
            }})
        else:
            self.request("POST", "/betaBuildLocalizations", {"data": {
                "type": "betaBuildLocalizations",
                "attributes": {"locale": "en-US", "whatsNew": text},
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }})


@contextlib.contextmanager
def client_from_environment():
    """A client whose private key lives in a file only the runner's user can read, removed after."""
    with tempfile.TemporaryDirectory() as directory:
        key_path = os.path.join(directory, "AuthKey.p8")
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as key:
            key.write(os.environ["APP_STORE_CONNECT_PRIVATE_KEY"])
        yield Client(os.environ["APP_STORE_CONNECT_KEY_ID"], os.environ["APP_STORE_CONNECT_ISSUER_ID"], key_path)
