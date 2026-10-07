--!strict
--[[
	misc.luau — port of TinyGL's src/misc.c.

	glViewport, glEnable/glDisable, glShadeModel, glCullFace, glFrontFace,
	glPolygonMode, glHint and glPolygonOffset.
]]

local Config = require("./config")
local Light = require("./light")
local MSH = require("./msghandling")

local MAX_LIGHTS = Config.MAX_LIGHTS
local TGL_OFFSET_FILL = Config.TGL_OFFSET_FILL
local TGL_OFFSET_LINE = Config.TGL_OFFSET_LINE
local TGL_OFFSET_POINT = Config.TGL_OFFSET_POINT

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_LIGHTING was a table lookup, and this is the hot dispatch of every
-- glEnable/glDisable.  CHECK validates each literal against the frozen table it
-- stands for as this module loads.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_BACK = 0x405; CHECK("GL_BACK", GL_BACK)
local GL_COLOR_MATERIAL = 0xB57; CHECK("GL_COLOR_MATERIAL", GL_COLOR_MATERIAL)
local GL_CULL_FACE = 0xB44; CHECK("GL_CULL_FACE", GL_CULL_FACE)
local GL_DEPTH_TEST = 0xB71; CHECK("GL_DEPTH_TEST", GL_DEPTH_TEST)
local GL_FRONT = 0x404; CHECK("GL_FRONT", GL_FRONT)
local GL_FRONT_AND_BACK = 0x408; CHECK("GL_FRONT_AND_BACK", GL_FRONT_AND_BACK)
local GL_LIGHT0 = 0x4000; CHECK("GL_LIGHT0", GL_LIGHT0)
local GL_LIGHTING = 0xB50; CHECK("GL_LIGHTING", GL_LIGHTING)
local GL_NORMALIZE = 0xBA1; CHECK("GL_NORMALIZE", GL_NORMALIZE)
local GL_POLYGON_OFFSET_FILL = 0x8037; CHECK("GL_POLYGON_OFFSET_FILL", GL_POLYGON_OFFSET_FILL)
local GL_POLYGON_OFFSET_LINE = 0x2A02; CHECK("GL_POLYGON_OFFSET_LINE", GL_POLYGON_OFFSET_LINE)
local GL_POLYGON_OFFSET_POINT = 0x2A01; CHECK("GL_POLYGON_OFFSET_POINT", GL_POLYGON_OFFSET_POINT)
local GL_TEXTURE_2D = 0xDE1; CHECK("GL_TEXTURE_2D", GL_TEXTURE_2D)

local Misc = {}

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

--- glopViewport
function Misc.glopViewport(c: any, p: { number })
	local xmin, ymin, xsize, ysize = p[1], p[2], p[3], p[4]

	-- we may need to resize the zbuffer
	if
		c.viewport.xmin ~= xmin
		or c.viewport.ymin ~= ymin
		or c.viewport.xsize ~= xsize
		or c.viewport.ysize ~= ysize
	then
		local xsize_req = xmin + xsize
		local ysize_req = ymin + ysize

		-- C: `if (c->glResizeViewport && c->glResizeViewport(c, w, h))`; the hook is
		-- installed by the host application (see context.luau)
		local resize = c.glResizeViewport :: (any, number, number) -> any
		if resize ~= nil and resize(c, xsize_req, ysize_req) then
			error("TinyGL: glViewport: error while resizing display", 2)
		end

		local v = c.viewport
		v.xsize = xsize_req - xmin
		v.ysize = ysize_req - ymin
		if v.xsize <= 0 or v.ysize <= 0 then
			error("TinyGL: glViewport: size too small", 2)
		end

		MSH.trace(
			"glViewport: %d %d %d %d",
			xmin,
			ymin,
			v.xsize,
			v.ysize
		)
		v.xmin = xmin
		v.ymin = ymin

		v.updated = 1
	end
end

--- glopEnableDisable
function Misc.glopEnableDisable(c: any, p: { number })
	local code = p[1]
	local v = p[2]

	if code == GL_CULL_FACE then
		c.cullFaceEnabled = v
	elseif code == GL_LIGHTING then
		c.lightingEnabled = v
	elseif code == GL_COLOR_MATERIAL then
		c.colorMaterialEnabled = v
	elseif code == GL_TEXTURE_2D then
		c.texture2dEnabled = v
	elseif code == GL_NORMALIZE then
		c.normalizeEnabled = v
	elseif code == GL_DEPTH_TEST then
		c.depthTest = v
	elseif code == GL_POLYGON_OFFSET_FILL then
		if v ~= 0 then
			c.offsetStates = bit32.bor(c.offsetStates, TGL_OFFSET_FILL)
		else
			c.offsetStates = bit32.band(c.offsetStates, bit32.bnot(TGL_OFFSET_FILL))
		end
	elseif code == GL_POLYGON_OFFSET_POINT then
		if v ~= 0 then
			c.offsetStates = bit32.bor(c.offsetStates, TGL_OFFSET_POINT)
		else
			c.offsetStates = bit32.band(c.offsetStates, bit32.bnot(TGL_OFFSET_POINT))
		end
	elseif code == GL_POLYGON_OFFSET_LINE then
		if v ~= 0 then
			c.offsetStates = bit32.bor(c.offsetStates, TGL_OFFSET_LINE)
		else
			c.offsetStates = bit32.band(c.offsetStates, bit32.bnot(TGL_OFFSET_LINE))
		end
	else
		if code >= GL_LIGHT0 and code < GL_LIGHT0 + MAX_LIGHTS then
			Light.gl_enable_disable_light(c, code - GL_LIGHT0, v)
		else
			-- TinyGL silently ignores everything else (GL_DITHER, GL_BLEND, ...)
			MSH.trace("glEnableDisable: 0x%X not supported.", code)
		end
	end
end

--- glopShadeModel
function Misc.glopShadeModel(c: any, p: { number })
	c.currentShadeModel = p[1]
end

--- glopCullFace
function Misc.glopCullFace(c: any, p: { number })
	c.currentCullFace = p[1]
end

--- glopFrontFace
function Misc.glopFrontFace(c: any, p: { number })
	c.currentFrontFace = p[1]
end

--- glopPolygonMode
function Misc.glopPolygonMode(c: any, p: { number })
	local face, mode = p[1], p[2]

	if face == GL_BACK then
		c.polygonModeBack = mode
	elseif face == GL_FRONT then
		c.polygonModeFront = mode
	elseif face == GL_FRONT_AND_BACK then
		c.polygonModeFront = mode
		c.polygonModeBack = mode
	else
		assert(false, "glopPolygonMode: illegal face")
	end
end

--- glopHint
function Misc.glopHint(c: any, p: { number })
	-- do nothing, exactly like TinyGL
end

--- glopPolygonOffset
function Misc.glopPolygonOffset(c: any, p: { number })
	c.offsetFactor = p[1]
	c.offsetUnits = p[2]
end

return Misc
