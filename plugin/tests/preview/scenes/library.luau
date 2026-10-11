-- Library tab: the real LibraryPanel + AnimLibrary (the real catalogue of Roblox animations) with a pack opened and an animation chosen
-- and playing (a still track at 1.1 s).
local LC, P, ARGS, common = ...
local S = LC.run("tests/preview/scenes/game.luau", nil, LC, P, ARGS, common)

local scene = S.scene{
	before = function(sc)
		local M, env = sc.M, sc.env
		local new, Enum = M.new, env.Enum
		local V3 = M.V3
		M.methods.GetProductInfoAsync = function(_, id)
			return { Name = "Animation " .. id, Creator = { Name = "Roblox", CreatorType = "User", CreatorTargetId = 1 }, AssetTypeId = 24 }
		end
		if ARGS.state ~= "empty" then
			local rig = new("Model", "LostCube Dummy R15", {}, {
				new("Humanoid", "Humanoid", { RigType = Enum.HumanoidRigType.R15, HipHeight = 2 }),
				new("Part", "HumanoidRootPart", { Anchored = false, Size = V3(2, 2, 1) }),
			})
			rig.Parent = M.workspace
			sc.demo = { rig = rig }
		end
	end,
}
local panel = scene.app:panel("Library")
if ARGS.state ~= "empty" then
	local AnimLibrary = scene.tree.load("AnimLibrary")
	local groups = AnimLibrary.groups()
	local pack
	for _, g in groups do
		if g.kind == "pack" and g.rig == "R15" and #g.entries > 3 then
			pack = g
			break
		end
	end
	pack = pack or groups[1]
	panel.rig = scene.demo.rig
	panel.openGroup = pack.key
	panel.sel = pack.entries[2] or pack.entries[1]
	panel.owner[panel.sel.id] = { ok = true, name = panel.sel.label, creator = "Roblox", roblox = true, assetType = 24 }
	-- the animation playing (a still track: the scene does not step animations)
	panel.track = { TimePosition = 1.1, Length = 2.4, IsPlaying = true, Looped = true }
	panel.animator = { StepAnimations = function() end }
	panel.playing = true
end
return scene
