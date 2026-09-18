"""Dress the published stall mesh for the existing lobby gadget display layout."""
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("props", Path(__file__).with_name("make-round3-props.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
m = p.model("GadgetStand", "ServerStorage.GameAssets.Props.GadgetStand")
body = p.part(m, "StallArt", (16, 12, 9), (0, 6, 0), p.WHITE)
body["mesh"] = {"id": "107813382287779", "texture": "98101039727657",
    "scale": [16 / 1.562622308731079, 12 / 1.9196252822875977, 9 / .9344350099563599]}
for name, size, pos in (
    ("CounterCollision", (14, 4.4, 2.4), (0, 2.2, -3.4)),
    ("BackCollision", (15, 10, .5), (0, 5, 4.1)),
    ("LeftPostCollision", (.7, 11, .7), (-7.2, 5.5, -3.4)),
    ("RightPostCollision", (.7, 11, .7), (7.2, 5.5, -3.4)),
):
    part = p.part(m, name, size, pos, p.NAVY)
    part["transparency"] = 1
for index, x in enumerate((-4.8, -1.6, 1.6, 4.8)):
    p.part(m, "StockCrate" + str(index), (2.2, 1.7, 1.8), (x, 1, 2.7), p.STEEL)
    p.part(m, "CrateBand" + str(index), (2.25, .2, 1.85), (x, 1.2, 2.7), p.GOLD)
p.write_model(m)
(p.OUT / "gadget-stand-source.json").write_text(json.dumps(m, indent=2) + "\n")
print("GadgetStand: " + str(len(m["parts"])) + " parts")
