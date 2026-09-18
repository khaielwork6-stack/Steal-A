"""Author shared bone-animation loops for the approved zone guardian skeleton."""
import importlib.util
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "art/guardians/animations"
OUT.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("animation_xml", ROOT / "tools/make-pet-animation-sources.py")
xml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(xml)
parents = {"Root": "Body", "Spine": "Root", "Head": "Spine"}
for side in ("Left", "Right"):
    parents.update({side + "UpperArm": "Spine", side + "Forearm": side + "UpperArm", side + "Hand": side + "Forearm",
                    side + "Thigh": "Root", side + "Shin": side + "Thigh", side + "Foot": side + "Shin"})
manifest = []
for kind, duration in (("Idle", 2.8), ("Walk", .96)):
    root = ET.Element("roblox", {"version": "4"})
    sequence, props = xml.item(root, "KeyframeSequence", "ZoneGuardian_" + kind)
    ET.SubElement(props, "bool", {"name": "Loop"}).text = "true"
    ET.SubElement(props, "token", {"name": "Priority"}).text = "0" if kind == "Idle" else "1"
    frames = []
    for i in range(25):
        phase = 0 if i == 24 else i / 24
        s = math.sin(phase * math.tau)
        values = {name: xml.transform() for name in parents}
        if kind == "Idle":
            values["Spine"] = xml.transform(pitch=.8 * s)
            values["Head"] = xml.transform(pitch=-1.1 * s, roll=.6 * s)
        else:
            values["Spine"] = xml.transform(roll=1.7 * s)
            values["Head"] = xml.transform(roll=-1.2 * s)
            for side, sign in (("Left", 1), ("Right", -1)):
                values[side + "Thigh"] = xml.transform(pitch=sign * 25 * s)
                values[side + "Shin"] = xml.transform(pitch=-max(0, sign * s) * 22)
                values[side + "Foot"] = xml.transform(pitch=max(0, sign * s) * 9)
                values[side + "UpperArm"] = xml.transform(pitch=-sign * 16 * s)
                values[side + "Forearm"] = xml.transform(pitch=-3 * (1 + sign * s))
        frame, props = xml.item(sequence, "Keyframe", "Frame")
        ET.SubElement(props, "float", {"name": "Time"}).text = str(duration * i / 24)
        nodes = {"Body": xml.pose_item(frame, "Body", xml.transform())}
        for name, parent in parents.items():
            nodes[name] = xml.pose_item(nodes[parent], name, values[name])
        frames.append({"time": duration * i / 24, "poses": values})
    assert frames[0]["poses"] == frames[-1]["poses"]
    ET.indent(root, space="  ")
    path = OUT / ("ZoneGuardian_" + kind + ".rbxmx")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    project = {"name": "ZoneGuardian_" + kind, "tree": {"$path": path.name}}
    (OUT / (kind.lower() + ".project.json")).write_text(json.dumps(project, indent=2))
    manifest.append({"clip": kind, "duration": duration, "groupId": 3774675, "frames": frames,
                     "status": "draft; awaiting Studio deformation and playback verification"})
(OUT / "sources.json").write_text(json.dumps(manifest, indent=2))
print("Authored idle/walk bone loops; both seams verified")
