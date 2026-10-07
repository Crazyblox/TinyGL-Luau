--!strict
--[[
	select.luau — port of TinyGL's src/select.c (render mode, the selection
	buffer and the name stack).

	`c.selectBuffer` is a Luau array of numbers, `c.selectPtr` a 1 based index in
	it and `c.selectHit` the index of the hit record being merged into (nil when
	no hit is open).  C expressed those as pointers; the offsets below take care
	of the 1 based convention.
]]

local Config = require("./config")

--[[
	Constants hoisted into this module's own scope: a local is a register read where
	GL.GL_SELECT was a table lookup.  CHECK validates each literal against the frozen
	table it stands for as this module loads -- gl_constants for the enumerants,
	Config.OP for the opcode numbers, an opcode being compile time data, the enum in
	zgl.h being generated from opinfo.h.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or
	two to check against it, which no single type says: hence the cast.
	CHECK(table) installs a profile, dropping whatever the module loaded
	before it installed.
	See CHECK.luau.
]]
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_RENDER = 0x1C00; CHECK("GL_RENDER", GL_RENDER)
local GL_SELECT = 0x1C02; CHECK("GL_SELECT", GL_SELECT)

local Select = {}

local MAX_NAME_STACK_DEPTH = Config.MAX_NAME_STACK_DEPTH

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

--- gl_add_select(): append or merge a hit record in the selection buffer
function Select.gl_add_select(c: any, zmin: number, zmax: number)
	if c.selectOverflow ~= 0 then
		return
	end

	if c.selectHit == nil then
		local n = c.nameStackSize
		if (c.selectPtr - 1 + 3 + n) > c.selectSize then
			c.selectOverflow = 1
		else
			local buf = c.selectBuffer
			local ptr = c.selectPtr
			c.selectHit = ptr
			buf[ptr] = c.nameStackSize
			buf[ptr + 1] = zmin
			buf[ptr + 2] = zmax
			for i = 0, n - 1 do
				buf[ptr + 3 + i] = c.nameStack[i + 1]
			end
			c.selectPtr = ptr + 3 + n
			c.selectHits += 1
		end
	else
		local hit = c.selectHit
		local buf = c.selectBuffer
		if zmin < buf[hit + 1] then
			buf[hit + 1] = zmin
		end
		if zmax > buf[hit + 2] then
			buf[hit + 2] = zmax
		end
	end
end

--- glRenderMode(): returns the number of hits when leaving GL_SELECT, like C
function Select.glRenderMode(c: any, mode: number): number
	local result = 0

	if c.renderMode == GL_RENDER then
		-- nothing
	elseif c.renderMode == GL_SELECT then
		if c.selectOverflow ~= 0 then
			result = -c.selectHits
		else
			result = c.selectHits
		end
		c.selectOverflow = 0
		c.selectPtr = 1
		c.nameStackSize = 0
	else
		assert(false, "glRenderMode: bad mode")
	end

	if mode == GL_RENDER then
		c.renderMode = GL_RENDER
	elseif mode == GL_SELECT then
		c.renderMode = GL_SELECT
		assert(c.selectBuffer ~= nil, "glRenderMode: select buffer not set")
		c.selectPtr = 1
		c.selectHits = 0
		c.selectOverflow = 0
		c.selectHit = nil
	else
		assert(false, "glRenderMode: bad mode")
	end

	return result
end

--- glSelectBuffer()
function Select.glSelectBuffer(c: any, size: number, buf: { number })
	assert(c.renderMode ~= GL_SELECT, "glSelectBuffer: called while in GL_SELECT")
	c.selectBuffer = buf
	c.selectSize = size
end

--- glopInitNames()
function Select.glopInitNames(c: any, p: { number })
	if c.renderMode == GL_SELECT then
		c.nameStackSize = 0
		c.selectHit = nil
	end
end

--- glopPushName()
function Select.glopPushName(c: any, p: { number })
	if c.renderMode == GL_SELECT then
		assert(c.nameStackSize < MAX_NAME_STACK_DEPTH, "glPushName: name stack overflow")
		c.nameStackSize += 1
		c.nameStack[c.nameStackSize] = p[1]
		c.selectHit = nil
	end
end

--- glopPopName()
function Select.glopPopName(c: any, p: { number })
	if c.renderMode == GL_SELECT then
		assert(c.nameStackSize > 0, "glPopName: name stack empty")
		c.nameStackSize -= 1
		c.selectHit = nil
	end
end

--- glopLoadName()
function Select.glopLoadName(c: any, p: { number })
	if c.renderMode == GL_SELECT then
		assert(c.nameStackSize > 0, "glLoadName: name stack empty")
		c.nameStack[c.nameStackSize] = p[1]
		c.selectHit = nil
	end
end

--- the selection state glInit() installs (C's glInit sets render_mode,
--- select_buffer and name_stack_size)
function Select.initSelect(c: any)
	c.renderMode = GL_RENDER
	c.selectBuffer = nil
	c.selectSize = 0
	c.selectPtr = nil
	c.selectHit = nil
	c.selectOverflow = 0
	c.selectHits = 0
	c.nameStack = {}
	c.nameStackSize = 0
end

return Select
