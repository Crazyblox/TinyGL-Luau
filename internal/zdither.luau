--!strict
--[[
	zdither.luau — port of TinyGL's src/zdither.c.

	Ordered 16 bit -> 8 bit index dithering with the same 4x4 Bayer kernel and
	the same two lookup tables as the C code; ZB_initDither is a direct
	translation.

	Two versions of the frame buffer conversion are provided:

	* ZB_ditherFrameBuffer() is the faithful translation of the C
	  ZB_ditherFrameBuffer().  That code loads and stores *two* pixels at a time
	  through 32 bit / 16 bit accesses, and its loops walk the destination in
	  4x4 tiles, advancing 16 destination bytes per 2 pixel pair.  The result is
	  that only some of the output bytes are ever written (the rest keep
	  whatever the caller had put in the frame buffer).  It is reproduced here
	  byte for byte — including not touching the untouched bytes — so this port
	  can be compared against a C build of TinyGL.  Destination bytes that C
	  would leave alone are left alone here too, so callers should initialise
	  the destination (TinyGL's own examples never use the 8 bit mode).

	* ZB_ditherFrameBufferFull() writes every pixel, using the same per-pixel
	  half of the C macro and the kernel value that belongs to that pixel.  Use
	  this one if you actually want a dithered 8 bit image; it is what the C code
	  was presumably meant to do.  It is kept out of the byte-exact comparison
	  suite for that reason.

	DITHER_INDEX() may look up a (r,g,b) triple beyond the color_indexes array
	its caller allocated (TinyGL does that with no bounds check); both versions
	only ever read indexes that exist, see the comment in ZB_initDither.
]]

local Util = require("./util")

local buffer = buffer --[[(standard library)]]
local band, bor = bit32.band, bit32.bor
local rshift, lshift = bit32.rshift, bit32.lshift
local u32 = Util.u32

local zdither = {}

local _R = 5
local _G = 9
local _B = 5
local _DX = 4
local _DY = 4
local _D = _DX * _DY
local MAXC = 256
local DITHER_TABLE_SIZE = lshift(1, 15)

local function DITHER_INDEX(r: number, g: number, b: number): number
	return b + g * _B + r * (_B * _G)
end

-- kernel8[]: the 4x4 ordered dither matrix, scaled by MAXC
local kernel8 = {
	0 * MAXC,
	8 * MAXC,
	2 * MAXC,
	10 * MAXC,
	12 * MAXC,
	4 * MAXC,
	14 * MAXC,
	6 * MAXC,
	3 * MAXC,
	11 * MAXC,
	1 * MAXC,
	9 * MAXC,
	15 * MAXC,
	7 * MAXC,
	13 * MAXC,
	5 * MAXC,
}

--- ZB_initDither: build the palette (colorTable, an array of 0xRRGGBB ints the
--- caller owns) and the two internal tables:
---   dctable: 32768 entries, 16 bit pattern -> palette index
---   ctable : nb_colors entries, palette index -> 0xRRGGBB
function zdither.ZB_initDither(
	zb: any,
	nb_colors: number,
	colorIndexes: { number },
	colorTable: { number }
)
	if nb_colors < (_R * _G * _B) then
		error("zdither: not enough colors")
	end

	for i = 0, nb_colors - 1 do
		colorTable[i + 1] = 0
	end

	zb.nb_colors = nb_colors
	local ctable = table.create(nb_colors)
	zb.ctable = ctable

	for r = 0, _R - 1 do
		for g = 0, _G - 1 do
			for b = 0, _B - 1 do
				-- C integer division, truncating towards zero
				local r1 = (r * 255) // (_R - 1)
				local g1 = (g * 255) // (_G - 1)
				local b1 = (b * 255) // (_B - 1)
				local index = DITHER_INDEX(r, g, b)
				local c = lshift(r1, 16) + lshift(g1, 8) + b1
				ctable[index + 1] = c
				colorTable[index + 1] = c
			end
		end
	end

	local dctable = buffer.create(DITHER_TABLE_SIZE)
	-- DITHER_INDEX(7,15,7) = 7 + 75 + 200 = 280, while the caller normally passes
	-- the 5*9*5 = 225 indexes TinyGL's own front ends allocate.  C reads past the
	-- end of that array here; wrap into it instead, which keeps the table
	-- construction deterministic.
	local maxIndex = #colorIndexes
	for i = 0, DITHER_TABLE_SIZE - 1 do
		local r = band(rshift(i, 12), 0x7)
		local g = band(rshift(i, 8), 0xF)
		local b = band(rshift(i, 3), 0x7)
		local index = DITHER_INDEX(r, g, b) % maxIndex
		buffer.writeu8(dctable, i, colorIndexes[index + 1] :: number)
	end
	zb.dctable = dctable
end

--- ZB_closeDither
function zdither.ZB_closeDither(zb: any)
	zb.ctable = nil
	zb.dctable = nil
end

--[[
	The per-pixel-pair half of the C code:

	  v   = *(unsigned int *)(pp + a)              two 16 bit pixels
	  g   = (v & 0x07DF07DF) + g_d
	  r   = (((v & 0xF800F800) >> 2) + r_d) & 0x70007000
	  t   = r | g
	  c   = ctable[t & 0xFFFF] | (ctable[t >> 16] << 8)
	  *(unsigned short *)(dest + a) = c            two 8 bit indexes

	C computes it on 32 bit signed ints; bit32 gives the same two's complement
	results.  `vLow`/`vHigh` are the two 16 bit pixels (little endian order).
]]
local function ditherPair(vLow: number, vHigh: number, r_d: number, g_d: number, ctable: buffer): (number, number)
	-- the 32 bit value C loads: low pixel in the low half (little endian)
	local v = vLow + vHigh * 0x10000
	local g = u32(band(v, 0x07DF07DF) + g_d)
	-- `(v & 0xF800F800)` converts to `unsigned int` (the mask does not fit in an
	-- int), so the shift that follows is a *logical* shift in C
	local r = band(u32(rshift(band(v, 0xF800F800), 2) + r_d), 0x70007000)
	local t = band(bor(r, g), 0xFFFFFFFF)
	return buffer.readu8(ctable, band(t, 0xFFFF)), buffer.readu8(ctable, rshift(t, 16))
end

--- The dither offsets of one 4x4 tile column pair, as C computes them for the
--- two pixels of a pair (little endian: c1 is the left pixel, c2 the right one).
--- The blue offsets are folded into the green ones, exactly as the C code does
--- (`g_d = b_d | g_d;`), so only two values come out.
local function tileOffsets(yk: number, xk: number): (number, number)
	local c1 = kernel8[yk * _DX + xk + 1]
	local c2 = kernel8[yk * _DX + xk + 2]

	local r_d = band(rshift(band(lshift(c1, 2), 0xF800), 2), 0xFFFF)
	r_d = bor(r_d, lshift(band(rshift(band(lshift(c2, 2), 0xF800), 2), 0xFFFF), 16))

	local g_d = band(rshift(c1, 4), 0x07C0)
	g_d = bor(g_d, lshift(band(rshift(c2, 4), 0x07C0), 16))

	local b_d = band(rshift(c1, 9), 0x001F)
	b_d = bor(b_d, lshift(band(rshift(c2, 9), 0x001F), 16))

	-- C really does this: g_d = b_d | g_d, so the blue offsets are folded into
	-- the green ones.
	g_d = bor(b_d, g_d)
	return r_d, g_d
end

--- ZB_ditherFrameBuffer, byte for byte.  `linesize` is the destination stride in
--- bytes (ZB_copyFrameBuffer passes the value it was given shifted right by 1).
function zdither.ZB_ditherFrameBuffer(zb: any, dest: buffer, linesize: number)
	local ctable = zb.dctable :: buffer
	local pbuf, xsize, ysize = zb.pbuf, zb.xsize, zb.ysize
	local destSize = buffer.len(dest)
	-- C walks pbuf with a row stride of xsize pixels; this port keeps `linesize`
	-- pixels, which is the same number for every xsize TinyGL accepts
	local pixCount = ysize * zb.linesize

	for yk = 0, _DY - 1 do
		for xk = 0, _DX - 2, 2 do
			local r_d, g_d = tileOffsets(yk, xk)

			local dest1 = yk * linesize + xk -- destination byte offset of the tile
			-- pixel offset of the tile in pbuf (C uses `xsize` for the row stride of
			-- its frame buffer; this port strides pbuf with `linesize`)
			local pp1 = yk * zb.linesize + xk

			local y = yk
			while y < ysize do
				local destOff = dest1
				local ppOff = pp1
				local x = xk
				while x < xsize do
					-- the four DITHER_PIXEL2(a) calls of the C macro, a = 0, 4, 8, 12
					for a = 0, 3 do
						-- `pp + a` is in 16 bit pixels and `dest + a` in bytes, so the same
						-- offset picks the same two pixels in both buffers
						local srcPix = ppOff + a * 4
						local dstByte = destOff + a * 4
						if srcPix + 1 < pixCount and dstByte + 1 < destSize then
							local cLow, cHigh = ditherPair(
								buffer.readu16(pbuf, srcPix * 2),
								buffer.readu16(pbuf, srcPix * 2 + 2),
								r_d,
								g_d,
								ctable
							)
							buffer.writeu8(dest, dstByte, cLow)
							buffer.writeu8(dest, dstByte + 1, cHigh)
						end
					end
					destOff += 16
					ppOff += 16
					x += 16
				end
				dest1 += linesize * 4
				pp1 += zb.linesize * 4
				y += 4
			end
		end
	end
end

--- Every pixel dithered and written; see the header comment for how this differs
--- from the C version.  `linesize` is the destination stride in bytes.
function zdither.ZB_ditherFrameBufferFull(zb: any, dest: buffer, linesize: number)
	local ctable = zb.dctable :: buffer
	local pbuf, xsize, ysize = zb.pbuf, zb.xsize, zb.ysize

	for y = 0, ysize - 1 do
		local yk = y % _DY
		local drow = y * linesize
		local srow = y * zb.linesize * 2
		for x = 0, xsize - 1 do
			local xk = x % _DX
			local c1 = kernel8[yk * _DX + xk + 1]

			-- the dither offsets for this pixel alone (the C macro keeps them in
			-- the two halves of a 32 bit register pair)
			local r_d = band(rshift(band(lshift(c1, 2), 0xF800), 2), 0xFFFF)
			local g_d = bor(band(rshift(c1, 4), 0x07C0), band(rshift(c1, 9), 0x001F))

			local v = buffer.readu16(pbuf, srow + x * 2)
			local g = band(v, 0x07DF) + g_d
			local r = band(band(rshift(v, 2), 0xF800) + r_d, 0x7000)
			local t = bor(r, g)

			buffer.writeu8(dest, drow + x, buffer.readu8(ctable, band(t, 0xFFFF)))
		end
	end
end

return zdither
