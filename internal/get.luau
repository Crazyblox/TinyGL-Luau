--!strict
--[[
	get.luau — port of TinyGL's src/get.c (glGetIntegerv / glGetFloatv).

	C wrote into caller supplied out-parameters; here the queries return a fresh
	array with the values (4 for the viewport and the 4x4 matrices, 1 otherwise),
	in the same order C used.  glGetFloatv() returns the matrices in OpenGL's
	column major order, so the result can be given straight back to
	glLoadMatrixf()/glMultMatrixf().
]]

local Config = require("./config")
local MSH = require("./msghandling")
local Matrix = require("./matrix")

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_VIEWPORT was a table lookup.  CHECK validates each literal against the
-- frozen table it stands for as this module loads, so one that drifts is an error
-- naming both values here rather than a query that answers with another query's
-- value.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_LINE_WIDTH = 0xB21; CHECK("GL_LINE_WIDTH", GL_LINE_WIDTH)
local GL_LINE_WIDTH_RANGE = 0xB22; CHECK("GL_LINE_WIDTH_RANGE", GL_LINE_WIDTH_RANGE)
local GL_MAX_LIGHTS = 0xD31; CHECK("GL_MAX_LIGHTS", GL_MAX_LIGHTS)
local GL_MAX_MODELVIEW_STACK_DEPTH = 0xD36; CHECK("GL_MAX_MODELVIEW_STACK_DEPTH", GL_MAX_MODELVIEW_STACK_DEPTH)
local GL_MAX_PROJECTION_STACK_DEPTH = 0xD38; CHECK("GL_MAX_PROJECTION_STACK_DEPTH", GL_MAX_PROJECTION_STACK_DEPTH)
local GL_MAX_TEXTURE_SIZE = 0xD33; CHECK("GL_MAX_TEXTURE_SIZE", GL_MAX_TEXTURE_SIZE)
local GL_MAX_TEXTURE_STACK_DEPTH = 0xD39; CHECK("GL_MAX_TEXTURE_STACK_DEPTH", GL_MAX_TEXTURE_STACK_DEPTH)
local GL_MODELVIEW_MATRIX = 0xBA6; CHECK("GL_MODELVIEW_MATRIX", GL_MODELVIEW_MATRIX)
local GL_POINT_SIZE = 0xB11; CHECK("GL_POINT_SIZE", GL_POINT_SIZE)
local GL_POINT_SIZE_RANGE = 0xB12; CHECK("GL_POINT_SIZE_RANGE", GL_POINT_SIZE_RANGE)
local GL_PROJECTION_MATRIX = 0xBA7; CHECK("GL_PROJECTION_MATRIX", GL_PROJECTION_MATRIX)
local GL_TEXTURE_MATRIX = 0xBA8; CHECK("GL_TEXTURE_MATRIX", GL_TEXTURE_MATRIX)
local GL_VIEWPORT = 0xBA2; CHECK("GL_VIEWPORT", GL_VIEWPORT)

local Get = {}

--- glGetIntegerv
function Get.glGetIntegerv(c: any, pname: number): { number }
	if pname == GL_VIEWPORT then
		local v = c.viewport
		return { v.xmin, v.ymin, v.xsize, v.ysize }
	elseif pname == GL_MAX_MODELVIEW_STACK_DEPTH then
		return { Config.MAX_MODELVIEW_STACK_DEPTH }
	elseif pname == GL_MAX_PROJECTION_STACK_DEPTH then
		return { Config.MAX_PROJECTION_STACK_DEPTH }
	elseif pname == GL_MAX_LIGHTS then
		return { Config.MAX_LIGHTS }
	elseif pname == GL_MAX_TEXTURE_SIZE then
		return { 256 } -- not completely true, but...
	elseif pname == GL_MAX_TEXTURE_STACK_DEPTH then
		return { Config.MAX_TEXTURE_STACK_DEPTH }
	else
		error("TinyGL: fatal error: glGet: option not implemented", 2)
	end
end

--- glGetFloatv
function Get.glGetFloatv(c: any, pname: number): { number }
	-- C used a chain of fallthrough switch cases with a `mnr` counter to map the
	-- three matrix queries onto the right stack; the mapping is spelled out here.
	local mnr: number?
	if pname == GL_TEXTURE_MATRIX then
		mnr = 2
	elseif pname == GL_PROJECTION_MATRIX then
		mnr = 1
	elseif pname == GL_MODELVIEW_MATRIX then
		mnr = 0
	elseif pname == GL_LINE_WIDTH or pname == GL_POINT_SIZE then
		return { 1.0 }
	elseif pname == GL_LINE_WIDTH_RANGE or pname == GL_POINT_SIZE_RANGE then
		return { 1.0, 1.0 }
	else
		MSH.warning("warning: unknown pname in glGetFloatv()")
		return {}
	end

	local m = Matrix.top(c, mnr :: number)
	local out = table.create(16) :: { number }
	local o = 1
	for j = 1, 4 do
		for i = 1, 4 do
			out[o] = m[i][j]
			o += 1
		end
	end
	return out
end

return Get
