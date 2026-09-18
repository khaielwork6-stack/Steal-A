"""Package verified group mesh references and Motor6D poses as portable rigs."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("props", Path(__file__).with_name("make-round3-props.py"))
props = importlib.util.module_from_spec(spec)
spec.loader.exec_module(props)
for animal in ("Cat", "Dog", "Panda", "Tiger"):
    folder = ROOT / "art/round3/models" / animal
    source = folder / "rig-source.json"
    if not source.exists():
        continue
    data = json.loads(source.read_text())
    assert len(data["parts"]) == 8 and len(data["joints"]) == 7
    assert data["parts"][0]["name"] == "HumanoidRootPart"
    props.OUT = folder
    props.write_model(data)
    print(animal + ": 8 parts, 7 joints")
