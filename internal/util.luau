--!strict
--[[
	util.luau — small helpers that stand in for C semantics which differ from
	Luau's defaults.

	The port is a faithful translation of integer arithmetic, so:

	* `(int)x` in C truncates towards zero  -> trunc()
	* `int / int` truncates towards zero    -> idiv()
	* `int >> n` is an arithmetic shift     -> asr()   (math.floor based)
	* storing into `unsigned short` wraps    -> handled by buffer.writeu16, which
	  already truncates like a C store
	* unsigned int arithmetic wraps mod 2^32 -> u32()

There used to be a second family here — f32, fmul, fadd, fsub, fdiv, fsqrt — which
rounded every intermediate to IEEE single precision because TinyGL's C keeps its
geometry in `float`.  They are gone: each one was a buffer write and a buffer read,
two to three times the cost of the operation it stood for, and the pipeline now simply
computes in Luau's own doubles and lets the results sit a fraction off the C renderer
in the last place of a mantissa.  Everything below is *integer* semantics, which Luau
has no operator for.
]]

local band = bit32.band

local util = {}

--- C's `(int)` / `(long)` cast: truncate towards zero.
function util.trunc(x: number): number
	if x < 0 then
		return math.ceil(x)
	else
		return math.floor(x)
	end
end

--- C's integer division: truncate towards zero.
function util.idiv(a: number, b: number): number
	local q = a / b
	if q < 0 then
		return math.ceil(q)
	else
		return math.floor(q)
	end
end

--- C's `x >> n` for signed x (arithmetic shift, so it floors).  Only valid for
--- 2^n divisors, which is all the places it is used in TinyGL.
function util.asr(x: number, n: number): number
	return math.floor(x / (2 ^ n))
end

--- C's `x << n` for signed x: wraps around to the 32 bit *signed* result, which
--- is what TinyGL's `(dx << 16) / dy` fixed point slopes rely on.
function util.shl(x: number, n: number): number
	local v = band(x * (2 ^ n), 0xFFFFFFFF)
	if v >= 2147483648 then
		v -= 4294967296
	end
	return v
end

--- the 32 bit unsigned interpretation of an integer (C's `unsigned int`)
function util.u32(x: number): number
	return band(x, 0xFFFFFFFF)
end

--- C's clampf() from light.c
function util.clampf(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

--[[
	C's `(unsigned int)` conversion of a floating point value.  x86 converts through a signed
	integer and repairs the out of range cases with compares, so a negative float
	becomes 0 and a float too large for 32 bits becomes 0xFFFFFFFF: the conversion
	saturates rather than wrapping.  That matters for glColor4f(), whose
	`(unsigned int) (r * (ZB_POINT_RED_MAX - ZB_POINT_RED_MIN) + ZB_POINT_RED_MIN)`
	is handed colours that are not in [0,1] and must come out as 0, not as the huge
	value a wrapping conversion (or floor, which is what Luau's bit32 ops would
	then mask into the *other* fields of the pixel) would give.
]]
function util.u32cast(x: number): number
	if x < 0 then
		return 0
	elseif x >= 4294967296 then
		return 4294967295
	end
	return math.floor(x) -- x is >= 0 here, so truncation is floor
end

util.M_PI = 3.14159265358979323846

return util
