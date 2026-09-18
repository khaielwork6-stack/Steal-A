"""Pack the four final PBR maps into each editable Blender source."""
import bpy
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "art/guardians"
for spec in json.loads((PACKAGE / "production.json").read_text())["guardians"]:
    path = PACKAGE / "models" / spec["name"] / (spec["name"] + ".blend")
    bpy.ops.wm.open_mainfile(filepath=str(path))
    body = bpy.data.objects["Body"]
    images = {node.image for mat in body.data.materials for node in mat.node_tree.nodes
              if node.type == "TEX_IMAGE" and node.image}
    assert len(images) == 4
    for image in images:
        image.pack()
    bpy.ops.wm.save_as_mainfile(filepath=str(path))
    print("PACKED_SOURCE", spec["name"])
