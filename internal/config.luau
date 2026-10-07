--!strict
--[[
	config.luau — port of TinyGL's src/zfeatures.h + the tunable constants of
	src/zgl.h + src/zbuffer.h.

	Everything that was a compile time switch in C is a plain value here.  The
	one that actually matters is `FEATURE_RENDER_BITS`: this port implements
	the 16 bit internal pixel format (ZB_MODE_5R6G5B / ZB_MODE_RGBA /
	ZB_MODE_RGB24 frame buffers plus 8 bit dithered output), exactly like the
	upstream default build.
]]

local Config = {}

------------------------------------------------------------------
-- zfeatures.h
------------------------------------------------------------------

Config.FEATURE_ARRAYS = true
Config.FEATURE_DISPLAYLISTS = true
Config.FEATURE_POLYGON_OFFSET = true

-- External pixel format conversion support (all supported by this port).
Config.FEATURE_16_BITS = true
Config.FEATURE_8_BITS = true
Config.FEATURE_24_BITS = true
Config.FEATURE_32_BITS = true

-- Internal pixel format: 15, 16, 24 or 32.  Only 16 is implemented.
Config.FEATURE_RENDER_BITS = 16

------------------------------------------------------------------
-- zbuffer.h
------------------------------------------------------------------

Config.ZB_Z_BITS = 16
Config.ZB_POINT_Z_FRAC_BITS = 14

local lshift = bit32.lshift

Config.ZB_POINT_S_MIN = lshift(1, 13)
Config.ZB_POINT_S_MAX = lshift(1, 22) - lshift(1, 13)
Config.ZB_POINT_T_MIN = lshift(1, 21)
Config.ZB_POINT_T_MAX = lshift(1, 30) - lshift(1, 21)

Config.ZB_POINT_RED_MIN = lshift(1, 10)
Config.ZB_POINT_RED_MAX = lshift(1, 16) - lshift(1, 10)
Config.ZB_POINT_GREEN_MIN = lshift(1, 9)
Config.ZB_POINT_GREEN_MAX = lshift(1, 16) - lshift(1, 9)
Config.ZB_POINT_BLUE_MIN = lshift(1, 10)
Config.ZB_POINT_BLUE_MAX = lshift(1, 16) - lshift(1, 10)

-- display modes
Config.ZB_MODE_5R6G5B = 1 -- true color 16 bits
Config.ZB_MODE_INDEX = 2 -- color index 8 bits
Config.ZB_MODE_RGBA = 3 -- 32 bit rgba mode
Config.ZB_MODE_RGB24 = 4 -- 24 bit rgb mode
Config.ZB_NB_COLORS = 225 -- number of colors for 8 bit display

-- bytes per pixel of the *internal* pixel format
if Config.FEATURE_RENDER_BITS == 16 then
	Config.PSZB = 2
	Config.PSZSH = 4
elseif Config.FEATURE_RENDER_BITS == 24 then
	Config.PSZB = 3
	Config.PSZSH = 5
elseif Config.FEATURE_RENDER_BITS == 32 then
	Config.PSZB = 4
	Config.PSZSH = 5
else
	error("TinyGL Luau: TGL_FEATURE_RENDER_BITS 15/24 rendering is not ported, use 16")
end

------------------------------------------------------------------
-- zgl.h
------------------------------------------------------------------

Config.POLYGON_MAX_VERTEX = 16 -- initially # of allocated GLVertexes (will grow)

Config.MAX_SPECULAR_BUFFERS = 8
Config.SPECULAR_BUFFER_SIZE = 1024
Config.SPECULAR_BUFFER_RESOLUTION = 1024

Config.MAX_MODELVIEW_STACK_DEPTH = 32
Config.MAX_PROJECTION_STACK_DEPTH = 8
Config.MAX_TEXTURE_STACK_DEPTH = 8
Config.MAX_NAME_STACK_DEPTH = 64
Config.MAX_TEXTURE_LEVELS = 11
Config.MAX_LIGHTS = 16

Config.MAX_DISPLAY_LISTS = 1024
Config.OP_BUFFER_MAX_SIZE = 512

Config.TEXTURE_HASH_TABLE_SIZE = 256

Config.TGL_OFFSET_FILL = 0x1
Config.TGL_OFFSET_LINE = 0x2
Config.TGL_OFFSET_POINT = 0x4

Config.CLIP_EPSILON = 1e-5

-- CLIP_* bits (clip.c)
Config.CLIP_XMIN = 1
Config.CLIP_XMAX = 2
Config.CLIP_YMIN = 4
Config.CLIP_YMAX = 8
Config.CLIP_ZMIN = 16
Config.CLIP_ZMAX = 32

------------------------------------------------------------------
-- opinfo.h — the opcode table
----------------------------------------------------------------
-- Each entry is { name, paramCount, printfStyleFormat } and is listed in the
-- exact order of TinyGL's src/opinfo.h so that opcode numbers match the C
-- build (the enum in zgl.h is generated from that file).
--
-- `paramCount` is the number of GLParam slots that follow the opcode, which is
-- what src/list.c calls the op size (op_table_size[i] = b + 1).

--- Each entry is a { name, paramCount, format } triple; Luau has no fixed arity
--- array type, so the fields are cast back at the point of use.
local OP_INFOS: { { string | number } } = {
	{ "Color", 7, "%f %f %f %f %d %d %d" },
	{ "TexCoord", 4, "%f %f %f %f" },
	{ "EdgeFlag", 1, "%d" },
	{ "Normal", 3, "%f %f %f" },

	{ "Begin", 1, "%C" },
	{ "Vertex", 4, "%f %f %f %f" },
	{ "End", 0, "" },

	{ "EnableDisable", 2, "%C %d" },

	{ "MatrixMode", 1, "%C" },
	{ "LoadMatrix", 16, "" },
	{ "LoadIdentity", 0, "" },
	{ "MultMatrix", 16, "" },
	{ "PushMatrix", 0, "" },
	{ "PopMatrix", 0, "" },
	{ "Rotate", 4, "%f %f %f %f" },
	{ "Translate", 3, "%f %f %f" },
	{ "Scale", 3, "%f %f %f" },

	{ "Viewport", 4, "%d %d %d %d" },
	{ "Frustum", 6, "%f %f %f %f %f %f" },

	{ "Material", 6, "%C %C %f %f %f %f" },
	{ "ColorMaterial", 2, "%C %C" },
	{ "Light", 6, "%C %C %f %f %f %f" },
	{ "LightModel", 5, "%C %f %f %f %f" },

	{ "Clear", 1, "%d" },
	{ "ClearColor", 4, "%f %f %f %f" },
	{ "ClearDepth", 1, "%f" },

	{ "InitNames", 0, "" },
	{ "PushName", 1, "%d" },
	{ "PopName", 0, "" },
	{ "LoadName", 1, "%d" },

	{ "TexImage2D", 9, "%d %d %d %d %d %d %d %d %d" },
	{ "BindTexture", 2, "%C %d" },
	{ "TexEnv", 7, "%C %C %C %f %f %f %f" },
	{ "TexParameter", 7, "%C %C %C %f %f %f %f" },
	{ "PixelStore", 2, "%C %C" },

	{ "ShadeModel", 1, "%C" },
	{ "CullFace", 1, "%C" },
	{ "FrontFace", 1, "%C" },
	{ "PolygonMode", 2, "%C %C" },

	{ "CallList", 1, "%d" },
	{ "Hint", 2, "%C %C" },

	-- special opcodes
	{ "EndList", 0, "" },
	{ "NextBuffer", 1, "%p" },

	-- opengl 1.1 arrays
	{ "ArrayElement", 1, "%d" },
	{ "EnableClientState", 1, "%C" },
	{ "DisableClientState", 1, "%C" },
	{ "VertexPointer", 4, "%d %C %d %p" },
	{ "ColorPointer", 4, "%d %C %d %p" },
	{ "NormalPointer", 3, "%C %d %p" },
	{ "TexCoordPointer", 4, "%d %C %d %p" },

	-- opengl 1.1 polygon offset
	{ "PolygonOffset", 2, "%f %f" },
}

-- OP_Color, OP_TexCoord, ... (0 based, identical to the C enum)
local OP: { [string]: number } = {}
-- op size, i.e. how many slots (opcode + params) the op occupies in a display
-- list.  Matches op_table_size[] in src/list.c.
local OP_SIZE: { [number]: number } = {}
-- "glColor %f %f %f %f %d %d %d" — used by glPrintOp (gl_print_op)
local OP_PRINT: { [number]: string } = {}
-- opcode -> the name from opinfo.h (for error messages)
local OP_NAMES: { [number]: string } = {}

for i, info in ipairs(OP_INFOS) do
	local name = info[1] :: string
	local size = info[2] :: number
	local fmt = info[3] :: string
	-- Config.OP.Color and Config.OP.OP_Color are the same opcode number: the first
	-- spelling is the convenient one, the second is TinyGL's C name.
	OP[name] = i - 1
	OP["OP_" .. name] = i - 1
	OP_SIZE[i - 1] = size + 1
	OP_NAMES[i - 1] = name
	OP_PRINT[i - 1] = "gl" .. name .. (if size > 0 then " " .. fmt else "")
end

Config.OP_INFOS = OP_INFOS
Config.OP = table.freeze(OP)
Config.OP_SIZE = table.freeze(OP_SIZE)
Config.OP_PRINT = table.freeze(OP_PRINT)
Config.OP_NAMES = table.freeze(OP_NAMES)
Config.OP_COUNT = #OP_INFOS

--[[
	The five tables above are frozen, and the rows of OP_INFOS with them.  An
	opcode number is compile time data — the enum in zgl.h is generated from
	opinfo.h, and every module of the port agrees with every other one on what
	OP_Color means — so a write to any of them is a bug, and freezing it turns
	that bug into an error at the place that made it rather than an interpreter
	that dispatches the wrong handler from then on.

	It is also what lets the modules hoist their opcode literals into their own
	scope: CHECK.luau only accepts a frozen profile, because a profile a module
	could edit is not something to check a literal against.

	Config itself is *not* frozen: ASSERTS and CHECKS are switches a host is
	meant to flip (see GL.Config in the public API).
]]
for _, info in OP_INFOS do
	table.freeze(info)
end
table.freeze(OP_INFOS)

--[[
	opinfo.h declares the parameter layout of each opcode, but a few of TinyGL's
	API functions fill fewer slots than declared (the remaining GLParam slots
	were simply uninitialized stack memory that the display list copied
	verbatim).  This table is the number of parameters the port provides, so the
	argument checks can be exact.
]]
local OP_PARAMS: { [number]: number } = {}
OP_PARAMS[OP.OP_VertexPointer] = 3 -- size, stride, array
OP_PARAMS[OP.OP_ColorPointer] = 3
OP_PARAMS[OP.OP_NormalPointer] = 2 -- stride, array
OP_PARAMS[OP.OP_TexCoordPointer] = 3
Config.OP_PARAMS = table.freeze(OP_PARAMS)

function Config.opParamCount(op: number): number
	local n = OP_PARAMS[op]
	if n ~= nil then
		return n
	end
	return OP_SIZE[op] - 1
end

------------------------------------------------------------------
-- misc helpers shared by several modules
------------------------------------------------------------------

-- C's `assert()` is used liberally in TinyGL; keep the same checks so porting
-- bugs surface loudly instead of silently corrupting the frame buffer.
Config.ASSERTS = true

-- Validate the arguments of every opcode (all parameter slots filled, opcode in
-- range).  Cheap, and it turns C's silent undefined behaviour (reading past a
-- GLParam array, for instance) into an error.  Set to false once the calling
-- code is trusted and speed matters.
Config.CHECKS = true

function Config.assert(cond: any, message: string?)
	if Config.ASSERTS and not cond then
		error("TinyGL assertion failed: " .. (message or "assertion"), 2)
	end
end

return Config
