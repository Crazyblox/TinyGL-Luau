--!strict
--[[
	scenes.luau — the same scenes as ref/ref_scenes.c, written against the Luau
	port.  tests/test_against_c.luau renders these and compares the frame buffer
	digests with the ones the C program produces.

	Each scene gets a brand new Z buffer and a brand new context (glInit), just
	like the C harness does, so no state carries over between scenes.

	`st` is the equivalent of the C harness' fb_xsize / fb_ysize globals: a scene
	that resizes the frame buffer updates it, and the digest covers only the
	region described by it.

	Scenes that print text (glGet / selection) push the same lines the C harness
	prints into `st.lines`.
]]

local GL = require("../tinygl")
local Enum = GL.Enum
local ZB = GL.ZB

-- the geometry the examples draw with, put under the same oracle as the library
local Cube = require("../examples/cube")

local buffer = buffer --[[(standard library)]]

local Scenes = {}

local TEXSIZE = 256

-- the ortho matrix is column major, i.e. m[col * 4 + row], 1 based here
local function orthoMatrix(l: number, r: number, b: number, t: number, n: number, f: number): { number }
	local m = table.create(16) :: { number }
	for i = 1, 16 do
		m[i] = 0
	end
	m[0 * 4 + 1] = 2 / (r - l)
	m[1 * 4 + 2] = 2 / (t - b)
	m[2 * 4 + 3] = -2 / (f - n)
	m[3 * 4 + 1] = -(r + l) / (r - l)
	m[3 * 4 + 2] = -(t + b) / (t - b)
	m[3 * 4 + 3] = -(f + n) / (f - n)
	m[3 * 4 + 4] = 1
	return m
end

local function setViewportOrtho(st: any)
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	GL.glLoadMatrixf(orthoMatrix(0, st.xsize, 0, st.ysize, -1, 1))
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
end

local function frustumLike()
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
end

local function makeTexture(): buffer
	local t = buffer.create(TEXSIZE * TEXSIZE * 3)
	for y = 0, TEXSIZE - 1 do
		for x = 0, TEXSIZE - 1 do
			local o = (y * TEXSIZE + x) * 3
			local cx = (x // 32) % 2
			local cy = (y // 32) % 2
			local v = if cx ~= cy then 255 else 32
			buffer.writeu8(t, o, v)
			buffer.writeu8(t, o + 1, (x * 255) // (TEXSIZE - 1))
			buffer.writeu8(t, o + 2, (y * 255) // (TEXSIZE - 1))
		end
	end
	return t
end

local function clearBoth()
	GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)
end

--[[
	One entry of Scenes.list.  `mode` is the external frame buffer format, numbered
	the way the C harness numbers them: 0 = ZB_MODE_5R6G5B, 1 = ZB_MODE_RGBA,
	2 = ZB_MODE_RGB24, 3 = ZB_MODE_INDEX.
]]
export type Scene = {
	name: string,
	xsize: number,
	ysize: number,
	mode: number,
	fn: (st: any) -> (),
}

local sceneList: { Scene } = {}
Scenes.list = sceneList

local function scene(name: string, xsize: number, ysize: number, mode: number, fn: (st: any) -> ()): ()
	table.insert(sceneList, { name = name, xsize = xsize, ysize = ysize, mode = mode, fn = fn })
end

-- ---------------------------------------------------------------------------

scene("clear", 64, 64, 0, function(st)
	GL.glClearColor(0.2, 0.4, 0.6, 1.0)
	clearBoth()
end)

scene("points", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_POINTS)
	GL.glVertex2f(0, 0)
	GL.glVertex2f(63, 63)
	GL.glVertex2f(10.25, 20.75)
	GL.glVertex2f(-1, 10)
	GL.glVertex2f(10, -1)
	GL.glVertex2f(31.5, 31.5)
	GL.glVertex2f(64, 32)
	GL.glVertex2f(32, 32)
	GL.glEnd()
end)

scene("lines", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glBegin(Enum.GL_LINES)
	GL.glColor3f(1, 0, 0)
	GL.glVertex2f(0, 0)
	GL.glVertex2f(63, 0)
	GL.glColor3f(0, 1, 0)
	GL.glVertex2f(63, 1)
	GL.glVertex2f(0, 1)
	GL.glColor3f(0, 0, 1)
	GL.glVertex2f(2, 2)
	GL.glVertex2f(2, 60)
	GL.glColor3f(1, 1, 0)
	GL.glVertex2f(3, 60)
	GL.glVertex2f(3, 2)
	GL.glColor3f(1, 1, 1)
	GL.glVertex2f(5, 5)
	GL.glVertex2f(60, 60)
	GL.glColor3f(1, 0, 1)
	GL.glVertex2f(60, 5)
	GL.glVertex2f(5, 60)
	GL.glColor3f(0, 1, 1)
	GL.glVertex2f(10, 55)
	GL.glVertex2f(50, 58)
	GL.glColor3f(1, 1, 1)
	GL.glVertex2f(40, 40)
	GL.glVertex2f(40, 40)
	GL.glEnd()
end)

scene("lines_gouraud", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glBegin(Enum.GL_LINES)
	GL.glColor3f(1, 0, 0)
	GL.glVertex2f(2, 10)
	GL.glColor3f(0, 0, 1)
	GL.glVertex2f(60, 10)
	GL.glColor3f(0, 1, 0)
	GL.glVertex2f(2, 30)
	GL.glColor3f(0, 1, 0)
	GL.glVertex2f(60, 34)
	GL.glColor3f(1, 1, 1)
	GL.glVertex2f(2, 50)
	GL.glColor3f(0, 0, 0)
	GL.glVertex2f(60, 52)
	GL.glEnd()
	-- a gradient strip, to get many different interpolated values
	GL.glBegin(Enum.GL_LINES)
	GL.glColor3f(0, 0, 0)
	GL.glVertex2f(0, 62)
	GL.glColor3f(1, 1, 1)
	GL.glVertex2f(63, 62)
	GL.glEnd()
end)

scene("tri_flat", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glColor3f(1, 0, 0)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(4, 4)
	GL.glVertex2f(40, 8)
	GL.glVertex2f(10, 40)
	GL.glEnd()
	-- counter clockwise / clockwise both appear; a degenerate one too
	GL.glColor3f(0, 1, 0)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(50, 4)
	GL.glVertex2f(58, 4)
	GL.glVertex2f(54, 4)
	GL.glEnd()
	GL.glColor3f(0, 0, 1)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(60, 50)
	GL.glVertex2f(45, 55)
	GL.glVertex2f(60, 60)
	GL.glEnd()
end)

scene("tri_smooth", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(1, 0, 0)
	GL.glVertex2f(2, 2)
	GL.glColor3f(0, 1, 0)
	GL.glVertex2f(61, 6)
	GL.glColor3f(0, 0, 1)
	GL.glVertex2f(20, 61)
	GL.glEnd()
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(0.2, 0.2, 0.2)
	GL.glVertex2f(63, 20)
	GL.glColor3f(1, 1, 0)
	GL.glVertex2f(30, 40)
	GL.glColor3f(0, 1, 1)
	GL.glVertex2f(63, 61)
	GL.glEnd()
end)

scene("tri_depth", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glEnable(Enum.GL_DEPTH_TEST)

	-- A far red quad first, then a nearer green one -- and the RED one stays.
	-- glClear leaves the z buffer at 0 (clear.luau carries upstream's "TODO :
	-- correct value of Z"), the depth test is `zz >= stored` (ztriangle.c's ZCMP),
	-- and this ortho matrix maps a larger gl_z to a larger stored z, so the
	-- fragment with the largest z drawn so far survives.  Not what the GL spec
	-- would give, but it is what TinyGL draws; see ref/ref_scenes.c's tri_depth.
	GL.glColor3f(1, 0, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(10, 10, 0.8)
	GL.glVertex3f(50, 10, 0.8)
	GL.glVertex3f(50, 50, 0.8)
	GL.glVertex3f(10, 50, 0.8)
	GL.glEnd()
	GL.glColor3f(0, 1, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(20, 20, 0.2)
	GL.glVertex3f(40, 20, 0.2)
	GL.glVertex3f(40, 40, 0.2)
	GL.glVertex3f(20, 40, 0.2)
	GL.glEnd()
	-- equal depth would pass the `>=` test, but the green quad never reached the
	-- frame buffer, so this one is compared against the red quad's z and is
	-- rejected too: the whole overlap stays red
	GL.glColor3f(0, 0, 1)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(25, 25, 0.2)
	GL.glVertex3f(35, 25, 0.2)
	GL.glVertex3f(35, 35, 0.2)
	GL.glVertex3f(25, 35, 0.2)
	GL.glEnd()

	GL.glDisable(Enum.GL_DEPTH_TEST)
end)

scene("clip", 64, 64, 0, function(st)
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	-- a perspective frustum so primitives can cross w = 0
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 20.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
	GL.glTranslatef(0, 0, -3)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_LINES)
	-- across the near plane
	GL.glVertex3f(-2, 0, 0.5)
	GL.glVertex3f(2, 0, -5)
	GL.glVertex3f(0, -2, 0.5)
	GL.glVertex3f(0, 2, -5)
	-- completely behind the eye
	GL.glVertex3f(-1, -1, 2)
	GL.glVertex3f(1, 1, 2)
	-- outside the sides
	GL.glVertex3f(-8, 4, -2)
	GL.glVertex3f(8, 4, -2)
	GL.glVertex3f(-8, -4, -2)
	GL.glVertex3f(8, -4, -2)
	GL.glEnd()
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(1, 0, 0)
	GL.glVertex3f(-3, -3, -2)
	GL.glVertex3f(3, -1, -2)
	GL.glVertex3f(0, 4, -2)
	GL.glColor3f(0, 1, 0)
	GL.glVertex3f(-2, 3, 1)
	GL.glVertex3f(2, 3, 1)
	GL.glVertex3f(0, -3, -4)
	GL.glEnd()
end)

scene("poly_modes", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)

	GL.glPolygonMode(Enum.GL_FRONT_AND_BACK, Enum.GL_LINE)
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_POLYGON)
	GL.glVertex2f(4, 4)
	GL.glVertex2f(28, 6)
	GL.glVertex2f(26, 28)
	GL.glVertex2f(6, 26)
	GL.glEnd()

	GL.glPolygonMode(Enum.GL_FRONT_AND_BACK, Enum.GL_POINT)
	GL.glColor3f(1, 1, 0)
	GL.glBegin(Enum.GL_POLYGON)
	GL.glVertex2f(34, 4)
	GL.glVertex2f(58, 6)
	GL.glVertex2f(56, 28)
	GL.glVertex2f(36, 26)
	GL.glEnd()

	GL.glPolygonMode(Enum.GL_FRONT_AND_BACK, Enum.GL_FILL)
	GL.glColor3f(0, 1, 0)
	GL.glBegin(Enum.GL_POLYGON)
	GL.glVertex2f(4, 34)
	GL.glVertex2f(28, 36)
	GL.glVertex2f(26, 58)
	GL.glVertex2f(6, 56)
	GL.glEnd()

	GL.glPolygonMode(Enum.GL_FRONT_AND_BACK, Enum.GL_FILL)
end)

--- one lit cube face: normal then four vertices, as in examples/spin.c
local function face(
	nx: number,
	ny: number,
	nz: number,
	a: { number },
	b: { number },
	cc: { number },
	d: { number }
)
	GL.glNormal3f(nx, ny, nz)
	GL.glVertex3f(a[1], a[2], a[3])
	GL.glVertex3f(b[1], b[2], b[3])
	GL.glVertex3f(cc[1], cc[2], cc[3])
	GL.glVertex3f(d[1], d[2], d[3])
end

local function litCube()
	GL.glBegin(Enum.GL_QUADS)
	-- front
	GL.glColor3f(1, 0, 0)
	face(0, 0, 1, { -1, -1, 1 }, { 1, -1, 1 }, { 1, 1, 1 }, { -1, 1, 1 })
	-- back
	GL.glColor3f(0, 1, 0)
	face(0, 0, -1, { 1, -1, -1 }, { -1, -1, -1 }, { -1, 1, -1 }, { 1, 1, -1 })
	-- right
	GL.glColor3f(0, 0, 1)
	face(1, 0, 0, { 1, -1, 1 }, { 1, -1, -1 }, { 1, 1, -1 }, { 1, 1, 1 })
	-- left
	GL.glColor3f(1, 1, 0)
	face(-1, 0, 0, { -1, -1, -1 }, { -1, -1, 1 }, { -1, 1, 1 }, { -1, 1, -1 })
	-- top
	GL.glColor3f(1, 0, 1)
	face(0, 1, 0, { -1, 1, 1 }, { 1, 1, 1 }, { 1, 1, -1 }, { -1, 1, -1 })
	-- bottom
	GL.glColor3f(0, 1, 1)
	face(0, -1, 0, { -1, -1, -1 }, { 1, -1, -1 }, { 1, -1, 1 }, { -1, -1, 1 })
	GL.glEnd()
end

local function cubeLitSetup(st: any)
	frustumLike()
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()

	GL.glClearColor(0, 0, 0, 1)
	clearBoth()

	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_LIGHT0)
	GL.glShadeModel(Enum.GL_SMOOTH)
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 0, 0, 1, 0 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_AMBIENT, { 0.2, 0.2, 0.2, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_DIFFUSE, { 0.8, 0.8, 0.8, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_SPECULAR, { 1, 1, 1, 1 })

	GL.glTranslatef(0, 0, -4)
	GL.glRotatef(30, 1, 0, 0)
	GL.glRotatef(45, 0, 1, 0)
	litCube()
	GL.glDisable(Enum.GL_LIGHTING)
end

scene("cube_smooth_lit", 96, 96, 0, cubeLitSetup)

scene("cube_flat_lit", 96, 96, 0, function(st)
	GL.glShadeModel(Enum.GL_FLAT)
	cubeLitSetup(st)
	GL.glShadeModel(Enum.GL_SMOOTH)
end)

--[[
	The same six cubes as the C reference's cube_geom_common(): six poses, drawn from
	the tables in examples/cube.luau.  A cube turned to a corner shows three of its
	six faces, so one pose cannot be enough: whatever the other three look like does
	not change the picture.  Between the six poses every face is turned towards the
	camera square on at least once, the top and the bottom by the last two poses,
	which look almost down and almost up the cube.

	  cube_geom      no lighting, no culling: the shape of every face
	  cube_geom_cull GL_CULL_FACE on, which is the only thing that makes the winding
	                 of a ring observable
	  cube_geom_lit  lighting on, which is the only thing that makes a face normal
	                 observable: culling is decided from the projected triangles, so
	                 with lighting off a normal that points the wrong way does nothing
]]
local CUBE_POSE_ROT = { { 30, 45 }, { 30, 225 }, { -30, 45 }, { -30, 225 }, { 75, 45 }, { -75, 225 } }
local CUBE_POSE_OFF = {
	{ -2.6, 2.0 },
	{ 0, 2.0 },
	{ 2.6, 2.0 },
	{ -2.6, -2.0 },
	{ 0, -2.0 },
	{ 2.6, -2.0 },
}

-- the same six colours as litCube(), in Cube.FACES order
local CUBE_COLORS = {
	{ 1, 0, 0 }, -- front
	{ 0, 1, 0 }, -- back
	{ 0, 0, 1 }, -- right
	{ 1, 1, 0 }, -- left
	{ 1, 0, 1 }, -- top
	{ 0, 1, 1 }, -- bottom
}

local function cubeGeom(st: any, cull: number, lit: number)
	frustumLike()
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glShadeModel(Enum.GL_FLAT)
	GL.glEnable(Enum.GL_DEPTH_TEST)
	if lit ~= 0 then
		GL.glEnable(Enum.GL_LIGHTING)
		GL.glEnable(Enum.GL_LIGHT0)
		GL.glEnable(Enum.GL_COLOR_MATERIAL)
		GL.glColorMaterial(Enum.GL_FRONT_AND_BACK, Enum.GL_AMBIENT_AND_DIFFUSE)
		GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 0.3, 0.4, 1.0, 0 })
		GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_AMBIENT, { 0.2, 0.2, 0.2, 1 })
		GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_DIFFUSE, { 0.8, 0.8, 0.8, 1 })
	end
	if cull ~= 0 then
		GL.glEnable(Enum.GL_CULL_FACE)
	end
	for i = 1, #CUBE_POSE_ROT do
		GL.glPushMatrix()
		GL.glTranslatef(CUBE_POSE_OFF[i][1], CUBE_POSE_OFF[i][2], -4)
		GL.glRotatef(CUBE_POSE_ROT[i][1], 1, 0, 0)
		GL.glRotatef(CUBE_POSE_ROT[i][2], 0, 1, 0)
		Cube.draw(1, CUBE_COLORS, function(r: number, g: number, b: number)
			GL.glColor3f(r, g, b)
		end)
		GL.glPopMatrix()
	end
	if cull ~= 0 then
		GL.glDisable(Enum.GL_CULL_FACE)
	end
	if lit ~= 0 then
		GL.glDisable(Enum.GL_COLOR_MATERIAL)
		GL.glDisable(Enum.GL_LIGHTING)
	end
end

scene("cube_geom", 128, 128, 0, function(st)
	cubeGeom(st, 0, 0)
end)

scene("cube_geom_cull", 128, 128, 0, function(st)
	cubeGeom(st, 1, 0)
end)

scene("cube_geom_lit", 128, 128, 0, function(st)
	cubeGeom(st, 0, 1)
end)

scene("cube_spec", 96, 96, 0, function(st)
	frustumLike()
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_LIGHT0)
	GL.glShadeModel(Enum.GL_SMOOTH)
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 1, 1, 2, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_AMBIENT, { 0.1, 0.1, 0.1, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_DIFFUSE, { 0.8, 0.8, 0.8, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_SPECULAR, { 1, 1, 1, 1 })
	GL.glLightf(Enum.GL_LIGHT0, Enum.GL_SPOT_CUTOFF, 90)
	GL.glLightf(Enum.GL_LIGHT0, Enum.GL_SPOT_EXPONENT, 3)
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_SPOT_DIRECTION, { 1, 0.1, 0.01, 0 })
	GL.glLightModelfv(Enum.GL_LIGHT_MODEL_LOCAL_VIEWER, { 1, 0.1, 0.01, 0 })

	GL.glMaterialf(Enum.GL_FRONT_AND_BACK, Enum.GL_SHININESS, 80)
	GL.glMaterialfv(Enum.GL_FRONT_AND_BACK, Enum.GL_SPECULAR, { 1, 1, 1, 1 })

	GL.glTranslatef(0, 0, -4)
	GL.glRotatef(30, 1, 0, 0)
	GL.glRotatef(45, 0, 1, 0)
	litCube()
	GL.glDisable(Enum.GL_LIGHTING)
end)

scene("cube_two_side", 96, 96, 0, function(st)
	frustumLike()
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_LIGHT0)
	GL.glLightModeli(Enum.GL_LIGHT_MODEL_TWO_SIDE, 1)
	GL.glLightModelfv(Enum.GL_LIGHT_MODEL_AMBIENT, { 1, 1, 1, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 0.3, 0.4, 1, 0 })
	GL.glFrontFace(Enum.GL_CW)
	GL.glEnable(Enum.GL_CULL_FACE)
	GL.glCullFace(Enum.GL_BACK)
	GL.glTranslatef(0, 0, -4)
	GL.glRotatef(20, 1, 0, 0)
	GL.glRotatef(45, 0, 1, 0)
	litCube()
	GL.glDisable(Enum.GL_CULL_FACE)
	GL.glDisable(Enum.GL_LIGHTING)
	GL.glFrontFace(Enum.GL_CCW)
	GL.glLightModeli(Enum.GL_LIGHT_MODEL_TWO_SIDE, 0)
end)

local function texturedScene(st: any)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_TEXTURE_2D)
	local t = GL.glGenTextures(1)[1]
	GL.glBindTexture(Enum.GL_TEXTURE_2D, t)
	GL.glPixelStorei(Enum.GL_UNPACK_ALIGNMENT, 1)
	-- TinyGL 0.4.1 only accepts GL_DECAL (and GL_REPEAT for the wrap
	-- parameters): the texel is written straight to the frame buffer.
	GL.glTexEnvi(Enum.GL_TEXTURE_ENV, Enum.GL_TEXTURE_ENV_MODE, Enum.GL_DECAL)
	GL.glTexParameteri(Enum.GL_TEXTURE_2D, Enum.GL_TEXTURE_WRAP_S, Enum.GL_REPEAT)
	GL.glTexParameteri(Enum.GL_TEXTURE_2D, Enum.GL_TEXTURE_WRAP_T, Enum.GL_REPEAT)
	GL.glTexImage2D(Enum.GL_TEXTURE_2D, 0, 3, TEXSIZE, TEXSIZE, 0, Enum.GL_RGB, Enum.GL_UNSIGNED_BYTE, makeTexture())

	GL.glBegin(Enum.GL_QUADS)
	GL.glTexCoord2f(0, 0)
	GL.glVertex2f(2, 2)
	GL.glTexCoord2f(1, 0)
	GL.glVertex2f(62, 2)
	GL.glTexCoord2f(1, 1)
	GL.glVertex2f(62, 62)
	GL.glTexCoord2f(0, 1)
	GL.glVertex2f(2, 62)
	GL.glEnd()
	GL.glDisable(Enum.GL_TEXTURE_2D)
end

scene("textured", 64, 64, 0, function(st)
	setViewportOrtho(st)
	-- the texture environment has to be set before texImage for the C harness
	-- order to be identical; both orders end up using the same texture object
	texturedScene(st)
end)

scene("textured_nowrap", 64, 64, 0, function(st)
	setViewportOrtho(st)
	-- no glTexEnvi at all: the default texture object is used
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_TEXTURE_2D)
	GL.glTexImage2D(Enum.GL_TEXTURE_2D, 0, 3, TEXSIZE, TEXSIZE, 0, Enum.GL_RGB, Enum.GL_UNSIGNED_BYTE, makeTexture())
	GL.glBegin(Enum.GL_QUADS)
	GL.glTexCoord2f(0, 0)
	GL.glVertex2f(2, 2)
	GL.glTexCoord2f(1, 0)
	GL.glVertex2f(62, 2)
	GL.glTexCoord2f(1, 1)
	GL.glVertex2f(62, 62)
	GL.glTexCoord2f(0, 1)
	GL.glVertex2f(2, 62)
	GL.glEnd()
	GL.glDisable(Enum.GL_TEXTURE_2D)
end)

scene("textured_wrap", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_TEXTURE_2D)
	local t = GL.glGenTextures(1)[1]
	GL.glBindTexture(Enum.GL_TEXTURE_2D, t)
	GL.glTexEnvi(Enum.GL_TEXTURE_ENV, Enum.GL_TEXTURE_ENV_MODE, Enum.GL_DECAL)
	GL.glTexImage2D(Enum.GL_TEXTURE_2D, 0, 3, TEXSIZE, TEXSIZE, 0, Enum.GL_RGB, Enum.GL_UNSIGNED_BYTE, makeTexture())
	-- coordinates outside [0,1] exercise the wrap masks
	GL.glBegin(Enum.GL_QUADS)
	GL.glColor3f(1, 1, 1)
	GL.glTexCoord2f(-1, -1)
	GL.glVertex2f(2, 2)
	GL.glTexCoord2f(2, -1)
	GL.glVertex2f(62, 2)
	GL.glTexCoord2f(2, 2)
	GL.glVertex2f(62, 62)
	GL.glTexCoord2f(-1, 2)
	GL.glVertex2f(2, 62)
	GL.glEnd()
	GL.glDisable(Enum.GL_TEXTURE_2D)
end)

scene("displaylist", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)

	local first = GL.glGenLists(2)
	local list = first
	GL.glNewList(list, Enum.GL_COMPILE)
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(0, 0)
	GL.glVertex2f(10, 0)
	GL.glVertex2f(0, 10)
	GL.glEnd()
	GL.glColor3f(1, 0, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex2f(2, 2)
	GL.glVertex2f(12, 2)
	GL.glVertex2f(12, 12)
	GL.glVertex2f(2, 12)
	GL.glEnd()
	GL.glEndList()

	GL.glCallList(list)
	GL.glPushMatrix()
	GL.glTranslatef(20, 0, 0)
	GL.glCallList(list)
	GL.glPopMatrix()
	GL.glPushMatrix()
	GL.glScalef(2, 2, 1)
	GL.glCallList(list)
	GL.glPopMatrix()
	-- the second id is unused: calling it must not draw anything
	GL.glCallList(list + 1)

	--[[
		A list that calls another list.  glopCallList() runs the inner list's ops on
		the context it is already running on and then carries on with the outer
		list's own op stream, under whatever transform the call itself is made at.
		Note that the outer list never sets a colour: its triangle is drawn in the
		colour the inner list left behind, and the push/translate/pop around the
		second inner call are ordinary opcodes in the list like any other.
	]]
	list = GL.glGenLists(1)
	GL.glNewList(list, Enum.GL_COMPILE)
	GL.glCallList(first)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(0, 50)
	GL.glVertex2f(18, 50)
	GL.glVertex2f(0, 64)
	GL.glEnd()
	GL.glPushMatrix()
	GL.glTranslatef(0, 20, 0)
	GL.glCallList(first)
	GL.glPopMatrix()
	GL.glEndList()

	GL.glPushMatrix()
	GL.glTranslatef(34, 0, 0)
	GL.glCallList(list)
	GL.glPopMatrix()
end)

scene("arrays", 64, 64, 0, function(st)
	local verts = { -- glVertexPointer(3, GL_FLOAT, 0, verts)
		4, 4, 0, 50, 8, 0, 10, 50, 0,
		54, 4, 0, 62, 4, 0, 58, 40, 0,
	}
	local cols = { -- glColorPointer(4, GL_FLOAT, 0, cols)
		1, 0, 0, 1, -- red
		0, 1, 0, 1, -- green
		0, 0, 1, 1, -- blue
		1, 1, 0, 1, -- yellow
		1, 1, 1, 1, -- white
		0, 1, 1, 1, -- cyan
	}
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	GL.glEnableClientState(Enum.GL_VERTEX_ARRAY)
	GL.glEnableClientState(Enum.GL_COLOR_ARRAY)
	GL.glVertexPointer(3, Enum.GL_FLOAT, 0, verts)
	GL.glColorPointer(4, Enum.GL_FLOAT, 0, cols)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glArrayElement(0)
	GL.glArrayElement(1)
	GL.glArrayElement(2)
	GL.glArrayElement(3)
	GL.glArrayElement(4)
	GL.glArrayElement(5)
	GL.glEnd()
	GL.glDisableClientState(Enum.GL_VERTEX_ARRAY)
	GL.glDisableClientState(Enum.GL_COLOR_ARRAY)
end)

scene("arrays_stride", 64, 64, 0, function(st)
	-- interleaved position/colour in one buffer, with strides
	local a = { -- interleaved position + colour, five floats per vertex
		4, 4, 1, 0, 0,
		50, 8, 0, 1, 0,
		10, 50, 0, 0, 1,
		54, 4, 1, 1, 0,
		62, 4, 0, 1, 1,
		58, 40, 1, 0, 1,
	}
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	GL.glEnableClientState(Enum.GL_VERTEX_ARRAY)
	GL.glEnableClientState(Enum.GL_COLOR_ARRAY)
	-- glopArrayElement() indexes with i = idx * (size + stride), so the stride is
	-- the gap between two elements in floats: a pitch of five floats is a gap of
	-- 5 - 2 = 3 for the positions and of 5 - 3 = 2 for the colours.  Passing
	-- 5 * 4 bytes, the way OpenGL does, makes TinyGL read past the end of the
	-- array, which is why the strides here look too small (see arrays.luau).
	GL.glVertexPointer(2, Enum.GL_FLOAT, 3, a)
	-- C's `a + 2` colour pointer, i.e. the same buffer two samples further in
	GL.glColorPointer(3, Enum.GL_FLOAT, 2, GL.floatView(a, 2))
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glArrayElement(0)
	GL.glArrayElement(1)
	GL.glArrayElement(2)
	GL.glColor3f(1, 1, 1)
	GL.glDisableClientState(Enum.GL_COLOR_ARRAY)
	GL.glArrayElement(3)
	GL.glArrayElement(4)
	GL.glArrayElement(5)
	GL.glEnd()
	GL.glDisableClientState(Enum.GL_VERTEX_ARRAY)
end)

scene("arrays_normals", 96, 96, 0, function(st)
	local verts = {
		-1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1,
		1, -1, -1, -1, -1, -1, -1, 1, -1, 1, 1, -1,
	}
	local norms = {
		0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1,
		0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1,
	}
	local tcs = {
		0, 0, 1, 0, 1, 1, 0, 1,
		0, 0, 1, 0, 1, 1, 0, 1,
	}
	GL.glViewport(0, 0, st.xsize, st.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_LIGHT0)
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 0, 0, 1, 0 })
	GL.glEnable(Enum.GL_TEXTURE_2D)
	local t = GL.glGenTextures(1)[1]
	GL.glBindTexture(Enum.GL_TEXTURE_2D, t)
	GL.glTexEnvi(Enum.GL_TEXTURE_ENV, Enum.GL_TEXTURE_ENV_MODE, Enum.GL_DECAL)
	GL.glTexImage2D(Enum.GL_TEXTURE_2D, 0, 3, TEXSIZE, TEXSIZE, 0, Enum.GL_RGB, Enum.GL_UNSIGNED_BYTE, makeTexture())

	GL.glEnableClientState(Enum.GL_VERTEX_ARRAY)
	GL.glEnableClientState(Enum.GL_NORMAL_ARRAY)
	GL.glEnableClientState(Enum.GL_TEXTURE_COORD_ARRAY)
	GL.glVertexPointer(3, Enum.GL_FLOAT, 0, verts)
	GL.glNormalPointer(Enum.GL_FLOAT, 0, norms)
	GL.glTexCoordPointer(2, Enum.GL_FLOAT, 0, tcs)

	GL.glTranslatef(0, 0, -4)
	GL.glRotatef(25, 1, 0, 0)
	GL.glRotatef(35, 0, 1, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glArrayElement(0)
	GL.glArrayElement(1)
	GL.glArrayElement(2)
	GL.glArrayElement(3)
	GL.glArrayElement(4)
	GL.glArrayElement(5)
	GL.glArrayElement(6)
	GL.glArrayElement(7)
	GL.glColor3f(1, 1, 1)
	GL.glArrayElement(0)
	GL.glArrayElement(1)
	GL.glArrayElement(2)
	GL.glArrayElement(3)
	GL.glColor3f(0, 1, 0)
	GL.glArrayElement(4)
	GL.glArrayElement(5)
	GL.glArrayElement(6)
	GL.glArrayElement(7)
	GL.glEnd()
	GL.glDisableClientState(Enum.GL_VERTEX_ARRAY)
	GL.glDisableClientState(Enum.GL_NORMAL_ARRAY)
	GL.glDisableClientState(Enum.GL_TEXTURE_COORD_ARRAY)
	GL.glDisable(Enum.GL_TEXTURE_2D)
	GL.glDisable(Enum.GL_LIGHTING)
end)

scene("color_range", 64, 64, 0, function(st)
	--[[
		Out of range and awkward colour components.  glColor4f() turns each
		component into the integer the rasterizer uses with an `(unsigned int)`
		cast, which does not wrap: a negative component becomes 0 and nothing else.
		glClearColor() casts to `(int)` instead, which truncates towards zero, and
		both multiplies are float multiplies, so a component like 1/3 is rounded to
		single precision before the cast.  None of that is reachable with the
		pleasant colours the other scenes use.
	]]
	setViewportOrtho(st)
	GL.glClearColor(-0.2, 1.4, 0.5, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)

	-- flat shading: the precomputed integer colour goes straight into the pixel
	GL.glShadeModel(Enum.GL_FLAT)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(-0.5, 1.5, 0.25)
	GL.glVertex2f(4, 4)
	GL.glColor3f(1 / 3, 0.123456789, 0.0)
	GL.glVertex2f(30, 6)
	GL.glColor3f(0.0, 0.0, -0.75)
	GL.glVertex2f(10, 30)
	GL.glEnd()

	-- smooth shading: the same integers, now interpolated between vertices
	GL.glShadeModel(Enum.GL_SMOOTH)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(1.25, -0.5, 0.5)
	GL.glVertex2f(36, 4)
	GL.glColor3f(0.9999999, 0.5, 0.5)
	GL.glVertex2f(60, 6)
	GL.glColor3f(0.5, 1.0000001, -0.25)
	GL.glVertex2f(46, 30)
	GL.glEnd()

	-- Lit vertices, where gl_shade_vertex() clamps the result to [0,1] and where
	-- the specular term comes from the pow() tables, which are cached on
	-- `shininess_i`, the *integer* (shininess / 128) * SPECULAR_BUFFER_RESOLUTION:
	-- 17.5 and 17.5625 are the same bucket, so the second material is handed the
	-- table that was built for the first, while 40.0 gets one of its own.
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_LIGHT0)
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { -0.3, 0.6, 1.0, 0.0 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_DIFFUSE, { 1.0, 1.0, 1.5, 1.0 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_SPECULAR, { 1.0, 1.0, 1.0, 1.0 })
	GL.glMaterialfv(Enum.GL_FRONT_AND_BACK, Enum.GL_AMBIENT_AND_DIFFUSE, { 1.5, -0.5, 0.25, 1.0 })
	GL.glMaterialfv(Enum.GL_FRONT_AND_BACK, Enum.GL_SPECULAR, { 1.0, 0.5, 1.0, 1.0 })

	GL.glMaterialf(Enum.GL_FRONT_AND_BACK, Enum.GL_SHININESS, 17.5)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glNormal3f(0, 0, 1)
	GL.glVertex2f(4, 60)
	GL.glVertex2f(20, 36)
	GL.glVertex2f(30, 62)
	GL.glEnd()

	GL.glMaterialf(Enum.GL_FRONT_AND_BACK, Enum.GL_SHININESS, 17.5625)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glNormal3f(0, 0, 1)
	GL.glVertex2f(34, 62)
	GL.glVertex2f(44, 36)
	GL.glVertex2f(60, 60)
	GL.glEnd()

	GL.glMaterialf(Enum.GL_FRONT_AND_BACK, Enum.GL_SHININESS, 40.0)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glNormal3f(0, 0, 1)
	GL.glVertex2f(56, 34)
	GL.glVertex2f(62, 40)
	GL.glVertex2f(50, 46)
	GL.glEnd()
	GL.glDisable(Enum.GL_LIGHTING)
end)

scene("polygon_offset", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_POLYGON_OFFSET_FILL)
	-- two coplanar quads, the second one offset towards the eye
	GL.glColor3f(1, 0, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(5, 5, 0.5)
	GL.glVertex3f(59, 5, 0.5)
	GL.glVertex3f(59, 59, 0.5)
	GL.glVertex3f(5, 59, 0.5)
	GL.glEnd()
	GL.glPolygonOffset(-1, -2)
	GL.glColor3f(0, 1, 0)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(15, 15, 0.5)
	GL.glVertex3f(45, 15, 0.5)
	GL.glVertex3f(45, 45, 0.5)
	GL.glVertex3f(15, 45, 0.5)
	GL.glEnd()
	GL.glPolygonOffset(1, 2)
	GL.glColor3f(0, 0, 1)
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(25, 25, 0.5)
	GL.glVertex3f(35, 25, 0.5)
	GL.glVertex3f(35, 35, 0.5)
	GL.glVertex3f(25, 35, 0.5)
	GL.glEnd()
	GL.glDisable(Enum.GL_POLYGON_OFFSET_FILL)
	GL.glDisable(Enum.GL_DEPTH_TEST)
end)

scene("select", 64, 64, 0, function(st)
	setViewportOrtho(st)
	GL.glClearColor(0, 0, 0, 1)
	clearBoth()
	GL.glDisable(Enum.GL_DEPTH_TEST)
	local _viewport = GL.glGetIntegerv(Enum.GL_VIEWPORT)

	local selbuf = GL.glSelectBuffer(256)
	local hits = GL.glRenderMode(Enum.GL_SELECT)
	assert(hits == 0)
	GL.glInitNames()
	GL.glPushName(0)
	-- TinyGL refreshes its triangle drawing functions when state is marked
	-- dirty; the viewport update below is what makes it notice that we entered
	-- GL_SELECT.
	GL.glViewport(0, 0, st.xsize, st.ysize)

	for i = 0, 2 do
		GL.glLoadName(100 + i)
		GL.glColor3f(1, 1, 1)
		GL.glBegin(Enum.GL_TRIANGLES)
		GL.glVertex2f(2 + i * 20, 2)
		GL.glVertex2f(18 + i * 20, 2)
		GL.glVertex2f(10 + i * 20, 30)
		GL.glEnd()
	end
	-- a name stack push/load/pop sequence, then a primitive that is *outside*
	-- the frustum and must not produce a hit
	GL.glPushName(7)
	GL.glLoadName(200)
	GL.glPopName()
	GL.glLoadName(300)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(40, 40)
	GL.glVertex2f(60, 40)
	GL.glVertex2f(50, 60)
	GL.glEnd()
	GL.glLoadName(400)
	GL.glBegin(Enum.GL_LINES)
	GL.glVertex2f(-30, 10)
	GL.glVertex2f(-20, 20)
	GL.glEnd()
	hits = GL.glRenderMode(Enum.GL_RENDER)
	table.insert(st.lines, ("SELECT hits %d"):format(hits))
	do
		local p = 1 -- Luau arrays start at 1
		for h = 0, hits - 1 do
			local n = selbuf[p] :: number
			local line = ("SELECT hit %d n=%d zmin=%d zmax=%d"):format(h, n, selbuf[p + 1], selbuf[p + 2])
			for i = 0, n - 1 do
				line = line .. (" name=%d"):format(selbuf[p + 3 + i])
			end
			table.insert(st.lines, line)
			p += 3 + n
		end
	end
	-- the frame buffer must be untouched by the pick pass
	GL.glRenderMode(Enum.GL_RENDER)
end)

scene("get", 64, 64, 0, function(st)
	local lines = st.lines
	setViewportOrtho(st)
	GL.glRotatef(30, 1, 0, 0)
	GL.glScalef(2, 3, 4)

	local vi = GL.glGetIntegerv(Enum.GL_VIEWPORT)
	table.insert(lines, ("GET viewport %d %d %d %d"):format(vi[1], vi[2], vi[3], vi[4]))
	table.insert(lines, ("GET max_mv_stack %d"):format(GL.glGetIntegerv(Enum.GL_MAX_MODELVIEW_STACK_DEPTH)[1]))
	table.insert(lines, ("GET max_pr_stack %d"):format(GL.glGetIntegerv(Enum.GL_MAX_PROJECTION_STACK_DEPTH)[1]))
	table.insert(lines, ("GET max_tex_stack %d"):format(GL.glGetIntegerv(Enum.GL_MAX_TEXTURE_STACK_DEPTH)[1]))
	table.insert(lines, ("GET max_lights %d"):format(GL.glGetIntegerv(Enum.GL_MAX_LIGHTS)[1]))
	table.insert(lines, ("GET max_tex_size %d"):format(GL.glGetIntegerv(Enum.GL_MAX_TEXTURE_SIZE)[1]))

	local function fmt(v: { number }): string
		local parts = table.create(#v)
		for i = 1, #v do
			parts[i] = string.format("%.9g", v[i])
		end
		return table.concat(parts, " ")
	end

	table.insert(lines, "GET modelview " .. fmt(GL.glGetFloatv(Enum.GL_MODELVIEW_MATRIX)))
	table.insert(lines, "GET projection " .. fmt(GL.glGetFloatv(Enum.GL_PROJECTION_MATRIX)))
	table.insert(lines, "GET texture " .. fmt(GL.glGetFloatv(Enum.GL_TEXTURE_MATRIX)))
	table.insert(lines, ("GET line_width %.9g"):format(GL.glGetFloatv(Enum.GL_LINE_WIDTH)[1]))
	local lwr = GL.glGetFloatv(Enum.GL_LINE_WIDTH_RANGE)
	table.insert(lines, ("GET line_width_range %.9g %.9g"):format(lwr[1], lwr[2]))
	table.insert(lines, ("GET point_size %.9g"):format(GL.glGetFloatv(Enum.GL_POINT_SIZE)[1]))
	local psr = GL.glGetFloatv(Enum.GL_POINT_SIZE_RANGE)
	table.insert(lines, ("GET point_size_range %.9g %.9g"):format(psr[1], psr[2]))
end)

scene("resize", 64, 64, 0, function(st)
	local c = GL.getContext()
	setViewportOrtho(st)
	GL.glClearColor(0.1, 0.2, 0.3, 1)
	clearBoth()
	ZB.ZB_resize(c.zb, nil, 32, 32)
	st.xsize = 32
	st.ysize = 32
	GL.glViewport(0, 0, 32, 32)
	GL.glClearColor(0.6, 0.2, 0.1, 1)
	clearBoth()
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glVertex2f(2, 2)
	GL.glVertex2f(30, 6)
	GL.glVertex2f(6, 30)
	GL.glEnd()
end)

-- the same scenes rendered into the other supported external pixel formats
scene("fb32", 64, 64, 1, function(st)
	local s2 = { xsize = st.xsize, ysize = st.ysize, lines = {} }
	local f = Scenes.list
	for i = 1, #f do
		if f[i].name == "tri_smooth" then
			f[i].fn(s2)
		end
	end
end)

scene("fb24", 64, 64, 2, function(st)
	local s2 = { xsize = st.xsize, ysize = st.ysize, lines = {} }
	local f = Scenes.list
	for i = 1, #f do
		if f[i].name == "tri_smooth" then
			f[i].fn(s2)
		end
	end
end)

scene("fb8", 64, 64, 3, function(st)
	local s2 = { xsize = st.xsize, ysize = st.ysize, lines = {} }
	local f = Scenes.list
	for i = 1, #f do
		if f[i].name == "tri_smooth" then
			f[i].fn(s2)
		end
	end
end)

scene("fb8_clear", 64, 64, 3, function(st)
	GL.glClearColor(0.2, 0.4, 0.6, 1.0)
	clearBoth()
end)

return Scenes
