--!strict
--[[
	PivotBatch
	Moves many models in ONE workspace:BulkMoveTo call per frame instead of a
	Model:PivotTo per model.

	HOW A MODEL IS MOVED
	Each model gets a Cache: its BaseParts and each part's offset from the
	model pivot. Moving the model to `target` is then, per part,
	    part.CFrame = target * offset
	which is exactly what PivotTo does, so a multi-part model stays rigid.

	WHEN THE CACHE IS REBUILT
	The offsets are only valid while the model's shape is unchanged, so the
	cache is recaptured (from the live parts, against the live pivot) when:
	  * a descendant is added or removed (the server re-dressed it),
	  * the model's scale changed (DisplayFx's pop-in and the hatch reveal
	    call ScaleTo, which moves parts relative to the pivot),
	  * the caller marks it dirty.
	Sub-parts that another animator moves relative to the model (the
	ItemArtMotion joints) are carried along at their captured offset and then
	re-posed by that animator right after the flush, in the same frame.

	WHEN IT FALLS BACK TO PivotTo
	A model with no PrimaryPart keeps its pivot in WorldPivot, which a bulk
	move does not update - the next GetPivot would be stale. Those models are
	moved with PivotTo, as before.
]]

local PivotBatch = {}

export type Cache = {
	parts: { BasePart },
	offsets: { CFrame },
	scale: number,
	dirty: boolean,
	connections: { RBXScriptConnection },
}

export type Batch = {
	parts: { BasePart },
	cframes: { CFrame },
}

function PivotBatch.newBatch(): Batch
	return { parts = {}, cframes = {} }
end

function PivotBatch.newCache(model: Model): Cache
	local cache: Cache = {
		parts = {},
		offsets = {},
		scale = -1,
		dirty = true,
		connections = {},
	}
	local function markDirty()
		cache.dirty = true
	end
	table.insert(cache.connections, model.DescendantAdded:Connect(markDirty))
	table.insert(cache.connections, model.DescendantRemoving:Connect(markDirty))
	return cache
end

function PivotBatch.release(cache: Cache)
	for _, connection in cache.connections do
		connection:Disconnect()
	end
	table.clear(cache.connections)
	table.clear(cache.parts)
	table.clear(cache.offsets)
end

local function capture(model: Model, cache: Cache, scale: number)
	table.clear(cache.parts)
	table.clear(cache.offsets)
	local pivot = model:GetPivot()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(cache.parts, descendant)
			table.insert(cache.offsets, pivot:ToObjectSpace(descendant.CFrame))
		end
	end
	cache.scale = scale
	cache.dirty = false
end

--- Queues `model` to be moved so its pivot lands on `target`. Moves it
--- immediately (PivotTo) when it cannot be batched.
function PivotBatch.queue(batch: Batch, model: Model, cache: Cache, target: CFrame)
	if not model.PrimaryPart then
		model:PivotTo(target)
		return
	end
	local scale = model:GetScale()
	if cache.dirty or scale ~= cache.scale then
		capture(model, cache, scale)
	end
	local parts, cframes = batch.parts, batch.cframes
	local offsets = cache.offsets
	for i, part in cache.parts do
		table.insert(parts, part)
		table.insert(cframes, target * offsets[i])
	end
end

--- Applies everything queued since the last flush. Returns false (and the
--- caller should mark its caches dirty) if the engine refused the move.
function PivotBatch.flush(batch: Batch): boolean
	local parts = batch.parts
	if #parts == 0 then
		return true
	end
	local ok, err = pcall(function()
		workspace:BulkMoveTo(parts, batch.cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end)
	-- Cleared, not replaced: the arrays keep their capacity frame to frame.
	table.clear(parts)
	table.clear(batch.cframes)
	if not ok then
		warn(`[PivotBatch] BulkMoveTo failed: {err}`)
	end
	return ok
end

return PivotBatch
