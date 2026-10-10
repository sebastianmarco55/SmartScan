-- LibraryPanel (real UI + AnimLibrary + panel): dummy rig creation, the ownership check (GetProductInfoAsync preferred),
-- playback and its Heartbeat connection, no requests after destroy, the search box keeps what is typed.
local LC = ...
local T = LC.kit.new("library_panel_ui")
local M = LC.run("tests/mocks/datamodel.luau")
LC.loadJoined({ "tests/mocks/panel_prologue.luau", "tests/suites/bodies/library_panel_ui.luau" }, "library_panel_ui", nil)(LC, T, M)
T.finish()
