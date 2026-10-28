"""Creates FITNS's permanent release signing key and hands it to GitHub Actions.

Run once, ever, from the repository root:

    python tool/setup_release_signing.py

It
  1. generates a keystore (default ~/keys/fitns-release.jks),
  2. writes android/key.properties (gitignored) so local release builds are
     signed with it too,
  3. sets the four repository secrets .github/workflows/release.yml reads:
     ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
     ANDROID_KEY_PASSWORD, ANDROID_KEY_ALIAS.

The password is random and never printed — it lives in key.properties.

BACK UP the keystore and key.properties somewhere safe (a password manager).
Every future release must be signed with this exact key: lose it and no
installed copy of FITNS can ever be updated again — users would have to
uninstall (losing their data) to move to a new key.

Needs `keytool` (any JDK) and the GitHub CLI (`gh`), signed in.
"""

import argparse
import base64
import secrets
import string
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALIAS = "fitns"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--dir",
        type=Path,
        default=Path.home() / "keys",
        help="where the keystore goes (default: ~/keys)",
    )
    args = parser.parse_args()

    keystore = args.dir / "fitns-release.jks"
    properties = ROOT / "android" / "key.properties"
    for existing in (keystore, properties):
        if existing.exists():
            sys.exit(f"{existing} already exists — refusing to replace a release key.")

    repo = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()

    password = "".join(
        secrets.choice(string.ascii_letters + string.digits) for _ in range(32)
    )

    args.dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "keytool", "-genkeypair",
            "-keystore", str(keystore), "-storetype", "PKCS12",
            "-alias", ALIAS, "-keyalg", "RSA", "-keysize", "4096",
            "-validity", "10000",
            # PKCS12 has one password for the store and its key.
            "-storepass", password, "-keypass", password,
            "-dname", "CN=FITNS, O=TRAKVRS, C=IN",
        ],
        check=True,
        capture_output=True,
    )

    properties.write_text(
        f"storePassword={password}\n"
        f"keyPassword={password}\n"
        f"keyAlias={ALIAS}\n"
        f"storeFile={keystore.as_posix()}\n",
        encoding="utf-8",
    )

    def set_secret(name: str, value: str) -> None:
        subprocess.run(
            ["gh", "secret", "set", name, "--repo", repo],
            input=value.encode(),
            check=True,
            capture_output=True,
        )

    set_secret("ANDROID_KEYSTORE_BASE64", base64.b64encode(keystore.read_bytes()).decode())
    set_secret("ANDROID_KEYSTORE_PASSWORD", password)
    set_secret("ANDROID_KEY_PASSWORD", password)
    set_secret("ANDROID_KEY_ALIAS", ALIAS)

    print(f"Keystore:       {keystore}")
    print(f"key.properties: {properties}")
    print(f"Secrets set on: {repo}")
    print("Back up both files now — see the note at the top of this script.")


if __name__ == "__main__":
    main()
