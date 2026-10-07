--!strict
--[[
	tinygl.luau — public API of the Luau port of TinyGL.

	This is the port of src/api.c (plus the handful of entry points that TinyGL
	defines outside of it: display lists, textures, selection and the client
	array pointers).  Function names are the C names; the only mechanical
	changes are:

	* the suffix-less overloads of C (`glVertex2f`, `glColor3f`, ...) are all
	  present, but a `float` argument is just a Luau number, so `*f`/`*d`
	  variants would be duplicates and are not provided;
	* `*fv` variants take a Luau table (or, where TinyGL took a `float *` for a
	  whole matrix or a client array, a table *or* a `buffer` of f32);
	* C's `void *` op parameters become host objects registered in a per context
	  handle table, so display lists can safely remember them;
	* C's out-parameters (glGetIntegerv, glGenTextures, ...) are return values.

	Everything works on the *current* context, like TinyGL's single `gl_ctx`: call
	glInit() (or create one through oscontext.luau) and the glXxx() functions
	below become usable. Use GL.getContext() when you need to pass it explicitly.
]]

local Config = require("./internal/config")
local GL = require("./gl_constants")
local Context = require("./internal/context")
local List = require("./internal/list")
local Handle = require("./internal/handle")
local Arrays = require("./internal/arrays")
local Vertex = require("./internal/vertex")
local Texture = require("./internal/texture")
local Select = require("./internal/select")
local Get = require("./internal/get")
local ZBuffer = require("./internal/zbuffer")

local buffer = buffer --[[(the standard library)]]
local bnot = bit32.bnot

local TinyGL = {}

TinyGL.VERSION = "0.4.1-luau"
TinyGL.Config = Config
TinyGL.Enum = GL
TinyGL.ZB = ZBuffer

-- Display modes for ZB_open().  TinyGL's internal pixel format is 16 bit
-- (TGL_FEATURE_RENDER_BITS == 16) so the internal mode is ZB_MODE_5R6G5B; the
-- others describe an externally supplied frame buffer's layout, which is what
-- ZB_copyFrameBuffer() converts to.
TinyGL.ZB_MODE_5R6G5B = Config.ZB_MODE_5R6G5B
TinyGL.ZB_MODE_INDEX = Config.ZB_MODE_INDEX
TinyGL.ZB_MODE_RGBA = Config.ZB_MODE_RGBA
TinyGL.ZB_MODE_RGB24 = Config.ZB_MODE_RGB24
TinyGL.ZB_NB_COLORS = Config.ZB_NB_COLORS

--[[
	Constant values, hoisted into this module's own scope: a local is a register read
	where GL.GL_SELECT and OP.Vertex were table lookups, and every glXxx() call here
	builds an op from those.  CHECK validates each literal as the module loads,
	against the frozen table it stands for -- gl_constants for the enumerants,
	Config.OP for the opcode numbers, those being compile time data, the enum in zgl.h
	being generated from opinfo.h -- so a value that drifts is an error naming both
	values here rather than an op the interpreter answers with another handler.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or two
	to check against it, which no single type says: hence the cast.  CHECK(table)
	installs a profile, dropping whatever the module loaded before it installed.
	See CHECK.luau.
]]
local CHECK = require("./CHECK") :: (any?, any?) -> any
CHECK()(GL)
local GL_BACK = 0x405; CHECK("GL_BACK", GL_BACK)
local GL_CCW = 0x901; CHECK("GL_CCW", GL_CCW)
local GL_COLOR_ARRAY = 0x8076; CHECK("GL_COLOR_ARRAY", GL_COLOR_ARRAY)
local GL_CW = 0x900; CHECK("GL_CW", GL_CW)
local GL_FILL = 0x1B02; CHECK("GL_FILL", GL_FILL)
local GL_FLAT = 0x1D00; CHECK("GL_FLAT", GL_FLAT)
local GL_FLOAT = 0x1406; CHECK("GL_FLOAT", GL_FLOAT)
local GL_FRONT = 0x404; CHECK("GL_FRONT", GL_FRONT)
local GL_FRONT_AND_BACK = 0x408; CHECK("GL_FRONT_AND_BACK", GL_FRONT_AND_BACK)
local GL_LINE = 0x1B01; CHECK("GL_LINE", GL_LINE)
local GL_NORMAL_ARRAY = 0x8075; CHECK("GL_NORMAL_ARRAY", GL_NORMAL_ARRAY)
local GL_POINT = 0x1B00; CHECK("GL_POINT", GL_POINT)
local GL_SHININESS = 0x1601; CHECK("GL_SHININESS", GL_SHININESS)
local GL_SMOOTH = 0x1D01; CHECK("GL_SMOOTH", GL_SMOOTH)
local GL_TEXTURE_COORD_ARRAY = 0x8078; CHECK("GL_TEXTURE_COORD_ARRAY", GL_TEXTURE_COORD_ARRAY)
local GL_VERTEX_ARRAY = 0x8074; CHECK("GL_VERTEX_ARRAY", GL_VERTEX_ARRAY)
CHECK()(Config.OP)
local OP_Color = 0; CHECK("OP_Color", OP_Color)
local OP_TexCoord = 1; CHECK("OP_TexCoord", OP_TexCoord)
local OP_EdgeFlag = 2; CHECK("OP_EdgeFlag", OP_EdgeFlag)
local OP_Normal = 3; CHECK("OP_Normal", OP_Normal)
local OP_Begin = 4; CHECK("OP_Begin", OP_Begin)
local OP_Vertex = 5; CHECK("OP_Vertex", OP_Vertex)
local OP_End = 6; CHECK("OP_End", OP_End)
local OP_EnableDisable = 7; CHECK("OP_EnableDisable", OP_EnableDisable)
local OP_MatrixMode = 8; CHECK("OP_MatrixMode", OP_MatrixMode)
local OP_LoadMatrix = 9; CHECK("OP_LoadMatrix", OP_LoadMatrix)
local OP_LoadIdentity = 10; CHECK("OP_LoadIdentity", OP_LoadIdentity)
local OP_MultMatrix = 11; CHECK("OP_MultMatrix", OP_MultMatrix)
local OP_PushMatrix = 12; CHECK("OP_PushMatrix", OP_PushMatrix)
local OP_PopMatrix = 13; CHECK("OP_PopMatrix", OP_PopMatrix)
local OP_Rotate = 14; CHECK("OP_Rotate", OP_Rotate)
local OP_Translate = 15; CHECK("OP_Translate", OP_Translate)
local OP_Scale = 16; CHECK("OP_Scale", OP_Scale)
local OP_Viewport = 17; CHECK("OP_Viewport", OP_Viewport)
local OP_Frustum = 18; CHECK("OP_Frustum", OP_Frustum)
local OP_Material = 19; CHECK("OP_Material", OP_Material)
local OP_ColorMaterial = 20; CHECK("OP_ColorMaterial", OP_ColorMaterial)
local OP_Light = 21; CHECK("OP_Light", OP_Light)
local OP_LightModel = 22; CHECK("OP_LightModel", OP_LightModel)
local OP_Clear = 23; CHECK("OP_Clear", OP_Clear)
local OP_ClearColor = 24; CHECK("OP_ClearColor", OP_ClearColor)
local OP_ClearDepth = 25; CHECK("OP_ClearDepth", OP_ClearDepth)
local OP_InitNames = 26; CHECK("OP_InitNames", OP_InitNames)
local OP_PushName = 27; CHECK("OP_PushName", OP_PushName)
local OP_PopName = 28; CHECK("OP_PopName", OP_PopName)
local OP_LoadName = 29; CHECK("OP_LoadName", OP_LoadName)
local OP_TexImage2D = 30; CHECK("OP_TexImage2D", OP_TexImage2D)
local OP_BindTexture = 31; CHECK("OP_BindTexture", OP_BindTexture)
local OP_TexEnv = 32; CHECK("OP_TexEnv", OP_TexEnv)
local OP_TexParameter = 33; CHECK("OP_TexParameter", OP_TexParameter)
local OP_PixelStore = 34; CHECK("OP_PixelStore", OP_PixelStore)
local OP_ShadeModel = 35; CHECK("OP_ShadeModel", OP_ShadeModel)
local OP_CullFace = 36; CHECK("OP_CullFace", OP_CullFace)
local OP_FrontFace = 37; CHECK("OP_FrontFace", OP_FrontFace)
local OP_PolygonMode = 38; CHECK("OP_PolygonMode", OP_PolygonMode)
local OP_CallList = 39; CHECK("OP_CallList", OP_CallList)
local OP_Hint = 40; CHECK("OP_Hint", OP_Hint)
local OP_ArrayElement = 43; CHECK("OP_ArrayElement", OP_ArrayElement)
local OP_EnableClientState = 44; CHECK("OP_EnableClientState", OP_EnableClientState)
local OP_DisableClientState = 45; CHECK("OP_DisableClientState", OP_DisableClientState)
local OP_VertexPointer = 46; CHECK("OP_VertexPointer", OP_VertexPointer)
local OP_ColorPointer = 47; CHECK("OP_ColorPointer", OP_ColorPointer)
local OP_NormalPointer = 48; CHECK("OP_NormalPointer", OP_NormalPointer)
local OP_TexCoordPointer = 49; CHECK("OP_TexCoordPointer", OP_TexCoordPointer)
local OP_PolygonOffset = 50; CHECK("OP_PolygonOffset", OP_PolygonOffset)

--- the current context, with the same "must be initialised" error as C's assert
local function ctx(): any
	local c = Context.get()
	if c == nil then
		error("TinyGL: no current context (call glInit first)", 3)
	end
	return c
end

--- read element `i` (0 based, as TinyGL computes it) of a float source.  C read
--- straight out of the caller's memory, so a short array read whatever followed
--- it; here it is reported.
local function f32(a: any, i: number): number
	if type(a) == "buffer" then
		if i < 0 or (i + 1) * 4 > buffer.len(a) then
			error(("TinyGL: expected %d f32 samples, buffer has %d"):format(i + 1, buffer.len(a) // 4), 3)
		end
		return buffer.readf32(a, i * 4)
	end
	local v = a[i + 1]
	if v == nil then
		error(("TinyGL: expected %d numbers, array has %d"):format(i + 1, #a), 3)
	end
	return v :: number
end

--- push one opcode through the interpreter (C's gl_add_op)
local function gl_add_op(p: { number })
	List.glAddOp(ctx(), p)
end

-- the precomputed integer colour form glColor4f() passes in p[5..7]
local colorIntensities = Vertex.colorIntensities

-- ---------------------------------------------------------------------------
-- glVertex
-- ---------------------------------------------------------------------------

function TinyGL.glVertex4f(x: number, y: number, z: number, w: number)
	gl_add_op({ [0] = OP_Vertex, x, y, z, w })
end

function TinyGL.glVertex2f(x: number, y: number)
	TinyGL.glVertex4f(x, y, 0, 1)
end

function TinyGL.glVertex3f(x: number, y: number, z: number)
	TinyGL.glVertex4f(x, y, z, 1)
end

--- v = { x, y, z }
function TinyGL.glVertex3fv(v: { number })
	TinyGL.glVertex4f(v[1], v[2], v[3], 1)
end

-- ---------------------------------------------------------------------------
-- glNormal
-- ---------------------------------------------------------------------------

function TinyGL.glNormal3f(x: number, y: number, z: number)
	gl_add_op({ [0] = OP_Normal, x, y, z })
end

function TinyGL.glNormal3fv(v: { number })
	TinyGL.glNormal3f(v[1], v[2], v[3])
end

-- ---------------------------------------------------------------------------
-- glColor
-- ---------------------------------------------------------------------------

function TinyGL.glColor4f(r: number, g: number, b: number, a: number)
	local ri, gi, bi = colorIntensities(r, g, b)
	gl_add_op({ [0] = OP_Color, r, g, b, a, ri, gi, bi })
end

--- v = { r, g, b, a }
function TinyGL.glColor4fv(v: { number })
	local ri, gi, bi = colorIntensities(v[1], v[2], v[3])
	gl_add_op({ [0] = OP_Color, v[1], v[2], v[3], v[4], ri, gi, bi })
end

function TinyGL.glColor3f(x: number, y: number, z: number)
	TinyGL.glColor4f(x, y, z, 1)
end

--- v = { r, g, b }
function TinyGL.glColor3fv(v: { number })
	TinyGL.glColor4f(v[1], v[2], v[3], 1)
end

-- ---------------------------------------------------------------------------
-- glTexCoord
-- ---------------------------------------------------------------------------

function TinyGL.glTexCoord4f(s: number, t: number, r: number, q: number)
	gl_add_op({ [0] = OP_TexCoord, s, t, r, q })
end

function TinyGL.glTexCoord2f(s: number, t: number)
	TinyGL.glTexCoord4f(s, t, 0, 1)
end

--- v = { s, t }
function TinyGL.glTexCoord2fv(v: { number })
	TinyGL.glTexCoord4f(v[1], v[2], 0, 1)
end

-- ---------------------------------------------------------------------------
-- glEdgeFlag
-- ---------------------------------------------------------------------------

function TinyGL.glEdgeFlag(flag: number)
	gl_add_op({ [0] = OP_EdgeFlag, if flag then 1 else 0 })
end

-- ---------------------------------------------------------------------------
-- misc state
-- ---------------------------------------------------------------------------

function TinyGL.glShadeModel(mode: number)
	assert(mode == GL_FLAT or mode == GL_SMOOTH, "glShadeModel: bad mode")
	gl_add_op({ [0] = OP_ShadeModel, mode })
end

function TinyGL.glCullFace(mode: number)
	assert(
		mode == GL_BACK or mode == GL_FRONT or mode == GL_FRONT_AND_BACK,
		"glCullFace: bad mode"
	)
	gl_add_op({ [0] = OP_CullFace, mode })
end

function TinyGL.glFrontFace(mode: number)
	assert(mode == GL_CCW or mode == GL_CW, "glFrontFace: bad mode")
	-- C stores (mode != GL_CCW), i.e. 0 for CCW and 1 for CW
	gl_add_op({ [0] = OP_FrontFace, if mode ~= GL_CCW then 1 else 0 })
end

function TinyGL.glPolygonMode(face: number, mode: number)
	assert(face == GL_BACK or face == GL_FRONT or face == GL_FRONT_AND_BACK, "glPolygonMode: bad face")
	assert(mode == GL_POINT or mode == GL_LINE or mode == GL_FILL, "glPolygonMode: bad mode")
	gl_add_op({ [0] = OP_PolygonMode, face, mode })
end

-- ---------------------------------------------------------------------------
-- glEnable / glDisable
-- ---------------------------------------------------------------------------

function TinyGL.glEnable(cap: number)
	gl_add_op({ [0] = OP_EnableDisable, cap, 1 })
end

function TinyGL.glDisable(cap: number)
	gl_add_op({ [0] = OP_EnableDisable, cap, 0 })
end

-- ---------------------------------------------------------------------------
-- glBegin / glEnd
-- ---------------------------------------------------------------------------

function TinyGL.glBegin(mode: number)
	gl_add_op({ [0] = OP_Begin, mode })
end

function TinyGL.glEnd()
	gl_add_op({ [0] = OP_End })
end

-- ---------------------------------------------------------------------------
-- matrix
-- ---------------------------------------------------------------------------

function TinyGL.glMatrixMode(mode: number)
	gl_add_op({ [0] = OP_MatrixMode, mode })
end

--- m is column major (OpenGL order): either a 16 element table or a buffer of f32
function TinyGL.glLoadMatrixf(m: { number } | buffer)
	gl_add_op({
		[0] = OP_LoadMatrix,
		f32(m, 0),
		f32(m, 1),
		f32(m, 2),
		f32(m, 3),
		f32(m, 4),
		f32(m, 5),
		f32(m, 6),
		f32(m, 7),
		f32(m, 8),
		f32(m, 9),
		f32(m, 10),
		f32(m, 11),
		f32(m, 12),
		f32(m, 13),
		f32(m, 14),
		f32(m, 15),
	})
end

function TinyGL.glLoadIdentity()
	gl_add_op({ [0] = OP_LoadIdentity })
end

function TinyGL.glMultMatrixf(m: { number } | buffer)
	gl_add_op({
		[0] = OP_MultMatrix,
		f32(m, 0),
		f32(m, 1),
		f32(m, 2),
		f32(m, 3),
		f32(m, 4),
		f32(m, 5),
		f32(m, 6),
		f32(m, 7),
		f32(m, 8),
		f32(m, 9),
		f32(m, 10),
		f32(m, 11),
		f32(m, 12),
		f32(m, 13),
		f32(m, 14),
		f32(m, 15),
	})
end

function TinyGL.glPushMatrix()
	gl_add_op({ [0] = OP_PushMatrix })
end

function TinyGL.glPopMatrix()
	gl_add_op({ [0] = OP_PopMatrix })
end

function TinyGL.glRotatef(angle: number, x: number, y: number, z: number)
	gl_add_op({ [0] = OP_Rotate, angle, x, y, z })
end

function TinyGL.glTranslatef(x: number, y: number, z: number)
	gl_add_op({ [0] = OP_Translate, x, y, z })
end

function TinyGL.glScalef(x: number, y: number, z: number)
	gl_add_op({ [0] = OP_Scale, x, y, z })
end

function TinyGL.glViewport(x: number, y: number, width: number, height: number)
	gl_add_op({ [0] = OP_Viewport, x, y, width, height })
end

--- The C parameter names `near`/`far` are Lua keywords, so they are called
--- nearVal/farVal here (same trick TinyGL's own source uses with `farp`).
function TinyGL.glFrustum(
	left: number,
	right: number,
	bottom: number,
	top: number,
	nearVal: number,
	farVal: number
)
	gl_add_op({ [0] = OP_Frustum, left, right, bottom, top, nearVal, farVal })
end

-- ---------------------------------------------------------------------------
-- lighting
-- ---------------------------------------------------------------------------

local function materialParams(v: { number } | buffer, type_: number): (number, number, number, number)
	if type_ == GL_SHININESS then
		return f32(v, 0), 0, 0, 0
	end
	return f32(v, 0), f32(v, 1), f32(v, 2), f32(v, 3)
end

function TinyGL.glMaterialfv(mode: number, type_: number, v: { number } | buffer)
	assert(mode == GL_FRONT or mode == GL_BACK or mode == GL_FRONT_AND_BACK, "glMaterialfv: bad mode")
	local a, b, c_, d = materialParams(v, type_)
	gl_add_op({ [0] = OP_Material, mode, type_, a, b, c_, d })
end

function TinyGL.glMaterialf(mode: number, type_: number, v: number)
	gl_add_op({ [0] = OP_Material, mode, type_, v, 0, 0, 0 })
end

function TinyGL.glColorMaterial(mode: number, type_: number)
	gl_add_op({ [0] = OP_ColorMaterial, mode, type_ })
end

function TinyGL.glLightfv(light: number, type_: number, v: { number } | buffer)
	gl_add_op({ [0] = OP_Light, light, type_, f32(v, 0), f32(v, 1), f32(v, 2), f32(v, 3) })
end

function TinyGL.glLightf(light: number, type_: number, v: number)
	gl_add_op({ [0] = OP_Light, light, type_, v, 0, 0, 0 })
end

function TinyGL.glLightModeli(pname: number, param: number)
	gl_add_op({ [0] = OP_LightModel, pname, param, 0, 0, 0 })
end

function TinyGL.glLightModelfv(pname: number, param: { number } | buffer)
	gl_add_op({
		[0] = OP_LightModel,
		pname,
		f32(param, 0),
		f32(param, 1),
		f32(param, 2),
		f32(param, 3),
	})
end

-- ---------------------------------------------------------------------------
-- clear
-- ---------------------------------------------------------------------------

function TinyGL.glClear(mask: number)
	gl_add_op({ [0] = OP_Clear, mask })
end

function TinyGL.glClearColor(r: number, g: number, b: number, a: number)
	gl_add_op({ [0] = OP_ClearColor, r, g, b, a })
end

function TinyGL.glClearDepth(depth: number)
	gl_add_op({ [0] = OP_ClearDepth, depth })
end

-- ---------------------------------------------------------------------------
-- textures
-- ---------------------------------------------------------------------------

--- `pixels` is 8 bit RGB data: a `buffer` of 3 bytes per pixel or a table of
--- numbers in the same order.  TinyGL accepts only GL_RGB/GL_UNSIGNED_BYTE and
--- resizes everything to 256x256.
function TinyGL.glTexImage2D(
	target: number,
	level: number,
	components: number,
	width: number,
	height: number,
	border: number,
	format: number,
	type_: number,
	pixels: any
)
	gl_add_op({
		[0] = OP_TexImage2D,
		target,
		level,
		components,
		width,
		height,
		border,
		format,
		type_,
		Handle.alloc(ctx(), pixels),
	})
end

function TinyGL.glBindTexture(target: number, texture: number)
	gl_add_op({ [0] = OP_BindTexture, target, texture })
end

function TinyGL.glTexEnvi(target: number, pname: number, param: number)
	gl_add_op({ [0] = OP_TexEnv, target, pname, param, 0, 0, 0, 0 })
end

function TinyGL.glTexParameteri(target: number, pname: number, param: number)
	gl_add_op({ [0] = OP_TexParameter, target, pname, param, 0, 0, 0, 0 })
end

function TinyGL.glPixelStorei(pname: number, param: number)
	gl_add_op({ [0] = OP_PixelStore, pname, param })
end

--- glGenTextures(n): returns a fresh array of n unused texture ids
function TinyGL.glGenTextures(n: number): { number }
	return Texture.glGenTextures(ctx(), n)
end

function TinyGL.glDeleteTextures(textures: { number }, n: number?)
	Texture.glDeleteTextures(ctx(), textures, n)
end

-- ---------------------------------------------------------------------------
-- selection
-- ---------------------------------------------------------------------------

function TinyGL.glInitNames()
	gl_add_op({ [0] = OP_InitNames })
end

function TinyGL.glPushName(name: number)
	gl_add_op({ [0] = OP_PushName, name })
end

function TinyGL.glPopName()
	gl_add_op({ [0] = OP_PopName })
end

function TinyGL.glLoadName(name: number)
	gl_add_op({ [0] = OP_LoadName, name })
end

--- glRenderMode(mode): returns the number of hits recorded when leaving
--- GL_SELECT (negative when the selection buffer overflowed), like C.
function TinyGL.glRenderMode(mode: number): number
	return Select.glRenderMode(ctx(), mode)
end

--- glSelectBuffer(size): returns the table to record hits in.  Pass it to
--- glSelectBuffer before switching to GL_SELECT, then read it back afterwards:
--- each hit is [m, zmin, zmax, name...].
function TinyGL.glSelectBuffer(size: number): { number }
	local c = ctx()
	local buf = table.create(size) :: { number }
	Select.glSelectBuffer(c, size, buf)
	return buf
end

-- ---------------------------------------------------------------------------
-- polygon offset
-- ---------------------------------------------------------------------------

function TinyGL.glPolygonOffset(factor: number, units: number)
	gl_add_op({ [0] = OP_PolygonOffset, factor, units })
end

-- ---------------------------------------------------------------------------
-- display lists
-- ---------------------------------------------------------------------------

function TinyGL.glCallList(list: number)
	gl_add_op({ [0] = OP_CallList, list })
end

function TinyGL.glFlush()
	-- nothing to do
end

function TinyGL.glHint(target: number, mode: number)
	gl_add_op({ [0] = OP_Hint, target, mode })
end

function TinyGL.glGenLists(range: number): number
	return List.glGenLists(ctx(), range)
end

function TinyGL.glNewList(list: number, mode: number)
	List.glNewList(ctx(), list, mode)
end

function TinyGL.glEndList()
	List.glEndList(ctx())
end

function TinyGL.glIsList(list: number): boolean
	return List.glIsList(ctx(), list)
end

-- ---------------------------------------------------------------------------
-- OpenGL 1.1 vertex arrays
-- ---------------------------------------------------------------------------

--- GL.floatView(array, first) is C's `array + first`: the way to hand a slice of
--- an interleaved buffer to glVertexPointer/glColorPointer/..., e.g. C's
--- `glColorPointer(3, GL_FLOAT, 2, a + 2)` is
--- `GL.glColorPointer(3, GL_FLOAT, 2, GL.floatView(a, 2))` here.
TinyGL.floatView = Arrays.floatView

function TinyGL.glArrayElement(i: number)
	gl_add_op({ [0] = OP_ArrayElement, i })
end

-- The client state bits of arrays.c, keyed by the enumerant glEnableClientState
-- is handed.  Frozen: it is read by every glEnableClientState/glDisableClientState
-- and written by nothing, and a write here would make the arrays path enable the
-- wrong array for the rest of the process.
local CLIENT_STATE = table.freeze({
	[GL_VERTEX_ARRAY] = 0x0001,
	[GL_NORMAL_ARRAY] = 0x0004,
	[GL_COLOR_ARRAY] = 0x0002,
	[GL_TEXTURE_COORD_ARRAY] = 0x0008,
})

function TinyGL.glEnableClientState(array: number)
	local bit = CLIENT_STATE[array]
	assert(bit ~= nil, "glEnableClientState: unsupported array")
	gl_add_op({ [0] = OP_EnableClientState, bit })
end

function TinyGL.glDisableClientState(array: number)
	local bit = CLIENT_STATE[array]
	assert(bit ~= nil, "glDisableClientState: unsupported array")
	-- C passes the complement of the bit and the handler ANDs it in
	gl_add_op({ [0] = OP_DisableClientState, bnot(bit) })
end

--- `data` is a `buffer` of f32 samples or a table of numbers
function TinyGL.glVertexPointer(size: number, type_: number, stride: number, data: any)
	assert(type_ == GL_FLOAT, "glVertexPointer: only GL_FLOAT is supported")
	gl_add_op({ [0] = OP_VertexPointer, size, stride, Handle.alloc(ctx(), data) })
end

function TinyGL.glColorPointer(size: number, type_: number, stride: number, data: any)
	assert(type_ == GL_FLOAT, "glColorPointer: only GL_FLOAT is supported")
	gl_add_op({ [0] = OP_ColorPointer, size, stride, Handle.alloc(ctx(), data) })
end

function TinyGL.glNormalPointer(type_: number, stride: number, data: any)
	assert(type_ == GL_FLOAT, "glNormalPointer: only GL_FLOAT is supported")
	gl_add_op({ [0] = OP_NormalPointer, stride, Handle.alloc(ctx(), data) })
end

function TinyGL.glTexCoordPointer(size: number, type_: number, stride: number, data: any)
	assert(type_ == GL_FLOAT, "glTexCoordPointer: only GL_FLOAT is supported")
	gl_add_op({ [0] = OP_TexCoordPointer, size, stride, Handle.alloc(ctx(), data) })
end

-- ---------------------------------------------------------------------------
-- queries
-- ---------------------------------------------------------------------------

function TinyGL.glGetIntegerv(pname: number): { number }
	return Get.glGetIntegerv(ctx(), pname)
end

function TinyGL.glGetFloatv(pname: number): { number }
	return Get.glGetFloatv(ctx(), pname)
end

-- ---------------------------------------------------------------------------
-- context management (init.c)
-- ---------------------------------------------------------------------------

--- glInit(zbuffer): create the context for an opened Z buffer and make it
--- current.  Returns the context (also available through GL.getContext()).
function TinyGL.glInit(zbuffer: any): any
	local c = Context.init(zbuffer)
	return c
end

--- glClose()
function TinyGL.glClose()
	local c = Context.get()
	if c ~= nil then
		Context.close(c)
	end
end

function TinyGL.getContext(): any
	return Context.get()
end

function TinyGL.setContext(c: any)
	Context.set(c)
end

--- glDebug(mode), TinyGL's non standard switch that makes every opcode be
--- printed as it is executed.
function TinyGL.glDebug(mode: number)
	ctx().printFlag = if mode ~= 0 then 1 else 0
end

--- Same as glDebug but routing the text through a host supplied function
--- (C would print to stderr, which not every Luau host has).
function TinyGL.glDebugOutput(f: ((string) -> ())?)
	local MSH = require("./internal/msghandling")
	MSH.output = f or print
end

return TinyGL
