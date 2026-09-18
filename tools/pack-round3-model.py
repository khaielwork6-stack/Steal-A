"""Package lossless Studio mesh/texture exports as GLB for group publication."""
import argparse
import base64
import json
import re
import struct
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "art/round3/.tool-deps"))
import zstandard


def pack_glb(folder):
    geometry = json.loads((folder / "mesh.json").read_text())
    binary = bytearray()
    views, accessors = [], []

    def add_view(data, target=None):
        while len(binary) % 4:
            binary.append(0)
        view = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)}
        if target:
            view["target"] = target
        views.append(view)
        binary.extend(data)
        return len(views) - 1

    def attribute(rows, size, bounds=False):
        flattened = [v for row in rows for v in row]
        view = add_view(struct.pack("<" + "f" * len(flattened), *flattened), 34962)
        accessor = {"bufferView": view, "componentType": 5126,
                    "count": len(rows), "type": "VEC" + str(size)}
        if bounds:
            accessor["min"] = [min(row[i] for row in rows) for i in range(size)]
            accessor["max"] = [max(row[i] for row in rows) for i in range(size)]
        accessors.append(accessor)
        return len(accessors) - 1

    parts = geometry.get("parts", [{"name": folder.name, "faces": geometry.get("faces")}])
    nodes, meshes, materials, textures, images = [], [], [], [], []
    triangle_count = 0
    for index, part in enumerate(parts):
        positions, normals, uvs = [], [], []
        for face in part["faces"]:
            for vertex in face:
                positions.append(vertex[:3])
                normals.append(vertex[3:6])
                uvs.append(vertex[6:8])
        assert positions and len(positions) % 3 == 0
        triangle_count += len(positions) // 3
        attributes = {"POSITION": attribute(positions, 3, True),
                      "NORMAL": attribute(normals, 3), "TEXCOORD_0": attribute(uvs, 2)}
        texture_name = "texture_" + part["name"] + ".png" if "parts" in geometry else "texture.png"
        image_view = add_view((folder / texture_name).read_bytes())
        node = {"name": part["name"], "mesh": index}
        if "cframe" in part:
            x, y, z, a, b, c, d, e, f, g, h, i = part["cframe"]
            node["matrix"] = [a, d, g, 0, b, e, h, 0, c, f, i, 0, x, y, z, 1]
        nodes.append(node)
        meshes.append({"name": part["name"], "primitives": [{"attributes": attributes, "material": index}]})
        materials.append({"pbrMetallicRoughness": {"baseColorTexture": {"index": index},
                          "metallicFactor": 0, "roughnessFactor": 0.65}, "doubleSided": False})
        textures.append({"source": index})
        images.append({"bufferView": image_view, "mimeType": "image/png"})
    document = {
        "asset": {"version": "2.0", "generator": "Steal and Run Studio art export"},
        "scene": 0, "scenes": [{"nodes": list(range(len(nodes)))}],
        "nodes": nodes, "meshes": meshes, "materials": materials,
        "textures": textures, "images": images,
        "accessors": accessors, "bufferViews": views,
        "buffers": [{"byteLength": len(binary)}],
    }
    encoded = json.dumps(document, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    result = struct.pack("<III", 0x46546C67, 2, 28 + len(encoded) + len(binary))
    result += struct.pack("<II", len(encoded), 0x4E4F534A) + encoded
    result += struct.pack("<II", len(binary), 0x004E4942) + binary
    (folder / (folder.name + ".glb")).write_bytes(result)
    return {"name": folder.name, "parts": len(parts), "triangles": triangle_count, "bytes": len(result)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("--size", type=int, nargs=2, default=[1024, 1024])
    args = parser.parse_args()
    assert re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,64}", args.name)
    folder = ROOT / "art/round3/models" / args.name
    manifest_file = folder / "export-manifest.json"
    manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else None
    kinds = [f["name"] for f in manifest["files"]] if manifest else ("mesh", "texture")
    for kind in kinds:
        chunks = sorted(folder.glob(kind + "-*.b64"))
        if not chunks:
            chunks = sorted(folder.glob(kind + "_*.b64"), key=lambda p: int(p.stem.rsplit("_", 1)[1]))
        assert chunks, kind
        if manifest:
            record = next(f for f in manifest["files"] if f["name"] == kind)
            assert len(chunks) == record["chunks"], kind
        encoded = "".join(p.read_text(encoding="utf-8-sig").strip() for p in chunks)
        if manifest:
            assert len(encoded) == record["length"], kind
        data = zstandard.ZstdDecompressor().decompress(base64.b64decode(encoded, validate=True))
        if kind == "mesh":
            parsed = json.loads(data)
            assert parsed.get("faces") or parsed.get("parts")
            (folder / "mesh.json").write_bytes(data)
        else:
            width, height = next(p["textureSize"] for p in manifest["parts"] if kind == "texture_" + p["name"]) if manifest else args.size
            assert len(data) == width * height * 4
            # Lossless encoding only: the generated RGBA pixels stay unchanged.
            Image.frombytes("RGBA", (width, height), data).save(folder / (kind + ".png"))
    print(json.dumps(pack_glb(folder)))



