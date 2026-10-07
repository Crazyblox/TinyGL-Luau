--!strict
--[[
	test_check.luau — the contract of CHECK.luau.

	The contract, from the usage example at the top of CHECK.luau:

		local CHECK = require("./CHECK")(require("./gl_constants"))
		local GL_TEXTURE_MATRIX = 0xBA8
		CHECK("GL_TEXTURE_MATRIX", GL_TEXTURE_MATRIX)

	one argument installs a profile; a name and a value assert that the profile
	holds that value for that name.

	`profile` is one upvalue of the memoized module, so the whole process shares a
	single profile and `require.byPath`, which would hand out a fresh instance, is
	not available in this host.  The tests therefore run as one sequence and the
	teardown goes last.
]]

local H = require("./harness")
local CHECK = require("../CHECK")

--- passes only if f does not raise; the harness has no such check yet
local function checkPass(f: () -> (), msg: string)
	local ok, err = pcall(f)
	H.check(ok, msg .. (if ok then "" else " (raised: " .. tostring(err) .. ")"))
end

--- raises, and the message mentions everything in `contains`
local function checkFails(f: () -> (), contains: { string }, msg: string)
	local ok, err = pcall(f)
	if not ok then
		local text = tostring(err)
		for _, needle in contains do
			H.check(
				string.find(text, needle, 1, true) ~= nil,
				("%s: message does not mention %q (got: %s)"):format(msg, needle, text)
			)
		end
	else
		H.check(false, msg .. " (expected it to raise, but it passed)")
	end
end

local PROFILES = {
	GL_TEXTURE_MATRIX = 0xBA8,
	GL_POINTS = 0, -- a real enumerant whose value is 0
	GL_POLYGON = 9,
	GL_OFF = false, -- a falsy value, to see whether it can be verified
}

--- installing must not raise, or the run ends before anything is reported
local function install(profile: any): (boolean, any)
	return pcall(function()
		return CHECK(profile)
	end)
end

-- ---------------------------------------------------------------------------
H.section("install")

local installed, installErr = install(PROFILES)
H.check(installed, "installing a profile works, as the header example shows: " .. tostring(installErr))
if not installed then
	H.check(false, "every check below fails as a consequence of this one")
end

local okHandle, checker = install(PROFILES)
if okHandle then
	H.eq(typeof(checker), "function", "install returns something callable")
	checkPass(function()
		checker("GL_POLYGON", 9)
	end, "what install returns performs checks")
end

-- ---------------------------------------------------------------------------
H.section("checking against a table profile")

install(PROFILES)
checkPass(function()
	CHECK("GL_TEXTURE_MATRIX", 0xBA8)
end, "a matching name and value pass")

checkPass(function()
	CHECK("GL_POINTS", 0)
end, "an enumerant whose value is zero passes, 0 being truthy in Luau")

checkPass(function()
	CHECK("GL_TEXTURE_MATRIX", 0xBA8)("GL_POLYGON", 9)
end, "checks chain, CHECK returning itself")

checkFails(function()
	CHECK("GL_TEXTURE_MATRIX", 1)
end, { "GL_TEXTURE_MATRIX", "2984", "1" }, "a wrong value raises and names the key and both values")

checkFails(function()
	CHECK("GL_NOT_A_REAL_ENUMERANT", 1)
end, { "GL_NOT_A_REAL_ENUMERANT" }, "a name the profile lacks raises instead of passing")

checkFails(function()
	CHECK(3, 1)
end, { "string" }, "a non-string name against a table profile raises")

checkPass(function()
	CHECK("GL_TEXTURE_MATRIX", 0xBA8)
end, "a failed check leaves the profile usable")

-- ---------------------------------------------------------------------------
H.section("checking against a value profile")

install(7)
checkPass(function()
	CHECK("anything", 7)
end, "a non-table profile compares by equality")
checkFails(function()
	CHECK("anything", 8)
end, { "7", "8" }, "a value profile raises on inequality")

-- ---------------------------------------------------------------------------
H.section("a missing or falsy value in a check")

install(PROFILES)
-- Installing is recognised by the value being absent, so there is no way to say
-- "compare this name against nil", and an entry holding false cannot be compared
-- either.  These assert what a caller would expect.
checkFails(function()
	CHECK("GL_TEXTURE_MATRIX", nil)
end, { "CHECK" }, "a check whose value is nil raises rather than reconfiguring")

install(PROFILES)
checkPass(function()
	CHECK("GL_OFF", false)
end, "an entry whose value is false can be verified against the profile")

-- ---------------------------------------------------------------------------
H.section("a bad first argument")

install(PROFILES)
checkFails(function()
	CHECK(false, 1)
end, { "CHECK" }, "a false name raises rather than clearing the profile")

-- ---------------------------------------------------------------------------
H.section("what the two above cost the rest of the process")

-- Not separate defects: each is the consequence of one of the two checks above,
-- reported so the size of the blast radius is visible.
install(PROFILES)
local knockOn1 = pcall(function()
	CHECK("GL_TEXTURE_MATRIX", nil) -- the reconfiguration
	return CHECK("GL_TEXTURE_MATRIX", 0xBA8) -- the check the caller meant
end)
H.check(
	knockOn1,
	"a nil value in one check does not break the intended comparison in that same check"
)

install(PROFILES)
local knockOn2 = pcall(function()
	CHECK(false, 1) -- the clear
	return CHECK("GL_POLYGON", 9) -- a check from anywhere else in the process
end)
H.check(knockOn2, "a false first argument does not stop the rest of the process checking")

-- ---------------------------------------------------------------------------
H.section("teardown") -- last: it leaves the module un-configured

install(PROFILES)
checkPass(function()
	CHECK()
end, "CHECK() clears the profile")
checkFails(function()
	CHECK("GL_POLYGON", 9)
end, { "Profile not yet configured" }, "checking after teardown raises")
checkPass(function()
	CHECK()
end, "clearing an already clear profile is not an error")

H.summary()
