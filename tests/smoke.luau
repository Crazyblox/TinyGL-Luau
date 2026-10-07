--!strict
--[[
	smoke.luau — end to end checks that do not need the C reference.

	tests/test_against_c.luau is the real oracle, but it can only run once ref/
	has been built.  This file drives the host facing API the way an application
	would -- open a frame buffer, init, clear, draw, read back, hit the error
	paths -- and asserts the invariants that must hold whatever the exact bit
	patterns are: that a clear lands one colour everywhere, that a triangle covers
	the area its vertices span, that the z buffer behaves the way TinyGL's
	rasterizer behaves, that two runs of the same scene give the same picture, and
	that the calls C asserts on raise.

	Run with:  luau tests/smoke.luau  (exit status 0 on success)
]]

local H = require("./harness")
local GL = require("../tinygl")

local Enum = GL.Enum
local ZB = GL.ZB

local WHITE, RED, GREEN, BLUE, YELLOW = 65535, 63488, 2016, 31, 65504

--- the ortho projection the C harness uses, so vertex coordinates are pixel
--- coordinates; without it the identity projection means normalized [-1,1] space
local function setViewportOrtho(zb: any)
	local m = table.create(16) :: { number }
	for i = 1, 16 do
		m[i] = 0
	end
	-- column major: m[col * 4 + row], 1 based
	m[0 * 4 + 1] = 2 / zb.xsize
	m[1 * 4 + 2] = 2 / zb.ysize
	m[2 * 4 + 3] = -2 / 2
	m[3 * 4 + 1] = -(zb.xsize - 0) / zb.xsize
	m[3 * 4 + 2] = -(zb.ysize - 0) / zb.ysize
	m[3 * 4 + 4] = 1

	GL.glViewport(0, 0, zb.xsize, zb.ysize)
	GL.glMatrixMode(Enum.GL_PROJECTION)
	GL.glLoadIdentity()
	GL.glLoadMatrixf(m)
	GL.glMatrixMode(Enum.GL_MODELVIEW)
	GL.glLoadIdentity()
end

--- a fresh 64x64 16 bit frame buffer, cleared to black, with a clean context and
--- an ortho projection on it
local function open(): any
	local zb = ZB.ZB_open(64, 64, GL.ZB_MODE_5R6G5B)
	GL.glInit(zb)
	GL.glClearColor(0, 0, 0, 1)
	GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)
	setViewportOrtho(zb)
	return zb
end

--- the internal pixels, as one flat list of 5R6G5B values, row 0 first
local function pixels(zb: any): { number }
	local out = table.create(zb.xsize * zb.ysize) :: { number }
	for y = 0, zb.ysize - 1 do
		for x = 0, zb.xsize - 1 do
			out[y * zb.xsize + x + 1] = ZB.pixelGet(zb, y * zb.linesize + x)
		end
	end
	return out
end

--- how many of `a[from] .. a[to]` disagree with `b`
local function countDiff(a: { number }, b: { number }, from: number, to: number): number
	local n = 0
	for i = from, to do
		if a[i] ~= b[i] then
			n += 1
		end
	end
	return n
end

--- how many of `a[from] .. a[to]` are not `value`
local function countNot(a: { number }, value: number, from: number, to: number): number
	local n = 0
	for i = from, to do
		if a[i] ~= value then
			n += 1
		end
	end
	return n
end

--- how many pixels of the rectangle [x0,x1) x [y0,y1) differ between two pictures
local function countDiffRect(
	a: { number },
	b: { number },
	xsize: number,
	x0: number,
	x1: number,
	y0: number,
	y1: number
): number
	local n = 0
	for y = y0, y1 - 1 do
		for x = x0, x1 - 1 do
			if a[y * xsize + x + 1] ~= b[y * xsize + x + 1] then
				n += 1
			end
		end
	end
	return n
end

local function color(a: { number }, xsize: number, x: number, y: number): number
	return a[y * xsize + x + 1]
end

--- one axis aligned quad, given as its corners and a colour
local function quad(colorValue: number, x0: number, y0: number, x1: number, y1: number, z: number)
	if colorValue == WHITE then
		GL.glColor3f(1, 1, 1)
	elseif colorValue == RED then
		GL.glColor3f(1, 0, 0)
	elseif colorValue == GREEN then
		GL.glColor3f(0, 1, 0)
	elseif colorValue == BLUE then
		GL.glColor3f(0, 0, 1)
	else
		GL.glColor3f(1, 1, 0)
	end
	GL.glBegin(Enum.GL_QUADS)
	GL.glVertex3f(x0, y0, z)
	GL.glVertex3f(x1, y0, z)
	GL.glVertex3f(x1, y1, z)
	GL.glVertex3f(x0, y1, z)
	GL.glEnd()
end

--[[
	The four quads the depth checks draw, in the same order in every context:

	 * BLUE over almost the whole buffer at z = 0.9
	 * YELLOW inside it at z = 0.1, the smaller z
	 * RED over the same inner area at z = 0.99, the larger z
	 * GREEN at z = 0.99 as well, so at an equal depth and a smaller area
]]
local function quadSequence()
	quad(BLUE, 4, 4, 60, 60, 0.9)
	quad(YELLOW, 16, 16, 48, 48, 0.1)
	quad(RED, 16, 16, 48, 48, 0.99)
	quad(GREEN, 20, 20, 44, 44, 0.99)
end

H.section("context and viewport")
local zb = open()
local vi = GL.glGetIntegerv(Enum.GL_VIEWPORT)
H.eq(#vi, 4, "GL_VIEWPORT is four integers")
H.check(
	vi[1] == 0 and vi[2] == 0 and vi[3] == 64 and vi[4] == 64,
	("GL_VIEWPORT defaults to the frame buffer, got %d %d %d %d"):format(vi[1], vi[2], vi[3], vi[4])
)
H.check(countNot(pixels(zb), 0, 1, 64 * 64) == 0, "a fresh context shows a cleared frame buffer")

H.section("clear")
GL.glClearColor(0.2, 0.4, 0.6, 1)
GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)
local cleared = pixels(zb)
H.check(cleared[1] ~= 0, "the clear colour is not black")
H.countEquals(countNot(cleared, cleared[1], 1, #cleared), 0, "glClear paints one colour everywhere")

H.section("drawing")
GL.glBegin(Enum.GL_TRIANGLES)
GL.glColor3f(1, 0, 0)
GL.glVertex2f(4, 4)
GL.glVertex2f(40, 8)
GL.glVertex2f(10, 40)
GL.glEnd()
local drawn = pixels(zb)
-- the vertices span a triangle of 636 px; the rasterizer's fill conventions move
-- that by a few, so this is a range -- the exact count is test_against_c's job
H.countNear(countDiffRect(cleared, drawn, 64, 0, 64, 0, 64), 636, 40, "the triangle replaces the clear colour")
H.countEquals(countDiffRect(cleared, drawn, 64, 41, 64, 41, 64), 0, "nothing is drawn outside the triangle")

H.section("the z buffer behind filled triangles")
--[[
	GL_DEPTH_TEST does not do to filled triangles what the specification says: the
	fill functions of src/ztriangle.c unconditionally do `#define INTERP_Z` and
	then `if (ZCMP(zz, pz[a])) { ...; pz[a] = zz; }`, so every painted pixel is
	depth tested against the z buffer and updates it, whether GL_DEPTH_TEST is on
	or not; the flag only picks ZB_line over ZB_line_z and ZB_point over its z
	variant in src/clip.c.  With the ortho matrix above a larger gl_z becomes a
	larger stored z, so the pixel that survives is the one with the largest z
	drawn so far, and the second quad of quadSequence() loses even though nothing
	tells it to.  The port must reproduce this; the tri_depth and polygon_offset
	scenes of test_against_c.luau pin the exact pixels.
]]
local withTest = open()
GL.glEnable(Enum.GL_DEPTH_TEST)
quadSequence()
local tested = pixels(withTest)
H.check(color(tested, 64, 30, 30) == GREEN, "the last quad at the largest z owns the middle pixel")
H.check(color(tested, 64, 22, 22) == GREEN, "an equal depth passes ZCMP and is drawn")
H.check(color(tested, 64, 18, 18) == RED, "the smaller z never reaches the frame buffer")
H.check(color(tested, 64, 8, 8) == BLUE, "the first quad owns the pixels nothing else covers")

local withoutTest = open()
quadSequence()
H.countEquals(countDiff(pixels(withoutTest), tested, 1, 64 * 64), 0, "fills depth test with GL_DEPTH_TEST off too")

H.section("GL_DEPTH_TEST and lines")
--[[
	The flag does decide ZB_line versus ZB_line_z: a line drawn with the test on
	leaves a depth behind, which then keeps a later fill at a smaller z off its
	pixels, while a line drawn without it is simply painted over.  The line is at
	vertex y = 32, which the viewport mapping puts on some row near the middle, so
	the counts cover the whole picture rather than one row.
]]
local function lineThenQuad(depthTest: number): (number, number)
	local z = open()
	if depthTest ~= 0 then
		GL.glEnable(Enum.GL_DEPTH_TEST)
	else
		GL.glDisable(Enum.GL_DEPTH_TEST)
	end
	GL.glColor3f(1, 1, 1)
	GL.glBegin(Enum.GL_LINES)
	GL.glVertex3f(6, 32, 0.5)
	GL.glVertex3f(58, 32, 0.5)
	GL.glEnd()
	local before = pixels(z)
	local whiteBefore = countNot(before, 0, 1, #before)
	quad(RED, 4, 4, 60, 60, 0.2) -- a smaller z than the line's, over all of it
	local after = pixels(z)
	local whiteAfter = 0
	for i = 1, #after do
		if after[i] == WHITE and before[i] == WHITE then
			whiteAfter += 1
		end
	end
	H.countNear(whiteBefore, 53, 4, ("the line covers its own pixels (depth test %d)"):format(depthTest))
	return whiteBefore, whiteAfter
end

local _, survivedTested = lineThenQuad(1)
local _, survivedUntested = lineThenQuad(0)
H.countNear(survivedTested, 53, 4, "with the test on the line keeps its pixels against a later fill")
H.countEquals(survivedUntested, 0, "with the test off the line wrote no depth and is painted over")

H.section("frame buffer read back")
--[[
	ZB_copyFrameBuffer converts to the format the buffer was opened as, so a
	ZB_MODE_5R6G5B buffer comes back as two bytes per pixel (the 8, 24 and 32 bit
	destinations are covered by the fb8 / fb24 / fb32 scenes).  Comparing the copy
	with the internal pixels checks the copy itself.
]]
local ext = buffer.create(zb.ysize * zb.xsize * 2)
for i = 0, buffer.len(ext) - 1 do
	buffer.writeu8(ext, i, 0xAA)
end
ZB.ZB_copyFrameBuffer(zb, ext, zb.xsize * 2)
local left = 0
for i = 0, buffer.len(ext) - 1 do
	if buffer.readu8(ext, i) == 0xAA then
		left += 1
	end
end
H.countEquals(left, 0, "ZB_copyFrameBuffer writes every byte of the destination")
local mismatch = 0
for y = 0, zb.ysize - 1 do
	for x = 0, zb.xsize - 1 do
		if buffer.readu16(ext, (y * zb.xsize + x) * 2) ~= ZB.pixelGet(zb, y * zb.linesize + x) then
			mismatch += 1
		end
	end
end
H.countEquals(mismatch, 0, "the copy holds the internal pixels")

H.section("determinism")
-- the same scene in a second context must give exactly the same picture; this is
-- what catches state that leaks between contexts or a cache that is not reset
local function render(): { number }
	local z = open()
	GL.glClearColor(0.1, 0.2, 0.3, 1)
	GL.glClear(Enum.GL_COLOR_BUFFER_BIT + Enum.GL_DEPTH_BUFFER_BIT)
	GL.glShadeModel(Enum.GL_SMOOTH)
	GL.glBegin(Enum.GL_TRIANGLES)
	GL.glColor3f(1, 0, 0)
	GL.glVertex2f(2, 2)
	GL.glColor3f(0, 1, 0)
	GL.glVertex2f(62, 6)
	GL.glColor3f(0, 0, 1)
	GL.glVertex2f(30, 60)
	GL.glEnd()
	local p = pixels(z)
	ZB.ZB_close(z)
	return p
end

local first = render()
local second = render()
H.countEquals(countDiff(first, second, 1, #first), 0, "rendering twice into two contexts gives the same picture")
-- smooth shading must have produced a gradient, not one flat colour
local colours: { [number]: boolean } = {}
for i = 1, #first do
	colours[first[i]] = true
end
local distinct = 0
for _ in pairs(colours) do
	distinct += 1
end
H.check(distinct > 100, ("smooth shading gives a gradient, saw %d distinct colours"):format(distinct))

H.section("error paths")
-- TinyGL's assertions are about the current state, so each check runs from a
-- known state: a context that is not inside begin/end, and bad enum values
local e = open()
H.checkRaises(function()
	GL.glVertex2f(1, 1)
end, "glVertex outside glBegin raises")
GL.glBegin(Enum.GL_TRIANGLES)
H.checkRaises(function()
	GL.glBegin(Enum.GL_TRIANGLES)
end, "glBegin inside glBegin raises")
GL.glEnd()
H.checkRaises(function()
	GL.glEnd()
end, "glEnd without glBegin raises")
H.checkRaises(function()
	GL.glShadeModel(7)
end, "glShadeModel with a bad mode raises")
H.checkRaises(function()
	GL.glMatrixMode(999)
end, "glMatrixMode with a bad mode raises")
ZB.ZB_close(e)

H.summary()
