"""Record completed Studio verification without exposing upload credentials."""
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/guardians"
audit = json.loads((PACKAGE / "studio-production-audit.json").read_text())
assert audit["allPassed"] and len(audit["guardians"]) == 12
playback = json.loads((PACKAGE / "studio-playback-proof.json").read_text())
assert len(playback) == 12
orientation = json.loads((PACKAGE / "studio-orientation-proof.json").read_text())
assert len(orientation) == 12 and all(row["passed"] for row in orientation)
production = json.loads((PACKAGE / "production.json").read_text())
production["status"] = "Installed in Studio Edit mode; asset and bone-playback audits passed; Save & Publish required"
(PACKAGE / "production.json").write_text(json.dumps(production, indent=2) + "\n")
ledger = json.loads((PACKAGE / "published-assets.json").read_text())
for spec in production["guardians"]:
    name = spec["name"]
    for suffix in ("_Production_v1", "_Walk_v1"):
        ledger[name + suffix]["status"] = "installed-and-verified-in-Studio-Edit"
    path = PACKAGE / "models" / name / "blender-validation.json"
    record = json.loads(path.read_text())
    row = next(row for row in audit["guardians"] if row["name"] == name)
    record["status"] = "Installed; Studio geometry, texture, ownership and bone playback checks passed"
    record["importedDeformingBones"] = row["bones"]
    record["importedTriangles"] = row["triangles"]
    path.write_text(json.dumps(record, indent=2) + "\n")
ledger["ZoneGuardian_Idle_v1"]["status"] = "installed-and-verified-in-Studio-Edit"
(PACKAGE / "published-assets.json").write_text(json.dumps(ledger, indent=2) + "\n")
print("Recorded all twelve completed Edit-mode validations")
