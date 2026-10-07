--!strict
--[[
	clip.luau — port of TinyGL's src/clip.c.

	Viewport transform, the point/line/triangle drawing entry points, and the
	Sutherland-Hodgman clipping of lines and triangles against the six planes of
	the normalized view volume.

	GLVertex layout (as in zgl.h):
	  edge_flag, normal (V3), coord (V4), tex_coord (V4), color (V4),
	  ec (V4), pc (V4), clip_code, zp (ZBufferPoint)

	Everything here takes the vertex records by reference and, as in C, mutates
	the temporaries it creates itself; nothing is aliased into the context.
]]

local Config = require("./config")
local Util = require("./util")
local ZBuffer = require("./zbuffer")
local ZLine = require("./zline")
local ZTriangle = require("./ztriangle")
local Select = require("./select")

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local trunc = Util.trunc

local Clip = {}

local ZB_POINT_RED_MIN = Config.ZB_POINT_RED_MIN
local ZB_POINT_RED_MAX = Config.ZB_POINT_RED_MAX
local ZB_POINT_GREEN_MIN = Config.ZB_POINT_GREEN_MIN
local ZB_POINT_GREEN_MAX = Config.ZB_POINT_GREEN_MAX
local ZB_POINT_BLUE_MIN = Config.ZB_POINT_BLUE_MIN
local ZB_POINT_BLUE_MAX = Config.ZB_POINT_BLUE_MAX
local ZB_POINT_S_MIN = Config.ZB_POINT_S_MIN
local ZB_POINT_S_MAX = Config.ZB_POINT_S_MAX
local ZB_POINT_T_MIN = Config.ZB_POINT_T_MIN
local ZB_POINT_T_MAX = Config.ZB_POINT_T_MAX

local CLIP_EPSILON = Config.CLIP_EPSILON

local UINT32_MAX = 4294967295 -- 0xffffffff, used by the selection z range

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_SELECT was a table lookup, and these are compared per vertex and per
-- triangle.  CHECK validates each literal against the frozen table it stands for
-- as this module loads.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_BACK = 0x405; CHECK("GL_BACK", GL_BACK)
local GL_FRONT = 0x404; CHECK("GL_FRONT", GL_FRONT)
local GL_SELECT = 0x1C02; CHECK("GL_SELECT", GL_SELECT)
local GL_SMOOTH = 0x1D01; CHECK("GL_SMOOTH", GL_SMOOTH)

--- A fresh GLVertex.  TinyGL reuses stack allocated temporaries; in Luau every
--- call that needs one allocates, which is the safe thing to do.
function Clip.newVertex(): any
	return {
		edge_flag = 1,
		normal = { 0, 0, 0 }, -- V3
		coord = { 0, 0, 0, 1 }, -- V4
		tex_coord = { 0, 0, 0, 1 }, -- V4
		color = { 1, 1, 1, 1 }, -- V4
		ec = { 0, 0, 0, 0 }, -- V4, eye coordinates
		pc = { 0, 0, 0, 1 }, -- V4, coordinates in the normalized volume
		clip_code = 0,
		zp = { x = 0, y = 0, z = 0, s = 0, t = 0, r = 0, g = 0, b = 0, sz = 0, tz = 0 },
	}
end

--[[
	gl_clipcode from zgl.h.  Note the epsilon: TinyGL deliberately inflates w so
	that a few extra roundings do not make geometry disappear.
]]
function Clip.gl_clipcode(x: number, y: number, z: number, w1: number): number
	local w = w1 * (1.0 + CLIP_EPSILON)
	return (if x < -w then 1 else 0)
		+ (if x > w then 2 else 0)
		+ (if y < -w then 4 else 0)
		+ (if y > w then 8 else 0)
		+ (if z < -w then 16 else 0)
		+ (if z > w then 32 else 0)
end

--- gl_transform_to_viewport
function Clip.gl_transform_to_viewport(c: any, v: any)
	local zp = v.zp

	-- coordinates (C does every one of these operations in `float`; here they are
	-- Luau doubles, and the Z term is compared against the depth buffer afterwards,
	-- so the extra precision is where a depth may land one unit from C's)
	local winv = 1.0 / v.pc[4]
	zp.x = trunc(v.pc[1] * winv * c.viewport.scale[1] + c.viewport.trans[1])
	zp.y = trunc(v.pc[2] * winv * c.viewport.scale[2] + c.viewport.trans[2])
	zp.z = trunc(v.pc[3] * winv * c.viewport.scale[3] + c.viewport.trans[3])

	-- color
	if c.lightingEnabled ~= 0 then
		zp.r = trunc(v.color[1] * (ZB_POINT_RED_MAX - ZB_POINT_RED_MIN) + ZB_POINT_RED_MIN)
		zp.g = trunc(v.color[2] * (ZB_POINT_GREEN_MAX - ZB_POINT_GREEN_MIN) + ZB_POINT_GREEN_MIN)
		zp.b = trunc(v.color[3] * (ZB_POINT_BLUE_MAX - ZB_POINT_BLUE_MIN) + ZB_POINT_BLUE_MIN)
	else
		-- no need to convert to integer if no lighting: take the current color
		zp.r = c.longcurrentColor[1]
		zp.g = c.longcurrentColor[2]
		zp.b = c.longcurrentColor[3]
	end

	-- texture
	if c.texture2dEnabled ~= 0 then
		zp.s = trunc(v.tex_coord[1] * (ZB_POINT_S_MAX - ZB_POINT_S_MIN) + ZB_POINT_S_MIN)
		zp.t = trunc(v.tex_coord[2] * (ZB_POINT_T_MAX - ZB_POINT_T_MIN) + ZB_POINT_T_MIN)
	end
end

--[[
	gl_add_select1: the z range of a primitive, converted to the "distance from
	the eye" convention of the selection buffer (0xffffffff - z), so that hits
	come out back to front.
]]
local function gl_add_select1(c: any, z1: number, z2: number, z3: number)
	local min, max = z1, z1
	if z2 < min then
		min = z2
	end
	if z3 < min then
		min = z3
	end
	if z2 > max then
		max = z2
	end
	if z3 > max then
		max = z3
	end

	Select.gl_add_select(c, UINT32_MAX - min, UINT32_MAX - max)
end

--- gl_draw_point
function Clip.gl_draw_point(c: any, p0: any)
	if p0.clip_code == 0 then
		if c.renderMode == GL_SELECT then
			Select.gl_add_select(c, p0.zp.z, p0.zp.z)
		else
			ZLine.ZB_plot(c.zb, p0.zp)
		end
	end
end

--- clip.c's inline interpolate (used for lines: colour rgb only, no texture)
local function interpolate(q: any, p0: any, p1: any, t: number)
	q.pc[1] = p0.pc[1] + (p1.pc[1] - p0.pc[1]) * t
	q.pc[2] = p0.pc[2] + (p1.pc[2] - p0.pc[2]) * t
	q.pc[3] = p0.pc[3] + (p1.pc[3] - p0.pc[3]) * t
	q.pc[4] = p0.pc[4] + (p1.pc[4] - p0.pc[4]) * t

	q.color[1] = p0.color[1] + (p1.color[1] - p0.color[1]) * t
	q.color[2] = p0.color[2] + (p1.color[2] - p0.color[2]) * t
	q.color[3] = p0.color[3] + (p1.color[3] - p0.color[3]) * t
end

--[[
	Line clipping algorithm from 'Computer Graphics', Principles and Practice
	(ClipLine1 in clip.c).  C passed tmin/tmax by address; here they are returned.
]]
local function ClipLine1(denom: number, num: number, tmin: number, tmax: number): (boolean, number, number)
	if denom > 0 then
		local t = num / denom
		if t > tmax then
			return false, tmin, tmax
		end
		if t > tmin then
			tmin = t
		end
	elseif denom < 0 then
		local t = num / denom
		if t < tmin then
			return false, tmin, tmax
		end
		if t < tmax then
			tmax = t
		end
	elseif num > 0 then
		return false, tmin, tmax
	end
	return true, tmin, tmax
end

--- gl_draw_line
function Clip.gl_draw_line(c: any, p1: any, p2: any)
	local cc1 = p1.clip_code
	local cc2 = p2.clip_code

	if bor(cc1, cc2) == 0 then
		if c.renderMode == GL_SELECT then
			gl_add_select1(c, p1.zp.z, p2.zp.z, p2.zp.z)
		else
			if c.depthTest ~= 0 then
				ZLine.ZB_line_z(c.zb, p1.zp, p2.zp)
			else
				ZLine.ZB_line(c.zb, p1.zp, p2.zp)
			end
		end
	elseif band(cc1, cc2) ~= 0 then
		-- completely outside
		return
	else
		local q1, q2 = Clip.newVertex(), Clip.newVertex()

		local dx = p2.pc[1] - p1.pc[1]
		local dy = p2.pc[2] - p1.pc[2]
		local dz = p2.pc[3] - p1.pc[3]
		local dw = p2.pc[4] - p1.pc[4]
		local x1 = p1.pc[1]
		local y1 = p1.pc[2]
		local z1 = p1.pc[3]
		local w1 = p1.pc[4]

		local tmin, tmax = 0.0, 1.0
		local ok

		ok, tmin, tmax = ClipLine1(dx + dw, -x1 - w1, tmin, tmax)
		if ok then
			ok, tmin, tmax = ClipLine1(-dx + dw, x1 - w1, tmin, tmax)
		end
		if ok then
			ok, tmin, tmax = ClipLine1(dy + dw, -y1 - w1, tmin, tmax)
		end
		if ok then
			ok, tmin, tmax = ClipLine1(-dy + dw, y1 - w1, tmin, tmax)
		end
		if ok then
			ok, tmin, tmax = ClipLine1(dz + dw, -z1 - w1, tmin, tmax)
		end
		if ok then
			ok, tmin, tmax = ClipLine1(-dz + dw, z1 - w1, tmin, tmax)
		end

		if ok then
			interpolate(q1, p1, p2, tmin)
			interpolate(q2, p1, p2, tmax)
			Clip.gl_transform_to_viewport(c, q1)
			Clip.gl_transform_to_viewport(c, q2)

			if c.depthTest ~= 0 then
				ZLine.ZB_line_z(c.zb, q1.zp, q2.zp)
			else
				ZLine.ZB_line(c.zb, q1.zp, q2.zp)
			end
		end
	end
end

--[[
	clip.c's clip_func() macro, which computed the intersection of the segment
	[a,b] with one of the six planes.  `dir`, `dir1`, `dir2` are the 1 based
	indices of the axis being clipped and of the two carried along, and `sign`
	is -1 for the min planes and +1 for the max planes.

	  den   = -(sign * d_dir) + dW
	  t     = (sign * a_dir - a_W) / den      (0 when den == 0)
	  c_dir1 = a_dir1 + t*d_dir1 ...
	  c_dir  = sign * c_W
]]
local function clipPlane(
	cc: { number },
	a: { number },
	b: { number },
	dir: number,
	dir1: number,
	dir2: number,
	sign: number
): number
	local dX = b[dir] - a[dir]
	local d1 = b[dir1] - a[dir1]
	local d2 = b[dir2] - a[dir2]
	local dW = b[4] - a[4]

	local den = -sign * dX + dW
	local t
	if den == 0 then
		t = 0
	else
		t = (sign * a[dir] - a[4]) / den
	end

	cc[dir1] = a[dir1] + t * d1
	cc[dir2] = a[dir2] + t * d2
	cc[4] = a[4] + t * dW
	cc[dir] = sign * cc[4]
	return t
end

-- clip_proc[6], indexed by the CLIP_* bit
local function clip_proc(bit: number, cc: { number }, a: { number }, b: { number }): number
	if bit == 0 then
		return clipPlane(cc, a, b, 1, 2, 3, -1) -- clip_xmin
	elseif bit == 1 then
		return clipPlane(cc, a, b, 1, 2, 3, 1) -- clip_xmax
	elseif bit == 2 then
		return clipPlane(cc, a, b, 2, 1, 3, -1) -- clip_ymin
	elseif bit == 3 then
		return clipPlane(cc, a, b, 2, 1, 3, 1) -- clip_ymax
	elseif bit == 4 then
		return clipPlane(cc, a, b, 3, 1, 2, -1) -- clip_zmin
	else
		return clipPlane(cc, a, b, 3, 1, 2, 1) -- clip_zmax
	end
end

Clip.clip_proc = clip_proc

--- clip.c's updateTmp()
local function updateTmp(c: any, q: any, p0: any, p1: any, t: number)
	if c.currentShadeModel == GL_SMOOTH then
		q.color[1] = p0.color[1] + (p1.color[1] - p0.color[1]) * t
		q.color[2] = p0.color[2] + (p1.color[2] - p0.color[2]) * t
		q.color[3] = p0.color[3] + (p1.color[3] - p0.color[3]) * t
	else
		q.color[1] = p0.color[1]
		q.color[2] = p0.color[2]
		q.color[3] = p0.color[3]
	end

	if c.texture2dEnabled ~= 0 then
		q.tex_coord[1] = p0.tex_coord[1] + (p1.tex_coord[1] - p0.tex_coord[1]) * t
		q.tex_coord[2] = p0.tex_coord[2] + (p1.tex_coord[2] - p0.tex_coord[2]) * t
	end

	q.clip_code = Clip.gl_clipcode(q.pc[1], q.pc[2], q.pc[3], q.pc[4])
	if q.clip_code == 0 then
		Clip.gl_transform_to_viewport(c, q)
	end
end

--- gl_draw_triangle
function Clip.gl_draw_triangle(c: any, p0: any, p1: any, p2: any)
	local cc0 = p0.clip_code
	local cc1 = p1.clip_code
	local cc2 = p2.clip_code

	local co = bor(cc0, bor(cc1, cc2))

	-- we handle the non clipped case here to go faster
	if co == 0 then
		local norm = (p1.zp.x - p0.zp.x) * (p2.zp.y - p0.zp.y)
			- (p2.zp.x - p0.zp.x) * (p1.zp.y - p0.zp.y)

		if norm == 0 then
			return
		end

		local front = bxor(if norm < 0.0 then 1 else 0, c.currentFrontFace)

		-- back face culling
		if c.cullFaceEnabled ~= 0 then
			if c.currentCullFace == GL_BACK then
				-- most used case first
				if front == 0 then
					return
				end
				c.drawTriangleFront(c, p0, p1, p2)
			elseif c.currentCullFace == GL_FRONT then
				if front ~= 0 then
					return
				end
				c.drawTriangleBack(c, p0, p1, p2)
			else
				return
			end
		else
			-- no culling
			if front ~= 0 then
				c.drawTriangleFront(c, p0, p1, p2)
			else
				c.drawTriangleBack(c, p0, p1, p2)
			end
		end
	else
		local c_and = band(cc0, band(cc1, cc2))
		if c_and == 0 then
			Clip.gl_draw_triangle_clip(c, p0, p1, p2, 0)
		end
	end
end

--- gl_draw_triangle_clip
function Clip.gl_draw_triangle_clip(c: any, p0: any, p1: any, p2: any, clip_bit: number)
	local cc0 = p0.clip_code
	local cc1 = p1.clip_code
	local cc2 = p2.clip_code

	local co = bor(cc0, bor(cc1, cc2))
	if co == 0 then
		Clip.gl_draw_triangle(c, p0, p1, p2)
		return
	end

	local c_and = band(cc0, band(cc1, cc2))
	-- the triangle is completely outside
	if c_and ~= 0 then
		return
	end

	-- find the next direction to clip
	local clip_bit_local = clip_bit
	while clip_bit_local < 6 and band(co, 2 ^ clip_bit_local) == 0 do
		clip_bit_local += 1
	end

	-- this test can be true only in case of rounding errors
	if clip_bit_local == 6 then
		return
	end

	local clip_mask = 2 ^ clip_bit_local
	-- C: co1 = (cc[0] ^ cc[1] ^ cc[2]) & clip_mask, i.e. only the plane being
	-- clipped takes part in the "one vertex outside / two outside" decision
	local co1 = band(bxor(bxor(cc0, cc1), cc2), clip_mask)
	-- C tests `cc[i] & clip_mask` in the branches below; only the first two are
	-- ever looked at, the third vertex is the `else` of both chains
	local bit0 = if band(cc0, clip_mask) ~= 0 then 1 else 0
	local bit1 = if band(cc1, clip_mask) ~= 0 then 1 else 0

	if co1 ~= 0 then
		-- one point outside
		local q0, q1, q2
		if bit0 == 1 then
			q0, q1, q2 = p0, p1, p2
		elseif bit1 == 1 then
			q0, q1, q2 = p1, p2, p0
		else
			q0, q1, q2 = p2, p0, p1
		end

		local tmp1, tmp2 = Clip.newVertex(), Clip.newVertex()

		local tt = clip_proc(clip_bit_local, tmp1.pc, q0.pc, q1.pc)
		updateTmp(c, tmp1, q0, q1, tt)

		tt = clip_proc(clip_bit_local, tmp2.pc, q0.pc, q2.pc)
		updateTmp(c, tmp2, q0, q2, tt)

		tmp1.edge_flag = q0.edge_flag
		local edge_flag_tmp = q2.edge_flag
		q2.edge_flag = 0
		Clip.gl_draw_triangle_clip(c, tmp1, q1, q2, clip_bit_local + 1)

		tmp2.edge_flag = 1
		tmp1.edge_flag = 0
		q2.edge_flag = edge_flag_tmp
		Clip.gl_draw_triangle_clip(c, tmp2, tmp1, q2, clip_bit_local + 1)
	else
		-- two points outside
		local q0, q1, q2
		if bit0 == 0 then
			q0, q1, q2 = p0, p1, p2
		elseif bit1 == 0 then
			q0, q1, q2 = p1, p2, p0
		else
			q0, q1, q2 = p2, p0, p1
		end

		local tmp1, tmp2 = Clip.newVertex(), Clip.newVertex()

		local tt = clip_proc(clip_bit_local, tmp1.pc, q0.pc, q1.pc)
		updateTmp(c, tmp1, q0, q1, tt)

		tt = clip_proc(clip_bit_local, tmp2.pc, q0.pc, q2.pc)
		updateTmp(c, tmp2, q0, q2, tt)

		tmp1.edge_flag = 1
		tmp2.edge_flag = q2.edge_flag
		Clip.gl_draw_triangle_clip(c, q0, tmp1, tmp2, clip_bit_local + 1)
	end
end

--- gl_draw_triangle_select
function Clip.gl_draw_triangle_select(c: any, p0: any, p1: any, p2: any)
	gl_add_select1(c, p0.zp.z, p1.zp.z, p2.zp.z)
end

--- gl_draw_triangle_fill
function Clip.gl_draw_triangle_fill(c: any, p0: any, p1: any, p2: any)
	if c.texture2dEnabled ~= 0 then
		ZBuffer.ZB_setTexture(c.zb, c.currentTexture.images[1].pixmap)
		ZTriangle.fillTriangle(c.zb, p0.zp, p1.zp, p2.zp, ZTriangle.MAPPING_PERSPECTIVE)
	elseif c.currentShadeModel == GL_SMOOTH then
		ZTriangle.fillTriangle(c.zb, p0.zp, p1.zp, p2.zp, ZTriangle.SMOOTH)
	else
		ZTriangle.fillTriangle(c.zb, p0.zp, p1.zp, p2.zp, ZTriangle.FLAT)
	end
end

--- gl_draw_triangle_line: render a clipped triangle in line mode
function Clip.gl_draw_triangle_line(c: any, p0: any, p1: any, p2: any)
	if c.depthTest ~= 0 then
		if p0.edge_flag ~= 0 then
			ZLine.ZB_line_z(c.zb, p0.zp, p1.zp)
		end
		if p1.edge_flag ~= 0 then
			ZLine.ZB_line_z(c.zb, p1.zp, p2.zp)
		end
		if p2.edge_flag ~= 0 then
			ZLine.ZB_line_z(c.zb, p2.zp, p0.zp)
		end
	else
		if p0.edge_flag ~= 0 then
			ZLine.ZB_line(c.zb, p0.zp, p1.zp)
		end
		if p1.edge_flag ~= 0 then
			ZLine.ZB_line(c.zb, p1.zp, p2.zp)
		end
		if p2.edge_flag ~= 0 then
			ZLine.ZB_line(c.zb, p2.zp, p0.zp)
		end
	end
end

--- gl_draw_triangle_point: render a clipped triangle in point mode
function Clip.gl_draw_triangle_point(c: any, p0: any, p1: any, p2: any)
	if p0.edge_flag ~= 0 then
		ZLine.ZB_plot(c.zb, p0.zp)
	end
	if p1.edge_flag ~= 0 then
		ZLine.ZB_plot(c.zb, p1.zp)
	end
	if p2.edge_flag ~= 0 then
		ZLine.ZB_plot(c.zb, p2.zp)
	end
end

return Clip
