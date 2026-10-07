--!strict
--[[
	arrays.luau — port of TinyGL's src/arrays.c (OpenGL 1.1 vertex arrays).

	Client side arrays are host objects registered in the per context handle
	registry (see handle.luau); `glopArrayElement` then reads them through
	`f32()`, which accepts a Luau `buffer` of f32 samples, a table of numbers, or
	a GL.floatView() of either (the port of C pointer arithmetic, so that
	`glColorPointer(..., a + 2)` becomes `glColorPointer(..., GL.floatView(a, 2))`).
	Indices handed to f32() are the 0 based element indices TinyGL computes, so
	arrays are indexed with the C convention offset by one.

	Two upstream typos in glopArrayElement() are *fixed* here, because they make
	the array path obviously broken:
	* it called glopColor() with a 5 slot GLParam array, so the three precomputed
	  integer colour slots (p[5..7]) were uninitialized stack garbage; we compute
	  them the way api.c's glColor4f() does.
	* it assigned current_normal.Z twice (the second time to 0) instead of setting
	  current_normal.W; we set W = 0 like glNormal3f() does.
	Both fixes are what ref/arrays_det.c, the deterministic reference build, does,
	so the fixed behaviour is hashed rather than assumed; see ref/README.md.

	Reading past the end of a client array is a hard error here.  TinyGL indexes
	with i = idx * (size + stride), where stride is the *gap* between two elements
	in floats; hand it OpenGL's stride in bytes and it walks off the array, where C
	quietly reads whatever the allocator put next to it.
]]

local Vertex = require("./vertex")
local Handle = require("./handle")

local buffer = buffer --[[(standard library)]]
local band = bit32.band

--[[
	The two opcodes this module puts into an op stream, hoisted into its own scope as
	literal numbers instead of Config.OP lookups.  CHECK validates each against the
	frozen opcode table as the module loads, so a literal that no longer means the
	handler it is given to is an error here.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or
	two to check against it, which no single type says: hence the cast.
	CHECK(table) installs a profile, dropping whatever the module loaded
	before it installed.
	See CHECK.luau.
]]
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("./config").OP)
local OP_Color = 0; CHECK("OP_Color", OP_Color)
local OP_Vertex = 5; CHECK("OP_Vertex", OP_Vertex)

local Arrays = {}

local VERTEX_ARRAY = 0x0001
local COLOR_ARRAY = 0x0002
local NORMAL_ARRAY = 0x0004
local TEXCOORD_ARRAY = 0x0008

Arrays.VERTEX_ARRAY = VERTEX_ARRAY
Arrays.COLOR_ARRAY = COLOR_ARRAY
Arrays.NORMAL_ARRAY = NORMAL_ARRAY
Arrays.TEXCOORD_ARRAY = TEXCOORD_ARRAY

local ViewMeta = {}

--- The C expression `array + first` written in Luau: same samples, starting
--- `first` f32 samples later.  TinyGL keeps no length for its client arrays, so
--- this is only a base pointer, exactly as in C.
function Arrays.floatView(data: any, first: number?): any
	return setmetatable({ data = data, offset = first or 0 }, ViewMeta)
end

local function viewOf(a: any): (any, number)
	if getmetatable(a) == ViewMeta then
		return a.data :: any, a.offset :: number
	end
	return a, 0
end

--- float number `i` (0 based, as TinyGL computes it) of a client array
local function f32(a: any, i: number): number
	local data, base = viewOf(a)
	local count: number
	if type(data) == "buffer" then
		count = buffer.len(data) // 4
	else
		count = #data
	end
	if i < 0 or base + i >= count then
		error(
			(
				"TinyGL: client array element %d is past the end of the array (%d samples); "
				.. "TinyGL indexes a client array with idx * (size + stride), where stride is the gap "
				.. "between two elements in floats, not OpenGL's stride in bytes"
			):format(i, count - base),
			4
		)
	end
	if type(data) == "buffer" then
		return buffer.readf32(data, (base + i) * 4)
	end
	return data[base + i + 1] :: number
end

--- glopArrayElement
function Arrays.glopArrayElement(c: any, param: { number })
	local states = c.clientStates
	local idx = param[1]

	if band(states, COLOR_ARRAY) ~= 0 then
		local size = c.colorArraySize
		local i = idx * (size + c.colorArrayStride)
		local r = f32(c.colorArray, i)
		local g = f32(c.colorArray, i + 1)
		local b = f32(c.colorArray, i + 2)
		local a = if size > 3 then f32(c.colorArray, i + 3) else 1.0
		-- the same three integer slots glColor4f() in api.c precomputes
		local ri, gi, bi = Vertex.colorIntensities(r, g, b)
		Vertex.glopColor(c, {
			[0] = OP_Color,
			r,
			g,
			b,
			a,
			ri,
			gi,
			bi,
		})
	end

	if band(states, NORMAL_ARRAY) ~= 0 then
		local i = idx * (3 + c.normalArrayStride)
		c.currentNormal[1] = f32(c.normalArray, i)
		c.currentNormal[2] = f32(c.normalArray, i + 1)
		c.currentNormal[3] = f32(c.normalArray, i + 2)
		c.currentNormal[4] = 0.0
	end

	if band(states, TEXCOORD_ARRAY) ~= 0 then
		local size = c.texcoordArraySize
		local i = idx * (size + c.texcoordArrayStride)
		c.currentTexCoord[1] = f32(c.texcoordArray, i)
		c.currentTexCoord[2] = f32(c.texcoordArray, i + 1)
		c.currentTexCoord[3] = if size > 2 then f32(c.texcoordArray, i + 2) else 0.0
		c.currentTexCoord[4] = if size > 3 then f32(c.texcoordArray, i + 3) else 1.0
	end

	if band(states, VERTEX_ARRAY) ~= 0 then
		local size = c.vertexArraySize
		local i = idx * (size + c.vertexArrayStride)
		Vertex.glopVertex(c, {
			[0] = OP_Vertex,
			f32(c.vertexArray, i),
			f32(c.vertexArray, i + 1),
			if size > 2 then f32(c.vertexArray, i + 2) else 0.0,
			if size > 3 then f32(c.vertexArray, i + 3) else 1.0,
		})
	end
end

--- glopEnableClientState
function Arrays.glopEnableClientState(c: any, p: { number })
	c.clientStates = bit32.bor(c.clientStates, p[1])
end

--- glopDisableClientState
function Arrays.glopDisableClientState(c: any, p: { number })
	c.clientStates = band(c.clientStates, p[1])
end

--- glopVertexPointer
function Arrays.glopVertexPointer(c: any, p: { number })
	c.vertexArraySize = p[1]
	c.vertexArrayStride = p[2]
	c.vertexArray = Handle.get(c, p[3]) -- the op stream carries a handle id
end

--- glopColorPointer
function Arrays.glopColorPointer(c: any, p: { number })
	c.colorArraySize = p[1]
	c.colorArrayStride = p[2]
	c.colorArray = Handle.get(c, p[3])
end

--- glopNormalPointer
function Arrays.glopNormalPointer(c: any, p: { number })
	c.normalArrayStride = p[1]
	c.normalArray = Handle.get(c, p[2])
end

--- glopTexCoordPointer
function Arrays.glopTexCoordPointer(c: any, p: { number })
	c.texcoordArraySize = p[1]
	c.texcoordArrayStride = p[2]
	c.texcoordArray = Handle.get(c, p[3])
end

--- the state glInit() installs for the client arrays
function Arrays.initArrays(c: any)
	c.clientStates = 0
	c.vertexArray = nil
	c.vertexArraySize = 0
	c.vertexArrayStride = 0
	c.normalArray = nil
	c.normalArrayStride = 0
	c.colorArray = nil
	c.colorArraySize = 0
	c.colorArrayStride = 0
	c.texcoordArray = nil
	c.texcoordArraySize = 0
	c.texcoordArrayStride = 0
end

return Arrays
