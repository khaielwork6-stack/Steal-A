"""Render a saved guardian in a temporary Blender review scene."""
import bpy
import math
import json
import sys
from pathlib import Path
from mathutils import Vector, Matrix

root = Path(__file__).resolve().parents[1]
args = sys.argv[sys.argv.index("--") + 1:]
name = args[0]
folder = root / "art/guardians/models" / name
bpy.ops.wm.open_mainfile(filepath=str(folder / (name + ".blend")))
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 24
scene.render.resolution_x = 900
scene.render.resolution_y = 1000
scene.render.resolution_percentage = 100
scene.world.color = (.2, .2, .2)
scene.view_settings.view_transform = "AgX"
body = bpy.data.objects["Body"]
height = body.dimensions.z
if len(args) > 1 and args[1] == "stride":
    rig = body.parent
    poses = json.loads((folder / "walk-validation.json").read_text())["frames"][6]["poses"]
    for bone, values in poses.items():
        matrix = Matrix(((values[3], values[4], values[5], values[0]),
                         (values[6], values[7], values[8], values[1]),
                         (values[9], values[10], values[11], values[2]), (0, 0, 0, 1)))
        rig.pose.bones[bone].matrix_basis = matrix
    scene.frame_set(1)
bpy.ops.object.camera_add(location=(height * .95, height * 1.6, height * .90))
camera = bpy.context.object
target = Vector((0, 0, height * .5))
camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
camera.data.type = "ORTHO"
camera.data.ortho_scale = height * 1.32
scene.camera = camera
for position, energy, size in [((.6, 1.2, 1.7), 1200, 1), ((-1, .5, .9), 650, 1), ((0, -.9, 1.3), 1400, .7)]:
    bpy.ops.object.light_add(type="AREA", location=Vector(position) * height)
    light = bpy.context.object
    light.data.energy = energy * (height / 7) ** 2
    light.data.shape = "DISK"
    light.data.size = size * height
    light.rotation_euler = (target - light.location).to_track_quat("-Z", "Y").to_euler()
bpy.ops.mesh.primitive_plane_add(size=height * 200, location=(0, 0, -.015))
floor = bpy.context.object
material = bpy.data.materials.new("ReviewBackdrop")
material.diffuse_color = (.06, .075, .11, 1)
floor.data.materials.append(material)
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(folder / ("review-stride.png" if len(args) > 1 else "review-rest.png"))
bpy.ops.render.render(write_still=True)
