--!strict
--[[
	zbuffer.luau — port of TinyGL's src/zbuffer.c / src/zbuffer.h.

	The Z buffer holds one 16 bit depth value per pixel plus a frame buffer of
	16 bit RGB pixels (TGL_FEATURE_RENDER_BITS == 16, which is upstream's only
	fully working internal format).

	Storage
	-------
	C used raw pointers; this port uses Luau `buffer` objects:

	* `zbuf`  — one u16 per pixel, `xsize * ysize` entries, no padding.
	* `pbuf`  — the colour frame buffer, PSZB bytes per pixel.  C kept
	  `linesize` in *bytes*; because Luau buffers are always dense we keep
	  `linesize` in *pixels* (always >= xsize; upstream keeps it equal to
	  xsize, and ZB_resize/ZB_open round xsize down to a multiple of 4 exactly
	  like the C code does).  When an external frame buffer is supplied it must
	  be `ysize * linesize * PSZB` bytes long.

	Pixel helpers: `pixelGet/pixelSet` take a *pixel index* (y*linesize + x),
	`zGet/zSet` take a *z index* (y*xsize + x).  Both hide the byte offsets.
]]

local Config = require("./config")
local ZDither = require("./zdither")

local buffer = buffer --[[(the standard library)]]
local band, bor = bit32.band, bit32.bor
local lshift, rshift = bit32.lshift, bit32.rshift
local bnot = bit32.bnot

local ZBuffer = {}

export type ZBuffer = {
	xsize: number,
	ysize: number,
	linesize: number, -- in pixels, see header comment
	mode: number,
	zbuf: buffer,
	pbuf: buffer,
	frameBufferAllocated: boolean,
	nb_colors: number,
	dctable: buffer?,
	ctable: { number }?,
	currentTexture: buffer?,
	-- cached solid-colour row used to speed up ZB_clear (pure an optimisation)
	clearRow: buffer?,
	clearRowColor: number,
}

export type ZBufferPoint = {
	x: number,
	y: number,
	z: number, -- integer coordinates in the z buffer
	s: number,
	t: number, -- coordinates for the mapping
	r: number,
	g: number,
	b: number, -- colour indexes
	sz: number,
	tz: number, -- temporary coordinates for the mapping
}

function ZBuffer.newPoint(): ZBufferPoint
	return { x = 0, y = 0, z = 0, s = 0, t = 0, r = 0, g = 0, b = 0, sz = 0, tz = 0 }
end

--[[
	RGB_TO_PIXEL from zbuffer.h (16 bit mode).  r, g, b are in the
	ZB_POINT_{RED,GREEN,BLUE}_{MIN,MAX} fixed point range (roughly 0..65536), and
	the blue term is *not* masked in C: `((b) >> 11)` is ORed in as is, so a blue
	value above 0xFFFF (which the interpolated line colouring happily produces,
	since it accumulates into an `unsigned int` scaled by 256) spills into the
	green field.  That is visible in the output, so it is reproduced exactly.
]]
function ZBuffer.RGB_TO_PIXEL(r: number, g: number, b: number): number
	return bor(bor(band(r, 0xF800), band(rshift(g, 5), 0x07E0)), rshift(b, 11))
end

function ZBuffer.pixelGet(zb: ZBuffer, index: number): number
	return buffer.readu16(zb.pbuf, index * 2)
end

function ZBuffer.pixelSet(zb: ZBuffer, index: number, value: number)
	buffer.writeu16(zb.pbuf, index * 2, value)
end

function ZBuffer.zGet(zb: ZBuffer, index: number): number
	return buffer.readu16(zb.zbuf, index * 2)
end

function ZBuffer.zSet(zb: ZBuffer, index: number, value: number)
	buffer.writeu16(zb.zbuf, index * 2, value)
end

--- byte offset of the first byte of pixel (x, y) in the colour frame buffer
function ZBuffer.pixelByte(zb: ZBuffer, x: number, y: number): number
	return (y * zb.linesize + x) * 2
end

--- byte offset of the depth of pixel (x, y)
function ZBuffer.zByte(zb: ZBuffer, x: number, y: number): number
	return (y * zb.xsize + x) * 2
end

--[[
	ZB_open.  `frameBuffer` is optional: when nil a frame buffer is allocated
	(like C's gl_malloc), otherwise it must be a `buffer` large enough for
	ysize * linesize * PSZB bytes.

	Returns nil on out of memory in C; here an invalid size is a hard error
	instead, since Luau has no malloc failure.
]]
function ZBuffer.ZB_open(
	xsize: number,
	ysize: number,
	mode: number,
	nb_colors: number?,
	colorIndexes: { number }?,
	colorTable: { number }?,
	frameBuffer: buffer?
): ZBuffer
	if xsize <= 0 or ysize <= 0 then
		error("ZB_open: invalid size")
	end
	if
		mode ~= Config.ZB_MODE_5R6G5B and mode ~= Config.ZB_MODE_INDEX and mode ~= Config.ZB_MODE_RGBA and mode ~= Config.ZB_MODE_RGB24
	then
		error("ZB_open: unknown display mode " .. tostring(mode))
	end

	-- C: linesize = (xsize * PSZB + 3) & ~3, in *bytes*; this port keeps it in
	-- pixels (the two only differ for xsize not a multiple of 4).
	local linesize = band(xsize * Config.PSZB + 3, bnot(3)) // Config.PSZB

	local zb: ZBuffer = {
		xsize = xsize,
		ysize = ysize,
		linesize = linesize,
		mode = mode,
		zbuf = buffer.create(xsize * ysize * 2),
		pbuf = buffer.create(0),
		frameBufferAllocated = false,
		nb_colors = 0,
		dctable = nil,
		ctable = nil,
		currentTexture = nil,
		clearRow = nil,
		clearRowColor = -1,
	}

	if mode == Config.ZB_MODE_INDEX then
		ZDither.ZB_initDither(zb, nb_colors or 0, colorIndexes or error("ZB_open: color indexes required"), colorTable or {})
	else
		zb.nb_colors = 0
	end

	if frameBuffer == nil then
		zb.pbuf = buffer.create(ysize * linesize * Config.PSZB)
		zb.frameBufferAllocated = true
	else
		local need = ysize * linesize * Config.PSZB
		if buffer.len(frameBuffer) < need then
			error(("ZB_open: frame buffer too small (need %d bytes, got %d)"):format(need, buffer.len(frameBuffer)))
		end
		zb.pbuf = frameBuffer
		zb.frameBufferAllocated = false
	end

	zb.currentTexture = nil
	return zb
end

--- ZB_close: nothing to do in Luau but the dither tables, which C frees.
function ZBuffer.ZB_close(zb: ZBuffer)
	if zb.mode == Config.ZB_MODE_INDEX then
		ZDither.ZB_closeDither(zb)
	end
	zb.pbuf = buffer.create(0)
	zb.zbuf = buffer.create(0)
end

--- ZB_resize.  `frameBuffer` nil reallocates, otherwise it must be a `buffer`
--- of at least ysize * (xsize & ~3) * PSZB bytes.
function ZBuffer.ZB_resize(zb: ZBuffer, frameBuffer: buffer?, xsize: number, ysize: number)
	xsize = band(xsize, bnot(3)) -- xsize must be a multiple of 4

	if xsize <= 0 or ysize <= 0 then
		error("ZB_resize: size too small")
	end

	zb.xsize = xsize
	zb.ysize = ysize
	zb.linesize = band(xsize * Config.PSZB + 3, bnot(3)) // Config.PSZB
	zb.clearRow = nil
	zb.clearRowColor = -1

	zb.zbuf = buffer.create(xsize * ysize * 2)

	if frameBuffer == nil then
		zb.pbuf = buffer.create(ysize * zb.linesize * Config.PSZB)
		zb.frameBufferAllocated = true
	else
		local need = ysize * zb.linesize * Config.PSZB
		if buffer.len(frameBuffer) < need then
			error(("ZB_resize: frame buffer too small (need %d bytes, got %d)"):format(need, buffer.len(frameBuffer)))
		end
		zb.pbuf = frameBuffer
		zb.frameBufferAllocated = false
	end
end

--- memset_s() from zbuffer.c: fill `count` 16 bit values with `val`.
function ZBuffer.fillZ(zb: ZBuffer, val: number)
	local zbuf, count = zb.zbuf, zb.xsize * zb.ysize
	for i = 0, count - 1 do
		buffer.writeu16(zbuf, i * 2, val)
	end
end

local function fillColourRow(zb: ZBuffer, color: number): buffer
	local row = zb.clearRow
	if row == nil or zb.clearRowColor ~= color then
		row = buffer.create(zb.xsize * 2)
		for i = 0, zb.xsize - 1 do
			buffer.writeu16(row, i * 2, color)
		end
		zb.clearRow = row
		zb.clearRowColor = color
		return row :: buffer
	end
	return row
end

--- ZB_clear
function ZBuffer.ZB_clear(
	zb: ZBuffer,
	clearZ: number,
	z: number,
	clearColor: number,
	r: number,
	g: number,
	b: number
)
	if clearZ ~= 0 then
		ZBuffer.fillZ(zb, z)
	end
	if clearColor ~= 0 then
		local color = ZBuffer.RGB_TO_PIXEL(r, g, b)
		local row = fillColourRow(zb, color)
		local pbuf, linesize = zb.pbuf, zb.linesize
		local nbytes = zb.xsize * 2
		for y = 0, zb.ysize - 1 do
			buffer.copy(pbuf, y * linesize * 2, row, 0, nbytes)
		end
	end
end

--[[
	ZB_copyBuffer: plain line by line copy (internal format == frame buffer
	format).  `linesize` is in BYTES, as in C.
]]
function ZBuffer.copyBuffer(zb: ZBuffer, buf: buffer, linesize: number)
	local n = zb.xsize * Config.PSZB
	for y = 0, zb.ysize - 1 do
		buffer.copy(buf, y * linesize, zb.pbuf, y * zb.linesize * Config.PSZB, n)
	end
end

--- ZB_copyFrameBufferRGB32: 16 bit RGB -> 32 bit packed pixels.
--- The C macro is equivalent to, per pixel:
---   out = (b << 3) | (g << 10) | (r << 19)   (little endian: bytes B, G, R, 0)
function ZBuffer.copyFrameBufferRGB32(zb: ZBuffer, buf: buffer, linesize: number)
	local pbuf, zsrc = zb.pbuf, zb.linesize * 2
	for y = 0, zb.ysize - 1 do
		local dst = y * linesize
		local src = y * zsrc
		for x = 0, zb.xsize - 1 do
			local v = buffer.readu16(pbuf, src + x * 2)
			buffer.writeu32(
				buf,
				dst + x * 4,
				bor(bor(lshift(band(v, 0x001F), 3), lshift(band(v, 0x07E0), 5)), lshift(band(v, 0xF800), 8))
			)
		end
	end
end

--[[
	RGB16_TO_RGB24() from zbuffer.c, for the little endian case: it turns four
	16 bit pixels (packed as two 32 bit words v1 = p0 | p1 << 16 and
	v2 = p2 | p3 << 16) into three 32 bit words, i.e. twelve bytes.  Upstream
	comments the layout as "order: RGBR GBRG BRGB": the twelve bytes are *not*
	p0.p0.p0 p1.p1.p1 ..., the channels come out rotated inside every aligned
	four byte group, which is why the macro is flagged "not tested" in TinyGL.
	It is reproduced here byte for byte anyway, because that is what a C build
	of TinyGL writes into a 24 bit frame buffer.
]]
local function rgb16ToRGB24(v1: number, v2: number): (number, number, number)
	local r1 = band(v1, 0xF800F800)
	local g1 = lshift(band(v1, 0x07E007E0), 5)
	local b1 = lshift(band(v1, 0x001F001F), 3)
	local gb1 = bor(g1, b1)
	local p0 = bor(bor(lshift(band(gb1, 0x0000FFFF), 8), lshift(r1, 16)), rshift(r1, 24))

	local g2 = lshift(band(v2, 0x07E007E0), 5)
	local b2 = lshift(band(v2, 0x001F001F), 3)
	local gb2 = bor(g2, b2)

	local p1 = bor(bor(band(gb1, 0xFFFF0000), band(v2, 0xF800)), band(rshift(gb2, 8), 0xFF))
	local p2 = bor(bor(lshift(gb2, 24), rshift(band(v2, 0xF8000000), 8)), rshift(gb2, 16))
	return p0, p1, p2
end

local function putLE32(buf: buffer, o: number, v: number)
	buffer.writeu8(buf, o, band(v, 0xFF))
	buffer.writeu8(buf, o + 1, band(rshift(v, 8), 0xFF))
	buffer.writeu8(buf, o + 2, band(rshift(v, 16), 0xFF))
	buffer.writeu8(buf, o + 3, band(rshift(v, 24), 0xFF))
end

--- ZB_copyFrameBufferRGB24.  `linesize` is the destination stride in *pixels*
--- (the C code multiplies it by three), and, as in C, only the first
--- `(xsize >> 2) * 4` pixels of each row are written.
function ZBuffer.copyFrameBufferRGB24(zb: ZBuffer, buf: buffer, linesize: number)
	local pbuf = zb.pbuf
	local srcStride = zb.linesize * 2 -- bytes per row of the internal frame buffer
	local dstStride = linesize * 3 -- the C code does linesize = linesize * 3
	local n = rshift(zb.xsize, 2) -- groups of four pixels, like C's do/while loop
	for y = 0, zb.ysize - 1 do
		local dst = y * dstStride
		local src = y * srcStride
		for i = 0, n - 1 do
			-- two 32 bit loads; assembled from 16 bit reads so that the port does
			-- not depend on the alignment of `pbuf`
			local o = src + i * 8
			local v1 = buffer.readu16(pbuf, o) + buffer.readu16(pbuf, o + 2) * 0x10000
			local v2 = buffer.readu16(pbuf, o + 4) + buffer.readu16(pbuf, o + 6) * 0x10000
			local w0, w1, w2 = rgb16ToRGB24(v1, v2)
			local d = dst + i * 12
			putLE32(buf, d, w0)
			putLE32(buf, d + 4, w1)
			putLE32(buf, d + 8, w2)
		end
	end
end

--[[
	ZB_copyFrameBuffer: dispatch on the display mode, exactly like C, including
	C's rather inconsistent `linesize` conventions.  What the caller must pass:

	  ZB_MODE_5R6G5B  destination row stride in bytes   (xsize * 2)
	  ZB_MODE_RGBA    destination row stride in bytes   (xsize * 4)
	  ZB_MODE_RGB24   destination row stride in PIXELS  (xsize)
	  ZB_MODE_INDEX   destination row stride in bytes of a *16 bit* buffer; C
	                  halves it (linesize >> 1) for the 8 bit destination
	                  because it was written for callers that think in the
	                  internal pixel format
]]
function ZBuffer.ZB_copyFrameBuffer(zb: ZBuffer, buf: buffer, linesize: number)
	if zb.mode == Config.ZB_MODE_INDEX then
		ZDither.ZB_ditherFrameBuffer(zb, buf, rshift(linesize, 1))
	elseif zb.mode == Config.ZB_MODE_5R6G5B then
		ZBuffer.copyBuffer(zb, buf, linesize)
	elseif zb.mode == Config.ZB_MODE_RGBA then
		ZBuffer.copyFrameBufferRGB32(zb, buf, linesize)
	elseif zb.mode == Config.ZB_MODE_RGB24 then
		ZBuffer.copyFrameBufferRGB24(zb, buf, linesize)
	else
		error("ZB_copyFrameBuffer: unknown display mode")
	end
end

--- ZB_setTexture
function ZBuffer.ZB_setTexture(zb: ZBuffer, texture: buffer?)
	zb.currentTexture = texture
end

return ZBuffer
