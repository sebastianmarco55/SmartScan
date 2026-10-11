-- Anim tab: the real AnimPanel + AnimGen on the DataModel mock: a rig, KeyframeSequences with poses and markers, a chosen clip
-- that is playing (a still track at 0.42 s), a generated animation chosen.
local LC, P, ARGS, common = ...
local S = LC.run("tests/preview/scenes/game.luau", nil, LC, P, ARGS, common)

local scene = S.scene{
	before = function(sc)
		local M, env = sc.M, sc.env
		local new, Enum = M.new, env.Enum
		local V3 = M.V3
		-- what the panels call on KeyframeSequences (the base mock has no such methods)
		M.methods.GetKeyframes = function(o)
			local out = {}
			for _, c in rawget(o, "_data")._children do
				if c.ClassName == "Keyframe" then table.insert(out, c) end
			end
			return out
		end
		M.methods.GetMarkers = function(o)
			local out = {}
			for _, c in rawget(o, "_data")._children do
				if c.ClassName == "KeyframeMarker" then table.insert(out, c) end
			end
			return out
		end
		local function pose(name, style)
			return new("Pose", name, { EasingStyle = Enum.PoseEasingStyle[style or "Cubic"], EasingDirection = Enum.PoseEasingDirection.Out,
				Weight = 1 })
		end
		local function clip(name, parent, frames, looped)
			local ks = new("KeyframeSequence", name, { Loop = looped == true, Priority = Enum.AnimationPriority.Action })
			for _, f in frames do
				local kids = { pose("HumanoidRootPart", f.style) }
				for _, m in f.markers or {} do
					table.insert(kids, new("KeyframeMarker", m, { Value = "" }))
				end
				new("Keyframe", f.name, { Time = f.t }, kids).Parent = ks
			end
			ks.Parent = parent
			return ks
		end
		local RS, SS, ws = M.services.ReplicatedStorage, M.services.ServerStorage, M.workspace
		local saves = new("Folder", "RBX_ANIMSAVES")
		saves.Parent = SS
		local punch = clip("Lovitură", new("Folder", "Combat", {}, {}), {
			{ name = "Start", t = 0 }, { name = "Wind-up", t = 0.2, style = "Cubic" }, { name = "Hit", t = 0.35, style = "Bounce", markers = { "Hit" } },
			{ name = "Recover", t = 0.6, style = "Linear" }, { name = "End", t = 0.8 } })
		rawget(punch, "_data").Parent.Parent = RS
		local rig
		rig = new("Model", "LostCube Dummy R15", {}, {
			new("Humanoid", "Humanoid", { RigType = Enum.HumanoidRigType.R15, HipHeight = 2 }),
			new("Part", "HumanoidRootPart", { Anchored = false, Size = V3(2, 2, 1) }),
			new("Part", "UpperTorso", {}), new("Part", "Head", {}),
		})
		rig.Parent = ws
		local sub = new("Folder", "Locomotion")
		sub.Parent = RS
		clip("Mers", sub, { { name = "A", t = 0 }, { name = "B", t = 0.5 }, { name = "C", t = 1 } }, true)
		clip("Salt", sub, { { name = "A", t = 0 }, { name = "B", t = 0.4 } })
		clip("Teleport", RS, { { name = "A", t = 0 }, { name = "B", t = 0.3, markers = { "Flash" } }, { name = "C", t = 0.9 } })
		clip("Vindecare", saves, { { name = "A", t = 0 }, { name = "B", t = 1.2 } })
		sc.demo = { rig = rig, punch = punch }
		sc.mocks.AI = nil
	end,
}
local panel = scene.app:panel("Anim")
if ARGS.state ~= "empty" then
	panel:findClips()
	panel.rig = scene.demo.rig
	panel.clip = scene.demo.punch
	panel.picked = {}
	for _, kf in panel:keyframes() do
		if kf.Name == "Hit" or kf.Name == "Wind-up" then
			panel.picked[kf] = true
		end
	end
	-- a generated animation chosen and the clip playing (a still track: the scene does not step animations)
	panel.genKey = "heavy_punch"
	panel.track = { TimePosition = 0.42, Length = 0.8, IsPlaying = true, Looped = true }
	panel.playing = true
end
return scene
