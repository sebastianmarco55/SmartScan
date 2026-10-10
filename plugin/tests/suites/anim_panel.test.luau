-- AnimPanel (real UI + panel, fake AnimGen): the dummy rig from a HumanoidDescription (the Async name is preferred, the old one
-- is the fallback, no undo recording is open across the web request), playback (the temporary Animator, one Heartbeat
-- connection, failures stop the preview, destroy cleans up), the marker text kept across redraws, the sorted clip list.
local LC = ...
local T = LC.kit.new("anim_panel")
local M = LC.run("tests/mocks/datamodel.luau")
LC.loadJoined({ "tests/mocks/panel_prologue.luau", "tests/suites/bodies/anim_panel.luau" }, "anim_panel", nil)(LC, T, M)
T.finish()
