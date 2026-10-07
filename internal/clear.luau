--!strict
--[[
	clear.luau — port of TinyGL's src/clear.c.
]]

local Util = require("./util")
local ZBuffer = require("./zbuffer")

local band = bit32.band
local trunc = Util.trunc

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_COLOR_BUFFER_BIT was a table lookup.  CHECK validates each literal against
-- the frozen table it stands for as this module loads, so one that drifts is an
-- error naming both values here rather than a clear that clears the wrong buffer.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_COLOR_BUFFER_BIT = 0x4000; CHECK("GL_COLOR_BUFFER_BIT", GL_COLOR_BUFFER_BIT)
local GL_DEPTH_BUFFER_BIT = 0x100; CHECK("GL_DEPTH_BUFFER_BIT", GL_DEPTH_BUFFER_BIT)

local Clear = {}

--- glopClearColor
function Clear.glopClearColor(c: any, p: { number })
	c.clearColor[1] = p[1]
	c.clearColor[2] = p[2]
	c.clearColor[3] = p[3]
	c.clearColor[4] = p[4]
end

--- glopClearDepth
function Clear.glopClearDepth(c: any, p: { number })
	c.clearDepth = p[1]
end

--- glopClear
function Clear.glopClear(c: any, p: { number })
	local mask = p[1]
	local z = 0 -- TODO : correct value of Z — same limitation as TinyGL: the
	-- current clear depth is remembered but never used for the clear itself.

	-- C's `(int) (clear_color.v[0] * 65535)`: the cast truncates towards zero, so a
	-- negative clear colour is a negative colour component here too rather than a
	-- wrapped huge one.
	local r = trunc(c.clearColor[1] * 65535)
	local g = trunc(c.clearColor[2] * 65535)
	local b = trunc(c.clearColor[3] * 65535)

	ZBuffer.ZB_clear(
		c.zb,
		if band(mask, GL_DEPTH_BUFFER_BIT) ~= 0 then 1 else 0,
		z,
		if band(mask, GL_COLOR_BUFFER_BIT) ~= 0 then 1 else 0,
		r,
		g,
		b
	)
end

--- the state glInit() installs for glClear
function Clear.initClear(c: any)
	c.clearColor = { 0, 0, 0, 0 }
	c.clearDepth = 0
end

return Clear
