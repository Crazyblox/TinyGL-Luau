--!strict
--[[
	matrix.luau — port of TinyGL's src/matrix.c.

	The three matrix stacks (model view, projection, texture).  C kept
	`M4 *matrix_stack[i]` plus a moving `matrix_stack_ptr[i]`; here each stack is
	an array of 4x4 matrices and `c.matrixStackPtr[i]` is a 1 based index into it.

	Matrix order note: the arrays handed to glLoadMatrixf/glMultMatrixf are in
	OpenGL's column major order, so they are transposed into the internal
	row major M4 exactly like glopLoadMatrix() does in C.
]]

local Config = require("./config")
local ZMath = require("./zmath")
local Util = require("./util")
local MSH = require("./msghandling")

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_MODELVIEW was a table lookup.  CHECK validates each literal against the
-- frozen table it stands for as this module loads, so one that drifts is an error
-- naming both values here rather than a stack written in the wrong order.  See
-- CHECK.luau.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_MODELVIEW = 0x1700; CHECK("GL_MODELVIEW", GL_MODELVIEW)
local GL_PROJECTION = 0x1701; CHECK("GL_PROJECTION", GL_PROJECTION)
local GL_TEXTURE = 0x1702; CHECK("GL_TEXTURE", GL_TEXTURE)

local Matrix = {}

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

--- the current matrix of a stack (C's c->matrix_stack_ptr[mode])
function Matrix.top(c: any, mode: number): ZMath.M4
	return c.matrixStack[mode + 1][c.matrixStackPtr[mode + 1]]
end

--- gl_print_matrix
function Matrix.gl_print_matrix(m: { number })
	for i = 0, 3 do
		MSH.output((("%f %f %f %f"):format(m[i + 1], m[4 + i + 1], m[8 + i + 1], m[12 + i + 1])) :: string)
	end
end

--- gl_matrix_update (inline in C)
local function gl_matrix_update(c: any)
	c.matrixModelProjectionUpdated = if c.matrixMode <= 1 then 1 else 0
end

--- glopMatrixMode
function Matrix.glopMatrixMode(c: any, p: { number })
	local mode = p[1]
	if mode == GL_MODELVIEW then
		c.matrixMode = 0
	elseif mode == GL_PROJECTION then
		c.matrixMode = 1
	elseif mode == GL_TEXTURE then
		c.matrixMode = 2
	else
		assert(false, "glopMatrixMode: illegal mode")
	end
end

--- glopLoadMatrix
function Matrix.glopLoadMatrix(c: any, p: { number })
	local m = Matrix.top(c, c.matrixMode)
	for i = 0, 3 do
		for j = 0, 3 do
			-- C stores into a `float` GLParam, which rounds the double the host
			-- handed to glLoadMatrixf(); here the value is kept in full
			m[j + 1][i + 1] = p[1 + i * 4 + j]
		end
	end
	gl_matrix_update(c)
end

--- glopLoadIdentity
function Matrix.glopLoadIdentity(c: any, _p: { number })
	ZMath.gl_M4_Id(Matrix.top(c, c.matrixMode))
	gl_matrix_update(c)
end

--- glopMultMatrix
function Matrix.glopMultMatrix(c: any, p: { number })
	local m = ZMath.m4New()
	for i = 0, 3 do
		for j = 0, 3 do
			m[j + 1][i + 1] = p[1 + i * 4 + j]
		end
	end
	ZMath.gl_M4_MulLeft(Matrix.top(c, c.matrixMode), m)
	gl_matrix_update(c)
end

--- glopPushMatrix
function Matrix.glopPushMatrix(c: any, _p: { number })
	local n = c.matrixMode
	local stack = c.matrixStack[n + 1]

	assert(c.matrixStackPtr[n + 1] < c.matrixStackDepthMax[n + 1], "glopPushMatrix: stack overflow")

	c.matrixStackPtr[n + 1] += 1
	ZMath.gl_M4_Move(stack[c.matrixStackPtr[n + 1]], stack[c.matrixStackPtr[n + 1] - 1])

	gl_matrix_update(c)
end

--- glopPopMatrix
function Matrix.glopPopMatrix(c: any, _p: { number })
	local n = c.matrixMode

	assert(c.matrixStackPtr[n + 1] > 1, "glopPopMatrix: stack underflow")
	c.matrixStackPtr[n + 1] -= 1

	gl_matrix_update(c)
end

--- glopRotate
function Matrix.glopRotate(c: any, p: { number })
	local m = ZMath.m4New()
	-- C stores this into a `float`; here it stays a double
	local angle = p[1] * Util.M_PI / 180.0
	local u = { p[2], p[3], p[4] }

	-- simple case detection
	local dir_code = (if u[1] ~= 0 then 4 else 0) + (if u[2] ~= 0 then 2 else 0) + (if u[3] ~= 0 then 1 else 0)

	if dir_code == 0 then
		ZMath.gl_M4_Id(m)
	elseif dir_code == 4 then
		if u[1] < 0 then
			angle = -angle
		end
		ZMath.gl_M4_Rotate(m, angle, 0)
	elseif dir_code == 2 then
		if u[2] < 0 then
			angle = -angle
		end
		ZMath.gl_M4_Rotate(m, angle, 1)
	elseif dir_code == 1 then
		if u[3] < 0 then
			angle = -angle
		end
		ZMath.gl_M4_Rotate(m, angle, 2)
	else
		-- normalize vector
		local len = u[1] * u[1] + u[2] * u[2] + u[3] * u[3]
		if len == 0.0 then
			return
		end
		len = 1.0 / math.sqrt(len)
		u[1] = u[1] * len
		u[2] = u[2] * len
		u[3] = u[3] * len

		-- store cos and sin values
		local cost = math.cos(angle)
		local sint = math.sin(angle)
		local omc = 1 - cost -- (1 - cost), computed once, as the C compiler does

		-- fill in the values
		m[4][1] = 0
		m[4][2] = 0
		m[4][3] = 0
		m[1][4] = 0
		m[2][4] = 0
		m[3][4] = 0
		m[4][4] = 1

		-- do the math
		local u11, u22, u33 = u[1] * u[1], u[2] * u[2], u[3] * u[3]
		m[1][1] = u11 + cost * (1 - u11)
		m[2][1] = u[1] * u[2] * omc - u[3] * sint
		m[3][1] = u[3] * u[1] * omc + u[2] * sint
		m[1][2] = u[1] * u[2] * omc + u[3] * sint
		m[2][2] = u22 + cost * (1 - u22)
		m[3][2] = u[2] * u[3] * omc - u[1] * sint
		m[1][3] = u[3] * u[1] * omc - u[2] * sint
		m[2][3] = u[2] * u[3] * omc + u[1] * sint
		m[3][3] = u33 + cost * (1 - u33)
	end

	ZMath.gl_M4_MulLeft(Matrix.top(c, c.matrixMode), m)

	gl_matrix_update(c)
end

--- glopScale
function Matrix.glopScale(c: any, p: { number })
	local m = Matrix.top(c, c.matrixMode)
	local x, y, z = p[1], p[2], p[3]

	for i = 1, 4 do
		local row = m[i]
		row[1] = row[1] * x
		row[2] = row[2] * y
		row[3] = row[3] * z
	end

	gl_matrix_update(c)
end

--- glopTranslate
function Matrix.glopTranslate(c: any, p: { number })
	local m = Matrix.top(c, c.matrixMode)
	local x, y, z = p[1], p[2], p[3]

	for i = 1, 4 do
		local row = m[i]
		row[4] = row[1] * x + row[2] * y + row[3] * z + row[4]
	end

	gl_matrix_update(c)
end

--- glopFrustum.  C cannot name its parameters `near`/`far` either, hence
--- nearVal/farVal here as well.
function Matrix.glopFrustum(c: any, p: { number })
	local m = ZMath.m4New()
	local left, right, bottom, top_ = p[1], p[2], p[3], p[4]
	local nearVal, farVal = p[5], p[6]

	-- C keeps every intermediate in a `float`; here they are plain doubles
	local x = (2.0 * nearVal) / (right - left)
	local y = (2.0 * nearVal) / (top_ - bottom)
	local A = (right + left) / (right - left)
	local B = (top_ + bottom) / (top_ - bottom)
	local C = -(farVal + nearVal) / (farVal - nearVal)
	local D = -(2.0 * farVal * nearVal) / (farVal - nearVal)

	-- r[0..15] in C == the row major 4x4 below
	m[1][1] = x
	m[1][2] = 0
	m[1][3] = A
	m[1][4] = 0
	m[2][1] = 0
	m[2][2] = y
	m[2][3] = B
	m[2][4] = 0
	m[3][1] = 0
	m[3][2] = 0
	m[3][3] = C
	m[3][4] = D
	m[4][1] = 0
	m[4][2] = 0
	m[4][3] = -1
	m[4][4] = 0

	ZMath.gl_M4_MulLeft(Matrix.top(c, c.matrixMode), m)

	gl_matrix_update(c)
end

--- Allocate the stacks glInit() needs.
function Matrix.initStacks(c: any)
	c.matrixStack = {}
	c.matrixStackPtr = {}
	c.matrixStackDepthMax = { Config.MAX_MODELVIEW_STACK_DEPTH, Config.MAX_PROJECTION_STACK_DEPTH, Config.MAX_TEXTURE_STACK_DEPTH }
	for i = 1, 3 do
		local depth = c.matrixStackDepthMax[i]
		local stack = table.create(depth)
		for j = 1, depth do
			stack[j] = ZMath.m4New()
		end
		-- glInit() leaves an identity on top of all three stacks (it calls
		-- glMatrixMode/glLoadIdentity for each of them)
		stack[1] = ZMath.m4Identity()
		c.matrixStack[i] = stack
		c.matrixStackPtr[i] = 1
	end
end

return Matrix
