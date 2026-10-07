--!strict
--[[
	zline.luau — port of TinyGL's src/zline.c / src/zline.h.

	Bresenham line drawing with depth test and optional colour interpolation.

	C generated the four variants (with/without Z test, with/without rgb
	interpolation) by including zline.h four times with different INTERP_*
	macros defined; here the same body is written once and parameterised.

	Notes on fidelity:
	* `ZCMP(z, zpix)` is `(z) >= (zpix)`, so equal depth passes the test.
	* the colour interpolation works on `unsigned int` values scaled by 2^8 and
	  the pixel is written with `RGB_TO_PIXEL(r >> 8, g >> 8, b >> 8)`; the
	  wrapping that C performs is reproduced with util.u32().
	* the single-pixel special case (dx == dy == 0) uses the *second* point's
	  colour for interpolated lines, exactly like the C macro expansion does.
]]

local Config = require("./config")
local Util = require("./util")

local buffer = buffer --[[(standard library)]]
local band, bor = bit32.band, bit32.bor
local asr, idiv, u32 = Util.asr, Util.idiv, Util.u32

local ZLine = {}

local ZB_POINT_Z_FRAC_BITS = Config.ZB_POINT_Z_FRAC_BITS
local PSZB = Config.PSZB

--[[
	RGB_TO_PIXEL from zbuffer.h.  Note the blue term is unmasked in C: for the
	interpolated lines, which accumulate `r = p2->r << 8` in an unsigned int, it
	can exceed 16 bits and `b >> 11` then reaches into the green field (and
	above, where the 16 bit store drops it).
]]
local function RGB_TO_PIXEL(r: number, g: number, b: number): number
	return bor(bor(band(r, 0xF800), band(asr(g, 5), 0x07E0)), asr(b, 11))
end

ZLine.RGB_TO_PIXEL = RGB_TO_PIXEL

--[[
	C's DRAWLINE(dx, dy, inc_1, inc_2) macro.

	`major`/`minor` are the two deltas with major >= 0 and major the number of
	steps minus one (C's `n = dx`, the loop is a do/while so it always draws the
	starting pixel).

	`pixelInc1`/`pixelInc2` are steps in *pixels* of the colour frame buffer
	(row stride = zb.linesize) and `zInc1`/`zInc2` steps in *entries* of the
	depth buffer (row stride = zb.xsize).  C derived both from a single `sx =
	zb->xsize` because with PSZB == 2 the two strides coincide.
]]
local function drawLine(
	zb: any,
	p1: any,
	p2: any,
	interpRGB: boolean,
	interpZ: boolean,
	color: number,
	major: number,
	minor: number,
	pixelInc1: number,
	pixelInc2: number,
	zInc1: number,
	zInc2: number
)
	local pbuf, zbuf = zb.pbuf, zb.zbuf
	local pofs = (p1.y * zb.linesize + p1.x) * PSZB -- byte offset into the colour buffer
	local zofs = (p1.y * zb.xsize + p1.x) * 2 -- byte offset into the depth buffer

	local z = p1.z
	local r, g, b, rinc, ginc, binc = 0, 0, 0, 0, 0, 0
	if interpRGB then
		r = u32(p2.r * 256)
		g = u32(p2.g * 256)
		b = u32(p2.b * 256)
		rinc = idiv((p2.r - p1.r) * 256, major)
		ginc = idiv((p2.g - p1.g) * 256, major)
		binc = idiv((p2.b - p1.b) * 256, major)
	end

	local n = major
	-- with the depth test off TinyGL uses the ZB_line()/ZB_line_flat() variants,
	-- which neither read nor write the depth buffer at all; that is observable,
	-- because a line drawn that way leaves no depth for later primitives
	local zinc = if interpZ then idiv(p2.z - p1.z, major) else 0
	local a = 2 * minor - major
	local dy2 = 2 * minor
	local dx2 = 2 * major - dy2

	while true do
		local write = true
		local zz = 0
		if interpZ then
			zz = asr(z, ZB_POINT_Z_FRAC_BITS)
			write = zz >= buffer.readu16(zbuf, zofs)
		end
		if write then
			if interpRGB then
				buffer.writeu16(pbuf, pofs, RGB_TO_PIXEL(asr(r, 8), asr(g, 8), asr(b, 8)))
			else
				buffer.writeu16(pbuf, pofs, color)
			end
			if interpZ then
				buffer.writeu16(zbuf, zofs, zz)
			end
		end

		if interpZ then
			z += zinc
		end
		if interpRGB then
			r += rinc
			g += ginc
			b += binc
		end

		if a > 0 then
			pofs += pixelInc1 * PSZB
			zofs += zInc1 * 2
			a -= dx2
		else
			pofs += pixelInc2 * PSZB
			zofs += zInc2 * 2
			a += dy2
		end

		n -= 1
		if n < 0 then
			break
		end
	end
end

--[[
	The common prologue of the four C variants: order the endpoints, handle the
	degenerate case and pick one of the four octant loops.
]]
local function lineBase(zb: any, pa: any, pb: any, interpRGB: boolean, interpZ: boolean, color: number)
	local p1, p2 = pa, pb
	if p1.y > p2.y or (p1.y == p2.y and p1.x > p2.x) then
		p1, p2 = p2, p1
	end

	local sx, ls = zb.xsize, zb.linesize -- depth / colour row strides
	local dx = p2.x - p1.x
	local dy = p2.y - p1.y

	if dx == 0 and dy == 0 then
		-- PUTPIXEL() with no loop
		local write = true
		local zz = 0
		local zofs = (p1.y * sx + p1.x) * 2
		if interpZ then
			zz = asr(p1.z, ZB_POINT_Z_FRAC_BITS)
			write = zz >= buffer.readu16(zb.zbuf, zofs)
		end
		if write then
			local c = color
			if interpRGB then
				c = RGB_TO_PIXEL(asr(u32(p2.r * 256), 8), asr(u32(p2.g * 256), 8), asr(u32(p2.b * 256), 8))
			end
			buffer.writeu16(zb.pbuf, (p1.y * ls + p1.x) * PSZB, c)
			if interpZ then
				buffer.writeu16(zb.zbuf, zofs, zz)
			end
		end
		return
	end

	if dx > 0 then
		if dx >= dy then
			drawLine(zb, p1, p2, interpRGB, interpZ, color, dx, dy, ls + 1, 1, sx + 1, 1)
		else
			drawLine(zb, p1, p2, interpRGB, interpZ, color, dy, dx, ls + 1, ls, sx + 1, sx)
		end
	else
		dx = -dx
		if dx >= dy then
			drawLine(zb, p1, p2, interpRGB, interpZ, color, dx, dy, ls - 1, -1, sx - 1, -1)
		else
			drawLine(zb, p1, p2, interpRGB, interpZ, color, dy, dx, ls - 1, ls, sx - 1, sx)
		end
	end
end

--- ZB_line_z: line with depth test
function ZLine.ZB_line_z(zb: any, p1: any, p2: any)
	local color1 = RGB_TO_PIXEL(p1.r, p1.g, p1.b)
	local color2 = RGB_TO_PIXEL(p2.r, p2.g, p2.b)
	-- choose if the line should have its color interpolated or not
	if color1 == color2 then
		lineBase(zb, p1, p2, false, true, color1)
	else
		lineBase(zb, p1, p2, true, true, 0)
	end
end

--- ZB_line: line without the depth test.  Like C's ZB_line()/ZB_line_flat()
--- pair, these neither read nor write the depth buffer, so a line drawn with
--- GL_DEPTH_TEST off leaves no depth behind.
function ZLine.ZB_line(zb: any, p1: any, p2: any)
	local color1 = RGB_TO_PIXEL(p1.r, p1.g, p1.b)
	local color2 = RGB_TO_PIXEL(p2.r, p2.g, p2.b)
	if color1 == color2 then
		lineBase(zb, p1, p2, false, false, color1)
	else
		lineBase(zb, p1, p2, true, false, 0)
	end
end

--- ZB_plot: one pixel
function ZLine.ZB_plot(zb: any, p: any)
	local zofs = (p.y * zb.xsize + p.x) * 2
	local zz = asr(p.z, ZB_POINT_Z_FRAC_BITS)
	if zz >= buffer.readu16(zb.zbuf, zofs) then
		buffer.writeu16(zb.pbuf, (p.y * zb.linesize + p.x) * PSZB, RGB_TO_PIXEL(p.r, p.g, p.b))
		buffer.writeu16(zb.zbuf, zofs, zz)
	end
end

return ZLine
