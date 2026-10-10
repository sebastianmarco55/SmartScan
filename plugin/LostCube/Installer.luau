-- Puts LostCube's two modules into the game (ReplicatedStorage.LostCube):
--   VFX    - plays the effects in the game (client)
--   Editor - the same editing functions the plugin uses; Claude calls it through Studio
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local Installer = {}

local function source()
	local editor = script.Parent.Editor
	return editor, editor.VFX, require(editor).VERSION
end

function Installer.status()
	local _, _, version = source()
	local root = ReplicatedStorage:FindFirstChild("LostCube")
	local editor = root and root:FindFirstChild("Editor")
	local vfx = root and root:FindFirstChild("VFX")
	local function v(inst)
		return inst and (inst:GetAttribute("LC_Version") or "?") or nil
	end
	return {
		version = version,
		editor = v(editor),
		vfx = v(vfx),
		ok = v(editor) == version and v(vfx) == version,
	}
end

function Installer.install()
	local editorSource, vfxSource, version = source()
	local ok, id = pcall(ChangeHistoryService.TryBeginRecording, ChangeHistoryService, "LostCube: instalare module")
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
	local done, err = pcall(function()
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
			copy:SetAttribute("LC_Version", version)
			copy.Parent = root
		end
	end)
	if ok and id then
		-- a failed install is rolled back instead of leaving a half-written LostCube folder (and an open recording)
		ChangeHistoryService:FinishRecording(id, done and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel)
	end
	if not done then
		error(err, 0)
	end
	return Installer.status()
end

return Installer
