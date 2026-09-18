"""Upload a reviewed model or animation under group 3774675; retain operation IDs."""
import argparse
import importlib.util
import json
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("art_upload", Path(__file__).with_name("upload-round3-art.py"))
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument("file", type=Path)
    parser.add_argument("--type", choices=("Model", "Animation"), default="Model")
    parser.add_argument("--key-file", type=Path, required=True)
    args = parser.parse_args()
    path = args.file.resolve()
    assert path.is_relative_to(ROOT / "art/round3") and path.is_file()
    assert path.suffix in (".glb", ".rbxm", ".rbxmx")
    assert not args.key_file.resolve().is_relative_to(ROOT)
    key = upload.unlock_key(args.key_file).strip()
    auth = upload.request(key, "POST", "/api-keys/v1/introspect", json.dumps({"apiKey": key}).encode())
    assert auth.get("enabled") and not auth.get("expired")
    assert any(s.get("name") == "asset" and "write" in s.get("operations", [])
               and any(str(g) in ("3774675", "*") for g in s.get("groupIds", []))
               for s in auth.get("scopes", []))
    ledger = ROOT / "art/round3/models/published-assets.json"
    records = json.loads(ledger.read_text()) if ledger.exists() else {}
    record = records.get(args.name, {})
    if record.get("assetId"):
        print(json.dumps(record))
        return
    assert record.get("status") not in ("creating", "uncertain"), "Reconcile the earlier request first"
    if record.get("operationPath"):
        operation = upload.request(key, "GET", record["operationPath"])
    else:
        metadata = {"assetType": args.type, "displayName": "Steal and Run - " + args.name,
                    "description": "Original Round 3 game art for Steal and Run.",
                    "creationContext": {"creator": {"groupId": "3774675"}}}
        body, mime = upload.multipart(metadata, path)
        record = {"status": "creating", "groupId": "3774675", "type": args.type,
                  "file": str(path.relative_to(ROOT)).replace("\\", "/")}
        records[args.name] = record
        upload.save(ledger, records)
        try:
            operation = upload.request(key, "POST", "/assets/v1/assets", body, mime)
        except Exception:
            record["status"] = "uncertain"
            upload.save(ledger, records)
            raise
        if operation.get("path"):
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
    record.update(status="awaiting-ownership-and-load-check", assetId=asset,
                  response=operation.get("response"))
    upload.save(ledger, records)
    print(json.dumps({"name": args.name, "assetId": asset, "groupId": "3774675"}))


if __name__ == "__main__":
    main()
