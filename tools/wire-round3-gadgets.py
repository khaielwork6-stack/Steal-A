"""Install ownership-verified gadget mesh and texture references in config."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
proof = json.loads((root / "art/round3/models/gadget-ownership-proof.json").read_text())
path = root / "src/shared/Config/GadgetConfig.luau"
data = path.read_bytes()
for name in ("Smoke", "Jammer", "Grapple"):
    row = proof[name]
    assert row["owner"] == 3774675
    start = data.index(('key = "' + name + '"').encode())
    end = data.index(b"\n\t},", start)
    block = data[start:end]
    for field, value in (("meshId", row["meshId"]), ("textureId", row["textureId"])):
        old = (field + ' = "rbxassetid://0"').encode()
        assert old in block
        block = block.replace(old, (field + ' = "rbxassetid://' + value + '"').encode(), 1)
    data = data[:start] + block + data[end:]
path.write_bytes(data)
print("Wired three group-owned gadget meshes and textures.")
