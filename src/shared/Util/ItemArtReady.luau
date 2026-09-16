--!strict
-- Replication may deliver a Model before all its parts. Scaling a partial
-- arrival caches different original scales for its early and late parts.
-- Only source-authored art declares a count; imports retain existing behavior.
local Ready={}
function Ready.check(model: Model): boolean
	local expected=model:GetAttribute("ItemArtPartCount")
	if type(expected)~="number" then return true end
	local count=0
	for _,d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("ItemArtShadow")~=nil then count+=1 end
	end
	return count>=expected
end
function Ready.waitFor(model: Model, seconds: number): boolean
	local deadline=os.clock()+seconds
	while model.Parent and not Ready.check(model) and os.clock()<deadline do task.wait() end
	return model.Parent~=nil and Ready.check(model)
end
return Ready
