# MacAuth backup format (`.macauth`, version 1)

A backup is one UTF-8 JSON file. It does not depend on the app: everything needed to decrypt it is
described here (see the script at the end).

```json
{
  "format": "macauth-backup",
  "version": 1,
  "kdf": { "name": "pbkdf2-hmac-sha256", "iterations": 600000, "salt": "<base64, 16 bytes>" },
  "cipher": "aes-256-gcm",
  "nonce": "<base64, 12 bytes>",
  "ciphertext": "<base64>",
  "tag": "<base64, 16 bytes>"
}
```

All binary values are standard Base64 with padding.

## Key derivation

- Password: Unicode NFC normalised, UTF-8 encoded. Minimum 10 characters when creating a backup.
- Key: PBKDF2-HMAC-SHA256, the given salt and iteration count, 32 bytes of output.
- The app writes 600 000 iterations and refuses files outside 100 000 to 10 000 000.

## Encryption

AES-256-GCM with the given nonce. Ciphertext and tag are stored separately (`ciphertext` has the
length of the plaintext). The additional authenticated data (AAD) is this text, UTF-8, joined by
single `\n` (no trailing newline):

```
macauth-backup
1
pbkdf2-hmac-sha256
<iterations as decimal>
<salt as base64, re-encoded from the decoded bytes>
aes-256-gcm
```

A wrong password and a modified file both fail the GCM tag check and are indistinguishable.

## Plaintext

JSON, UTF-8. Dates are ISO 8601 (`2023-11-14T22:13:20Z`), binary values Base64.

```json
{
  "accounts": [{
    "id": "UUID", "issuer": "Example", "name": "alice@example.com",
    "secret": "<base64 of the raw secret bytes>",
    "algorithm": "sha1 | sha256 | sha512", "digits": 6, "period": 30,
    "kind": "totp | hotp", "counter": 0,
    "groupID": "UUID or absent", "pinned": false, "sortIndex": 0,
    "createdAt": "ISO 8601", "lastUsedAt": "absent (never written to a backup; ignored when reading)", "note": ""
  }],
  "groups": [{ "id": "UUID", "name": "Firma", "symbol": "building.2", "colour": "#3B82F6" }]
}
```

To use a secret in another app, Base32-encode the raw bytes (RFC 4648, no padding needed); the script
below prints a ready-made `otpauth://` link per account.

## Stand-alone decryption (Python 3 + `cryptography`)

```python
#!/usr/bin/env python3
"""Decrypt a MacAuth backup.  Usage: python3 decrypt_macauth.py backup.macauth
Prints the plaintext JSON to stdout, otpauth links to stderr.  Needs: pip install cryptography"""
import base64, getpass, json, sys, unicodedata
from urllib.parse import quote
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert doc["format"] == "macauth-backup" and doc["version"] == 1, "not a MacAuth v1 backup"
assert doc["kdf"]["name"] == "pbkdf2-hmac-sha256" and doc["cipher"] == "aes-256-gcm"
b64 = base64.b64decode
salt, nonce, ct, tag = b64(doc["kdf"]["salt"]), b64(doc["nonce"]), b64(doc["ciphertext"]), b64(doc["tag"])
iterations = doc["kdf"]["iterations"]

password = unicodedata.normalize("NFC", getpass.getpass("Password: ")).encode("utf-8")
key = PBKDF2HMAC(hashes.SHA256(), 32, salt, iterations).derive(password)
aad = "\n".join(["macauth-backup", "1", "pbkdf2-hmac-sha256", str(iterations),
                 base64.b64encode(salt).decode(), "aes-256-gcm"]).encode()
try:
    plain = AESGCM(key).decrypt(nonce, ct + tag, aad)
except Exception:
    sys.exit("Wrong password or damaged file")

data = json.loads(plain)
print(json.dumps(data, indent=2, ensure_ascii=False))
for a in data["accounts"]:
    secret = base64.b32encode(b64(a["secret"])).decode().rstrip("=")
    label = quote(f'{a["issuer"]}:{a["name"]}' if a["issuer"] else a["name"], safe=":")
    extra = f'&counter={a["counter"]}' if a["kind"] == "hotp" else f'&period={a["period"]}'
    print(f'otpauth://{a["kind"]}/{label}?secret={secret}&issuer={quote(a["issuer"])}'
          f'&algorithm={a["algorithm"].upper()}&digits={a["digits"]}{extra}', file=sys.stderr)
```
