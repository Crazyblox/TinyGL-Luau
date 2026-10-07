--!strict
--[[
	cube.luau — the geometry of a cube, for the examples.

	Eight corners at +-1 in x, y and z, drawn as six quads with one flat colour
	and one normal each.  Nothing here is arbitrary: the corner numbers, the order
	the faces are drawn in and the way each ring is wound are the ones the
	reference cube in ref/ref_scenes.c uses, which the port already renders
	bit exactly.

	Two properties are invisible in a picture and are what makes a hand written
	cube wrong more often than not:

	  * every face is a plane.  A ring that visits its corners in the wrong order
		draws an hourglass across the cube instead of the face, and a corner table
		that names the same position twice draws a triangle where a quad belongs.
	  * each ring is wound counter clockwise as seen from outside the cube, so the
		cross product of its first two edges points along the normal the face is
		lit with.  GL_CULL_FACE throws the face away if it does not.

	tests/test_cube.luau checks the tables below against exactly those properties,
	and the cube_geom / cube_geom_cull scenes of tests/test_against_c.luau render
	them against the C reference's own cube, at the pixel level.
]]

local GL = require("../tinygl")
local Enum = GL.Enum

export type Corner = { number } -- { x, y, z }, each component +-1

export type Face = {
	name: string,
	--- the outward normal the face is lit with
	normal: { number },
	--- the four corner indices into Cube.CORNERS, counter clockwise seen from
	--- outside the cube
	corners: { number },
}

export type Colors = { { number } } -- one { r, g, b } per face, Cube.FACES order
export type ColorSink = (r: number, g: number, b: number) -> ()

--- x grows to the right, y upwards and z towards the eye, so corner 1 is the near
--- bottom left corner and corner 5 is the far one directly behind it.  The
--- numbering goes once around the near face and then once around the far one, in
--- the same order, which is what makes the faces below fall out so regularly.
local CORNERS: { Corner } = {
	{ -1, -1, 1 }, -- 1 near bottom left
	{ 1, -1, 1 }, --  2 near bottom right
	{ 1, 1, 1 }, --  3 near top right
	{ -1, 1, 1 }, --  4 near top left
	{ -1, -1, -1 }, -- 5 far bottom left
	{ 1, -1, -1 }, -- 6 far bottom right
	{ 1, 1, -1 }, -- 7 far top right
	{ -1, 1, -1 }, -- 8 far top left
}

--[[
	Front, back, right, left, top, bottom: the order the reference cube emits its
	faces in, and the order the per face colours are given in.  Every ring below is
	the same walk around a face, started wherever it reads clearest; what matters is
	the direction, not the starting corner.
]]
local FACES: { Face } = {
	{ name = "front", normal = { 0, 0, 1 }, corners = { 1, 2, 3, 4 } },
	{ name = "back", normal = { 0, 0, -1 }, corners = { 6, 5, 8, 7 } },
	{ name = "right", normal = { 1, 0, 0 }, corners = { 2, 6, 7, 3 } },
	{ name = "left", normal = { -1, 0, 0 }, corners = { 5, 1, 4, 8 } },
	{ name = "top", normal = { 0, 1, 0 }, corners = { 4, 3, 7, 8 } },
	{ name = "bottom", normal = { 0, -1, 0 }, corners = { 5, 6, 2, 1 } },
}

--- The cube of half size `hs`, as six flat quads.  `colours` holds one { r, g, b }
--- per face in Cube.FACES order, and `setColor` is called with it before each
--- face: a caller that tints the whole object (the room darkens its reflected
--- pass, for instance) does that there, without the geometry knowing.
local function draw(hs: number, colours: Colors, setColor: ColorSink)
	GL.glShadeModel(Enum.GL_FLAT)
	GL.glBegin(Enum.GL_QUADS)
	for f = 1, #FACES do
		local face = FACES[f]
		local col = colours[f]
		local nn = face.normal
		setColor(col[1], col[2], col[3])
		GL.glNormal3f(nn[1], nn[2], nn[3])
		for k = 1, #face.corners do
			local c = CORNERS[face.corners[k]]
			-- multiplying by +-1 is exact, so a scaled cube lands on exactly the
			-- same pixels as the unit one written out long hand
			GL.glVertex3f(c[1] * hs, c[2] * hs, c[3] * hs)
		end
	end
	GL.glEnd()
end

type Cube = {
	CORNERS: { Corner },
	FACES: { Face },
	draw: (hs: number, colours: Colors, setColor: ColorSink) -> (),
}

return {
	CORNERS = CORNERS,
	FACES = FACES,
	draw = draw,
} :: Cube
