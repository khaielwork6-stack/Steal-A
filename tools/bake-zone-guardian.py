"""Blender: clean an AI draft, bind bones, bake a single PBR atlas and export.

Run with --background --python-exit-code 1 --python this.py -- Zone01_NightWatchman.
Uses the AI mesh and its original color textures, not primitive replacement art.
"""
import bpy
import bmesh
import json
import math
import sys
import numpy as np
from pathlib import Path
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
NAME = sys.argv[sys.argv.index("--") + 1]
FOLDER = ROOT / "art/guardians/models" / NAME
spec = next(s for s in json.loads((ROOT / "art/guardians/production.json").read_text())["guardians"] if s["name"] == NAME)
source = json.loads((FOLDER / "mesh.json").read_text())
manifest = json.loads((FOLDER / "export-manifest.json").read_text())
W, H, D = spec["size"]
CONVERT = Matrix.Rotation(math.pi / 2, 4, "X")
INVERSE = CONVERT.inverted()
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 8
scene.render.bake.margin = 8
scene.render.bake.use_clear = True
scene.unit_settings.system = "NONE"
scene.view_settings.view_transform = "Standard"
all_positions = [v[:3] for p in source["parts"] for f in p["faces"] for v in f]
lo = [min(v[i] for v in all_positions) for i in range(3)]
hi = [max(v[i] for v in all_positions) for i in range(3)]
scale = Vector((W / (hi[0] - lo[0]), H / (hi[1] - lo[1]), D / (hi[2] - lo[2])))
center = Vector(((hi[0] + lo[0]) / 2, lo[1], (hi[2] + lo[2]) / 2))


def roblox_position(row):
    return (Vector(row[:3]) - center) * scale


def node(nodes, kind, name=None):
    n = nodes.new(kind)
    if name:
        n.name = name
    return n


objects = []
materials = []
source_bounds = {}
geometry_report = []
for index, part in enumerate(source["parts"]):
    vertices, faces, face_uvs = [], [], []
    index_by_pos = {}
    for face in part["faces"]:
        ids, uvs = [], []
        for vertex in face:
            pos = roblox_position(vertex)
            key = tuple(round(v, 6) for v in pos)
            if key not in index_by_pos:
                index_by_pos[key] = len(vertices)
                vertices.append(tuple(CONVERT @ pos))
            ids.append(index_by_pos[key])
            # Roblox and glTF textures have the origin at top left.
            uvs.append((vertex[6], 1 - vertex[7]))
        faces.append(ids)
        face_uvs.append(uvs)
    mesh = bpy.data.meshes.new(part["name"])
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(part["name"], mesh)
    bpy.context.collection.objects.link(obj)
    uv = mesh.uv_layers.new(name="SourceUV")
    for polygon, coords in zip(mesh.polygons, face_uvs):
        polygon.use_smooth = True
        for loop, coord in zip(polygon.loop_indices, coords):
            uv.data[loop].uv = coord
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=0.00001)
    boundary_before = sum(e.is_boundary for e in bm.edges)
    if boundary_before:
        bmesh.ops.holes_fill(bm, edges=[e for e in bm.edges if e.is_boundary], sides=12)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bmesh.ops.triangulate(bm, faces=list(bm.faces))
    boundary_after = sum(e.is_boundary for e in bm.edges)
    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")
    bm.to_mesh(mesh)
    bm.free()
    geometry_report.append({"part": part["name"], "triangles": len(mesh.polygons),
                            "boundaryBefore": boundary_before, "boundaryAfter": boundary_after})
    assert boundary_after == 0, f"Unclosed mesh: {part['name']}"
    positions = [INVERSE @ v.co for v in mesh.vertices]
    source_bounds[part["name"]] = [[min(v[i] for v in positions) for i in range(3)],
                                  [max(v[i] for v in positions) for i in range(3)]]
    mat = bpy.data.materials.new(part["name"] + "_Source")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    output = node(nodes, "ShaderNodeOutputMaterial")
    shader = node(nodes, "ShaderNodeBsdfPrincipled", "SourceShader")
    links.new(shader.outputs["BSDF"], output.inputs["Surface"])
    uvnode = node(nodes, "ShaderNodeUVMap")
    uvnode.uv_map = "SourceUV"
    tex = node(nodes, "ShaderNodeTexImage", "OriginalColor")
    tex.image = bpy.data.images.load(str(FOLDER / (manifest["parts"][index]["texture"] + ".png")))
    links.new(uvnode.outputs["UV"], tex.inputs["Vector"])
    links.new(tex.outputs["Color"], shader.inputs["Base Color"])
    # Explicit material masks based on the source palette: navy fabric, skin,
    # leather boots/belt and yellow-gold/silver hardware. The geometric part
    # provides context so moustache and skin never become metallic.
    sep = node(nodes, "ShaderNodeSeparateColor")
    links.new(tex.outputs["Color"], sep.inputs["Color"])
    def math_node(operation, a, b):
        m = node(nodes, "ShaderNodeMath")
        m.operation = operation
        for socket, value in zip(m.inputs, (a, b)):
            if isinstance(value, (float, int)):
                socket.default_value = value
            else:
                links.new(value, socket)
        return m.outputs[0]
    red_green = math_node("SUBTRACT", sep.outputs["Red"], sep.outputs["Green"])
    green_blue = math_node("SUBTRACT", sep.outputs["Green"], sep.outputs["Blue"])
    yellow = math_node("MULTIPLY", math_node("LESS_THAN", red_green, .28),
                       math_node("GREATER_THAN", green_blue, .07))
    yellow = math_node("MULTIPLY", yellow, math_node("GREATER_THAN", sep.outputs["Green"], .10))
    hsv = node(nodes, "ShaderNodeSeparateColor")
    hsv.mode = "HSV"
    links.new(tex.outputs["Color"], hsv.inputs["Color"])
    yellow = math_node("MULTIPLY", yellow, math_node("GREATER_THAN", hsv.outputs[1], .55))
    yellow = math_node("MULTIPLY", yellow, math_node("GREATER_THAN", red_green, -.01))
    metal = math_node("MULTIPLY", yellow, 0 if "head" in part["name"] else .85)
    if NAME in ("Zone05_FrostYeti", "Zone10_Granny"):
        metal = math_node("MULTIPLY", yellow, 0)
    if NAME == "Zone07_IronTitan" and "arm" in part["name"]:
        steel = math_node("MULTIPLY", math_node("LESS_THAN", hsv.outputs[1], .18),
                          math_node("GREATER_THAN", hsv.outputs[2], .035))
        metal = math_node("MULTIPLY", steel, .8)
    if NAME in ("Zone03_IronKnight", "Zone08_VaultBot"):
        # Steel and brass armor; keep saturated red plumes, lenses and capes
        # dielectric. This mask is baked into the shared material atlas.
        steel = math_node("LESS_THAN", hsv.outputs[1], .32)
        metal = math_node("MULTIPLY", math_node("MAXIMUM", steel, yellow), .85)
    rough = math_node("SUBTRACT", .66 if "torso" in part["name"] else .52, math_node("MULTIPLY", metal, .38))
    links.new(metal, shader.inputs["Metallic"])
    links.new(rough, shader.inputs["Roughness"])
    geometry = node(nodes, "ShaderNodeNewGeometry")
    position = node(nodes, "ShaderNodeSeparateXYZ")
    links.new(geometry.outputs["Position"], position.inputs[0])
    lower_body = math_node("LESS_THAN", position.outputs["Z"], H * .43)
    alpha = math_node("SUBTRACT", 1, math_node("MULTIPLY", lower_body, .40 if NAME == "Zone02_GhostCaptain" else 0))
    links.new(alpha, shader.inputs["Alpha"])
    noise = node(nodes, "ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 95
    noise.inputs["Detail"].default_value = 2
    bump = node(nodes, "ShaderNodeBump")
    bump.inputs["Strength"].default_value = .12
    bump.inputs["Distance"].default_value = .015 * H / 7
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], shader.inputs["Normal"])
    mesh.materials.append(mat)
    materials.append(mat)
    objects.append(obj)

if NAME == "Zone07_IronTitan":
    # Restore the approved readable head proportion: the image-to-mesh draft
    # undersized the face relative to the shoulders and barbell.
    head = next(o for o in objects if "head" in o.name)
    points = [INVERSE @ v.co for v in head.data.vertices]
    bottom = Vector(((min(p.x for p in points) + max(p.x for p in points)) / 2,
                     min(p.y for p in points), (min(p.z for p in points) + max(p.z for p in points)) / 2))
    for vertex in head.data.vertices:
        vertex.co = CONVERT @ (bottom + (INVERSE @ vertex.co - bottom) * Vector((1.65, 1.30, 1.40)))

# Keep the higher-resolution image-conditioned silhouette until cleanup, then
# reduce every part with UV boundaries protected for the final mobile budget.
source_triangles = sum(len(o.data.polygons) for o in objects)
if source_triangles >= 4000:
    for obj in objects:
        bpy.context.view_layer.objects.active = obj
        modifier = obj.modifiers.new("MobileBudget", "DECIMATE")
        modifier.ratio = 3750 / source_triangles
        modifier.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=modifier.name)
assert sum(len(o.data.polygons) for o in objects) < 4000, "Complete character exceeds triangle budget"
for obj in objects:
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    assert not any(e.is_boundary for e in bm.edges), "Reduction opened a mesh boundary"
    bm.free()

# Decimation can move the extremal vertices. Restore the documented bounds
# before calculating bind poses, so imported bone positions and mesh agree.
positions = [INVERSE @ v.co for o in objects for v in o.data.vertices]
final_lo = Vector(tuple(min(v[i] for v in positions) for i in range(3)))
final_hi = Vector(tuple(max(v[i] for v in positions) for i in range(3)))
final_scale = Vector(tuple(size / (final_hi[i] - final_lo[i]) for i, size in enumerate((W, H, D))))
final_center = Vector(((final_hi.x + final_lo.x) / 2, final_lo.y, (final_hi.z + final_lo.z) / 2))
for obj in objects:
    for v in obj.data.vertices:
        v.co = CONVERT @ ((INVERSE @ v.co - final_center) * final_scale)
    positions = [INVERSE @ v.co for v in obj.data.vertices]
    source_bounds[obj.name] = [[min(v[i] for v in positions) for i in range(3)],
                               [max(v[i] for v in positions) for i in range(3)]]

# Derive joint placements from the actual separated limb geometry, not a stock
# avatar. All bind transforms and vertex weights are exported for verification.
def bounds_for(phrase):
    matches = [b for name, b in source_bounds.items() if phrase in name.lower()]
    assert len(matches) == 1, (phrase, list(source_bounds))
    return Vector(matches[0][0]), Vector(matches[0][1])

torso_lo, torso_hi = bounds_for("torso")
head_lo, head_hi = bounds_for("head")
root_y = torso_lo.y + (torso_hi.y - torso_lo.y) * .22
spine_y = torso_lo.y + (torso_hi.y - torso_lo.y) * .52
neck_y = head_lo.y + (head_hi.y - head_lo.y) * .14
joints = {
    "Root": (None, Vector((0, root_y, 0)), Vector((0, spine_y, 0))),
    "Spine": ("Root", Vector((0, spine_y, 0)), Vector((0, neck_y, 0))),
    "Head": ("Spine", Vector((0, neck_y, 0)), Vector((0, H * .98, 0))),
}
for side in ("left", "right"):
    a, b = bounds_for(side + " arm")
    mid = (a + b) / 2
    shoulder = Vector((mid.x * .76, min(b.y - .10 * (b.y - a.y), torso_hi.y - .05 * H), mid.z * .45))
    elbow = Vector((mid.x, a.y + .53 * (b.y - a.y), mid.z))
    wrist = Vector((mid.x, a.y + .18 * (b.y - a.y), mid.z))
    hand = wrist + Vector((0, -.16 * (b.y - a.y), 0))
    title = side.title()
    joints[title + "UpperArm"] = ("Spine", shoulder, elbow)
    joints[title + "Forearm"] = (title + "UpperArm", elbow, wrist)
    joints[title + "Hand"] = (title + "Forearm", wrist, hand)
    a, b = bounds_for(side + " leg")
    mid = (a + b) / 2
    hip = Vector((mid.x, b.y - .03 * H, mid.z))
    knee = Vector((mid.x, a.y + .48 * (b.y - a.y), mid.z))
    ankle = Vector((mid.x, a.y + .18 * (b.y - a.y), mid.z))
    toe = Vector((mid.x, ankle.y, a.z))
    joints[title + "Thigh"] = ("Root", hip, knee)
    joints[title + "Shin"] = (title + "Thigh", knee, ankle)
    joints[title + "Foot"] = (title + "Shin", ankle, toe)

bpy.ops.object.armature_add()
rig = bpy.context.object
rig.name = NAME + "_Armature"
bpy.ops.object.mode_set(mode="EDIT")
for b in list(rig.data.edit_bones):
    rig.data.edit_bones.remove(b)
for name, (parent, head, tail) in joints.items():
    b = rig.data.edit_bones.new(name)
    b.head, b.tail = CONVERT @ head, CONVERT @ tail
    if (b.tail - b.head).length < .01:
        b.tail.z += .05
    if parent:
        b.parent = rig.data.edit_bones[parent]
bpy.ops.object.mode_set(mode="OBJECT")

def segment_distance(point, start, end):
    vector = end - start
    t = max(0, min(1, (point - start).dot(vector) / max(vector.length_squared, 1e-8)))
    return (point - (start + t * vector)).length

for obj in objects:
    part = obj.name.lower()
    if "head" in part:
        candidates = ["Head"]
    elif "arm" in part:
        side = "Left" if "left" in part else "Right"
        # Keep the generated closed arm/held-prop assembly rigid about the
        # shoulder. Blending a cutlass or barbell across elbow weights bends
        # metal and separates the grip. Limb bones remain available for edits.
        candidates = [side + "UpperArm"]
    elif "leg" in part:
        side = "Left" if "left" in part else "Right"
        candidates = [side + suffix for suffix in ("Thigh", "Shin", "Foot")]
    else:
        candidates = ["Root", "Spine"]
    groups = {name: obj.vertex_groups.new(name=name) for name in candidates}
    for vertex in obj.data.vertices:
        pos = INVERSE @ vertex.co
        distances = sorted((segment_distance(pos, joints[name][1], joints[name][2]), name) for name in candidates)
        picked = distances[:2]
        weights = [1 / max(distance, .02 * H) ** 4 for distance, _ in picked]
        total = sum(weights)
        for (_, name), weight in zip(picked, weights):
            groups[name].add([vertex.index], weight / total, "REPLACE")

# Join into one skinned MeshPart, keeping original UVs for the source textures.
bpy.ops.object.select_all(action="DESELECT")
for obj in objects:
    obj.select_set(True)
bpy.context.view_layer.objects.active = objects[0]
bpy.ops.object.join()
body = bpy.context.object
body.name = "Body"
body.data.name = "Body"
body.parent = rig
modifier = body.modifiers.new("GuardianSkin", "ARMATURE")
modifier.object = rig
atlas_uv = body.data.uv_layers.new(name="AtlasUV")
body.data.uv_layers.active = atlas_uv
body.data.uv_layers.active_index = body.data.uv_layers.find("AtlasUV")
atlas_uv.active_render = True
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=.012)
bpy.ops.object.mode_set(mode="OBJECT")

maps = {}
for map_name, bake_type in [("ColorMap", "EMIT"), ("NormalMap", "NORMAL"), ("RoughnessMap", "EMIT"), ("MetalnessMap", "EMIT"), ("AlphaBake", "EMIT")]:
    target = bpy.data.images.new(NAME + "_" + map_name, 1024, 1024, alpha=map_name == "ColorMap")
    target.colorspace_settings.name = "sRGB" if map_name == "ColorMap" else "Non-Color"
    for mat in materials:
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        out = next(n for n in nodes if n.type == "OUTPUT_MATERIAL")
        shader = nodes["SourceShader"]
        for link in list(out.inputs["Surface"].links):
            links.remove(link)
        if bake_type == "NORMAL":
            links.new(shader.outputs["BSDF"], out.inputs["Surface"])
        else:
            emission = nodes.get("BakeEmission") or node(nodes, "ShaderNodeEmission", "BakeEmission")
            for link in list(emission.inputs["Color"].links):
                links.remove(link)
            socket = {"ColorMap": "Base Color", "RoughnessMap": "Roughness", "MetalnessMap": "Metallic", "AlphaBake": "Alpha"}[map_name]
            links.new(shader.inputs[socket].links[0].from_socket, emission.inputs["Color"])
            links.new(emission.outputs[0], out.inputs["Surface"])
        bake = nodes.get("BakeTarget") or node(nodes, "ShaderNodeTexImage", "BakeTarget")
        bake.image = target
        for n in nodes:
            n.select = False
        bake.select = True
        nodes.active = bake
    bpy.ops.object.bake(type=bake_type)
    target.filepath_raw = str(FOLDER / (map_name + ".png"))
    target.file_format = "PNG"
    target.save()
    maps[map_name] = target

if NAME == "Zone02_GhostCaptain":
    # The alpha channel is baked from the 3D lower-body material, in the same
    # atlas coordinates as color; this is not a post-hoc image recolor.
    color_pixels = np.empty(1024 * 1024 * 4, dtype=np.float32)
    alpha_pixels = np.empty_like(color_pixels)
    maps["ColorMap"].pixels.foreach_get(color_pixels)
    maps["AlphaBake"].pixels.foreach_get(alpha_pixels)
    color_pixels[3::4] = alpha_pixels[0::4]
    maps["ColorMap"].pixels.foreach_set(color_pixels)
    maps["ColorMap"].save()

final = bpy.data.materials.new("Guardian_PBR")
final.use_nodes = True
nodes, links = final.node_tree.nodes, final.node_tree.links
shader = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
for map_name, socket in (("ColorMap", "Base Color"), ("RoughnessMap", "Roughness"), ("MetalnessMap", "Metallic")):
    texture = node(nodes, "ShaderNodeTexImage")
    texture.image = maps[map_name]
    links.new(texture.outputs["Color"], shader.inputs[socket])
    if map_name == "ColorMap" and NAME == "Zone02_GhostCaptain":
        links.new(texture.outputs["Alpha"], shader.inputs["Alpha"])
normal_texture = node(nodes, "ShaderNodeTexImage")
normal_texture.image = maps["NormalMap"]
normal = node(nodes, "ShaderNodeNormalMap")
links.new(normal_texture.outputs["Color"], normal.inputs["Color"])
links.new(normal.outputs["Normal"], shader.inputs["Normal"])
body.data.materials.clear()
body.data.materials.append(final)
body.data.uv_layers.remove(body.data.uv_layers["SourceUV"])
for p in body.data.polygons:
    p.material_index = 0

for obj in (rig, body):
    obj.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.wm.save_as_mainfile(filepath=str(FOLDER / (NAME + ".blend")))
bpy.ops.export_scene.gltf(filepath=str(FOLDER / (NAME + ".glb")), export_format="GLB", use_selection=True,
                          export_animations=False, export_yup=True, export_apply=False)
bpy.ops.export_scene.fbx(filepath=str(FOLDER / (NAME + ".fbx")), use_selection=True, object_types={"ARMATURE", "MESH"},
                         add_leaf_bones=False, bake_anim=False, axis_forward="-Z", axis_up="Y", apply_unit_scale=True,
                         global_scale=1, path_mode="COPY", embed_textures=True)

# Export editable mesh data independently of the importer so the Studio path
# can preserve bone weights and validate the exact uploaded mesh topology.
mesh = body.data
mesh.calc_loop_triangles()
bone_names = list(joints)
bone_data = []
for name in bone_names:
    bone = rig.data.bones[name]
    matrix = INVERSE @ bone.matrix_local @ CONVERT
    bone_data.append({"name": name, "parent": bone.parent.name if bone.parent else None,
                      "matrix": [matrix[r][c] for r in range(3) for c in range(4)]})
vertex_data = []
for v in mesh.vertices:
    pos = INVERSE @ v.co
    groups = [(body.vertex_groups[g.group].name, g.weight) for g in v.groups if g.weight > .00001]
    total = sum(w for _, w in groups)
    assert total > 0 and len(groups) <= 4
    vertex_data.append({"position": list(pos), "bones": [bone_names.index(n) + 1 for n, _ in groups],
                        "weights": [w / total for _, w in groups]})
triangle_data = []
for tri in mesh.loop_triangles:
    corners = []
    for loop in tri.loops:
        lp = mesh.loops[loop]
        normal = INVERSE.to_3x3() @ lp.normal
        uv = mesh.uv_layers.active.data[loop].uv
        corners.append({"vertex": lp.vertex_index + 1, "normal": list(normal), "uv": [uv.x, 1 - uv.y]})
    triangle_data.append(corners)
payload = {"name": NAME, "size": spec["size"], "bones": bone_data, "vertices": vertex_data, "triangles": triangle_data}
(FOLDER / "skinned-mesh.json").write_text(json.dumps(payload, separators=(",", ":")))
(FOLDER / "blender-validation.json").write_text(json.dumps({"name": NAME, "parts": geometry_report,
    "triangles": len(triangle_data), "bones": len(bone_data), "vertices": len(vertex_data), "size": spec["size"],
    "textureResolution": 1024, "allVerticesWeighted": True, "status": "awaiting Studio import and deformation inspection"}, indent=2))
print("GUARDIAN_BAKE_COMPLETE", NAME, len(triangle_data), "triangles", len(bone_data), "bones")
