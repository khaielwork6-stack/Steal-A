"""Publish guardian assets under group 3774675, with a resumable private ledger."""
import argparse
import hashlib
import importlib.util
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/guardians"
spec = importlib.util.spec_from_file_location("art_upload", ROOT / "tools/upload-round3-art.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


def create_asset(key, body, mime):
    request = urllib.request.Request("https://apis.roblox.com/assets/v1/assets", body, method="POST",
                                     headers={"x-api-key": key, "Content-Type": mime})
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Only response diagnostics, never credential-bearing request objects.
        try:
            details = json.loads(error.read())
        except (ValueError, OSError):
            details = {"message": "No JSON response"}
        raise RejectedAsset(error.code, details) from None


class RejectedAsset(Exception):
    def __init__(self, status, details):
        self.status, self.details = status, details
        super().__init__(f"Roblox HTTP {status}: {json.dumps(details)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument("file", type=Path)
    parser.add_argument("--type", choices=("Model", "Animation", "Image"), default="Model")
    parser.add_argument("--key-file", type=Path, required=True)
    args = parser.parse_args()
    file = args.file.resolve()
    assert file.is_relative_to(PACKAGE) and file.is_file()
    assert file.suffix in (".glb", ".fbx", ".rbxm", ".rbxmx", ".png")
    assert not args.key_file.resolve().is_relative_to(ROOT)
    digest = hashlib.sha256(file.read_bytes()).hexdigest()
    ledger = PACKAGE / "published-assets.json"
    records = json.loads(ledger.read_text()) if ledger.exists() else {}
    record = records.get(args.name, {})
    if record:
        assert record["sha256"] == digest, "Use a new version name for changed asset content"
    if record.get("assetId"):
        print(json.dumps(record))
        return
    assert record.get("status") not in ("creating", "uncertain"), "Reconcile the earlier request before retrying"
    key = upload.unlock_key(args.key_file).strip()
    auth = upload.request(key, "POST", "/api-keys/v1/introspect", json.dumps({"apiKey": key}).encode())
    assert auth.get("enabled") and not auth.get("expired")
    assert any(s.get("name") == "asset" and "write" in s.get("operations", [])
               and any(str(g) in ("3774675", "*") for g in s.get("groupIds", [])) for s in auth.get("scopes", []))
    if record.get("operationPath"):
        operation = upload.request(key, "GET", record["operationPath"])
    else:
        metadata = {"assetType": args.type, "displayName": ("Steal and Run - " + args.name)[:50],
                    "description": "Original approved zone guardian art for Steal and Run.",
                    "creationContext": {"creator": {"groupId": "3774675"}}}
        body, mime = upload.multipart(metadata, file)
        if file.suffix == ".fbx":
            body = body.replace(b"Content-Type: application/octet-stream", b"Content-Type: model/fbx")
        record = {"status": "creating", "groupId": "3774675", "type": args.type,
                  "sha256": digest, "file": file.relative_to(ROOT).as_posix()}
        records[args.name] = record
        upload.save(ledger, records)
        try:
            operation = create_asset(key, body, mime)
        except RejectedAsset as error:
            record.update(status="rejected" if 400 <= error.status < 500 else "uncertain",
                          httpStatus=error.status, error=error.details)
            upload.save(ledger, records)
            raise
        except Exception:
            record["status"] = "uncertain"
            upload.save(ledger, records)
            raise
        assert operation.get("path"), "No operation ID; reconcile this request"
        record.update(status="processing", operationPath="/assets/v1/" + operation["path"].removeprefix("/assets/v1/"))
        upload.save(ledger, records)
    for _ in range(90):
        if operation.get("done"):
            break
        time.sleep(2)
        operation = upload.request(key, "GET", record["operationPath"])
    else:
        raise RuntimeError("Still processing; rerun to resume")
    if operation.get("error"):
        record.update(status="failed", error=operation["error"])
        upload.save(ledger, records)
        raise RuntimeError("Roblox rejected this asset; see ledger")
    asset = str(operation.get("response", {}).get("assetId", ""))
    assert asset.isdigit(), "No asset ID; inspect operation before retrying"
    record.update(status="awaiting-ownership-and-load-check", assetId=asset, response=operation.get("response"))
    upload.save(ledger, records)
    print(json.dumps({"name": args.name, "assetId": asset, "groupId": "3774675"}))


if __name__ == "__main__":
    main()
