--!strict
-- Studio-only, temporary review fixtures on already-free pads. Never move an
-- existing item. Saves for the tester are withheld while fixtures exist, and
-- the exact pre-review profile is restored before saving resumes.
local RunService=game:GetService("RunService")
local Players=game:GetService("Players")
local HttpService=game:GetService("HttpService")
local DataService=require(script.Parent.DataService)
local BaseService=require(script.Parent.BaseService)
local EconomyService=require(script.Parent.EconomyService)
local StateService=require(script.Parent.StateService)
local IndexService=require(script.Parent.IndexService)
local Review={}
local active: any=nil
local installed=false

local function restore(persist: boolean): any
	local session=active
	if not session then return {active=false} end
	local profile=DataService.get(session.player)
	if not profile then error("Review profile disappeared before restoration") end
	-- Replace fields on the original profile object, which the services retain.
	table.clear(profile)
	for key,value in session.snapshot do (profile :: any)[key]=value end
	active=nil
	DataService.save=session.save
	session.player:SetAttribute("ItemArtReviewActive",nil)
	EconomyService.recalculate(session.player)
	BaseService.rebuildDisplays(session.player)
	IndexService.push(session.player)
	StateService.pushNow(session.player)
	local saved=if persist and DataService.isPersistent() then DataService.save(session.player) else nil
	return {restored=true,saved=saved,displays=#profile.DisplayItems,stored=#profile.Inventory,
		speedPower=profile.SpeedPower,blockedSaves=session.blockedSaves}
end

function Review.run(player: Player, action: string?): any
	assert(RunService:IsStudio(),"Item art review is Studio-only")
	if action=="restore" then
		assert(not active or active.player==player,"Another tester owns the review")
		return restore(true)
	end
	if action=="vaseUnknown" then
		assert(active and active.player==player,"Begin a protected review first")
		local profile=assert(DataService.get(player),"No profile")
		profile.Index.Museum_AncientVase=nil
		IndexService.push(player)
		return {temporaryUndiscovered="Museum_AncientVase"}
	end
	if action=="begin" then
		assert(not active,"Restore the existing review before beginning another")
		local profile=assert(DataService.get(player),"No profile")
		local free=BaseService.freeSlots(player)
		assert(#free>0,"No free pad; existing items must not be moved")
		-- Finish a clean baseline save before the guard is installed.
		if DataService.isPersistent() then assert(DataService.save(player),"Baseline save failed") end
		local session={player=player,snapshot=HttpService:JSONDecode(HttpService:JSONEncode(profile)),
			save=DataService.save,blockedSaves=0}
		active=session
		DataService.save=function(target: Player): boolean
			if active==session and target==player then
				session.blockedSaves+=1
				return false -- never report a withheld write as a successful save
			end
			return session.save(target)
		end
		player:SetAttribute("ItemArtReviewActive",true)
		if not installed then
			installed=true
			DataService.onBeforeRelease(function(leaving)
				if active and active.player==leaving then restore(false) end
			end)
			game:BindToClose(function() if active then restore(true) end end)
		end
		-- A forgotten review is bounded even if its external caller disconnects.
		task.delay(600,function()
			if active==session then
				local ok,err=pcall(restore,true)
				if not ok then warn("[ItemArtReview] restoration failed: "..tostring(err)) end
			end
		end)
		return {active=true,freeSlots=free,displays=#profile.DisplayItems,stored=#profile.Inventory,timeout=600}
	end
	return {active=active~=nil,blockedSaves=active and active.blockedSaves or 0}
end

return Review
