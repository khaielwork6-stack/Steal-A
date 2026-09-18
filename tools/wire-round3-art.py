"""Verify saved Studio evidence and wire genuine Round 3 image IDs.

Run after upload and Studio ownership/load checks. Byte-based source edits
preserve the original file's line endings and fail on ambiguous matches.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/round3/upload"


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proof", type=Path)
    args = parser.parse_args()
    proof = read(args.proof)
    owners = json.loads(proof["ownership"]["content"][0]["text"])
    loading = json.loads(proof["loading"]["content"][0]["text"])
    assert loading["ok"]
    records = read(PACKAGE / "uploaded-assets.json")
    specs = read(PACKAGE / "asset-specs.json")
    verified = set()
    for row in owners:
        assert row["ok"] and row["group"] == 3774675 and row["creatorType"] == "Group", row
        asset = str(row["id"])
        assert loading["statuses"]["rbxassetid://" + asset] == "Success", asset
        verified.add(asset)
    # The caller also records ImageLabel.IsLoaded for every asset.
    images = loading["images"]
    assert all(row["loaded"] for row in images), images
    assert len(images) == len(verified)
    updates = {}
    wired = []
    for spec in specs:
        name = spec["name"]
        record = records.get(name, {})
        asset = record.get("assetId")
        if asset not in verified:
            continue
        for key in spec["configKeys"]:
            module, leaf = key.split(".", 1)
            path = ROOT / "src/shared/Config" / (module + ".luau")
            if module == "LoadingConfig":
                path = ROOT / "src/first/LoadingConfig.luau"
            elif module == "AutoRevealPassCard":
                path = ROOT / "src/client/Controllers/AutoRevealPassCard.luau"
            source = updates.get(path, path.read_bytes())
            if name.startswith(("theme-", "pedestal-", "board-", "event-")):
                rowkey = name.split("-", 1)[1]
                field = leaf.rsplit(".", 1)[1]
                prefix = r'key = "' + re.escape(rowkey) + r'"[\s\S]*?\b' + field + r' = "'
            elif name.startswith("daily-day-"):
                prefix = r'day = ' + name.rsplit("-", 1)[1] + r',[^\r\n]*?icon = "'
            elif "().icon" in leaf:
                kind = leaf.split("(", 1)[0]
                prefix = r'kind = "' + kind + r'",[^\r\n]*?icon = "'
            elif leaf.startswith("TIPS["):
                index = int(re.search(r'\[(\d+)\]', leaf)[1])
                matches = list(re.finditer(rb'\{ icon = "([^"\r\n]+)"', source))
                assert len(matches) == 14
                match = matches[index - 1]
                old = match[1]
                new = ("rbxassetid://" + asset).encode()
                assert old in (b"rbxassetid://0", new), (key, old)
                source = source[:match.start(1)] + new + source[match.end(1):]
                updates[path] = source
                continue
            elif name.startswith("gadget-"):
                prefix = re.escape(name.split("-", 1)[1]) + r' = \{[\s\S]*?icon = "'
            else:
                field = leaf.rsplit(".", 1)[-1]
                if "." in leaf:
                    table = leaf.rsplit(".", 1)[0]
                    prefix = re.escape(module + "." + table) + r' = \{[^}]*?\b' + re.escape(field) + r' = "'
                else:
                    prefix = re.escape(module + "." + field) + r' = "'
            pattern = ("(" + prefix + r')([^"\r\n]+)(")').encode()
            matches = list(re.finditer(pattern, source))
            assert len(matches) == 1, (key, len(matches))
            match = matches[0]
            new = ("rbxassetid://" + asset).encode()
            assert match[2] in (b"rbxassetid://0", new, b"rbxasset://textures/particles/smoke_main.dds", b"rbxasset://textures/particles/sparkles_main.dds"), (key, match[2])
            updates[path] = source[:match.start(2)] + new + source[match.end(2):]
        record.update(status="verified", verifiedCreatorType="Group", verifiedCreatorId=3774675,
                      verifiedCreatorName="99 Dreams Studio", studioPreload="Success", studioImageLoaded=True)
        spec.update(assetId=asset, status="verified-upload")
        wired.append(name)
    for path, source in updates.items():
        path.write_bytes(source)
    save(PACKAGE / "uploaded-assets.json", records)
    save(PACKAGE / "asset-specs.json", specs)
    print(json.dumps({"wired": wired, "files": len(updates)}))


if __name__ == "__main__":
    main()
