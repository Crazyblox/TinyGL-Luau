--!strict
--[[
	vertex.luau — port of TinyGL's src/vertex.c.

	The current-vertex state (glColor/glNormal/glTexCoord/glEdgeFlag), the
	immediate mode primitive assembly of glBegin/glVertex/glEnd and the cached
	projection / viewport / drawing mode state that gl_eval_viewport() and
	glopBegin() set up.
]]

local Config = require("./config")
local Util = require("./util")
local ZMath = require("./zmath")
local Clip = require("./clip")
local Light = require("./light")
local Matrix = require("./matrix")

local u32cast = Util.u32cast
local band = bit32.band

local Vertex = {}

local ZB_Z_BITS = Config.ZB_Z_BITS
local ZB_POINT_Z_FRAC_BITS = Config.ZB_POINT_Z_FRAC_BITS
local POLYGON_MAX_VERTEX = Config.POLYGON_MAX_VERTEX

local ZB_POINT_RED_MIN = Config.ZB_POINT_RED_MIN
local ZB_POINT_RED_MAX = Config.ZB_POINT_RED_MAX
local ZB_POINT_GREEN_MIN = Config.ZB_POINT_GREEN_MIN
local ZB_POINT_GREEN_MAX = Config.ZB_POINT_GREEN_MAX
local ZB_POINT_BLUE_MIN = Config.ZB_POINT_BLUE_MIN
local ZB_POINT_BLUE_MAX = Config.ZB_POINT_BLUE_MAX

--[[
	Constants hoisted into this module's own scope: a local is a register read where
	GL.GL_TRIANGLES was a table lookup, and glopVertex is the primitive assembly
	every drawn pixel goes through.  CHECK validates each one as the module loads,
	against the frozen table it stands for -- gl_constants for the enumerants,
	Config.OP for the opcode number.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or
	two to check against it, which no single type says: hence the cast.
	CHECK(table) installs a profile, dropping whatever the module loaded
	before it installed.
	See CHECK.luau.
]]
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_LINE = 0x1B01; CHECK("GL_LINE", GL_LINE)
local GL_LINES = 1; CHECK("GL_LINES", GL_LINES)
local GL_LINE_LOOP = 2; CHECK("GL_LINE_LOOP", GL_LINE_LOOP)
local GL_LINE_STRIP = 3; CHECK("GL_LINE_STRIP", GL_LINE_STRIP)
local GL_POINT = 0x1B00; CHECK("GL_POINT", GL_POINT)
local GL_POINTS = 0; CHECK("GL_POINTS", GL_POINTS)
local GL_POLYGON = 9; CHECK("GL_POLYGON", GL_POLYGON)
local GL_QUADS = 7; CHECK("GL_QUADS", GL_QUADS)
local GL_QUAD_STRIP = 8; CHECK("GL_QUAD_STRIP", GL_QUAD_STRIP)
local GL_SELECT = 0x1C02; CHECK("GL_SELECT", GL_SELECT)
local GL_TRIANGLES = 4; CHECK("GL_TRIANGLES", GL_TRIANGLES)
local GL_TRIANGLE_FAN = 6; CHECK("GL_TRIANGLE_FAN", GL_TRIANGLE_FAN)
local GL_TRIANGLE_STRIP = 5; CHECK("GL_TRIANGLE_STRIP", GL_TRIANGLE_STRIP)
CHECK()(Config.OP)
local OP_Material = 19; CHECK("OP_Material", OP_Material)

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

--- glopNormal
function Vertex.glopNormal(c: any, p: { number })
	c.currentNormal[1] = p[1]
	c.currentNormal[2] = p[2]
	c.currentNormal[3] = p[3]
	c.currentNormal[4] = 0
end

--- glopTexCoord
function Vertex.glopTexCoord(c: any, p: { number })
	c.currentTexCoord[1] = p[1]
	c.currentTexCoord[2] = p[2]
	c.currentTexCoord[3] = p[3]
	c.currentTexCoord[4] = p[4]
end

--- glopEdgeFlag
function Vertex.glopEdgeFlag(c: any, p: { number })
	c.currentEdgeFlag = p[1]
end

--[[
	The three precomputed integer colour slots that api.c's glColor4f() passes in
	p[5..7] and that glopColor() keeps as c.longcurrentColor, which
	gl_transform_to_viewport() then paints every vertex with while lighting is off.

	C converts with `(unsigned int)`, which saturates (see Util.u32cast).  C does the
	multiply and the add in `float`; here they are Luau doubles, so a colour outside
	[0,1] still saturates the same way while an in range one may land one unit away
	from C's value in the last place.
]]
function Vertex.colorIntensities(r: number, g: number, b: number): (number, number, number)
	return u32cast(r * (ZB_POINT_RED_MAX - ZB_POINT_RED_MIN) + ZB_POINT_RED_MIN),
		u32cast(g * (ZB_POINT_GREEN_MAX - ZB_POINT_GREEN_MIN) + ZB_POINT_GREEN_MIN),
		u32cast(b * (ZB_POINT_BLUE_MAX - ZB_POINT_BLUE_MIN) + ZB_POINT_BLUE_MIN)
end

--- glopColor
function Vertex.glopColor(c: any, p: { number })
	c.currentColor[1] = p[1]
	c.currentColor[2] = p[2]
	c.currentColor[3] = p[3]
	c.currentColor[4] = p[4]
	c.longcurrentColor[1] = p[5]
	c.longcurrentColor[2] = p[6]
	c.longcurrentColor[3] = p[7]

	if c.colorMaterialEnabled ~= 0 then
		-- C builds a local GLParam array and calls glopMaterial() with it; the
		-- opcode slot ([0] here) is never read, so only the 6 parameters matter.
		local q = { [0] = OP_Material, c.currentColorMaterialMode, c.currentColorMaterialType, p[1], p[2], p[3], p[4] }
		Light.glopMaterial(c, q)
	end
end

--- gl_eval_viewport
function Vertex.gl_eval_viewport(c: any)
	local v = c.viewport
	-- `float zsize = (1 << (ZB_Z_BITS + ZB_POINT_Z_FRAC_BITS));` in C.  C computes
	-- the Z terms in single precision, where (1<<30) - 0.5 rounds to (1<<30), so it
	-- ends up with trans.Z = 536879104 and scale.Z = -536870912.  Doubles keep the
	-- .5 and land on .75 instead, which moves the raw fixed point zp.z by up to half
	-- a unit — much less than one step of the stored 16 bit depth, since
	-- ZB_POINT_Z_FRAC_BITS of those units make one step, but it is seen by anything
	-- that reads zp.z directly: the selection buffer reports 536879103 here where the
	-- C library reports 536879104.
	local zsize = 2 ^ (ZB_Z_BITS + ZB_POINT_Z_FRAC_BITS)

	v.trans[1] = ((v.xsize - 0.5) / 2.0) + v.xmin
	v.trans[2] = ((v.ysize - 0.5) / 2.0) + v.ymin
	v.trans[3] = ((zsize - 0.5) / 2.0) + (2 ^ ZB_POINT_Z_FRAC_BITS) / 2

	v.scale[1] = (v.xsize - 0.5) / 2.0
	v.scale[2] = -(v.ysize - 0.5) / 2.0
	v.scale[3] = -((zsize - 0.5) / 2.0)
end

--- glopBegin
function Vertex.glopBegin(c: any, p: { number })
	local ptype = p[1]

	assert(c.inBegin == 0, "glopBegin: already in begin")

	c.beginType = ptype
	c.inBegin = 1
	c.vertexN = 0
	c.vertexCnt = 0

	if c.matrixModelProjectionUpdated ~= 0 then
		if c.lightingEnabled ~= 0 then
			-- precompute inverse modelview
			local tmp = ZMath.m4New()
			ZMath.gl_M4_Inv(tmp, Matrix.top(c, 0))
			ZMath.gl_M4_Transpose(c.matrixModelViewInv, tmp)
		else
			-- precompute projection matrix
			local mp = c.matrixModelProjection
			ZMath.gl_M4_Mul(mp, Matrix.top(c, 1), Matrix.top(c, 0))
			-- test to accelerate computation
			local noW = 1
			if mp[4][1] ~= 0 or mp[4][2] ~= 0 or mp[4][3] ~= 0 then
				noW = 0
			end
			c.matrixModelProjectionNoWTransform = noW
		end

		-- test if the texture matrix is not Identity
		c.applyTextureMatrix = if ZMath.gl_M4_IsId(Matrix.top(c, 2)) then 0 else 1

		c.matrixModelProjectionUpdated = 0
	end

	-- viewport
	if c.viewport.updated ~= 0 then
		Vertex.gl_eval_viewport(c)
		c.viewport.updated = 0
	end

	-- triangle drawing functions
	if c.renderMode == GL_SELECT then
		c.drawTriangleFront = Clip.gl_draw_triangle_select
		c.drawTriangleBack = Clip.gl_draw_triangle_select
	else
		if c.polygonModeFront == GL_POINT then
			c.drawTriangleFront = Clip.gl_draw_triangle_point
		elseif c.polygonModeFront == GL_LINE then
			c.drawTriangleFront = Clip.gl_draw_triangle_line
		else
			c.drawTriangleFront = Clip.gl_draw_triangle_fill
		end

		if c.polygonModeBack == GL_POINT then
			c.drawTriangleBack = Clip.gl_draw_triangle_point
		elseif c.polygonModeBack == GL_LINE then
			c.drawTriangleBack = Clip.gl_draw_triangle_line
		else
			c.drawTriangleBack = Clip.gl_draw_triangle_fill
		end
	end
end

--- coords, transformation, clip code and projection (gl_vertex_transform)
local function gl_vertex_transform(c: any, v: any)
	local m: { { number } }
	local n: { number }

	if c.lightingEnabled ~= 0 then
		-- eye coordinates needed for lighting
		local mv = Matrix.top(c, 0)
		-- C's eye coordinate sums add the translation column straight on, without
		-- multiplying it by coord.W (`NOTE: W = 1 is assumed`), so w is not read
		local x, y, z = v.coord[1], v.coord[2], v.coord[3]

		m = mv
		v.ec[1] = x * m[1][1] + y * m[1][2] + z * m[1][3] + m[1][4]
		v.ec[2] = x * m[2][1] + y * m[2][2] + z * m[2][3] + m[2][4]
		v.ec[3] = x * m[3][1] + y * m[3][2] + z * m[3][3] + m[3][4]
		v.ec[4] = x * m[4][1] + y * m[4][2] + z * m[4][3] + m[4][4]

		-- projection coordinates
		m = Matrix.top(c, 1)
		local ex, ey, ez, ew = v.ec[1], v.ec[2], v.ec[3], v.ec[4]
		v.pc[1] = ex * m[1][1] + ey * m[1][2] + ez * m[1][3] + ew * m[1][4]
		v.pc[2] = ex * m[2][1] + ey * m[2][2] + ez * m[2][3] + ew * m[2][4]
		v.pc[3] = ex * m[3][1] + ey * m[3][2] + ez * m[3][3] + ew * m[3][4]
		v.pc[4] = ex * m[4][1] + ey * m[4][2] + ez * m[4][3] + ew * m[4][4]

		m = c.matrixModelViewInv
		n = c.currentNormal

		v.normal[1] = n[1] * m[1][1] + n[2] * m[1][2] + n[3] * m[1][3]
		v.normal[2] = n[1] * m[2][1] + n[2] * m[2][2] + n[3] * m[2][3]
		v.normal[3] = n[1] * m[3][1] + n[2] * m[3][2] + n[3] * m[3][3]

		if c.normalizeEnabled ~= 0 then
			ZMath.gl_V3_Norm(v.normal)
		end
	else
		-- no eye coordinates needed, no normal
		-- NOTE: W = 1 is assumed
		m = c.matrixModelProjection
		local x, y, z = v.coord[1], v.coord[2], v.coord[3]

		v.pc[1] = x * m[1][1] + y * m[1][2] + z * m[1][3] + m[1][4]
		v.pc[2] = x * m[2][1] + y * m[2][2] + z * m[2][3] + m[2][4]
		v.pc[3] = x * m[3][1] + y * m[3][2] + z * m[3][3] + m[3][4]
		if c.matrixModelProjectionNoWTransform ~= 0 then
			v.pc[4] = m[4][4]
		else
			v.pc[4] = x * m[4][1] + y * m[4][2] + z * m[4][3] + m[4][4]
		end
	end

	v.clip_code = Clip.gl_clipcode(v.pc[1], v.pc[2], v.pc[3], v.pc[4])
end

--- glopVertex
function Vertex.glopVertex(c: any, p: { number })
	assert(c.inBegin ~= 0, "glopVertex: outside of glBegin")

	local n = c.vertexN
	local cnt = c.vertexCnt + 1
	c.vertexCnt = cnt

	-- grow the vertex pool when needed
	if n >= c.vertexMax then
		local newarray = table.create(c.vertexMax * 2)
		for i = 1, n do
			newarray[i] = c.vertex[i]
		end
		c.vertexMax *= 2
		c.vertex = newarray
	end

	local vertices = c.vertex
	local v = vertices[n + 1]
	if v == nil then
		v = Clip.newVertex()
		vertices[n + 1] = v
	end
	n += 1 -- C: `v = &c->vertex[n]; n++;` so all the tests below use n = index + 1

	v.coord[1] = p[1]
	v.coord[2] = p[2]
	v.coord[3] = p[3]
	v.coord[4] = p[4]

	gl_vertex_transform(c, v)

	-- color
	if c.lightingEnabled ~= 0 then
		Light.gl_shade_vertex(c, v)
	else
		local cc = c.currentColor
		v.color[1] = cc[1]
		v.color[2] = cc[2]
		v.color[3] = cc[3]
		v.color[4] = cc[4]
	end

	-- tex coords
	if c.texture2dEnabled ~= 0 then
		if c.applyTextureMatrix ~= 0 then
			ZMath.gl_M4_MulV4(v.tex_coord, Matrix.top(c, 2), c.currentTexCoord)
		else
			local tc = c.currentTexCoord
			v.tex_coord[1] = tc[1]
			v.tex_coord[2] = tc[2]
			v.tex_coord[3] = tc[3]
			v.tex_coord[4] = tc[4]
		end
	end

	-- precompute the mapping to the viewport
	if v.clip_code == 0 then
		Clip.gl_transform_to_viewport(c, v)
	end

	-- edge flag
	v.edge_flag = c.currentEdgeFlag

	local btype = c.beginType

	if btype == GL_POINTS then
		Clip.gl_draw_point(c, vertices[1])
		n = 0
	elseif btype == GL_LINES then
		if n == 2 then
			Clip.gl_draw_line(c, vertices[1], vertices[2])
			n = 0
		end
	elseif btype == GL_LINE_STRIP or btype == GL_LINE_LOOP then
		if n == 1 then
			vertices[3] = vertices[1]
		elseif n == 2 then
			Clip.gl_draw_line(c, vertices[1], vertices[2])
			vertices[1] = vertices[2]
			n = 1
		end
	elseif btype == GL_TRIANGLES then
		if n == 3 then
			Clip.gl_draw_triangle(c, vertices[1], vertices[2], vertices[3])
			n = 0
		end
	elseif btype == GL_TRIANGLE_STRIP then
		if cnt >= 3 then
			if n == 3 then
				n = 0
			end
			-- needed to respect triangle orientation
			if band(cnt, 1) == 0 then
				Clip.gl_draw_triangle(c, vertices[3], vertices[2], vertices[1])
			else
				Clip.gl_draw_triangle(c, vertices[1], vertices[2], vertices[3])
			end
		end
	elseif btype == GL_TRIANGLE_FAN then
		if n == 3 then
			Clip.gl_draw_triangle(c, vertices[1], vertices[2], vertices[3])
			vertices[2] = vertices[3]
			n = 2
		end
	elseif btype == GL_QUADS then
		if n == 4 then
			vertices[3].edge_flag = 0
			Clip.gl_draw_triangle(c, vertices[1], vertices[2], vertices[3])
			vertices[3].edge_flag = 1
			vertices[1].edge_flag = 0
			Clip.gl_draw_triangle(c, vertices[1], vertices[3], vertices[4])
			n = 0
		end
	elseif btype == GL_QUAD_STRIP then
		if n == 4 then
			Clip.gl_draw_triangle(c, vertices[1], vertices[2], vertices[3])
			Clip.gl_draw_triangle(c, vertices[2], vertices[4], vertices[3])
			vertices[1] = vertices[3]
			vertices[2] = vertices[4]
			n = 2
		end
	elseif btype == GL_POLYGON then
		-- collected until glEnd
	else
		error(("TinyGL: glBegin: type %x not handled"):format(btype), 2)
	end

	c.vertexN = n
end

--- glopEnd
function Vertex.glopEnd(c: any, _p: { number })
	assert(c.inBegin == 1, "glopEnd: outside of glBegin")

	local vertices = c.vertex

	if c.beginType == GL_LINE_LOOP then
		if c.vertexCnt >= 3 then
			Clip.gl_draw_line(c, vertices[1], vertices[3])
		end
	elseif c.beginType == GL_POLYGON then
		local i = c.vertexCnt
		while i >= 3 do
			i -= 1
			Clip.gl_draw_triangle(c, vertices[i + 1], vertices[1], vertices[i])
		end
	end

	c.inBegin = 0
end

--- the initial state glInit() installs for the vertex machinery
function Vertex.initVertex(c: any)
	c.vertexMax = POLYGON_MAX_VERTEX
	c.vertex = table.create(c.vertexMax)
	c.inBegin = 0
	c.beginType = 0
	c.vertexN = 0
	c.vertexCnt = 0

	c.currentColor = { 1.0, 1.0, 1.0, 1.0 }
	c.longcurrentColor = { 65535, 65535, 65535 }
	c.currentNormal = { 1.0, 0.0, 0.0, 0.0 }
	c.currentEdgeFlag = 1
	c.currentTexCoord = { 0, 0, 0, 1 }

	c.viewport = {
		xmin = 0,
		ymin = 0,
		xsize = c.zb.xsize,
		ysize = c.zb.ysize,
		scale = { 0, 0, 0 },
		trans = { 0, 0, 0 },
		updated = 1,
	}
end

return Vertex
