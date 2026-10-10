local RunService = game:GetService("RunService")
local Foo = game:GetService("NotAService")
local p = Instance.new("Part")
p.Sise = Vector3.new(1,1,1)
p.Position = Enum.Material.Neon
p.ClassName = "x"
local h = Instance.new("Humanoid")
h:LoadAnimation(nil)
local b = UI.make("TextButton", { Text = "x", TextColour = Color3.new(), Font = Enum.Font.NotAFont, AutoButtonColor = 1 })
RunService:BindToRenderStepp("x")
local x = Instance.new("Players")
for _, d in workspace:GetChildren() do
	if d:IsA("ParticleEmitter") then
		d.Ratee = 3
	elseif d:IsA("Trail") then
		d.Lifetime = 2
		d.Speed = 3
	end
	d.Whatever = 1
end
local q = (p :: BasePart).Sizee
game:HttpGet("x")
local s = workspace:FindPartOnRay()
