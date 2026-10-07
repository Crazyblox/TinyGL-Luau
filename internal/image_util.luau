--!strict
--[[
	image_util.luau — port of TinyGL's src/image_util.c.

	Texture pixel conversion and resizing.  Source images are RGB unsigned bytes:
	either a Luau `buffer` holding 3 bytes per pixel (C's `unsigned char *`) or a
	plain table of numbers in the same order (1 based).
]]

local buffer = buffer --[[(standard library)]]
local band = bit32.band
local lshift = bit32.lshift

local ImageUtil = {}

--- byte at 0 based index `i` of an RGB byte source
local function byteAt(src: any, i: number): number
	if type(src) == "buffer" then
		return buffer.readu8(src, i)
	else
		return src[i + 1] :: number
	end
end

local function byteSet(dst: any, i: number, v: number)
	if type(dst) == "buffer" then
		buffer.writeu8(dst, i, v)
	else
		dst[i + 1] = v
	end
end

ImageUtil.byteAt = byteAt
ImageUtil.byteSet = byteSet

--- gl_convertRGB_to_5R6G5B: writes u16 values into `pixmap`
function ImageUtil.gl_convertRGB_to_5R6G5B(pixmap: buffer, rgb: any, xsize: number, ysize: number)
	local n = xsize * ysize
	for i = 0, n - 1 do
		local o = i * 3
		-- ((p[0] & 0xF8) << 8) | ((p[1] & 0xFC) << 3) | ((p[2] & 0xF8) >> 3)
		buffer.writeu16(
			pixmap,
			i * 2,
			lshift(band(byteAt(rgb, o), 0xF8), 8) + lshift(band(byteAt(rgb, o + 1), 0xFC), 3) + band(byteAt(rgb, o + 2), 0xF8) // 8
		)
	end
end

--- gl_convertRGB_to_8A8R8G8B: writes u32 values into `pixmap`
function ImageUtil.gl_convertRGB_to_8A8R8G8B(pixmap: buffer, rgb: any, xsize: number, ysize: number)
	local n = xsize * ysize
	for i = 0, n - 1 do
		buffer.writeu32(
			pixmap,
			i * 4,
			lshift(byteAt(rgb, i * 3), 16) + lshift(byteAt(rgb, i * 3 + 1), 8) + byteAt(rgb, i * 3 + 2)
		)
	end
end

--- linear interpolation with xf, yf normalized to 2^16
local INTERP_NORM = 65536 -- 1 << INTERP_NORM_BITS, INTERP_NORM_BITS == 16

local function interpolate(v00: number, v01: number, v10: number, xf: number, yf: number): number
	local d = (v01 - v00) * xf + (v10 - v00) * yf
	if d < 0 then
		return v00 + math.ceil(d / INTERP_NORM)
	else
		return v00 + math.floor(d / INTERP_NORM)
	end
end

--- gl_resizeImage: bilinear resampling
function ImageUtil.gl_resizeImage(
	dest: any,
	xsize_dest: number,
	ysize_dest: number,
	src: any,
	xsize_src: number,
	ysize_src: number
)
	local x1inc = (xsize_src - 1) / (xsize_dest - 1)
	local y1inc = (ysize_src - 1) / (ysize_dest - 1)

	local y1 = 0.0
	for y = 0, ysize_dest - 1 do
		local x1 = 0.0
		for x = 0, xsize_dest - 1 do
			local xi = math.floor(x1)
			local yi = math.floor(y1)
			local xf = math.floor((x1 - math.floor(x1)) * INTERP_NORM)
			local yf = math.floor((y1 - math.floor(y1)) * INTERP_NORM)

			local base, base2, base3
			if xf + yf <= INTERP_NORM then
				base = (yi * xsize_src + xi) * 3
				base2 = (yi * xsize_src + xi + 1) * 3
				base3 = ((yi + 1) * xsize_src + xi) * 3
				for j = 0, 2 do
					byteSet(dest, (y * xsize_dest + x) * 3 + j, interpolate(byteAt(src, base + j), byteAt(src, base2 + j), byteAt(src, base3 + j), xf, yf))
				end
			else
				local xfi, yfi = INTERP_NORM - xf, INTERP_NORM - yf
				base = ((yi + 1) * xsize_src + xi + 1) * 3
				base2 = ((yi + 1) * xsize_src + xi) * 3
				base3 = (yi * xsize_src + xi + 1) * 3
				for j = 0, 2 do
					byteSet(dest, (y * xsize_dest + x) * 3 + j, interpolate(byteAt(src, base + j), byteAt(src, base2 + j), byteAt(src, base3 + j), xfi, yfi))
				end
			end

			x1 += x1inc
		end
		y1 += y1inc
	end
end

local FRAC_BITS = 16
local FRAC_SCALE = 2 ^ FRAC_BITS

--- gl_resizeImageNoInterpolate: resizing with no interpolating nor nearest pixel
--- (this is what glTexImage2D uses, to respect the original image aliasing)
function ImageUtil.gl_resizeImageNoInterpolate(
	dest: any,
	xsize_dest: number,
	ysize_dest: number,
	src: any,
	xsize_src: number,
	ysize_src: number
)
	local x1inc = math.floor(xsize_src * FRAC_SCALE / xsize_dest)
	local y1inc = math.floor(ysize_src * FRAC_SCALE / ysize_dest)

	local y1 = 0
	for y = 0, ysize_dest - 1 do
		local x1 = 0
		for x = 0, xsize_dest - 1 do
			local xi = math.floor(x1 / FRAC_SCALE)
			local yi = math.floor(y1 / FRAC_SCALE)
			local o = (yi * xsize_src + xi) * 3
			local d = (y * xsize_dest + x) * 3
			byteSet(dest, d, byteAt(src, o))
			byteSet(dest, d + 1, byteAt(src, o + 1))
			byteSet(dest, d + 2, byteAt(src, o + 2))
			x1 += x1inc
		end
		y1 += y1inc
	end
end

return ImageUtil
