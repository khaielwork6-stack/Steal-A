"""Wire only group-owned animation IDs with verified readable keyframes."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
proof = json.loads((ROOT / "art/round3/animations/ownership-and-clip-proof.json").read_text())
assert len(proof) == 20 and all(r["owner"] == 3774675 and r["frames"] >= 21 for r in proof)
rows = {r["name"]: r for r in proof}
path = ROOT / "src/shared/Config/BaseGuardianConfig.luau"
data = path.read_bytes()
newline = b"\r\n" if b"\r\n" in data else b"\n"
text = data.decode().replace("\r\n", "\n")
start = text.index("-- Manual group uploads fill")
end = text.index("local function pass", start)
text = text[:start] + "-- Animation assets are owned by group 3774675; clip proof is in art/round3/animations.\n" + text[end:]
for animal in ("Cat", "Dog", "Panda", "Tiger"):
    marker = 'modelName = "' + animal + '",\n\t\tanimations = unpublishedClips(),'
    values = ", ".join(key + ' = "rbxassetid://' + rows[animal + "_" + key.title()]["assetId"] + '"' for key in ("idle", "walk", "run", "attack", "celebrate"))
    assert marker in text
    text = text.replace(marker, 'modelName = "' + animal + '",\n\t\tanimations = { ' + values + ' },', 1)
path.write_bytes(text.replace("\n", newline.decode()).encode())
print("Wired 20 verified group animation IDs; preserved line endings.")
