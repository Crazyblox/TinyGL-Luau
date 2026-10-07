--!strict
--[[
	list.luau — port of TinyGL's src/list.c: the opcode interpreter.

	Every public glXxx() call builds a small argument array laid out exactly like
	C's `GLParam p[N]` (`p[0]` is the opcode, `p[1] .. p[n]` its parameters) and
	hands it to glAddOp, which does what TinyGL does:

		exec_flag    -> call the opcode handler now
		compile_flag -> append it to the display list being compiled
		print_flag   -> print it (glPrintOp)

	Display lists hold arrays of those argument arrays instead of C's chunks of
	GLParam (GLParamBuffer + the OP_NextBuffer chaining), because Luau cannot put
	a host object into a number.  Host objects (client arrays, texture images)
	travel as ids from handle.luau, which is what makes compiled display lists
	safe to keep around; OP_NextBuffer therefore never appears and its handler
	still asserts like C's.
]]

local Config = require("./config")
local MSH = require("./msghandling")
local Vertex = require("./vertex")
local Matrix = require("./matrix")
local Light = require("./light")
local Misc = require("./misc")
local Texture = require("./texture")
local Arrays = require("./arrays")
local Clear = require("./clear")
local Select = require("./select")

local List = {}

--[[
	Constants hoisted into this module's own scope: a local is a register read where
	GL.GL_COMPILE and OP.EndList were table lookups, and executeOps is the
	interpreter loop every opcode passes through.  CHECK validates each one as the
	module loads, against the frozen table it stands for -- gl_constants for the
	enumerants, Config.OP for the opcode numbers, those being compile time data, the
	enum in zgl.h being generated from opinfo.h.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or
	two to check against it, which no single type says: hence the cast.
	CHECK(table) installs a profile, dropping whatever the module loaded
	before it installed.
	See CHECK.luau.
]]
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_COMPILE = 0x1300; CHECK("GL_COMPILE", GL_COMPILE)
local GL_COMPILE_AND_EXECUTE = 0x1301; CHECK("GL_COMPILE_AND_EXECUTE", GL_COMPILE_AND_EXECUTE)
CHECK()(Config.OP)
local OP_EndList = 41; CHECK("OP_EndList", OP_EndList)
local OP_NextBuffer = 42; CHECK("OP_NextBuffer", OP_NextBuffer)

local OP_SIZE = Config.OP_SIZE
local MAX_DISPLAY_LISTS = Config.MAX_DISPLAY_LISTS

local function opcodeName(op: number): string
	return Config.OP_NAMES[op] or "?"
end

--- the "opcode number -> handler" table (C's op_table_func); filled in below
--- once every handler module has been required.
type OpHandler = (any, { number }) -> ()

local opFunc = table.create(Config.OP_COUNT) :: { OpHandler }

local function find_list(c: any, list: number): any
	if list < 0 or list >= MAX_DISPLAY_LISTS then
		return nil
	end
	return c.sharedState.lists[list + 1]
end

local function delete_list(c: any, list: number)
	local l = find_list(c, list)
	if l == nil then
		error("TinyGL: delete_list: list " .. tostring(list) .. " is NULL", 2)
	end
	c.sharedState.lists[list + 1] = nil
end

local function alloc_list(c: any, list: number): any
	-- GLList: the terminating OP_EndList is implicit in the end of the array
	local l = { ops = {} }
	c.sharedState.lists[list + 1] = l
	return l
end

--- Run every opcode of a compiled list until OP_EndList (glopCallList's loop).
local function executeOps(c: any, ops: { { number } })
	for i = 1, #ops do
		local p = ops[i]
		local op = p[0]
		if op == OP_EndList then
			break
		elseif op == OP_NextBuffer then
			-- this port never generates it
			error("TinyGL: OP_NextBuffer in display list", 2)
		else
			opFunc[op](c, p)
		end
	end
end

--- glopCallList
local function glopCallList(c: any, p: { number })
	local list = p[1]
	local l = find_list(c, list)
	if l == nil then
		error(("TinyGL: fatal error: list %d not defined"):format(list), 2)
	end
	executeOps(c, l.ops)
end

-- this opcode is never called directly
local function glopEndList(_c: any, _p: { number }): ()
	error("TinyGL: OP_EndList should never be executed", 2)
end

-- this opcode is never called directly
local function glopNextBuffer(_c: any, _p: { number }): ()
	error("TinyGL: OP_NextBuffer should never be executed", 2)
end

--[[
	opcode name -> handler.  Listing the names of opinfo.h here means a missing
	handler is reported when the library loads, not as a nil call much later.
	C generated three parallel tables (op_table_str/op_table_func/op_table_size)
	from opinfo.h; the strings and the sizes come from config.luau, which mirrors
	the same file.
]]
local opHandlers: { [string]: (any, { number }) -> () } = {
	Color = Vertex.glopColor,
	TexCoord = Vertex.glopTexCoord,
	EdgeFlag = Vertex.glopEdgeFlag,
	Normal = Vertex.glopNormal,

	Begin = Vertex.glopBegin,
	Vertex = Vertex.glopVertex,
	End = Vertex.glopEnd,

	EnableDisable = Misc.glopEnableDisable,

	MatrixMode = Matrix.glopMatrixMode,
	LoadMatrix = Matrix.glopLoadMatrix,
	LoadIdentity = Matrix.glopLoadIdentity,
	MultMatrix = Matrix.glopMultMatrix,
	PushMatrix = Matrix.glopPushMatrix,
	PopMatrix = Matrix.glopPopMatrix,
	Rotate = Matrix.glopRotate,
	Translate = Matrix.glopTranslate,
	Scale = Matrix.glopScale,

	Viewport = Misc.glopViewport,
	Frustum = Matrix.glopFrustum,

	Material = Light.glopMaterial,
	ColorMaterial = Light.glopColorMaterial,
	Light = Light.glopLight,
	LightModel = Light.glopLightModel,

	Clear = Clear.glopClear,
	ClearColor = Clear.glopClearColor,
	ClearDepth = Clear.glopClearDepth,

	InitNames = Select.glopInitNames,
	PushName = Select.glopPushName,
	PopName = Select.glopPopName,
	LoadName = Select.glopLoadName,

	TexImage2D = Texture.glopTexImage2D,
	BindTexture = Texture.glopBindTexture,
	TexEnv = Texture.glopTexEnv,
	TexParameter = Texture.glopTexParameter,
	PixelStore = Texture.glopPixelStore,

	ShadeModel = Misc.glopShadeModel,
	CullFace = Misc.glopCullFace,
	FrontFace = Misc.glopFrontFace,
	PolygonMode = Misc.glopPolygonMode,

	CallList = glopCallList,
	Hint = Misc.glopHint,

	EndList = glopEndList,
	NextBuffer = glopNextBuffer,

	ArrayElement = Arrays.glopArrayElement,
	EnableClientState = Arrays.glopEnableClientState,
	DisableClientState = Arrays.glopDisableClientState,
	VertexPointer = Arrays.glopVertexPointer,
	ColorPointer = Arrays.glopColorPointer,
	NormalPointer = Arrays.glopNormalPointer,
	TexCoordPointer = Arrays.glopTexCoordPointer,

	PolygonOffset = Misc.glopPolygonOffset,
}

--- the "opcode number -> handler" table content (C's op_table_func)
do
	local missing = {}
	for i, info in ipairs(Config.OP_INFOS) do
		local name = info[1] :: string
		local f = opHandlers[name]
		if f == nil then
			table.insert(missing, name)
		else
			opFunc[i - 1] = f
		end
	end
	if #missing > 0 then
		error("TinyGL: internal error, no handler for opcode(s): " .. table.concat(missing, ", "), 2)
	end
end

List.opFunc = opFunc

--- gl_print_op: decode one opcode with the format string of opinfo.h
function List.glPrintOp(p: { number }): string
	local fmt = Config.OP_PRINT[p[0]]
	local out: { string } = {}
	local index = 1 -- the parameters live at p[1] and onwards
	local i = 1
	local len = #fmt
	while i <= len do
		local ch = string.sub(fmt, i, i)
		if ch == "%" then
			i += 1
			local spec = string.sub(fmt, i, i)
			if spec == "f" then
				table.insert(out, ("%g"):format(p[index]))
			else
				-- %d, %C and %p all print as an integer in TinyGL
				local v = p[index]
				table.insert(out, if v == nil then "nil" else tostring(math.floor(v)))
			end
			index += 1
			i += 1
		else
			table.insert(out, ch)
			i += 1
		end
	end
	return table.concat(out)
end

--- gl_compile_op
function List.glCompileOp(c: any, p: { number })
	local op = p[0]
	local params = Config.opParamCount(op)
	local ops = c.compileTarget

	local copy = table.create(params + 1)
	copy[0] = op
	for i = 1, params do
		copy[i] = p[i]
	end
	table.insert(ops, copy)
end

--- gl_add_op
function List.glAddOp(c: any, p: { number })
	local op = p[0]

	if Config.CHECKS then
		if OP_SIZE[op] == nil then
			error(("TinyGL: invalid opcode %s"):format(tostring(op)), 2)
		end
		for i = 1, Config.opParamCount(op) do
			if p[i] == nil then
				error(("TinyGL: opcode %d (%s) is missing parameter %d"):format(op, opcodeName(op), i), 3)
			end
		end
	end

	if c.execFlag ~= 0 then
		opFunc[op](c, p)
	end
	if c.compileFlag ~= 0 then
		List.glCompileOp(c, p)
	end
	if c.printFlag ~= 0 then
		MSH.output(List.glPrintOp(p))
	end
end

List.glopCallList = glopCallList

--- glNewList
function List.glNewList(c: any, list: number, mode: number)
	assert(mode == GL_COMPILE or mode == GL_COMPILE_AND_EXECUTE, "glNewList: bad mode")
	assert(c.compileFlag == 0, "glNewList: nested display lists are not supported")
	assert(list >= 0 and list < MAX_DISPLAY_LISTS, "glNewList: list out of range")

	local l = find_list(c, list)
	if l ~= nil then
		delete_list(c, list)
	end
	l = alloc_list(c, list)

	c.compileTarget = l.ops
	c.compileFlag = 1
	c.execFlag = if mode == GL_COMPILE_AND_EXECUTE then 1 else 0
end

--- glEndList
function List.glEndList(c: any)
	assert(c.compileFlag == 1, "glEndList: outside of glNewList")

	-- end of list
	List.glCompileOp(c, { [0] = OP_EndList })

	c.compileFlag = 0
	c.execFlag = 1
	c.compileTarget = nil
end

--- glIsList
function List.glIsList(c: any, list: number): boolean
	return find_list(c, list) ~= nil
end

--- glGenLists
function List.glGenLists(c: any, range: number): number
	local lists = c.sharedState.lists
	local count = 0

	for i = 0, MAX_DISPLAY_LISTS - 1 do
		if lists[i + 1] == nil then
			count += 1
			if count == range then
				local first = i - range + 1
				for j = 0, range - 1 do
					alloc_list(c, first + j)
				end
				return first
			end
		else
			count = 0
		end
	end
	return 0
end

--- the interpreter state glInit() installs (the lists table itself lives in
--- c.sharedState, which context.luau creates)
function List.initLists(c: any)
	c.execFlag = 1
	c.compileFlag = 0
	c.printFlag = 0
	c.compileTarget = nil
end

return List
