--!strict
--[[
	PartKit
	The small part/folder factory shared by the source-built world:
	MapBuilder, MuseumGallery and MuseumExhibits. Server only - the map is
	generated at boot and replicated as ordinary instances.

	WHY IT EXISTS. `folder()` was written twice (MapBuilder and MuseumGallery),
	the museum's GOLD/DARK were declared in both MuseumGallery and
	MuseumExhibits, and MuseumGallery's `bar` and MuseumExhibits' `rod` were the
	same "part stretched from A to B" arithmetic. One copy each lives here so a
	colour or a flag cannot drift between the rooms and their exhibits.

	WHAT A DECOR PART IS. Every museum decoration is Anchored, CanCollide=false,
	CanTouch=false, CanQuery=false and CastShadow=false. MuseumTests asserts the
	first four for every part under a room's Decorations; CastShadow=false
	keeps ~5k decorative parts out of the shadow pass. Structure (walls,
	ceilings) opts back in explicitly where it is built.
]]

local PartKit = {}

--- The museum's shared trim colours (gold fittings, near-black metal).
PartKit.GOLD = Color3.fromRGB(202, 157, 65)
PartKit.DARK = Color3.fromRGB(24, 29, 38)

--- A named Folder under `parent`. Name is set before Parent so a listener on
--- the parent never sees an unnamed "Folder" arrive.
function PartKit.folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

--- One museum decoration part: anchored, inert to physics, queries and
--- touches, shadowless, with the classic studs/inlet surfaces the museum's
--- toy look is built from. Plastic parts get studs on the sides as well.
function PartKit.decor(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name, p.Size, p.CFrame = name, size, cf
	p.Color, p.Material = color, material or Enum.Material.Plastic
	p.Anchored, p.CanCollide, p.CanTouch, p.CanQuery = true, false, false, false
	p.CastShadow = false
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Inlet
	p.Parent = parent
	if p.Material == Enum.Material.Plastic then
		p.FrontSurface, p.BackSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Studs
		p.LeftSurface, p.RightSurface = Enum.SurfaceType.Studs, Enum.SurfaceType.Studs
	end
	return p
end

--- The size and frame of a square-section beam of `width` running from `a`
--- to `b` (its long axis is local Z). Callers wrap it in their own part
--- factory: MuseumGallery's rope/laser bars and MuseumExhibits' scaled rods
--- both use this same arithmetic.
function PartKit.span(a: Vector3, b: Vector3, width: number): (Vector3, CFrame)
	return Vector3.new(width, width, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b)
end

--- A decor beam from `a` to `b`.
function PartKit.bar(
	parent: Instance,
	name: string,
	a: Vector3,
	b: Vector3,
	width: number,
	color: Color3,
	material: Enum.Material?
): Part
	local size, cf = PartKit.span(a, b, width)
	return PartKit.decor(parent, name, size, cf, color, material)
end

return PartKit
