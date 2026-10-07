--!strict
--[[
	scene_room.luau — a lit, reflective room for the Luau port of TinyGL, with
	several camera angles.  This is the scene only; examples/gallery.luau renders
	it and writes the pictures, examples/bench.luau times it.

	Everything on screen is produced by the ported renderer: depth buffering,
	smooth and flat shading, one warm positional key light with attenuation, one
	cold fill light, colour material and specular materials (the specular buffer
	gives the spheres their highlights).

	The floor is a checkerboard of matte tiles and *polished* tiles.  TinyGL has
	no blending, so the mirror floor is built the way the geometry allows: the
	whole scene is first drawn a second time reflected in the floor plane — a
	glScalef(1,-1,1) plus reflected light positions — darkened by drawing it with
	tinted colours.  The matte tiles are painted over that afterwards; the
	polished squares are simply not drawn, so what they show is the reflected
	image.  That is depth correct: the reflection of an object is always farther
	from the eye than the floor pixel it falls on, so the matte tiles always win
	the (>=) depth test against it.
]]

local GL = require("../tinygl")
local Enum = GL.Enum
local Cube = require("./cube")

local floor = math.floor
local pi = math.pi
local sin, cos, sqrt, tan = math.sin, math.cos, math.sqrt, math.tan

local W, H = 640, 480

-- ---------------------------------------------------------------------------
-- scene constants
-- ---------------------------------------------------------------------------

local FLOOR_HALF = 7.0 -- the floor spans [-7,7] in x and z
local TILE = 1.0
local GROUT = 0.09 -- the dark gap left between two tiles

--- how much of a colour survives the bounce off the floor
local REFL = 0.30

--- the current tint, applied by C3() so the reflected pass can darken itself
local tint = 1.0

local function C3(r: number, g: number, b: number)
	GL.glColor3f(r * tint, g * tint, b * tint)
end

--- A column major look-at matrix, ready for glLoadMatrixf (which, as in OpenGL,
--- takes the matrix in column major order).
local function lookAt(
	eyeX: number,
	eyeY: number,
	eyeZ: number,
	cx: number,
	cy: number,
	cz: number,
	upX: number,
	upY: number,
	upZ: number
): { number }
	local fX, fY, fZ = cx - eyeX, cy - eyeY, cz - eyeZ
	local n = sqrt(fX * fX + fY * fY + fZ * fZ)
	fX, fY, fZ = fX / n, fY / n, fZ / n

	local sX, sY, sZ = fY * upZ - fZ * upY, fZ * upX - fX * upZ, fX * upY - fY * upX
	n = sqrt(sX * sX + sY * sY + sZ * sZ)
	sX, sY, sZ = sX / n, sY / n, sZ / n

	local uX, uY, uZ = sY * fZ - sZ * fY, sZ * fX - sX * fZ, sX * fY - sY * fX

	local m = table.create(16) :: { number }
	for i = 1, 16 do
		m[i] = 0
	end
	-- glLoadMatrixf() takes OpenGL's column major order, so element (row, column)
	-- of the view matrix lives at m[column * 4 + row + 1]: the three basis rows
	-- are the first three entries of m[1], m[2] and m[3], and the -dot() terms are
	-- the fourth *column*, m[13..15].
	m[1], m[5], m[9] = sX, sY, sZ
	m[2], m[6], m[10] = uX, uY, uZ
	m[3], m[7], m[11] = -fX, -fY, -fZ
	m[13] = -(sX * eyeX + sY * eyeY + sZ * eyeZ)
	m[14] = -(uX * eyeX + uY * eyeY + uZ * eyeZ)
	m[15] = fX * eyeX + fY * eyeY + fZ * eyeZ
	m[16] = 1
	return m
end

--- A perspective frustum for `fovyDegrees` vertical field of view.  Note the
--- tan(): glFrustum() takes the near plane bounds, not the matrix term (1/tan)
--- that a hand written projection matrix would use.
local function perspective(fovyDegrees: number, aspect: number, nearVal: number, farVal: number)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	local halfTan = tan(fovyDegrees * pi / 180.0 / 2.0)
	local top = nearVal * halfTan
	local right = top * aspect
	GL.glFrustum(-right, right, -top, top, nearVal, farVal)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
end

-- ---------------------------------------------------------------------------
-- objects
-- ---------------------------------------------------------------------------

--[[
	The cube itself lives in examples/cube.luau, which holds the corner table, the
	six face rings and their normals.  What is picked here is only how bright each
	face is painted: the key light of this scene comes from the front, above and to
	the right, so the front, top and right faces are the bright ones.  They are
	looked up by face name rather than by position in a list, so that reordering the
	faces of the cube cannot silently repaint the wrong ones.
]]
local FACE_SHADE: { [string]: number } = {
	front = 0.98,
	back = 0.72,
	right = 0.90,
	left = 0.66,
	top = 1.00,
	bottom = 0.58,
}

--- An axis aligned cube of half size `hs`, one colour per face.  Flat shading
--- gives the faces their own intensity, which is what makes it read as a cube.
local function cube(hs: number, faces: Cube.Colors)
	Cube.draw(hs, faces, C3)
end

--- A cube whose faces fade slightly from the lit side to the shaded side, so it
--- keeps a readable silhouette even when the light is weak.
local function shadedCube(hs: number, r: number, g: number, b: number)
	local faces = table.create(#Cube.FACES) :: Cube.Colors
	for f = 1, #Cube.FACES do
		local s = FACE_SHADE[Cube.FACES[f].name]
		faces[f] = { r * s, g * s, b * s }
	end
	cube(hs, faces)
end

--- A smooth shaded sphere: the normals are per vertex, so TinyGL's specular
--- buffer produces an actual highlight on it.
local function sphere(radius: number, stacks: number, slices: number, r: number, g: number, b: number)
	GL.glShadeModel(Enum.GL_SMOOTH)
	GL.glBegin(Enum.GL_QUADS)
	for i = 0, stacks - 1 do
		local t0 = -pi / 2 + pi * i / stacks
		local t1 = -pi / 2 + pi * (i + 1) / stacks
		for j = 0, slices - 1 do
			local p0 = 2 * pi * j / slices
			local p1 = 2 * pi * (j + 1) / slices
			for k = 0, 3 do
				-- quad corner order: (t0,p0) (t1,p0) (t1,p1) (t0,p1)
				local th = if k == 1 or k == 2 then t1 else t0
				local ph = if k >= 2 then p1 else p0
				local ny = sin(th)
				local nx = cos(th) * cos(ph)
				local nz = cos(th) * sin(ph)
				-- the underside of a sphere hardly sees the key light, so fade the
				-- diffuse colour there instead of letting it go pitch black
				local lift = 0.45 + 0.55 * (0.5 + 0.5 * ny)
				C3(r * lift, g * lift, b * lift)
				GL.glNormal3f(nx, ny, nz)
				GL.glVertex3f(nx * radius, ny * radius, nz * radius)
			end
		end
	end
	GL.glEnd()
end

--- A square pyramid: four slanted, flat shaded triangles and a base.
local function pyramid(halfBase: number, height: number, r: number, g: number, b: number)
	local h = halfBase
	GL.glShadeModel(Enum.GL_FLAT)
	GL.glBegin(Enum.GL_TRIANGLES)
	local sides = {
		{ { -h, 0, h }, { h, 0, h }, { 0, height, 0 } },
		{ { h, 0, h }, { h, 0, -h }, { 0, height, 0 } },
		{ { h, 0, -h }, { -h, 0, -h }, { 0, height, 0 } },
		{ { -h, 0, -h }, { -h, 0, h }, { 0, height, 0 } },
	}
	for s = 1, 4 do
		local v = sides[s]
		local ax, ay, az = v[2][1] - v[1][1], v[2][2] - v[1][2], v[2][3] - v[1][3]
		local bx, by, bz = v[3][1] - v[1][1], v[3][2] - v[1][2], v[3][3] - v[1][3]
		local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
		local n = sqrt(nx * nx + ny * ny + nz * nz)
		if n > 0 then
			nx, ny, nz = nx / n, ny / n, nz / n
		end
		-- each slanted face gets a slightly different brightness
		local shade = 0.78 + 0.22 * cos(s * 1.3)
		C3(r * shade, g * shade, b * shade)
		GL.glNormal3f(nx, ny, nz)
		for k = 1, 3 do
			GL.glVertex3f(v[k][1], v[k][2], v[k][3])
		end
	end
	GL.glEnd()
end

local function place(x: number, y: number, z: number, rotDegrees: number, f: () -> ())
	GL.glPushMatrix()
	GL.glTranslatef(x, y, z)
	if rotDegrees ~= 0 then
		GL.glRotatef(rotDegrees, 0, 1, 0)
	end
	f()
	GL.glPopMatrix()
end

local function material(specR: number, specG: number, specB: number, shininess: number)
	GL.glMaterialfv(Enum.GL_FRONT_AND_BACK, Enum.GL_SPECULAR, { specR, specG, specB, 1 })
	GL.glMaterialf(Enum.GL_FRONT_AND_BACK, Enum.GL_SHININESS, shininess)
end

--- All the objects of the scene, standing on y = 0.
local function drawObjects()
	-- the big red cube: the anchor of the composition
	place(-1.70, 0.92, 0.55, 18, function()
		material(0.45, 0.42, 0.40, 48)
		shadedCube(0.92, 0.86, 0.26, 0.20)
	end)

	-- teal cube, further back
	place(2.05, 0.58, -1.75, -28, function()
		material(0.40, 0.45, 0.45, 40)
		shadedCube(0.58, 0.18, 0.62, 0.58)
	end)

	-- two stacked brass cubes
	place(0.55, 0.32, -3.35, 12, function()
		material(0.90, 0.80, 0.50, 70)
		shadedCube(0.32, 0.80, 0.60, 0.24)
	end)
	place(0.55, 0.94, -3.35, 36, function()
		material(0.90, 0.80, 0.50, 70)
		shadedCube(0.26, 0.86, 0.66, 0.28)
	end)

	-- chrome sphere
	place(-3.05, 1.02, -1.55, 0, function()
		material(0.95, 0.96, 1.00, 110)
		sphere(1.02, 12, 16, 0.42, 0.48, 0.60)
	end)

	-- ivory sphere, close to the camera
	place(1.45, 0.62, 1.85, 0, function()
		material(0.35, 0.33, 0.30, 26)
		sphere(0.62, 11, 14, 0.86, 0.80, 0.68)
	end)

	-- small brass sphere
	place(3.05, 0.36, 0.75, 0, function()
		material(0.80, 0.70, 0.40, 60)
		sphere(0.36, 9, 12, 0.78, 0.58, 0.22)
	end)

	-- green pyramid
	place(-1.15, 0.02, 3.35, 45, function()
		material(0.25, 0.30, 0.25, 20)
		pyramid(0.85, 1.35, 0.28, 0.62, 0.34)
	end)

	-- a tall slab at the back of the room, to catch the key light
	place(-4.20, 1.45, -4.20, 22, function()
		material(0.30, 0.30, 0.35, 30)
		shadedCube(1.45, 0.52, 0.55, 0.66)
	end)
end

--- The matte half of the checkerboard.  The polished squares are deliberately
--- not drawn, which is what reveals the reflected scene below them.
local function drawFloorMatte()
	GL.glShadeModel(Enum.GL_FLAT)
	material(0.14, 0.14, 0.14, 12)

	local n = floor(2 * FLOOR_HALF / TILE)
	GL.glBegin(Enum.GL_QUADS)
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			if (i + j) % 2 == 0 then -- the odd squares stay mirrors
				local x0 = -FLOOR_HALF + i * TILE + GROUT * 0.5
				local x1 = -FLOOR_HALF + (i + 1) * TILE - GROUT * 0.5
				local z0 = -FLOOR_HALF + j * TILE + GROUT * 0.5
				local z1 = -FLOOR_HALF + (j + 1) * TILE - GROUT * 0.5
				-- a slow variation over the room, so the tiles are not all equal
				local v = 0.60 + 0.10 * cos(i * 0.8) + 0.06 * sin(j * 0.6)
				local warm = if (i // 3 + j // 3) % 2 == 0 then 1.0 else 0.93
				C3(v * warm, v * 0.97 * warm, v * 0.90)
				GL.glNormal3f(0, 1, 0)
				GL.glVertex3f(x0, 0, z1)
				GL.glVertex3f(x1, 0, z1)
				GL.glVertex3f(x1, 0, z0)
				GL.glVertex3f(x0, 0, z0)
			end
		end
	end
	GL.glEnd()
end

--- The lights.  `mirror` reflects their positions in the floor plane together
--- with the geometry, so the reflected image is lit the way the real thing is.
local function setupLights(mirror: boolean)
	local s = if mirror then -1 else 1

	-- a dim, cool ambient so that the shaded sides are not black
	GL.glLightModelfv(Enum.GL_LIGHT_MODEL_AMBIENT, { 0.19, 0.20, 0.24, 1 })

	-- key light: warm and positional, with a gentle falloff
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_POSITION, { 4.0, 6.0 * s, 5.0, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_AMBIENT, { 0.12, 0.12, 0.13, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_DIFFUSE, { 0.95, 0.88, 0.76, 1 })
	GL.glLightfv(Enum.GL_LIGHT0, Enum.GL_SPECULAR, { 0.85, 0.80, 0.70, 1 })
	GL.glLightf(Enum.GL_LIGHT0, Enum.GL_CONSTANT_ATTENUATION, 1.0)
	GL.glLightf(Enum.GL_LIGHT0, Enum.GL_LINEAR_ATTENUATION, 0.030)
	GL.glLightf(Enum.GL_LIGHT0, Enum.GL_QUADRATIC_ATTENUATION, 0.004)

	-- fill light: cold, weak, from the other side
	GL.glLightfv(Enum.GL_LIGHT1, Enum.GL_POSITION, { -5.0, 3.0 * s, -4.0, 1 })
	GL.glLightfv(Enum.GL_LIGHT1, Enum.GL_AMBIENT, { 0.02, 0.03, 0.05, 1 })
	GL.glLightfv(Enum.GL_LIGHT1, Enum.GL_DIFFUSE, { 0.24, 0.30, 0.42, 1 })
	GL.glLightfv(Enum.GL_LIGHT1, Enum.GL_SPECULAR, { 0.0, 0.0, 0.0, 1 })
	GL.glLightf(Enum.GL_LIGHT1, Enum.GL_CONSTANT_ATTENUATION, 1.0)
	GL.glLightf(Enum.GL_LIGHT1, Enum.GL_LINEAR_ATTENUATION, 0.02)

	GL.glEnable(Enum.GL_LIGHT0)
	GL.glEnable(Enum.GL_LIGHT1)
end

--- One frame: the reflected scene, then the floor, then the objects.
local function renderView(cam: Camera)
	GL.glViewport(0, 0, W, H)
	GL.glClearColor(0.030, 0.040, 0.070, 1.0)
	GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)

	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glEnable(Enum.GL_LIGHTING)
	GL.glEnable(Enum.GL_COLOR_MATERIAL)
	GL.glColorMaterial(Enum.GL_FRONT_AND_BACK, Enum.GL_AMBIENT_AND_DIFFUSE)
	GL.glShadeModel(Enum.GL_SMOOTH)

	perspective(46.0, W / H, 0.35, 80.0)
	local camMatrix = lookAt(cam.eye[1], cam.eye[2], cam.eye[3], cam.at[1], cam.at[2], cam.at[3], 0, 1, 0)

	--[[
		1. the reflection: the same objects, mirrored in the floor plane.  The
		normals are transformed by the inverse transpose of the model view, so the
		negative scale mirrors them along with the positions.

		Note the order: glLightfv() transforms GL_POSITION by the *current* model
		view, so the camera has to be loaded before the lights are described.
		Loading it together with glScalef(1,-1,1) also reflects the light positions
		themselves, which is what makes the reflected image lit like the real one.
	]]
	tint = REFL
	GL.glLoadMatrixf(camMatrix)
	GL.glScalef(1, -1, 1)
	setupLights(true)
	drawObjects()

	-- 2. the real scene: matte tiles over the reflection, then the objects
	tint = 1.0
	GL.glLoadMatrixf(camMatrix)
	setupLights(false)
	drawFloorMatte()
	drawObjects()

	GL.glShadeModel(Enum.GL_SMOOTH)
end

-- ---------------------------------------------------------------------------
-- the camera angles of this one scene
-- ---------------------------------------------------------------------------

--- one camera setup: where the eye is and what it looks at, in room coordinates.
--- The room is 14 units across (the floor spans [-7,7]) and the objects stand on
--- y = 0.
export type Camera = {
	name: string,
	eye: { number },
	at: { number },
}

local Views: { Camera } = {
	-- the establishing shot: the whole room, floor to the horizon
	{ name = "01_wide", eye = { 7.2, 4.2, 8.6 }, at = { -0.1, 0.7, -0.3 } },
	-- just above the floor, where the mirror tiles read best
	{ name = "02_low", eye = { 4.0, 0.95, 5.6 }, at = { -0.6, 1.15, -0.7 } },
	-- close on the chrome sphere and its reflection, from the free side of the
	-- room so the red cube does not sit in the line of sight
	{ name = "03_chrome", eye = { -6.6, 1.70, 2.6 }, at = { -2.40, 0.90, -0.9 } },
	-- looking down on the checkerboard
	{ name = "04_high", eye = { 1.8, 7.6, 5.2 }, at = { -0.3, 0.0, -0.5 } },
	-- from the far corner, back towards the key light
	{ name = "05_behind", eye = { 7.8, 3.4, -7.4 }, at = { -0.4, 0.8, 0.6 } },
	-- the cubes and the ivory sphere, filling the frame
	{ name = "06_closeup", eye = { 4.4, 2.10, 4.6 }, at = { 0.0, 0.90, -0.6 } },
}

-- ---------------------------------------------------------------------------
-- what the drivers need
-- ---------------------------------------------------------------------------

return {
	W = W,
	H = H,
	Views = Views,
	renderView = renderView,
}
