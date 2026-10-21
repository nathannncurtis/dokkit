import os
import sys
import time

import jwt
import requests

APP_ID = "6825230954"
GROUP_ID = "8ad3fdf3-ad01-496f-860d-db069ead732f"
API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID = os.environ["ASC_KEY_ID"]


def token():
    key = open(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")).read()
    now = int(time.time())
    claims = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, key, algorithm="ES256", headers={"kid": KEY_ID})


def call(method, path, **kw):
    return requests.request(method, API + path, headers={"Authorization": "Bearer " + token()}, timeout=60, **kw)


def main(build_number):
    # App Store Connect drops leading zeros from each part of the build number
    build_number = ".".join(str(int(x)) for x in build_number.split("."))
    deadline = time.time() + 1800
    build = None
    while time.time() < deadline:
        r = call("GET", "/builds", params={"filter[app]": APP_ID, "filter[version]": build_number})
        r.raise_for_status()
        data = r.json()["data"]
        if data and data[0]["attributes"]["processingState"] == "VALID":
            build = data[0]["id"]
            break
        time.sleep(30)
    if not build:
        sys.exit("The build did not finish processing in 30 minutes.")

    r = call("POST", f"/betaGroups/{GROUP_ID}/relationships/builds", json={"data": [{"type": "builds", "id": build}]})
    if r.status_code >= 300 and r.status_code != 409:
        sys.exit(f"Adding the build to the group failed: {r.status_code} {r.text}")

    r = call("POST", "/betaAppReviewSubmissions", json={"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})
    if r.status_code >= 300 and r.status_code != 409:
        sys.exit(f"Submitting for beta review failed: {r.status_code} {r.text}")

    r = call("GET", f"/betaGroups/{GROUP_ID}")
    print("Public link:", r.json()["data"]["attributes"].get("publicLink"))


if __name__ == "__main__":
    main(sys.argv[1])
