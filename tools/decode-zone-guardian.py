"""Decode lossless Studio export buffers; no image resampling or editing."""
import argparse
import base64
import json
import sys
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "art/round3/.tool-deps"))
import zstandard

parser = argparse.ArgumentParser()
parser.add_argument("name")
parser.add_argument("--prefix", default="")
args = parser.parse_args()
folder = ROOT / "art/guardians/models" / args.name
assert folder.resolve().is_relative_to(ROOT / "art/guardians/models")
manifest = json.loads((folder / (args.prefix + "export-manifest.json")).read_text())
for item in manifest["files"]:
    chunks = sorted(folder.glob(args.prefix + item["name"] + "-*.b64"))
    encoded = "".join(p.read_text().strip() for p in chunks)
    assert len(encoded) == item["length"], item["name"]
    raw = zstandard.ZstdDecompressor().decompress(base64.b64decode(encoded, validate=True))
    if item["name"] == "mesh":
        json.loads(raw)
        (folder / "mesh.json").write_bytes(raw)
    else:
        part = next(p for p in manifest["parts"] if p["texture"] == item["name"])
        size = tuple(part["textureSize"])
        assert len(raw) == size[0] * size[1] * 4
        Image.frombytes("RGBA", size, raw).save(folder / (item["name"] + ".png"))
print("Decoded", args.name)
