--!strict
--[[
	test_modules.luau — every module must load.

	A `require()` of a module with a compile error yields the error *string* in
	this Luau, so a typo inside a function that is rarely called would otherwise
	pass unnoticed until something tries to call one of its missing functions.
	It is also where the hoisted literals are checked: a CHECK that disagrees with
	its table raises while the module loads, which lands in the same pcall, and the
	frozen-ness those literals are validated against is asserted at the end.
]]

local H = require("./harness")

local names = {
	"gl_constants",
	"tinygl",
	"internal/util",
	"internal/config",
	"internal/msghandling",
	"internal/handle",
	"internal/zmath",
	"internal/zbuffer",
	"internal/zdither",
	"internal/zline",
	"internal/ztriangle",
	"internal/image_util",
	"internal/specbuf",
	"internal/select",
	"internal/light",
	"internal/matrix",
	"internal/misc",
	"internal/clip",
	"internal/vertex",
	"internal/texture",
	"internal/arrays",
	"internal/clear",
	"internal/list",
	"internal/get",
	"internal/context",
}

H.section("module loading")
for _, name in ipairs(names) do
	local ok, mod = pcall(require, "../" .. name)
	H.check(ok and type(mod) == "table", ("require(\"%s\") must yield a table%s"):format(
		"../" .. name,
		if ok and type(mod) ~= "table" then ": " .. tostring(mod) else ""
	))
end

--[[
	The tables the modules' hoisted literals are checked against, and why those are
	frozen.  A module writes `local GL_FRONT = 0x404` and hands CHECK the table that
	literal has to agree with; a profile a module could still edit would agree with
	whatever it was written, so CHECK.luau refuses an unfrozen table outright and the
	tables used as profiles are frozen here, in config.luau and gl_constants.luau.

	Config itself is deliberately not one of them: it holds ASSERTS and CHECKS,
	switches the host is meant to flip through GL.Config.

	A wrong literal is caught by the requires above: CHECK raises while the module
	loads, so pcall reports it as a module that does not yield a table.
]]
local GL = require("../gl_constants")
local Config = require("../internal/config")

H.section("the profiles CHECK validates the hoisted literals against")

H.check(table.isfrozen(GL), "gl_constants is frozen")
H.checkRaises(function()
	(GL :: any).GL_FRONT = 1 -- the type checker already knows it is read-only; this says the runtime does too
end, "an enumerant cannot be reassigned, which is what makes it a constant to check against")

-- name and table: Config's fields cannot be indexed by a variable, so the name
-- travels next to the table rather than being used to reach it
local opcodeProfiles: { { any } } = {
	{ "OP", Config.OP },
	{ "OP_SIZE", Config.OP_SIZE },
	{ "OP_PRINT", Config.OP_PRINT },
	{ "OP_NAMES", Config.OP_NAMES },
	{ "OP_PARAMS", Config.OP_PARAMS },
}
for _, entry in ipairs(opcodeProfiles) do
	H.check(
		table.isfrozen(entry[2]),
		"Config." .. entry[1] .. " is frozen: an opcode number is compile time data"
	)
end
H.checkRaises(function()
	Config.OP.OP_Color = 99
end, "an opcode number cannot be reassigned")

H.check(table.isfrozen(Config.OP_INFOS), "Config.OP_INFOS is frozen")
H.check(
	(Config.OP_INFOS[1] :: any) ~= nil and table.isfrozen(Config.OP_INFOS[1] :: any),
	"and so each of its rows"
)

-- the hoisted literals are written OP_Color, the C enum's name is OP_Color, and
-- opinfo.h's own name is Color: the two spellings have to stay one number
H.eq(Config.OP.Color, Config.OP.OP_Color, "Config.OP spells an opcode both ways, and both agree")
H.eq(Config.OP["OP_Color"], 0, "the first opcode is still 0, which every module's literals count up from")

H.check(not table.isfrozen(Config), "Config is not frozen: ASSERTS and CHECKS are host switches")

H.summary()
