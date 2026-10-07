--!strict
--[[
	texture.luau — port of TinyGL's src/texture.c (texture manager) plus the
	texture related opcodes glopTexImage2D / glopBindTexture / glopTexEnv /
	glopTexParameter / glopPixelStore.

	Textures are kept in a hash table of `handle` -> GLTexture, exactly like the
	C code.  glTexImage2D only accepts 8 bit RGB images and resizes them to
	256x256 (TinyGL's one and only texture size), storing them in the internal
	pixel format.

	`pixels` may be a Luau `buffer` with 3 bytes per pixel or a table of numbers
	in the same order (1 based).
]]

local Config = require("./config")
local ImageUtil = require("./image_util")
local Handle = require("./handle")

local buffer = buffer --[[(standard library)]]

local Texture = {}

local TEXTURE_HASH_TABLE_SIZE = Config.TEXTURE_HASH_TABLE_SIZE
local MAX_TEXTURE_LEVELS = Config.MAX_TEXTURE_LEVELS

--[[
	Constants hoisted into this module's own scope: a local is a register read where
	GL.GL_TEXTURE_2D was a table lookup.  CHECK validates each one as the module
	loads, against the frozen table it stands for -- gl_constants for the enumerants,
	Config.OP for the opcode number, an opcode being compile time data, the enum in
	zgl.h being generated from opinfo.h.
	CHECK.luau is --!nocheck, and takes one argument to install a profile or
	two to check against it, which no single type says: hence the cast.
	CHECK(table) installs a profile, dropping whatever the module loaded
	before it installed.
	See CHECK.luau.
]]
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_DECAL = 0x2101; CHECK("GL_DECAL", GL_DECAL)
local GL_REPEAT = 0x2901; CHECK("GL_REPEAT", GL_REPEAT)
local GL_RGB = 0x1907; CHECK("GL_RGB", GL_RGB)
local GL_TEXTURE_2D = 0xDE1; CHECK("GL_TEXTURE_2D", GL_TEXTURE_2D)
local GL_TEXTURE_ENV = 0x2300; CHECK("GL_TEXTURE_ENV", GL_TEXTURE_ENV)
local GL_TEXTURE_ENV_MODE = 0x2200; CHECK("GL_TEXTURE_ENV_MODE", GL_TEXTURE_ENV_MODE)
local GL_TEXTURE_WRAP_S = 0x2802; CHECK("GL_TEXTURE_WRAP_S", GL_TEXTURE_WRAP_S)
local GL_TEXTURE_WRAP_T = 0x2803; CHECK("GL_TEXTURE_WRAP_T", GL_TEXTURE_WRAP_T)
local GL_UNPACK_ALIGNMENT = 0xCF5; CHECK("GL_UNPACK_ALIGNMENT", GL_UNPACK_ALIGNMENT)
local GL_UNSIGNED_BYTE = 0x1401; CHECK("GL_UNSIGNED_BYTE", GL_UNSIGNED_BYTE)
CHECK()(Config.OP)
local OP_BindTexture = 31; CHECK("OP_BindTexture", OP_BindTexture)

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

local function gl_fatal_error(msg: string): never
	error("TinyGL: fatal error: " .. msg, 2)
end

local function bucket(h: number): number
	return (h % TEXTURE_HASH_TABLE_SIZE) + 1 -- C: h % TEXTURE_HASH_TABLE_SIZE
end

--- find_texture
local function findTexture(c: any, h: number): any
	local t = c.sharedState.textureHashTable[bucket(h)]
	while t ~= nil do
		if t.handle == h then
			return t
		end
		t = t.next
	end
	return nil
end

--- free_texture
local function freeTexture(c: any, h: number)
	local t = findTexture(c, h)
	if t == nil then
		return
	end

	if t.prev == nil then
		c.sharedState.textureHashTable[bucket(t.handle)] = t.next
	else
		t.prev.next = t.next
	end
	if t.next ~= nil then
		t.next.prev = t.prev
	end

	for i = 1, MAX_TEXTURE_LEVELS do
		local im = t.images[i]
		if im.pixmap ~= nil then
			im.pixmap = nil
		end
	end
end

--- alloc_texture
function Texture.alloc_texture(c: any, h: number): any
	local t: any = { images = {}, handle = h, next = nil, prev = nil }
	for i = 1, MAX_TEXTURE_LEVELS do
		t.images[i] = { pixmap = nil, xsize = 0, ysize = 0 }
	end

	local ht = c.sharedState.textureHashTable
	local b = bucket(h)
	t.next = ht[b]
	t.prev = nil
	if t.next ~= nil then
		t.next.prev = t
	end
	ht[b] = t

	return t
end

--- glInitTextures
function Texture.glInitTextures(c: any)
	c.texture2dEnabled = 0
	-- texture 0 always exists (C calls alloc_texture(c, 0) from initSharedState)
	c.currentTexture = findTexture(c, 0) or Texture.alloc_texture(c, 0)
end

--- glGenTextures (API level in C: it does not go through the op stream)
function Texture.glGenTextures(c: any, n: number): { number }
	local max = 0
	local ht = c.sharedState.textureHashTable

	for i = 1, TEXTURE_HASH_TABLE_SIZE do
		local t = ht[i]
		while t ~= nil do
			if t.handle > max then
				max = t.handle
			end
			t = t.next
		end
	end

	local out = table.create(n) :: { number }
	for i = 1, n do
		out[i] = max + i
	end
	return out
end

--- glDeleteTextures (API level in C)
function Texture.glDeleteTextures(c: any, textures: { number }, n: number?)
	local count = n or #textures
	for i = 1, count do
		local t = findTexture(c, textures[i])
		if t ~= nil then
			if t == c.currentTexture then
				-- glBindTexture(GL_TEXTURE_2D, 0)
				Texture.glopBindTexture(c, { [0] = OP_BindTexture, GL_TEXTURE_2D, 0 })
			end
			freeTexture(c, textures[i])
		end
	end
end

--- glopBindTexture
function Texture.glopBindTexture(c: any, p: { number })
	local target = p[1]
	local texture = p[2]

	assert(target == GL_TEXTURE_2D and texture >= 0, "glopBindTexture: illegal arguments")

	local t = findTexture(c, texture)
	if t == nil then
		t = Texture.alloc_texture(c, texture)
	end
	c.currentTexture = t
end

--- glopTexImage2D
function Texture.glopTexImage2D(c: any, p: { number })
	local target = p[1]
	local level = p[2]
	local components = p[3]
	local width = p[4]
	local height = p[5]
	local border = p[6]
	local format = p[7]
	local kind = p[8]
	local pixelsId = p[9] :: number
	local pixels = Handle.get(c, pixelsId)

	if
		not (target == GL_TEXTURE_2D and level == 0 and components == 3 and border == 0 and format == GL_RGB and kind == GL_UNSIGNED_BYTE)
	then
		gl_fatal_error("glTexImage2D: combination of parameters not handled")
	end

	local src = pixels
	local do_free = false

	if width ~= 256 or height ~= 256 then
		-- no interpolation is done here to respect the original image aliasing !
		local pixels1 = buffer.create(256 * 256 * 3)
		ImageUtil.gl_resizeImageNoInterpolate(pixels1, 256, 256, pixels, width, height)
		src = pixels1
		do_free = true
		width = 256
		height = 256
	end

	local im = c.currentTexture.images[level + 1]
	im.xsize = width
	im.ysize = height

	local pixmap = buffer.create(width * height * Config.PSZB)
	if Config.FEATURE_RENDER_BITS == 16 then
		ImageUtil.gl_convertRGB_to_5R6G5B(pixmap, src, width, height)
	elseif Config.FEATURE_RENDER_BITS == 32 then
		ImageUtil.gl_convertRGB_to_8A8R8G8B(pixmap, src, width, height)
	else
		gl_fatal_error("unsupported TGL_FEATURE_RENDER_BITS")
	end
	im.pixmap = pixmap

	-- (do_free is a no-op here: Luau reclaims the temporary buffer)
	if do_free then
	end
end

--- glopTexEnv — TODO in TinyGL too: not all tests are done
function Texture.glopTexEnv(c: any, p: { number })
	local target = p[1]
	local pname = p[2]
	local param = p[3]

	if target ~= GL_TEXTURE_ENV then
		gl_fatal_error("glTexParameter: unsupported option")
	end

	if pname ~= GL_TEXTURE_ENV_MODE then
		gl_fatal_error("glTexParameter: unsupported option")
	end

	if param ~= GL_DECAL then
		gl_fatal_error("glTexParameter: unsupported option")
	end
end

--- glopTexParameter — TODO in TinyGL too: not all tests are done
function Texture.glopTexParameter(c: any, p: { number })
	local target = p[1]
	local pname = p[2]
	local param = p[3]

	if target ~= GL_TEXTURE_2D then
		gl_fatal_error("glTexParameter: unsupported option")
	end

	if pname == GL_TEXTURE_WRAP_S or pname == GL_TEXTURE_WRAP_T then
		if param ~= GL_REPEAT then
			gl_fatal_error("glTexParameter: unsupported option")
		end
	end
end

--- glopPixelStore
function Texture.glopPixelStore(c: any, p: { number })
	local pname = p[1]
	local param = p[2]

	if pname ~= GL_UNPACK_ALIGNMENT or param ~= 1 then
		gl_fatal_error("glPixelStore: unsupported option")
	end
end

--- the texture half of the shared state glInit() sets up.  The hash table itself
--- lives in c.sharedState, which context.luau creates.
function Texture.initTextures(c: any)
	Texture.glInitTextures(c)
end

return Texture
