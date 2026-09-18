"""Build the import manifest and sparse geometry/UV probes from saved sources."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/guardians"
ledger = json.loads((PACKAGE / "published-assets.json").read_text())
specs = json.loads((PACKAGE / "production.json").read_text())["guardians"]
result = []
for spec in specs:
    name = spec["name"]
    model = ledger.get(name + "_Production_v1", {}).get("assetId")
    walk = ledger.get(name + "_Walk_v1", {}).get("assetId")
    if not model or not walk:
        continue
    data = json.loads((PACKAGE / "models" / name / "skinned-mesh.json").read_text())
    probes = []
    for tri in data["triangles"][::max(1, len(data["triangles"]) // 20)]:
        corner = tri[0]
        probes.append({"uv": corner["uv"], "position": data["vertices"][corner["vertex"] - 1]["position"]})
    result.append({**spec, "modelId": int(model), "walkId": walk, "probes": probes})
(PACKAGE / "import-manifest.json").write_text(json.dumps(result, indent=2))
print(json.dumps({"ready": [r["name"] for r in result]}))
