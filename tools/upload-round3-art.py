"""Upload reviewed Round 3 PNGs to Roblox group 3774675 using Open Cloud.

The key is read from an explicit file outside the repository and never logged.
Run without --upload to check the manifest and authorization only. Creation is
not retried after an ambiguous failure: reconcile that entry before another run.
"""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import mimetypes
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/round3/upload"
GROUP = "3774675"
API = "https://apis.roblox.com"


def unlock_key(path: Path) -> str:
    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    encrypted = bytes.fromhex(path.read_text(encoding="utf-8-sig").strip())
    buffer = ctypes.create_string_buffer(encrypted)
    source = Blob(len(encrypted), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    output = Blob()
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    crypt32.CryptUnprotectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p,
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    if not crypt32.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 0, ctypes.byref(output)):
        raise RuntimeError("Could not unlock the upload key for this Windows user")
    try:
        return ctypes.string_at(output.data, output.size).decode("utf-16-le")
    finally:
        ctypes.memset(output.data, 0, output.size)
        kernel32 = ctypes.WinDLL("kernel32")
        kernel32.LocalFree.argtypes = [ctypes.c_void_p]
        kernel32.LocalFree(output.data)


def save(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def request(key: str, method: str, path: str, body: bytes | None = None,
            content_type: str = "application/json") -> dict:
    if not path.startswith(("/assets/v1/", "/api-keys/v1/")):
        raise ValueError("Unexpected API path")
    req = urllib.request.Request(API + path, body, method=method, headers={
        "x-api-key": key, "Content-Type": content_type,
    })
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Do not print request headers or credential-bearing request objects.
        raise RuntimeError(f"Roblox returned HTTP {error.code}; inspect the asset before retrying") from None
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("Network request failed; creation result may be uncertain") from None


def multipart(metadata: dict, image_path: Path) -> tuple[bytes, str]:
    boundary = "round3-" + uuid.uuid4().hex
    mime = {".glb": "model/gltf-binary", ".rbxm": "model/x-rbxm", ".rbxmx": "model/x-rbxm"}.get(image_path.suffix)
    mime = mime or mimetypes.guess_type(image_path.name)[0] or "image/png"
    prefix = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        "Content-Type: application/json\r\n\r\n"
        + json.dumps(metadata)
        + f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; "
        + f"filename=\"{image_path.name}\"\r\nContent-Type: {mime}\r\n\r\n"
    ).encode()
    return prefix + image_path.read_bytes() + f"\r\n--{boundary}--\r\n".encode(), \
        f"multipart/form-data; boundary={boundary}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", type=Path, required=True)
    parser.add_argument("--dpapi", action="store_true", help="Read a Windows-encrypted key cache")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--only", nargs="*", help="Manifest names to process")
    args = parser.parse_args()
    key_path = args.key_file.resolve()
    if key_path.is_relative_to(ROOT):
        parser.error("Store the API key outside the Git repository")
    if args.dpapi:
        key = unlock_key(key_path).strip()
    else:
        key = key_path.read_text(encoding="utf-8-sig").strip()
    if not key or any(c.isspace() for c in key):
        parser.error("The key file must contain only the API key")
    auth = request(key, "POST", "/api-keys/v1/introspect",
                   json.dumps({"apiKey": key}).encode())
    if not auth.get("enabled") or auth.get("expired"):
        raise RuntimeError("The upload key is disabled or expired")
    allowed = any(
        scope.get("name") == "asset"
        and "write" in scope.get("operations", [])
        and any(str(group) in (GROUP, "*") for group in scope.get("groupIds", []))
        for scope in auth.get("scopes", [])
    )
    if not allowed:
        raise RuntimeError("The key does not grant asset:write for group 3774675")
    print("Authorized: asset uploads for group 3774675", flush=True)
    specs = json.loads((PACKAGE / "asset-specs.json").read_text(encoding="utf-8"))
    record_path = PACKAGE / "uploaded-assets.json"
    records = json.loads(record_path.read_text()) if record_path.exists() else {}
    selected = [s for s in specs if not args.only or s["name"] in args.only]
    for spec in selected:
        name = spec["name"]
        prior = records.get(name, {})
        if prior.get("assetId"):
            print(f"{name}: already uploaded as {prior['assetId']}", flush=True)
            continue
        # Existing live badge images must update their badge, not create new IDs.
        if name.startswith("badge_"):
            print(f"{name}: badge artwork requires the separate badge-image workflow", flush=True)
            continue
        if prior.get("status") in ("creating", "uncertain"):
            raise RuntimeError(f"{name}: reconcile the earlier upload before creating another asset")
        image_path = PACKAGE / "ready" / f"{name}.png"
        if spec.get("status") != "reviewed" or not image_path.is_file():
            print(f"{name}: awaiting image review/export", flush=True)
            continue
        if not args.upload:
            print(f"{name}: ready for group upload", flush=True)
            continue
        metadata = {
            "assetType": "Image", "displayName": "Steal and Run - " + name,
            "description": "Original Round 3 game artwork for Steal and Run.",
            "creationContext": {"creator": {"groupId": GROUP}},
        }
        if prior.get("operationPath"):
            operation = request(key, "GET", prior["operationPath"])
        else:
            body, mime = multipart(metadata, image_path)
            records[name] = {"status": "creating", "groupId": GROUP,
                             "configKeys": spec["configKeys"]}
            save(record_path, records)
            try:
                operation = request(key, "POST", "/assets/v1/assets", body, mime)
            except Exception:
                records[name]["status"] = "uncertain"
                save(record_path, records)
                raise
        path = operation.get("path")
        if path:
            operation_path = "/assets/v1/" + path.removeprefix("/assets/v1/")
            records[name].update(status="processing", operationPath=operation_path)
            save(record_path, records)
        for _ in range(60):
            if operation.get("done"):
                break
            if not records[name].get("operationPath"):
                raise RuntimeError(f"{name}: response has no operation path; inspect before retrying")
            time.sleep(2)
            operation = request(key, "GET", records[name]["operationPath"])
        else:
            raise RuntimeError(f"{name}: still processing; rerun to resume polling")
        if operation.get("error"):
            records[name]["status"] = "failed"
            records[name]["error"] = operation["error"]
            save(record_path, records)
            raise RuntimeError(f"{name}: Roblox rejected the upload; see uploaded-assets.json")
        response = operation.get("response", {})
        asset_id = str(response.get("assetId", ""))
        if not asset_id.isdigit():
            raise RuntimeError(f"{name}: completed response has no asset ID; inspect before retrying")
        records[name].update(status="awaiting-ownership-and-load-check", assetId=asset_id)
        save(record_path, records)
        print(f"{name}: uploaded {asset_id}; ownership/load check pending", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
