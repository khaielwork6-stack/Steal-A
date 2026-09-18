"""Apply the measured landscape layout corrections without changing line endings."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
def edit(name, callback):
    path = ROOT / name
    raw = path.read_bytes()
    ending = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode().replace("\r\n", "\n")
    path.write_bytes(callback(text).replace("\n", ending).encode())

def index(text):
    text = text.replace("local IndexController = {}", 'local PanelStyle = require(ReplicatedStorage.Shared.Util.PanelStyle)\nlocal ClipSafe = require(ReplicatedStorage.Shared.Util.ClipSafe)\n\nlocal IndexController = {}')
    text = text.replace('local strip = Instance.new("Frame")\n\tstrip.Name = "ZoneTabs"', 'local strip = Instance.new("ScrollingFrame")\n\tstrip.Name = "ZoneTabs"\n\tstrip.BorderSizePixel = 0\n\tstrip.CanvasSize = UDim2.new()\n\tstrip.AutomaticCanvasSize = Enum.AutomaticSize.X\n\tstrip.ScrollingDirection = Enum.ScrollingDirection.X\n\tstrip.ScrollBarThickness = 3')
    start = text.index("local function buildTabs")
    end = text.index("local function buildClaimBar", start)
    block = text[start:end].replace("Enum.HorizontalAlignment.Center", "Enum.HorizontalAlignment.Left")
    text = text[:start] + block + text[end:]
    needle = "\n\treturn true\nend\n\n--- A small count"
    new = '''
	PanelStyle.window(frame, 900, 620)
	local function fitIndex()
		local factor = ClipSafe.scaleChain(frame)
		local h = frame.AbsoluteSize.Y / factor
		local topFrame = frame:FindFirstChild("Top")
		local headerHeight = if topFrame and topFrame:IsA("GuiObject") then topFrame.AbsoluteSize.Y / factor else 52 / factor
		local features = frame:FindFirstChild("Features")
		if features and features:IsA("GuiObject") then features.Visible = false end
		local strip = frame:FindFirstChild("ZoneTabs")
		if strip and strip:IsA("ScrollingFrame") then
			strip.AnchorPoint = Vector2.new(0.5, 0)
			strip.Position = UDim2.new(0.5, 0, 0, headerHeight + 4 / factor)
			strip.Size = UDim2.new(0.94, 0, 0, 50 / factor)
			for _, tab in strip:GetChildren() do
				if tab:IsA("GuiButton") then tab.Size = UDim2.fromOffset(48 / factor, 48 / factor) end
			end
		end
		header.Position = UDim2.new(0.5, 0, 0, headerHeight + 69 / factor)
		header.Size = UDim2.new(0.94, 0, 0, 24 / factor)
		list.AnchorPoint = Vector2.new(0.5, 0)
		list.Position = UDim2.new(0.5, 0, 0, headerHeight + 84 / factor)
		list.Size = UDim2.new(0.94, 0, 0, math.max(50 / factor, h - headerHeight - 148 / factor))
		list.ClipsDescendants = true
		if grid then
			grid.CellSize = UDim2.new(0.225, 0, 0, 112 / factor)
			grid.CellPadding = UDim2.new(0.03, 0, 0, 8 / factor)
		end
		if claimButton then
			claimButton.AnchorPoint = Vector2.new(0.5, 1)
			claimButton.Position = UDim2.new(0.5, 0, 1, -8 / factor)
			claimButton.Size = UDim2.new(0.94, 0, 0, 48 / factor)
		end
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitIndex)
	frame:GetPropertyChangedSignal("Visible"):Connect(fitIndex)
	task.defer(fitIndex)
	return true
end

--- A small count'''
    assert needle in text
    return text.replace(needle, "\n" + new, 1)

edit("src/client/Controllers/IndexController.luau", index)
edit("src/client/Controllers/InventoryController.luau", lambda t: t.replace('if portrait then 0.62 else 0.30, 0, 0, 44 / factor', 'if portrait then 0.62 else 0.30, 0, 0, 48 / factor'))
edit("src/client/Controllers/AutoRevealPassCard.luau", lambda t: t.replace('built.Name = "Card_AutoReveal"', 'require(ReplicatedStorage.Shared.Util.PanelStyle).productCard(built)\n\tbuilt.Name = "Card_AutoReveal"'))
def base(text):
    needle = '\tpage = holder'
    insert = '''
	local function fitTabs()
		local factor = ClipSafe.scaleChain(scroll)
		bar.Size = UDim2.new(0.94, 0, 0, 48 / factor)
		minimum.MinSize = Vector2.new(0, 48 / factor)
		for _, body in { card, holder } do
			body.Position = UDim2.new(0.5, 0, 0, 56 / factor)
			body.Size = UDim2.new(0.97, 0, 1, -60 / factor)
		end
	end
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitTabs)
	panel:GetPropertyChangedSignal("Visible"):Connect(fitTabs)
	task.defer(fitTabs)
'''
    assert needle in text
    text = text.replace(needle, needle + "\n" + insert, 1)
    return text.replace('activeTab ~= "Base" or Effects.isReduced()', 'activeTab ~= "Base" or Effects.isReduced() or Effects.isLowGraphics()')
edit("src/client/Controllers/BaseThemeController.luau", base)
edit("src/shared/Util/PanelStyle.luau", lambda t: t.replace('close.Size = UDim2.fromOffset(48 / factor, 48 / factor)', 'close.Active = true\n\t\t\t\tclose.Size = UDim2.fromOffset(48 / factor, 48 / factor)'))
print("Applied Index, Upgrade tabs, Storage action and pass-card landscape corrections.")
