--!strict
--[[
	context.luau — the GLContext record plus init.c's glInit()/glClose().

	The context is a plain table whose fields mirror TinyGL's `GLContext` struct,
	camelCased (c->matrix_stack_ptr -> c.matrixStackPtr).  Everything in this port
	takes the context as its first argument, exactly like the C handlers do, so
	there is no hidden global state except the "current context" that the public
	glXxx() functions need (C has the same one: `GLContext *gl_ctx`).
]]

local Config = require("./config")
local ZMath = require("./zmath")
local Matrix = require("./matrix")
local Clip = require("./clip")
local Vertex = require("./vertex")
local Light = require("./light")
local Texture = require("./texture")
local Clear = require("./clear")
local Select = require("./select")
local Arrays = require("./arrays")
local Handle = require("./handle")

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_FILL was a table lookup.  CHECK validates each literal against the frozen
-- table it stands for as this module loads, so one that drifts is an error naming
-- both values here rather than default state that nothing else understands.  See
-- CHECK.luau.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_AMBIENT_AND_DIFFUSE = 0x1602; CHECK("GL_AMBIENT_AND_DIFFUSE", GL_AMBIENT_AND_DIFFUSE)
local GL_BACK = 0x405; CHECK("GL_BACK", GL_BACK)
local GL_FILL = 0x1B02; CHECK("GL_FILL", GL_FILL)
local GL_FRONT_AND_BACK = 0x408; CHECK("GL_FRONT_AND_BACK", GL_FRONT_AND_BACK)
local GL_SMOOTH = 0x1D01; CHECK("GL_SMOOTH", GL_SMOOTH)

local Context = {}

local MAX_LIGHTS = Config.MAX_LIGHTS

--- The current context (C's gl_ctx / gl_get_context()).
local currentCtx: any = nil

function Context.get(): any
	return currentCtx
end

--- TinyGLX/ostgl let the host swap the Z buffer of the one and only context;
--- glXMakeCurrent / ostgl_make_current do it in C.
function Context.set(c: any)
	currentCtx = c
end

--- glInit(): create a context on top of an already opened Z buffer and make it
--- the current one.  Returns the context.
function Context.init(zbuffer: any): any
	local c: any = {}

	c.zb = zbuffer

	-- the handle registry stands in for C's void * op parameters
	Handle.init(c)

	-- vertex pool, current vertex state and the viewport record
	Vertex.initVertex(c)

	c.matrixModelViewInv = ZMath.m4New()
	c.matrixModelProjection = ZMath.m4New()

	-- shared state: display lists + the texture hash table
	c.sharedState = {
		lists = table.create(Config.MAX_DISPLAY_LISTS),
		textureHashTable = table.create(Config.TEXTURE_HASH_TABLE_SIZE),
	}

	-- lists
	c.execFlag = 1
	c.compileFlag = 0
	c.printFlag = 0
	c.compileTarget = nil

	c.inBegin = 0

	-- lights
	c.lights = table.create(MAX_LIGHTS)
	for i = 1, MAX_LIGHTS do
		c.lights[i] = Light.newLight()
	end
	c.firstLight = nil
	c.ambientLightModel = { 0.2, 0.2, 0.2, 1 }
	c.localLightModel = 0
	c.lightingEnabled = 0
	c.lightModelTwoSide = 0

	-- default materials
	c.materials = { Light.newMaterial(), Light.newMaterial() }
	c.currentColorMaterialMode = GL_FRONT_AND_BACK
	c.currentColorMaterialType = GL_AMBIENT_AND_DIFFUSE
	c.colorMaterialEnabled = 0

	-- textures (texture 0 always exists)
	Texture.initTextures(c)

	-- default state (c.currentColor / longcurrentColor / currentNormal /
	-- currentEdgeFlag / currentTexCoord come from Vertex.initVertex)
	c.polygonModeFront = GL_FILL
	c.polygonModeBack = GL_FILL

	c.currentFrontFace = 0 -- 0 = GL_CCW, 1 = GL_CW
	c.currentCullFace = GL_BACK
	c.currentShadeModel = GL_SMOOTH
	c.cullFaceEnabled = 0

	-- which drawing routine glBegin() will use (set by glopBegin, like C;
	-- initialised so a stray call cannot index nil)
	c.drawTriangleFront = Clip.gl_draw_triangle_fill
	c.drawTriangleBack = Clip.gl_draw_triangle_fill

	-- clear
	Clear.initClear(c)

	-- selection
	Select.initSelect(c)

	-- matrix: three stacks, all with an identity on top, in model view mode.
	-- (C reaches this state by calling glMatrixMode/glLoadIdentity through the
	-- op stream; doing it directly keeps this module free of a dependency on the
	-- interpreter, and is exactly equivalent.)
	Matrix.initStacks(c)
	c.matrixMode = 0
	c.matrixModelProjectionUpdated = 1
	c.matrixModelProjectionNoWTransform = 0
	c.applyTextureMatrix = 0

	-- opengl 1.1 arrays
	Arrays.initArrays(c)

	-- opengl 1.1 polygon offset
	c.offsetStates = 0
	c.offsetFactor = 0
	c.offsetUnits = 0

	-- resize viewport function (host callback, see oscontext.luau)
	c.glResizeViewport = nil

	-- specular buffer
	c.specbufFirst = nil
	c.specbufUsedCounter = 0
	c.specbufNumBuffers = 0

	-- depth test
	c.depthTest = 0

	-- opaque slot for the host application (C's c->opaque)
	c.opaque = nil

	Context.set(c)
	return c
end

--- glClose(): drop the context.  Luau reclaims the memory, so this only has to
--- make sure nothing keeps the buffers alive and that the context is unusable.
function Context.close(c: any)
	if Context.get() == c then
		Context.set(nil)
	end
	c.zb = nil
	c.vertex = {}
	c.sharedState = nil
	c.pointerTable = {}
end

return Context
