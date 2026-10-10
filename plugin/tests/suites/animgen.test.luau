-- AnimGen: the pure math of the procedural animation generator (matrices, readable joint axes, mirroring, R6 joint
-- axes, leg IK) and a forward-kinematics check of every generated animation on fake R15 / R6 rigs: strictly increasing
-- keyframes, orthonormal rotations, closed loops, markers kept, feet on the floor, R6 following R15, speed / intensity /
-- mirror options. The real AnimGen needs no Roblox globals to compute poses.
local LC = ...
local t = LC.kit.new("animgen")
local function check(cond, msg)
	t.check(cond, msg)
end

local tree = LC.modtree.new{}
local AnimGen = tree.load("AnimGen")
local M = AnimGen.M
local function near(a, b, eps)
	return math.abs(a - b) < (eps or 1e-6)
end
local function vnear(a, b, eps)
	return near(a[1], b[1], eps) and near(a[2], b[2], eps) and near(a[3], b[3], eps)
end
local function vstr(v)
	return string.format("(%.3f, %.3f, %.3f)", v[1], v[2], v[3])
end
local function mnear(a, b, eps)
	for i = 1, 9 do
		if not near(a[i], b[i], eps) then
			return false
		end
	end
	return true
end
local function orthonormal(m)
	return mnear(M.mul(m, M.transpose(m)), M.IDENTITY, 1e-9)
end
local function dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function norm(a)
	local l = math.sqrt(dot(a, a))
	return { a[1] / l, a[2] / l, a[3] / l }
end
local function sub(a, b)
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end
local function angleBetween(a, b)
	return math.deg(math.acos(math.clamp(dot(norm(a), norm(b)), -1, 1)))
end

local DOWN, UP, FWD, RIGHT = { 0, -1, 0 }, { 0, 1, 0 }, { 0, 0, -1 }, { 1, 0, 0 }

-- ---------------------------------------------------------------- matrices
check(mnear(M.eulerYXZ(0, 0, 0), M.IDENTITY), "euler zero = identity")
check(orthonormal(M.eulerYXZ(0.3, -1.2, 2.1)), "euler orthonormal")
check(vnear(M.apply(M.rx(math.pi / 2), { 0, 1, 0 }), { 0, 0, 1 }), "rx right-handed")
check(vnear(M.apply(M.ry(math.pi / 2), { 0, 0, 1 }), { 1, 0, 0 }), "ry right-handed")
check(vnear(M.apply(M.rz(math.pi / 2), { 1, 0, 0 }), { 0, 1, 0 }), "rz right-handed")
-- eulerYXZ = Ry * Rx * Rz
check(mnear(M.eulerYXZ(0.4, 0.5, 0.6), M.mul(M.ry(0.5), M.mul(M.rx(0.4), M.rz(0.6)))), "eulerYXZ order")

-- ---------------------------------------------------------------- readable axes
local function dir(joint, v, rest)
	return M.apply(AnimGen.jointRotation(joint, v), rest)
end
check(vnear(dir("shoulderR", { 90, 0, 0 }, DOWN), FWD), "right arm p90 points forward " .. vstr(dir("shoulderR", { 90, 0, 0 }, DOWN)))
check(vnear(dir("shoulderL", { 90, 0, 0 }, DOWN), FWD), "left arm p90 points forward")
check(vnear(dir("shoulderR", { 180, 0, 0 }, DOWN), UP), "right arm p180 points up")
check(vnear(dir("shoulderR", { 0, 0, 90 }, DOWN), RIGHT), "right arm r90 points right (outward)")
check(vnear(dir("shoulderL", { 0, 0, 90 }, DOWN), { -1, 0, 0 }), "left arm r90 points left (outward)")
check(dir("shoulderR", { 90, 30, 0 }, DOWN)[1] > 0.4, "right arm forward + y swings right (outward)")
check(dir("shoulderL", { 90, 30, 0 }, DOWN)[1] < -0.4, "left arm forward + y swings left (outward)")
check(dir("waist", { 0, 30, 0 }, FWD)[1] > 0.4, "waist y+ turns right")
check(dir("waist", { 30, 0, 0 }, UP)[3] < -0.4, "waist p+ leans forward")
check(dir("waist", { 0, 0, 20 }, UP)[1] > 0.3, "waist r+ tilts right")
check(dir("neck", { 20, 0, 0 }, FWD)[2] < -0.3, "neck p+ looks down")
check(vnear(dir("kneeR", { 90, 0, 0 }, DOWN), { 0, 0, 1 }), "knee bend sends the shin back")
check(vnear(dir("elbowR", { 90, 0, 0 }, DOWN), FWD), "elbow bend brings the forearm forward")
check(dir("ankleR", { 30, 0, 0 }, FWD)[2] > 0.4, "ankle p+ = toes up")
check(dir("hipR", { 0, 30, 0 }, FWD)[1] > 0.4, "hip y+ = right toes outward")
check(dir("hipL", { 0, 30, 0 }, FWD)[1] < -0.4, "hip y+ = left toes outward")

-- ---------------------------------------------------------------- mirroring
local MIR = { -1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mirrored(m)
	return M.mul(MIR, M.mul(m, MIR))
end
for _, v in { { 37, 12, -50 }, { -20, 80, 33 }, { 150, -40, 10 } } do
	check(mnear(AnimGen.jointRotation("shoulderL", v), mirrored(AnimGen.jointRotation("shoulderR", v)), 1e-9),
		"left limb = mirror image of right limb for " .. vstr(v))
	check(mnear(AnimGen.jointRotation("waist", { v[1], -v[2], -v[3] }), mirrored(AnimGen.jointRotation("waist", v)), 1e-9),
		"midline mirror negates yaw/roll")
end
check(AnimGen.mirrorName("shoulderR") == "shoulderL" and AnimGen.mirrorName("kneeL") == "kneeR"
	and AnimGen.mirrorName("root") == "root", "mirrorName")

-- ---------------------------------------------------------------- R6 joint axes (classic Animate: SetDesiredAngle rotates C0 about Z)
local function r6Transform(joint, v)
	local Q = AnimGen.RIGS.R6.c0[joint == "shoulderR" and "Right Arm" or joint == "shoulderL" and "Left Arm"
		or joint == "neck" and "Head" or joint == "hipR" and "Right Leg" or "Left Leg"]
	return M.conjugate(Q, { r = AnimGen.jointRotation(joint, v), p = { 0, 0, 0 } }).r
end
check(mnear(r6Transform("shoulderR", { 90, 0, 0 }), M.rz(math.pi / 2), 1e-9), "R6 right shoulder forward = Angles(0,0,+90)")
check(mnear(r6Transform("shoulderL", { 90, 0, 0 }), M.rz(-math.pi / 2), 1e-9), "R6 left shoulder forward = Angles(0,0,-90)")
check(mnear(r6Transform("hipR", { 30, 0, 0 }), M.rz(math.rad(30)), 1e-9), "R6 right hip forward = +Z")
local neckYaw = r6Transform("neck", { 0, 40, 0 })
check(near(neckYaw[9], 1, 1e-9), "R6 neck yaw is about the joint Z axis")

-- ---------------------------------------------------------------- IK
do
	local hip, bend = AnimGen.legIK(0, 1.76, 0.88, 0.88)
	check(math.abs(hip) < 1.5 and math.abs(bend) < 3, "IK straight leg")
	hip, bend = AnimGen.legIK(0, 1.2, 0.88, 0.88)
	check(hip > 0 and bend > 0 and near(hip * 2, bend, 1e-6), "IK crouch: knee forward, equal segments")
	-- FK back
	local h, k = math.rad(hip), math.rad(bend)
	local ankle = { 0.88 * math.sin(h) + 0.88 * math.sin(h - k), -(0.88 * math.cos(h) + 0.88 * math.cos(h - k)) }
	check(near(ankle[1], 0, 1e-6) and near(ankle[2], -1.2, 1e-6), "IK reaches its target")
	hip, bend = AnimGen.legIK(0.5, 1.4, 0.9, 0.85)
	h, k = math.rad(hip), math.rad(bend)
	ankle = { 0.9 * math.sin(h) + 0.85 * math.sin(h - k), -(0.9 * math.cos(h) + 0.85 * math.cos(h - k)) }
	check(near(ankle[1], 0.5, 1e-6) and near(ankle[2], -1.4, 1e-6), "IK unequal segments reaches target")
end

-- ---------------------------------------------------------------- fake rigs for FK
local function T(p, r)
	return { r = r or M.IDENTITY, p = p or { 0, 0, 0 } }
end
local function compose(a, b)
	return { r = M.mul(a.r, b.r), p = { a.p[1] + M.apply(a.r, b.p)[1], a.p[2] + M.apply(a.r, b.p)[2], a.p[3] + M.apply(a.r, b.p)[3] } }
end
local function inverse(a)
	local rt = M.transpose(a.r)
	local p = M.apply(rt, a.p)
	return { r = rt, p = { -p[1], -p[2], -p[3] } }
end
local R6Q = AnimGen.RIGS.R6.c0
local RIGS = {
	R15 = {
		hrp = T({ 0, 3, 0 }),
		joints = {
			LowerTorso = { T({ 0, -0.65, 0 }), T({ 0, 0.1, 0 }), { 2, 0.4, 1 } },
			UpperTorso = { T({ 0, 0.2, 0 }), T({ 0, -0.8, 0 }), { 2, 1.6, 1 } },
			Head = { T({ 0, 0.8, 0 }), T({ 0, -0.6, 0 }), { 1.2, 1.2, 1.2 } },
			RightUpperArm = { T({ 1, 0.55, 0 }), T({ -0.5, 0.4, 0 }), { 1, 1.17, 1 } },
			RightLowerArm = { T({ 0, -0.42, 0 }), T({ 0, 0.3, 0 }), { 1, 1.05, 1 } },
			RightHand = { T({ 0, -0.45, 0 }), T({ 0, 0.12, 0 }), { 1, 0.3, 1 } },
			LeftUpperArm = { T({ -1, 0.55, 0 }), T({ 0.5, 0.4, 0 }), { 1, 1.17, 1 } },
			LeftLowerArm = { T({ 0, -0.42, 0 }), T({ 0, 0.3, 0 }), { 1, 1.05, 1 } },
			LeftHand = { T({ 0, -0.45, 0 }), T({ 0, 0.12, 0 }), { 1, 0.3, 1 } },
			RightUpperLeg = { T({ 0.5, -0.27, 0 }), T({ 0, 0.45, 0 }), { 1, 1.2, 1 } },
			RightLowerLeg = { T({ 0, -0.43, 0 }), T({ 0, 0.3, 0 }), { 1, 1.1, 1 } },
			RightFoot = { T({ 0, -0.58, 0 }), T({ 0, 0.07, 0 }), { 1, 0.3, 1 } },
			LeftUpperLeg = { T({ -0.5, -0.27, 0 }), T({ 0, 0.45, 0 }), { 1, 1.2, 1 } },
			LeftLowerLeg = { T({ 0, -0.43, 0 }), T({ 0, 0.3, 0 }), { 1, 1.1, 1 } },
			LeftFoot = { T({ 0, -0.58, 0 }), T({ 0, 0.07, 0 }), { 1, 0.3, 1 } },
		},
	},
	R6 = {
		hrp = T({ 0, 3, 0 }),
		joints = {
			Torso = { T({ 0, 0, 0 }, R6Q.Torso), T({ 0, 0, 0 }, R6Q.Torso), { 2, 2, 1 } },
			Head = { T({ 0, 1, 0 }, R6Q.Head), T({ 0, -0.5, 0 }, R6Q.Head), { 2, 1, 1 } },
			["Right Arm"] = { T({ 1, 0.5, 0 }, R6Q["Right Arm"]), T({ -0.5, 0.5, 0 }, R6Q["Right Arm"]), { 1, 2, 1 } },
			["Left Arm"] = { T({ -1, 0.5, 0 }, R6Q["Left Arm"]), T({ 0.5, 0.5, 0 }, R6Q["Left Arm"]), { 1, 2, 1 } },
			["Right Leg"] = { T({ 1, -1, 0 }, R6Q["Right Leg"]), T({ 0.5, 1, 0 }, R6Q["Right Leg"]), { 1, 2, 1 } },
			["Left Leg"] = { T({ -1, -1, 0 }, R6Q["Left Leg"]), T({ -0.5, 1, 0 }, R6Q["Left Leg"]), { 1, 2, 1 } },
		},
	},
}

-- world transforms of every part for one compiled keyframe
local function fk(rigType, poses)
	local rig, parentOf = RIGS[rigType], AnimGen.RIGS[rigType].parent
	local world = { HumanoidRootPart = rig.hrp }
	local function get(part)
		if world[part] then
			return world[part]
		end
		local j = rig.joints[part]
		local tr = poses[part] or T()
		local w = compose(compose(compose(get(parentOf[part]), j[1]), tr), inverse(j[2]))
		world[part] = w
		return w
	end
	for part in rig.joints do
		get(part)
	end
	return world
end

local function lowest(rigType, world, parts)
	local y = math.huge
	for _, part in parts do
		local w, size = world[part], RIGS[rigType].joints[part][3]
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local c = M.apply(w.r, { sx * size[1] / 2, sy * size[2] / 2, sz * size[3] / 2 })
					y = math.min(y, w.p[2] + c[2])
				end
			end
		end
	end
	return y
end

-- rest pose: feet on the floor
do
	local w = fk("R15", {})
	check(near(lowest("R15", w, { "RightFoot" }), 0, 1e-6), "R15 fake rig stands on the floor")
	local hipY = compose(compose(w.LowerTorso, RIGS.R15.joints.RightUpperLeg[1]), T()).p[2]
	local ankleY = compose(w.RightLowerLeg, RIGS.R15.joints.RightFoot[1]).p[2]
	check(near(hipY - ankleY, 1.76, 1e-6), "R15 fake rig leg length matches thigh+shin")
	local pivot = compose(w.HumanoidRootPart, RIGS.R15.joints.LowerTorso[1]).p[2]
	check(near(pivot, AnimGen.RIGS.R15.rootHeight, 1e-6), "R15 fake rig root height matches default")
	w = fk("R6", {})
	check(near(lowest("R6", w, { "Right Leg" }), 0, 1e-6), "R6 fake rig stands on the floor")
end

-- ---------------------------------------------------------------- whole library
check(#AnimGen.LIST >= 16, "at least 16 animations")
local cats = {}
for _, c in AnimGen.CATEGORIES do
	cats[c] = 0
end
local seen = {}
for _, item in AnimGen.LIST do
	check(cats[item.category] ~= nil, item.key .. ": category")
	cats[item.category] = (cats[item.category] or 0) + 1
	check(not seen[item.key], "unique key " .. item.key)
	seen[item.key] = true
	check(type(item.label) == "string" and item.length > 0, item.key .. ": label/length")
end
for c, n in cats do
	check(n > 0, "category has animations: " .. c)
end

local function partSet(rigType)
	local set = { HumanoidRootPart = true }
	for part in AnimGen.RIGS[rigType].parent do
		set[part] = true
	end
	return set
end

for _, item in AnimGen.LIST do
	for _, rigType in { "R15", "R6" } do
		for _, opts in { {}, { mirror = true }, { speed = 2, intensity = 1.4 } } do
			local ok, data = pcall(AnimGen.compile, item.key, rigType, opts)
			check(ok, item.key .. " " .. rigType .. " compiles: " .. tostring(data))
			if ok then
				local speed = opts.speed or 1
				check(near(data.length, item.length / speed, 1e-9), item.key .. ": length scales with speed")
				local kfs = data.keyframes
				check(near(kfs[#kfs].time, data.length, 1e-6), item.key .. " " .. rigType .. ": last keyframe at the end")
				check(kfs[1].time == 0, item.key .. ": starts at 0")
				local parts = partSet(rigType)
				local markerCount = 0
				for i, kf in kfs do
					check(i == 1 or kf.time > kfs[i - 1].time, item.key .. ": strictly increasing times")
					markerCount += #kf.markers
					for part, t in kf.poses do
						check(parts[part] == true, item.key .. ": known part " .. part)
						check(orthonormal(t.r), item.key .. ": orthonormal " .. part)
						-- parent chain reaches the root
						local p, guard = part, 0
						while p ~= "HumanoidRootPart" and guard < 10 do
							p = AnimGen.RIGS[rigType].parent[p]
							guard += 1
						end
						check(p == "HumanoidRootPart", item.key .. ": hierarchy for " .. part)
					end
				end
				check(markerCount == #item.markers, item.key .. ": markers kept (" .. markerCount .. "/" .. #item.markers .. ")")
				if item.looped then
					local first, last = kfs[1], kfs[#kfs]
					for part, t in first.poses do
						check(last.poses[part] and mnear(t.r, last.poses[part].r, 1e-9), item.key .. ": loop closes on " .. part)
					end
				end
				-- R6: IK legs never go through the floor
				if rigType == "R6" and not opts.speed then
					local resolved = AnimGen.resolve(item.key, opts)
					local idx = 0
					for _, f in resolved.frames do
						if not f.event then
							idx += 1
							while kfs[idx] and not kfs[idx].style do
								idx += 1
							end
							local root = f.state.j.root or { 0, 0, 0 }
							if root[1] == 0 and root[3] == 0 and not f.state.floor then
								local world = fk("R6", kfs[idx].poses)
								for _, side in { "R", "L" } do
									if f.state.feet[side] then
										local w = world[side == "R" and "Right Leg" or "Left Leg"]
										local y = w.p[2] - w.r[5] * 1 -- sole centre (the box corners of a tilted leg always dip a little)
										check(y > -0.05, string.format("%s t=%.2f R6 leg %s above the floor (%.3f)", item.key, f.t, side, y))
									end
								end
							end
						end
					end
				end
				-- planted feet: IK feet with an upright root touch the floor (R15)
				if rigType == "R15" and not opts.speed then
					local resolved = AnimGen.resolve(item.key, opts)
					local idx = 0
					for _, f in resolved.frames do
						if not f.event then
							idx += 1
							while kfs[idx] and not kfs[idx].style do
								idx += 1
							end
							local st = f.state
							local root = st.j.root or { 0, 0, 0 }
							if root[1] == 0 and root[3] == 0 and not st.floor then
								local world = fk("R15", kfs[idx].poses)
								for _, side in { "R", "L" } do
									local foot = st.feet[side]
									if foot and foot[2] == 0 and foot[3] == 0 then
										local y = lowest("R15", world, { side == "R" and "RightFoot" or "LeftFoot" })
										check(math.abs(y) < 0.06, string.format("%s t=%.2f foot %s on the floor (%.3f)", item.key, f.t, side, y))
									end
								end
							end
						end
					end
				end
						end
		end
	end
end

-- R6 matches R15: torso, head and limb directions
for _, item in AnimGen.LIST do
	local a, b = AnimGen.compile(item.key, "R15"), AnimGen.compile(item.key, "R6")
	local deep = {}
	for _, f in AnimGen.resolve(item.key).frames do
		if f.state and f.state.crouch > 0.8 then
			deep[f.t] = true -- R6 straight legs only crouch a third as deep
		end
	end
	for i, kf in a.keyframes do
		if kf.style then
			local w15, w6 = fk("R15", kf.poses), fk("R6", b.keyframes[i].poses)
			local up15 = M.apply(w15.UpperTorso.r, UP)
			local up6 = M.apply(w6.Torso.r, UP)
			check(angleBetween(up15, up6) < 1, item.key .. ": R6 torso = R15 upper torso")
			check(angleBetween(M.apply(w15.Head.r, FWD), M.apply(w6.Head.r, FWD)) < 1, item.key .. ": R6 head = R15 head")
			for _, s in { { "RightUpperArm", "RightHand", "Right Arm" }, { "LeftUpperArm", "LeftHand", "Left Arm" } } do
				local joint = compose(w15[s[1]], T({ 0, 0.4, 0 })).p -- arm axis at shoulder height
				local chord = sub(w15[s[2]].p, joint)
				local arm6 = M.apply(w6[s[3]].r, DOWN)
				local ang = angleBetween(chord, arm6)
				check(ang < 25, string.format("%s t=%.2f: R6 %s follows R15 (%.0f°)", item.key, kf.time, s[3], ang))
			end
			for _, s in { { "RightUpperLeg", "RightFoot", "Right Leg" }, { "LeftUpperLeg", "LeftFoot", "Left Leg" } } do
				local joint = compose(w15.LowerTorso, RIGS.R15.joints[s[1]][1]).p
				local chord = sub(w15[s[2]].p, joint)
				local leg6 = M.apply(w6[s[3]].r, DOWN)
				local ang = angleBetween(chord, leg6)
				check(ang < 25 or deep[kf.time], string.format("%s t=%.2f: R6 %s follows R15 (%.0f°)", item.key, kf.time, s[3], ang))
			end
		end
	end
end

-- intensity scales angles, speed scales markers
do
	local a = AnimGen.resolve("wave", {})
	local b = AnimGen.resolve("wave", { intensity = 0.5 })
	check(near(b.frames[2].state.j.shoulderR[3], a.frames[2].state.j.shoulderR[3] * 0.5), "intensity halves angles")
	local c = AnimGen.resolve("punch_combo", { speed = 2 })
	check(near(c.frames[2].t, 0.05), "speed halves times")
	local m = AnimGen.resolve("wave", { mirror = true })
	local o = a.frames[2].state.j
	check(vnear(m.frames[2].state.j.shoulderL, o.shoulderR) and vnear(m.frames[2].state.j.shoulderR, o.shoulderL), "mirror swaps arms")
	check(near(m.frames[2].state.j.neck[2], -o.neck[2]) and near(m.frames[2].state.j.waist[3], -o.waist[3]), "mirror negates midline yaw/roll")
end


-- ---------------------------------------------------------------- odd inputs never produce errors or NaN
-- (AnimGen.measure can return any proportions; speed and intensity come from sliders)
do
	local function finite(x)
		return x == x and x ~= math.huge and x ~= -math.huge
	end
	local optionSets = {
		{ rootHeight = 1, thigh = 0.3, shin = 0.3 }, { rootHeight = 15, thigh = 5, shin = 5 }, { intensity = 0 },
		{ intensity = 3, speed = 0.1 }, { speed = 5 }, { speed = 0.5 }, { speed = 0.95 }, { speed = 1.05 },
		{ mirror = true, intensity = 0.3, speed = 0.5 }, { mirror = true, intensity = 1.6, speed = 2 },
	}
	local compiled = 0
	for _, item in AnimGen.LIST do
		for _, rigType in { "R15", "R6" } do
			for _, opts in optionSets do
				local ok, data = pcall(AnimGen.compile, item.key, rigType, opts)
				check(ok, string.format("%s %s compiles with odd options: %s", item.key, rigType, tostring(data)))
				if ok then
					compiled += 1
					for _, kf in data.keyframes do
						check(finite(kf.time), item.key .. ": finite keyframe time")
						for part, tr in kf.poses do
							local good = true
							for i = 1, 9 do
								good = good and finite(tr.r[i])
							end
							for i = 1, 3 do
								good = good and finite(tr.p[i])
							end
							check(good, string.format("%s %s %s: finite pose of %s", item.key, rigType, tostring(opts.speed), part))
						end
					end
				end
			end
		end
	end
	check(compiled > 0, "the odd-input matrix ran")
end

t.finish()
