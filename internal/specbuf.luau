--!strict
--[[
	specbuf.luau — port of TinyGL's src/specbuf.c.

	A tiny LRU cache of pow(x, shininess) tables, so that the specular term of
	the lighting model is one lookup instead of a pow().
]]

local Config = require("./config")

local SpecBuf = {}

local SPECULAR_BUFFER_SIZE = Config.SPECULAR_BUFFER_SIZE
local MAX_SPECULAR_BUFFERS = Config.MAX_SPECULAR_BUFFERS

export type GLSpecBuf = {
	shininess_i: number,
	last_used: number,
	buf: { number },
	next: GLSpecBuf?,
}

--- The table is `float buf[SPECULAR_BUFFER_SIZE + 1]` in C, and C's `val` is a float
--- too, so both the walk up the table and the pow() that fills it round to single
--- precision there.  Here they are Luau doubles: the tables are cached and built
--- once, and a step of 1/256 accumulated in double is exact enough that the walk
--- visits the same 257 sample points, at values that differ from C's in the last
--- places of a mantissa the 5 bit specular table cannot show.
local function calc_buf(buf: GLSpecBuf, shininess: number)
	local val = 0.0
	local inc = 1.0 / SPECULAR_BUFFER_SIZE
	for i = 0, SPECULAR_BUFFER_SIZE do
		buf.buf[i + 1] = val ^ shininess
		val = val + inc
	end
end

--- specbuf_get_buffer
function SpecBuf.specbuf_get_buffer(c: any, shininess_i: number, shininess: number): GLSpecBuf
	local found: GLSpecBuf? = c.specbufFirst
	local oldest: GLSpecBuf? = c.specbufFirst

	while found ~= nil do
		if found.shininess_i == shininess_i then
			break
		end
		if (found.last_used :: number) < (oldest :: GLSpecBuf).last_used then
			oldest = found
		end
		found = found.next
	end

	if found ~= nil then
		-- hey, found one!
		found.last_used = c.specbufUsedCounter
		c.specbufUsedCounter += 1
		return found
	end

	if oldest == nil or c.specbufNumBuffers < MAX_SPECULAR_BUFFERS then
		-- create new buffer
		local buf: GLSpecBuf = {
			shininess_i = shininess_i,
			last_used = 0,
			buf = table.create(SPECULAR_BUFFER_SIZE + 1) :: { number },
			next = nil,
		}
		c.specbufNumBuffers += 1
		buf.next = c.specbufFirst
		c.specbufFirst = buf
		buf.last_used = c.specbufUsedCounter
		c.specbufUsedCounter += 1
		buf.shininess_i = shininess_i
		calc_buf(buf, shininess)
		return buf
	end

	-- overwrite the least recently used buffer
	local ob = oldest :: GLSpecBuf
	ob.shininess_i = shininess_i
	ob.last_used = c.specbufUsedCounter
	c.specbufUsedCounter += 1
	calc_buf(ob, shininess)
	return ob
end

return SpecBuf
