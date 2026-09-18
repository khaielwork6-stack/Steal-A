"""Bake per-character bone walk loops with a grounded support foot."""
import bpy
import importlib.util
import json
import math
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAME = sys.argv[sys.argv.index("--") + 1]
FOLDER = ROOT / "art/guardians/models" / NAME
bpy.ops.wm.open_mainfile(filepath=str(FOLDER / (NAME + ".blend")))
body = bpy.data.objects["Body"]
rig = body.parent
spec = importlib.util.spec_from_file_location("animation_xml", ROOT / "tools/make-pet-animation-sources.py")
xml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xml)
parents = {"Root": "Body", "Spine": "Root", "Head": "Spine"}
for side in ("Left", "Right"):
    parents.update({side + "UpperArm": "Spine", side + "Forearm": side + "UpperArm", side + "Hand": side + "Forearm",
                    side + "Thigh": "Root", side + "Shin": side + "Thigh", side + "Foot": side + "Shin"})
carry = NAME in ("Zone03_IronKnight", "Zone07_IronTitan", "Zone11_WreckingForeman")
root = ET.Element("roblox", {"version": "4"})
sequence, props = xml.item(root, "KeyframeSequence", NAME + "_Walk")
ET.SubElement(props, "bool", {"name": "Loop"}).text = "true"
ET.SubElement(props, "token", {"name": "Priority"}).text = "1"
frames = []
for i in range(25):
    phase = 0 if i == 24 else i / 24
    s = math.sin(phase * math.tau)
    angles = {name: (0, 0) for name in parents}
    angles["Spine"] = (0, 1.7 * s)
    angles["Head"] = (0, -1.2 * s)
    for side, sign in (("Left", 1), ("Right", -1)):
        angles[side + "Thigh"] = (sign * 25 * s, 0)
        angles[side + "Shin"] = (-max(0, sign * s) * 22, 0)
        angles[side + "Foot"] = (max(0, sign * s) * 9, 0)
        angles[side + "UpperArm"] = (0 if carry else -sign * 16 * s, 0)
    for name, (pitch, roll) in angles.items():
        bone = rig.pose.bones[name]
        bone.location = (0, 0, 0)
        bone.rotation_mode = "XYZ"
        bone.rotation_euler = (math.radians(pitch), 0, math.radians(roll))
    bpy.context.view_layer.update()
    evaluated = body.evaluated_get(bpy.context.evaluated_depsgraph_get())
    low = min((evaluated.matrix_world @ vertex.co).z for vertex in evaluated.data.vertices)
    values = {name: xml.transform(pitch=pitch, roll=roll) for name, (pitch, roll) in angles.items()}
    values["Root"] = xml.transform(y=-low)
    frame, props = xml.item(sequence, "Keyframe", "Frame")
    ET.SubElement(props, "float", {"name": "Time"}).text = str(.96 * i / 24)
    nodes = {"Body": xml.pose_item(frame, "Body", xml.transform())}
    for name, parent in parents.items():
        nodes[name] = xml.pose_item(nodes[parent], name, values[name])
    rig.pose.bones["Root"].location.y = -low
    bpy.context.view_layer.update()
    evaluated = body.evaluated_get(bpy.context.evaluated_depsgraph_get())
    grounded = min((evaluated.matrix_world @ vertex.co).z for vertex in evaluated.data.vertices)
    assert abs(grounded) < .002, (i, grounded)
    frames.append({"time": .96 * i / 24, "rootY": -low, "floorError": grounded, "poses": values})
assert frames[0]["poses"] == frames[-1]["poses"]
ET.indent(root, space="  ")
path = FOLDER / (NAME + "_Walk.rbxmx")
ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
(FOLDER / "walk.project.json").write_text(json.dumps({"name": NAME + "_Walk", "tree": {"$path": path.name}}, indent=2))
(FOLDER / "walk-validation.json").write_text(json.dumps({"name": NAME, "duration": .96, "carryPose": carry,
    "maximumSampledFloorError": max(abs(f["floorError"]) for f in frames), "frames": frames}, indent=2))
print("GROUNDED_WALK_COMPLETE", NAME)
