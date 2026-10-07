--!strict
--[[
	test_cube.luau — is examples/cube.luau actually a cube?

	The pixel level answer is in tests/test_against_c.luau: the cube_geom and
	cube_geom_cull scenes render those tables through the port and are hashed
	against the C reference's own long hand cube.  That answer is only as good as
	the scenes, though, and "the digests match" says nothing if a table detail
	happens not to show up in the pose being drawn.  This file asks the geometry
	questions directly, with no renderer in the way:

	  * are there eight distinct corners, and are they the eight corners of a box?
	  * is every face a plane, and does each ring walk the four corners of that
		plane in order, so that all four of its sides are edges of the cube rather
		than diagonals across a face?  (A ring that visits its corners in the wrong
		order draws an hourglass; a corner table that repeats a position draws a
		triangle where a quad belongs.  Both look like a cube in a small picture.)
	  * do the rings agree with the normals they are lit with, and with each other,
		so the solid is closed?  A closed surface has every edge shared by two faces
		running it in opposite directions, and its triangles sum to its volume.

	The last section draws the cube with the port and checks which faces end up on
	screen, because winding is only observable through GL_CULL_FACE.

	Run with:  luau tests/test_cube.luau  (exit status 0 on success)

	Both this file and the oracle scenes were checked by breaking the tables on
	purpose, because a geometry test that nothing fails is not one.  Every mutation
	below is caught, and by these:

	  a corner moved off the box        test_cube, and all three cube_geom scenes
	  two corners at the same position  test_cube, and all three cube_geom scenes
	  a corner named twice in a ring    test_cube, and all three cube_geom scenes
	  a ring walked in the wrong order  test_cube, and all three cube_geom scenes
	  a ring wound the other way        test_cube, and all three cube_geom scenes
	  a normal pointed the wrong way    test_cube, and cube_geom_lit only

	That was not true when there was one cube in the picture: it hides three of its
	six faces at any pose, so a ring that walked an hourglass across the top of the
	cube, or a face normal pointed the wrong way, produced exactly the same pixels as
	the correct table.  Six poses, and a lit scene as well as an unlit one, is what
	it took for the twelve mutations of "one ring per face, broken two ways" to all
	land somewhere.  The last line is why the lit scene exists at all: culling is
	decided from the projected triangles and not from the normal, so with lighting
	off a normal that points the wrong way does nothing that anything can see.
]]

local H = require("./harness")
local GL = require("../tinygl")
local Cube = require("../examples/cube")

local Enum = GL.Enum
local ZB = GL.ZB

local Corners = Cube.CORNERS :: { Cube.Corner }
local Faces = Cube.FACES :: { Cube.Face }

local eps = 1e-9
local function close(a: number, b: number): boolean
	return math.abs(a - b) < eps
end

local function dot(a: { number }, b: { number }): number
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function sub(a: { number }, b: { number }): { number }
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end

local function cross(a: { number }, b: { number }): { number }
	return {
		a[2] * b[3] - a[3] * b[2],
		a[3] * b[1] - a[1] * b[3],
		a[1] * b[2] - a[2] * b[1],
	}
end

local function length(a: { number }): number
	return math.sqrt(dot(a, a))
end

--- how many of the four coordinates of a corner are not +-1
local function offBox(c: { number }): number
	local n = 0
	for i = 1, 3 do
		if not (close(math.abs(c[i]), 1)) then
			n += 1
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- the corners
-- ---------------------------------------------------------------------------

H.section("corners")
H.eq(#Corners, 8, "a cube has eight corners")

local seen = {}
local offCorners = {}
for i = 1, #Corners do
	local c = Corners[i]
	local key = ("%d,%d,%d"):format(math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5))
	if seen[key] ~= nil then
		table.insert(offCorners, ("corner %d and corner %d are the same position %s"):format(i, seen[key], key))
	else
		seen[key] = i
	end
	if offBox(c) ~= 0 then
		table.insert(offCorners, ("corner %d is not on the box: (%g, %g, %g)"):format(i, c[1], c[2], c[3]))
	end
end
H.check(#offCorners == 0 and #Corners == 8, table.concat(offCorners, "; ") .. " (eight distinct corners on the box)")

-- ---------------------------------------------------------------------------
-- the faces: four corners, one plane, four edges of the cube
-- ---------------------------------------------------------------------------

H.section("faces")
H.eq(#Faces, 6, "a cube has six faces")

local faceProblems = {}
local function complain(fmt: string, ...)
	table.insert(faceProblems, fmt:format(...))
end

local nameSeen = {}
local normalSeen = {}
type EdgeOwner = { face: string, dir: number }
local edgeOwners: { [string]: { EdgeOwner } } = {}
local cornerCount: { number } = table.create(#Corners) :: { number }
for i = 1, #Corners do
	cornerCount[i] = 0
end

local surfaceArea = 0
local signedVolume = 0

for f = 1, #Faces do
	local face = Faces[f]
	local nn = face.normal
	local ring = face.corners

	if nameSeen[face.name] then
		complain("two faces are called %s", face.name)
	end
	nameSeen[face.name] = true

	-- a normal has to be a unit vector, or the lighting is quietly scaled, and it
	-- has to point along an axis, or the face is not a face of this cube
	if not close(length(nn), 1) then
		complain("%s: normal (%g, %g, %g) is not unit length", face.name, nn[1], nn[2], nn[3])
	end
	local axes = 0
	for i = 1, 3 do
		if close(nn[i], 0) then
			axes += 1
		elseif not close(math.abs(nn[i]), 1) then
			complain("%s: normal component %g is neither 0 nor +-1", face.name, nn[i])
		end
	end
	if axes ~= 2 then
		complain("%s: normal (%g, %g, %g) does not point along an axis", face.name, nn[1], nn[2], nn[3])
	end
	local nkey = ("%d,%d,%d"):format(math.floor(nn[1] + 0.5), math.floor(nn[2] + 0.5), math.floor(nn[3] + 0.5))
	if normalSeen[nkey] then
		complain("%s and %s have the same normal", face.name, normalSeen[nkey])
	end
	normalSeen[nkey] = face.name

	if #ring ~= 4 then
		complain("%s: a face is a quad, its ring has %d corners", face.name, #ring)
	else
		local p = {}
		for k = 1, 4 do
			local idx = ring[k]
			if idx < 1 or idx > #Corners or idx ~= math.floor(idx) then
				complain("%s: ring refers to corner %s, which does not exist", face.name, tostring(idx))
			elseif p[idx] ~= nil then
				-- this is what leaves a triangle where a quad belongs
				complain("%s: ring names corner %d twice (rings: %s)", face.name, idx, table.concat(ring, " "))
			else
				p[idx] = true
				cornerCount[idx] += 1
			end
		end

		local v = {}
		for k = 1, 4 do
			v[k] = Corners[ring[k]]
		end

		-- all four corners in the plane the normal describes
		local plane = dot(v[1], nn)
		for k = 2, 4 do
			if not close(dot(v[k], nn), plane) then
				complain(
					"%s: corner %d is off the face plane (%g against %g along the normal)",
					face.name,
					ring[k],
					dot(v[k], nn),
					plane
				)
			end
		end
		-- and the plane is the one that bounds the box, not a diagonal slice
		-- through it
		if not close(math.abs(plane), 1) then
			complain("%s: its four corners sit at %g along the normal, not at the box face", face.name, plane)
		end

		-- every side of the ring has to be an edge of the cube: two corners that
		-- differ in exactly one coordinate.  Two that differ in two are a diagonal
		-- across the face, which is an hourglass, and two that differ in three are a
		-- diagonal straight through the middle of the cube.
		for k = 1, 4 do
			local a, b = v[k], v[k % 4 + 1]
			local differing, delta = 0, 0
			for i = 1, 3 do
				local d = b[i] - a[i]
				if not close(d, 0) then
					differing += 1
					delta += d * d
				end
			end
			if differing == 0 then
				complain("%s: two of its corners are the same position", face.name)
			elseif differing > 1 then
				complain(
					"%s: corner %d to corner %d is a %g long diagonal, not an edge of the cube",
					face.name,
					ring[k],
					ring[k % 4 + 1],
					math.sqrt(delta)
				)
			else
				-- an edge of a unit cube is two units long
				if not close(math.sqrt(delta), 2) then
					complain("%s: one of its edges is %g long instead of 2", face.name, math.sqrt(delta))
				end
				local ekey = if ring[k] < ring[k % 4 + 1]
					then ("%d,%d"):format(ring[k], ring[k % 4 + 1])
					else ("%d,%d"):format(ring[k % 4 + 1], ring[k])
				local dir = if ring[k] < ring[k % 4 + 1] then 1 else -1
				local owners = edgeOwners[ekey]
				local owner = { face = face.name, dir = dir }
				if owners == nil then
					edgeOwners[ekey] = { owner }
				else
					table.insert(owners, owner)
				end
			end
		end

		-- the winding has to agree with the normal the face is lit with
		local w = cross(sub(v[2], v[1]), sub(v[3], v[1]))
		local area = length(w)
		surfaceArea += area
		if not close(area, 4) then
			complain("%s: its area is %g instead of 4", face.name, area)
		end
		if dot(w, nn) <= 0 then
			complain(
				"%s: wound the wrong way: its edges turn %s the normal it is lit with",
				face.name,
				if dot(w, nn) < 0 then "against" else "at right angles to"
			)
		end

		-- the same quad as two triangles, for the volume sum below
		signedVolume += dot(v[1], cross(v[2], v[3])) / 6
		signedVolume += dot(v[1], cross(v[3], v[4])) / 6
	end
end

H.check(#faceProblems == 0, table.concat(faceProblems, "; "))

local sharedBy, notOpposed = {}, {}
for key, owners in edgeOwners :: { [string]: { EdgeOwner } } do
	sharedBy[key] = #owners
	if #owners == 2 then
		-- the two faces that meet on an edge have to run it in opposite directions,
		-- otherwise the surface is not orientable and culling makes nonsense of it
		if owners[1].dir + owners[2].dir ~= 0 then
			table.insert(notOpposed, ("%s and %s"):format(owners[1].face, owners[2].face))
		end
	end
end
local unshared, edgeCount = 0, 0
for _, n in sharedBy :: { [string]: number } do
	edgeCount += 1
	if n ~= 2 then
		unshared += 1
	end
end
H.eq(edgeCount, 12, "a closed cube has twelve edges")
H.eq(unshared, 0, "every edge is shared by exactly two faces")
H.check(#notOpposed == 0, "every pair of faces runs its shared edge the other way: " .. table.concat(notOpposed, ", "))

local badCorners = {}
for i = 1, #Corners do
	if cornerCount[i] ~= 3 then
		table.insert(badCorners, ("corner %d is on %d faces"):format(i, cornerCount[i]))
	end
end
H.check(#badCorners == 0, "every corner belongs to three faces: " .. table.concat(badCorners, ", "))

-- ---------------------------------------------------------------------------
-- the solid: area, volume, and a winding that is consistent all the way round
-- ---------------------------------------------------------------------------

H.section("the solid")
H.near(surfaceArea, 24, 1e-9, "six unit faces have the surface area of the unit box")
--[[
	Volume by summing the signed volumes of the tetrahedra from the origin to each
	triangle.  The sum is +8 only if the windings are consistent over the whole
	surface: flip one face and its share goes negative, and a face that is an
	hourglass or a half quad contributes what it is worth, not what it should be.
]]
H.near(signedVolume, 8, 1e-9, "the faces enclose the volume of the unit box, wound outwards")

-- the colours Cube.draw hands back have to be the ones it was given, in face order
H.section("drawing")
local givenColors: { { number } } = {}
local gotColors: { { number } } = {}
for f = 1, #Faces do
	table.insert(givenColors, { 0.1 * f, 0.2 * f, 0.3 * f })
end
GL.glInit(ZB.ZB_open(32, 32, GL.ZB_MODE_5R6G5B))
Cube.draw(1, givenColors, function(r, g, b)
	table.insert(gotColors, { r, g, b })
end)
H.eq(#gotColors, #Faces, "one colour per face")
local colourWrong = 0
for f = 1, math.min(#gotColors, #givenColors) do
	for i = 1, 3 do
		if gotColors[f][i] ~= givenColors[f][i] then
			colourWrong += 1
		end
	end
end
H.eq(colourWrong, 0, "each face is drawn in the colour it was given, in Cube.FACES order")

-- ---------------------------------------------------------------------------
-- winding, where it is observable: GL_CULL_FACE
-- ---------------------------------------------------------------------------

--[[
	Which faces GL_CULL_FACE throws away is the only way the winding of a ring
	shows up in a picture, so: draw the cube at the pose the oracle scenes use,
	once with culling and once without, and compare which colours are on screen
	with which normals point back at the eye.  The eye looks down -z, so a face
	faces the eye when its transformed normal has a positive z.

	The transforms are rotX(30) then rotY(45), applied in that order, which is the
	order glRotatef() post multiplies them in.
]]
local function rotX(degrees: number): { { number } }
	local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
	return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } }
end

local function rotY(degrees: number): { { number } }
	local c, s = math.cos(math.rad(degrees)), math.sin(math.rad(degrees))
	return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
end

local function apply(m: { { number } }, v: { number }): { number }
	return {
		m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3],
		m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
		m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3],
	}
end

local RX, RY = rotX(30), rotY(45)
local facing = {}
for f = 1, #Faces do
	local eye = apply(RY, apply(RX, Faces[f].normal))
	facing[Faces[f].name] = eye[3] > 0
end

--- the 5R6G5B value of a colour, and how many pixels of a picture hold it
local function rgb565(c: { number }): number
	local r, g, b = math.floor(c[1] * 31 + 0.5), math.floor(c[2] * 63 + 0.5), math.floor(c[3] * 31 + 0.5)
	return r * 2048 + g * 32 + b
end

-- the same six colours the oracle scenes use, so the two files talk about the
-- same picture: face name to colour, and the 5R6G5B value that colour becomes
local FACE_RGB: { [string]: { number } } = {
	front = { 1, 0, 0 },
	back = { 0, 1, 0 },
	right = { 0, 0, 1 },
	left = { 1, 1, 0 },
	top = { 1, 0, 1 },
	bottom = { 0, 1, 1 },
}
local FACE_COLOR: { [string]: number } = {}
for name, rgb in FACE_RGB :: { [string]: { number } } do
	FACE_COLOR[name] = rgb565(rgb)
end

local function drawCube(cull: boolean): { number }
	local zb = ZB.ZB_open(96, 96, GL.ZB_MODE_5R6G5B)
	GL.glInit(zb)
	GL.glClearColor(0, 0, 0, 1)
	GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)
	GL.glViewport(0, 0, 96, 96)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	GL.glFrustum(-1.0, 1.0, -1.0, 1.0, 1.0, 100.0)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
	GL.glShadeModel(Enum.GL_FLAT)
	GL.glEnable(Enum.GL_DEPTH_TEST)
	GL.glDisable(Enum.GL_LIGHTING)
	if cull then
		GL.glEnable(Enum.GL_CULL_FACE)
	end
	GL.glTranslatef(0, 0, -4)
	GL.glRotatef(30, 1, 0, 0)
	GL.glRotatef(45, 0, 1, 0)
	local colors = {}
	for f = 1, #Faces do
		colors[f] = FACE_RGB[Faces[f].name]
	end
	Cube.draw(1, colors, function(r: number, g: number, b: number)
		GL.glColor3f(r, g, b)
	end)

	local out = table.create(96 * 96) :: { number }
	for y = 0, 95 do
		for x = 0, 95 do
			out[y * 96 + x + 1] = ZB.pixelGet(zb, y * zb.linesize + x)
		end
	end
	return out
end

--[[
	How much of the picture the cube has to cover, worked out from the geometry
	rather than remembered from a picture: project the eight corners through the
	same transforms the scene applies (the frustum maps a point to x / -z, and the
	viewport spreads [-1,1] over the frame buffer), take the convex hull of the
	result, which is the silhouette of a convex solid, and measure it.  The
	rasterizer then wins or loses a pixel along the outline, so the tolerance is
	one pixel band around the perimeter.
]]
local function projectedCorners(): { { number } }
	local pts = {}
	for i = 1, #Corners do
		local eye = apply(RY, apply(RX, Corners[i]))
		local z = eye[3] - 4 -- glTranslatef(0, 0, -4)
		local x = (eye[1] / -z + 1) / 2 * 96
		local y = (1 - eye[2] / -z) / 2 * 96 -- row 0 of the frame buffer is the top
		table.insert(pts, { x, y })
	end
	return pts
end

local function turnsLeft(a: { number }, b: { number }, c: { number }): boolean
	return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]) > 0
end

--- Andrew's monotone chain; returns the hull in order, without repeating the first
--- point at the end
local function convexHull(pts: { { number } }): { { number } }
	local sorted = {}
	for i = 1, #pts do
		table.insert(sorted, pts[i])
	end
	local function less(a: { number }, b: { number }): boolean
		if a[1] ~= b[1] then
			return a[1] < b[1]
		end
		return a[2] < b[2]
	end
	table.sort(sorted, less)
	local lower: { { number } } = {}
	for i = 1, #sorted do
		while #lower >= 2 and not turnsLeft(lower[#lower - 1], lower[#lower], sorted[i]) do
			table.remove(lower)
		end
		table.insert(lower, sorted[i])
	end
	local upper: { { number } } = {}
	for i = #sorted, 1, -1 do
		while #upper >= 2 and not turnsLeft(upper[#upper - 1], upper[#upper], sorted[i]) do
			table.remove(upper)
		end
		table.insert(upper, sorted[i])
	end
	local hull = {}
	for i = 1, #lower - 1 do
		table.insert(hull, lower[i])
	end
	for i = 1, #upper - 1 do
		table.insert(hull, upper[i])
	end
	return hull
end

--- area and perimeter of a polygon given in order
local function measure(polygon: { { number } }): (number, number)
	local area, perimeter = 0, 0
	local n = #polygon
	for i = 1, n do
		local a, b = polygon[i], polygon[i % n + 1]
		area += a[1] * b[2] - b[1] * a[2]
		perimeter += math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
	end
	return math.abs(area) / 2, perimeter
end

local function countColour(pixels: { number }, colour: number): number
	local n = 0
	for i = 1, #pixels do
		if pixels[i] == colour then
			n += 1
		end
	end
	return n
end

H.section("GL_CULL_FACE keeps the faces that face the eye")
local culled = drawCube(true)
local unculled = drawCube(false)
local wantArea, wantPerimeter = measure(convexHull(projectedCorners()))
H.check(#convexHull(projectedCorners()) == 6, "at this pose the cube is seen from a corner, so six corners outline it")
H.countNear(
	96 * 96 - countColour(unculled, 0),
	math.floor(wantArea + 0.5),
	math.ceil(wantPerimeter),
	"the cube covers exactly the silhouette its corners outline"
)

local culledWrong, unculledWrong = {}, {}
for f = 1, #Faces do
	local name = Faces[f].name
	local here = countColour(culled, FACE_COLOR[name])
	-- with culling on a back facing face is not drawn at all, so it must be
	-- missing entirely rather than merely hidden
	if facing[name] then
		if here == 0 then
			table.insert(culledWrong, name .. " faces the eye but was culled")
		end
	elseif here > 0 then
		table.insert(culledWrong, name .. " faces away but was not culled")
	end
	-- with culling off, every front facing face still wins the depth test against
	-- the face behind it, which is the other half of a closed solid drawing right
	if facing[name] and countColour(unculled, FACE_COLOR[name]) == 0 then
		table.insert(unculledWrong, name .. " faces the eye and is not on screen at all")
	end
end
H.check(#culledWrong == 0, "with GL_CULL_FACE: " .. table.concat(culledWrong, "; "))
H.check(#unculledWrong == 0, "without GL_CULL_FACE: " .. table.concat(unculledWrong, "; "))

H.summary()
