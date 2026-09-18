"""Author the Round 3 quadruped KeyframeSequences for later group upload.

Drafts target the joint contract documented in art/round3/animations/README.md.
They need final review on each new mesh rig before publication.
"""
import json
import math
from pathlib import Path
import xml.etree.ElementTree as ET

OUT = Path(__file__).resolve().parents[1] / "art/round3/animations"
ANIMALS = {
    "Cat": {"idle": 2.8, "walk": .84, "run": .48, "stride": 25, "tail": 22, "hop": .34},
    "Dog": {"idle": 2.4, "walk": .78, "run": .44, "stride": 28, "tail": 34, "hop": .4},
    "Panda": {"idle": 3.2, "walk": 1.08, "run": .62, "stride": 19, "tail": 5, "hop": .24},
    "Tiger": {"idle": 2.7, "walk": .88, "run": .46, "stride": 29, "tail": 16, "hop": .36},
}
PARTS = ("Torso", "Head", "FrontLeft", "FrontRight", "HindLeft", "HindRight", "Tail")


def transform(x=0, y=0, z=0, pitch=0, yaw=0, roll=0):
    # CFrame.Angles XYZ rotation: Rx * Ry * Rz.
    a, b, c = map(math.radians, (pitch, yaw, roll))
    ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
    return [x, y, z, cb*cc, -cb*sc, sb,
            ca*sc+sa*sb*cc, ca*cc-sa*sb*sc, -sa*cb,
            sa*sc-ca*sb*cc, sa*cc+ca*sb*sc, ca*cb]


def poses(kind, t, tuning):
    s = math.sin(t * 2 * math.pi)
    c = math.cos(t * 2 * math.pi)
    pose = {part: transform() for part in PARTS}
    if kind == "idle":
        pose["Torso"] = transform(y=.025*s)
        pose["Head"] = transform(pitch=1.5*s, roll=.8*s)
        pose["Tail"] = transform(yaw=tuning["tail"]*.45*s)
    elif kind == "walk":
        pose["Torso"] = transform(y=.035*(1-math.cos(t*4*math.pi)), roll=2*s)
        pose["Head"] = transform(pitch=-2*s, roll=-1.5*s)
        for part, sign in (("FrontLeft",1),("HindRight",1),("FrontRight",-1),("HindLeft",-1)):
            pose[part] = transform(pitch=sign*tuning["stride"]*s)
        pose["Tail"] = transform(yaw=tuning["tail"]*.7*c)
    elif kind == "run":
        pose["Torso"] = transform(y=.11*(1-c), pitch=-5+6*s)
        pose["Head"] = transform(pitch=5-3*s)
        for part, phase in (("FrontLeft",0),("FrontRight",.1),("HindLeft",.5),("HindRight",.6)):
            pose[part] = transform(pitch=1.4*tuning["stride"]*math.sin((t+phase)*2*math.pi))
        pose["Tail"] = transform(pitch=12+5*s, yaw=tuning["tail"]*.3*s)
    elif kind == "attack":
        # Small crouch, forward pounce and paw swipe, then settle to rest.
        wind = max(0, 1-abs(t-.18)/.18)
        strike = max(0, 1-abs(t-.48)/.27)
        pose["Torso"] = transform(y=-.12*wind+.16*strike, z=.08*wind-.45*strike, pitch=8*wind-17*strike)
        pose["Head"] = transform(pitch=-10*wind+8*strike)
        pose["FrontLeft"] = transform(pitch=-48*strike, roll=-12*strike)
        pose["FrontRight"] = transform(pitch=-30*strike, roll=8*strike)
        pose["HindLeft"] = transform(pitch=18*wind+20*strike)
        pose["HindRight"] = transform(pitch=18*wind+20*strike)
        pose["Tail"] = transform(pitch=18*strike)
    else:
        hop = math.sin(math.pi*t)**2
        pose["Torso"] = transform(y=tuning["hop"]*hop, pitch=-5*hop)
        pose["Head"] = transform(pitch=-8*hop, roll=5*s*hop)
        pose["FrontLeft"] = transform(pitch=-22*hop, roll=-9*hop)
        pose["FrontRight"] = transform(pitch=-22*hop, roll=9*hop)
        pose["HindLeft"] = transform(pitch=16*hop)
        pose["HindRight"] = transform(pitch=16*hop)
        pose["Tail"] = transform(yaw=tuning["tail"]*math.sin(t*4*math.pi)*hop)
    return pose


def item(parent, class_name, name):
    node = ET.SubElement(parent, "Item", {"class": class_name})
    props = ET.SubElement(node, "Properties")
    ET.SubElement(props, "string", {"name": "Name"}).text = name
    return node, props


def pose_item(parent, name, cf):
    node, props = item(parent, "Pose", name)
    frame = ET.SubElement(props, "CoordinateFrame", {"name": "CFrame"})
    for label, value in zip(("X","Y","Z","R00","R01","R02","R10","R11","R12","R20","R21","R22"), cf):
        ET.SubElement(frame, label).text = f"{value:.8f}"
    ET.SubElement(props, "float", {"name": "Weight"}).text = "1"
    ET.SubElement(props, "token", {"name": "EasingStyle"}).text = "0"
    ET.SubElement(props, "token", {"name": "EasingDirection"}).text = "0"
    return node


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = []
    for animal, tuning in ANIMALS.items():
        for kind in ("idle", "walk", "run", "attack", "celebrate"):
            duration = tuning.get(kind, .55 if kind == "attack" else .9)
            looping = kind in ("idle", "walk", "run")
            root = ET.Element("roblox", {"version": "4"})
            sequence, props = item(root, "KeyframeSequence", animal+"_"+kind.title())
            ET.SubElement(props, "bool", {"name": "Loop"}).text = str(looping).lower()
            ET.SubElement(props, "token", {"name": "Priority"}).text = "0" if kind == "idle" else "1" if looping else "2"
            samples = 24 if looping else 20
            data = []
            for n in range(samples+1):
                phase = 0 if looping and n == samples else n/samples
                values = poses(kind, phase, tuning)
                frame, props = item(sequence, "Keyframe", "Frame")
                ET.SubElement(props, "float", {"name": "Time"}).text = f"{duration*n/samples:.8f}"
                root_pose = pose_item(frame, "HumanoidRootPart", transform())
                torso = pose_item(root_pose, "Torso", values["Torso"])
                for part in PARTS[1:]:
                    pose_item(torso, part, values[part])
                data.append({"time": duration*n/samples, "poses": values})
            if looping:
                assert data[0]["poses"] == data[-1]["poses"], "Loop seam mismatch"
            filename = f"{animal}_{kind.title()}.rbxmx"
            ET.indent(root, space="  ")
            ET.ElementTree(root).write(OUT/filename, encoding="utf-8", xml_declaration=True)
            manifest.append({"file": filename, "animal": animal, "clip": kind, "duration": duration,
                "loop": looping, "frames": data, "groupId": 3774675, "assetId": None,
                "status": "draft; requires final rig review", "configKey": f"BaseGuardianConfig.ByKey.{animal}.animations.{kind}"})
    (OUT/"animation-sources.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print("Authored 20 draft KeyframeSequences; loop seams verified. No assets uploaded.")


if __name__ == "__main__":
    main()
