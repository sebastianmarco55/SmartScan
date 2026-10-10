-- Puts LostCube's two modules into the game (ReplicatedStorage.LostCube):
--   VFX    - plays the effects in the game (client)
--   Editor - the same editing functions the plugin uses; Claude calls it through Studio
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Installer = {}

local version -- the plugin's own version (Editor.VERSION): read once, status() runs on every redraw of two tabs

local function source()
	local editor = script.Parent.Editor
	version = require(editor).VERSION
	return editor, editor.VFX, version
end

local function v(inst)
	return inst and (inst:GetAttribute("LC_Version") or "?") or nil
end

function Installer.status()
	if not version then
		source()
	end
	local root = ReplicatedStorage:FindFirstChild("LostCube")
	local editor = root and root:FindFirstChild("Editor")
	local vfx = root and root:FindFirstChild("VFX")
	return {
		version = version,
		editor = v(editor),
		vfx = v(vfx),
		ok = v(editor) == version and v(vfx) == version,
	}
end

function Installer.install()
	local editorSource, vfxSource, installing = source()
	local ok, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: instalare module")
	local done, err = pcall(function() -- (everything that edits the place is inside: an error cannot leave the recording open)
		local root = ReplicatedStorage:FindFirstChild("LostCube")
		if not root then
			root = Instance.new("Folder")
			root.Name = "LostCube"
			root.Parent = ReplicatedStorage
		end
		if not root:FindFirstChild("Effects") then
			local effects = Instance.new("Folder")
			effects.Name = "Effects"
			effects.Parent = root
		end
		for _, pair in { { "VFX", vfxSource }, { "Editor", editorSource } } do
			local old = root:FindFirstChild(pair[1])
			if old then
				old:Destroy()
			end
			local copy = pair[2]:Clone()
			for _, child in copy:GetChildren() do
				child:Destroy() -- the game's Editor uses the VFX next to it
			end
			copy.Name = pair[1]
			copy:SetAttribute("LC_Version", installing)
			copy.Parent = root
		end
	end)
	if ok and id then
		-- a failed install is rolled back instead of leaving a half-written LostCube folder (and an open recording)
		pcall(ChangeHistoryService.FinishRecording, ChangeHistoryService, id,
			done and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if not done then
		error(err, 0)
	end
	return Installer.status()
end

return Installer
