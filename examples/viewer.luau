--!strict
--[[
	viewer.luau — an interface for driving the room scene of
	examples/scene_room.luau (the scene whose establishing view is "01_wide") from
	a host application: point a camera, draw a frame, take the pixels.

	It is a module rather than a script: requiring it renders nothing and allocates
	nothing but the conversion tables.  The Z buffer, the GL context and the scratch
	row buffer are opened on the first render()/present() and reused afterwards, the
	way an application keeps them between frames.

	    local Viewer = require("./viewer")

	    -- a camera position and a look direction, in room coordinates: the room is
	    -- 14 units across (the floor spans [-7,7]) and the objects stand on y = 0
	    Viewer.render({ 7.2, 4.2, 8.6 }, { -7.3, -3.5, -8.9 })

	    -- the frame, in the host's own buffer, as RGBA8888
	    local pixels = Viewer.present()

	A vector argument is either a { x, y, z } array -- the convention the whole port
	uses -- or anything with .x/.y/.z (or .X/.Y/.Z) number fields.  The direction
	does not have to be normalised.

	The bytes of a presented row are R, G, B, A in that order at increasing
	addresses, A always 255, and row 0 is the *top* of the picture: the port's
	viewport mapping has a negative Y scale, so frame buffer row 0 already is the top
	of the window and the rows go out in order.  A host that wants the usual
	bottom-up GL texture order can present into a pitch and read the rows back
	upside down, or just index row (H - 1 - y).

	Requiring this module draws nothing and allocates nothing but the conversion
	tables.  Viewer.demo() is the whole interface in one call: it renders the 01_wide
	camera and prints what came out.

	A plain `return Viewer` at the end of a file makes it inert when required, and the
	standalone `luau` host has no way for a module to tell it is the script being run,
	so driving it from a command line is one line of someone else's script:

	    luau examples/viewer_demo.luau [frames]      -- see examples/viewer_demo.luau
]]

local GL = require("../tinygl")
local Scene = require("./scene_room")

local buffer = buffer --[[(the standard library)]]
local band, rshift = bit32.band, bit32.rshift

local W, H = Scene.W :: number, Scene.H :: number
local Views = Scene.Views :: { Scene.Camera }
local renderScene = Scene.renderView :: (cam: Scene.Camera) -> ()

local Viewer = {}

Viewer.W = W
Viewer.H = H
--- what one row of a presented image costs at the default pitch
Viewer.PITCH = W * 4
--- the byte order of a presented pixel: R, G, B, A at increasing addresses, which
--- is what "RGBA8888" means on a little endian host
Viewer.FORMAT = "RGBA8888"

-- ---------------------------------------------------------------------------
-- the context
-- ---------------------------------------------------------------------------

--[[
	The Z buffer is opened in ZB_MODE_5R6G5B, TinyGL's internal format
	(TGL_FEATURE_RENDER_BITS == 16), which is the one the renderer draws into
	without converting.  ZB_copyFrameBuffer() does convert to an external layout,
	and its ZB_MODE_RGBA output is the historical SGL packing -- bytes B, G, R and an
	*empty* alpha -- so it is no use for RGBA8888 and the expansion below is done
	here instead, from the 16 bit pixels.
]]
local zb: any = nil
local scratch: buffer? = nil

--- the camera record scene_room renders from, reused every frame
local camera: Scene.Camera = { name = "viewer", eye = { 0, 0, 0 }, at = { 0, 0, 0 } }

local function ensureContext()
	if zb == nil then
		zb = GL.ZB.ZB_open(W, H, GL.ZB_MODE_5R6G5B, 0, nil, nil, nil)
		GL.glInit(zb)
		scratch = buffer.create(zb.xsize * zb.ysize * 2)
	end
end

--- Drop the context and the Z buffer.  The host keeps the image buffers it was
--- handed: nothing here is shared with them.
function Viewer.close()
	if zb ~= nil then
		GL.glClose()
		GL.ZB.ZB_close(zb)
		zb = nil
		scratch = nil
	end
end

-- ---------------------------------------------------------------------------
-- vectors
-- ---------------------------------------------------------------------------

--- The three numbers of a vector argument.  `what` names it in the error.
local function vec3(v: any, what: string): (number, number, number)
	local x, y, z = v[1], v[2], v[3]
	if x == nil or y == nil or z == nil then
		-- a record rather than an array: Vector3 shaped things
		x, y, z = v.x or v.X, v.y or v.Y, v.z or v.Z
	end
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		error(
			(
				"Viewer: %s must be a { x, y, z } table or a vector with .x/.y/.z fields, "
				.. "got %s whose components are %s, %s, %s"
			):format(what, typeof(v), typeof(x), typeof(y), typeof(z)),
			4
		)
	end
	return x :: number, y :: number, z :: number
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------

--[[
	Draw one frame from a camera position and a look direction.

	scene_room builds its view matrix from an eye and a point looked *at*, so the
	direction becomes at = position + direction; its lookAt() normalises the
	difference, so any non-zero length works.  What cannot work is looking straight
	up or straight down: the scene's up vector is (0, 1, 0), and a direction parallel
	to it makes the view matrix degenerate, which draws nothing.

	All six numbers are read before anything is written, so passing one of the
	scene's own `eye` tables as the position is fine.
]]
function Viewer.render(position: any, direction: any)
	local px, py, pz = vec3(position, "the camera position")
	local dx, dy, dz = vec3(direction, "the camera look direction")

	local length = math.sqrt(dx * dx + dy * dy + dz * dz)
	if length == 0 then
		error("Viewer.render: the look direction has zero length", 2)
	end
	if math.abs(dy) / length > 1 - 1e-9 then
		error(
			"Viewer.render: looking straight up or straight down; the scene's up vector is "
			.. "(0, 1, 0) and the view matrix would degenerate",
			2
		)
	end

	ensureContext()
	local eye = camera.eye
	eye[1], eye[2], eye[3] = px, py, pz
	local at = camera.at
	at[1], at[2], at[3] = px + dx, py + dy, pz + dz

	renderScene(camera)
end

-- ---------------------------------------------------------------------------
-- present
-- ---------------------------------------------------------------------------

--[[
	565 back over eight bits, the way the port's own conversions do it (r * 8 +
	r // 4 rather than r * 8, so 31 reaches 255 instead of 248).  Precomputed
	because this is 307 200 pixels a frame at 640x480.
]]
local RED8: { number } = table.create(32) :: { number }
local GREEN8: { number } = table.create(64) :: { number }
local BLUE8: { number } = table.create(32) :: { number }
for i = 0, 31 do
	RED8[i + 1] = i * 8 + i // 4
	BLUE8[i + 1] = i * 8 + i // 4
end
for i = 0, 63 do
	GREEN8[i + 1] = i * 4 + i // 16
end

--- the alpha byte of an opaque RGBA8888 pixel, added rather than ORed: the four
--- fields below never overlap, and this keeps the value out of bit32's signed wrap
local OPAQUE = 0xFF000000

--[[
	Viewer.present(buffer?, pitch?): copy the last rendered frame out as RGBA8888.

	Returns the buffer it wrote, allocating one if the caller did not provide it, so
	both of these are the way in:

	    local pixels = Viewer.present()                    -- 640 * 480 * 4 bytes
	    Viewer.present(hostTextureBuffer, hostRowPitch)     -- into something existing

	`pitch` is the distance in bytes from the start of one row to the next, which a
	host uploading into a padded or sub-allocated buffer needs; it defaults to
	W * 4, and the buffer has to be at least (H - 1) * pitch + W * 4 bytes long.
	Bytes below the last written pixel of a row are left as they were, which is what
	a host with a padded pitch wants.

	Row 0 is the top of the picture.  Nothing here hands out the frame buffer itself,
	everything is a copy, so an image outlives Viewer.close().
]]
function Viewer.present(destination: buffer?, pitch: number?): buffer
	ensureContext()

	local out = destination or buffer.create(H * W * 4)
	local stride = pitch or (W * 4)
	local needed = (H - 1) * stride + W * 4
	if stride < W * 4 then
		error(("Viewer.present: a pitch of %d bytes is narrower than a row of %d pixels"):format(stride, W), 2)
	end
	if buffer.len(out) < needed then
		error(
			("Viewer.present: the buffer has %d bytes, %d are needed for %dx%d RGBA8888 at pitch %d")
			:format(buffer.len(out), needed, W, H, stride),
			2
		)
	end

	-- the 16 bit pixels, in one memcpy per row (the internal format *is* 5R6G5B, so
	-- ZB_copyFrameBuffer has nothing to convert here)
	local src = scratch :: buffer
	local srcPitch = zb.linesize * 2 -- zb.linesize is in pixels
	GL.ZB.ZB_copyFrameBuffer(zb, src, srcPitch)

	for y = 0, H - 1 do
		local from = y * srcPitch
		local to = y * stride
		for x = 0, W - 1 do
			local pixel = buffer.readu16(src, from + x * 2)
			-- one 32 bit store per pixel: R at the low address, then G, B, A
			buffer.writeu32(
				out,
				to + x * 4,
				RED8[rshift(pixel, 11) + 1]
					+ GREEN8[band(rshift(pixel, 5), 0x3F) + 1] * 0x100
					+ BLUE8[band(pixel, 0x1F) + 1] * 0x10000
					+ OPAQUE
			)
		end
	end
	return out
end

--- The RGBA8888 bytes of one pixel of the last frame, as four numbers.  Slow by
--- design: it is for checking what a host was handed, not for blitting.
function Viewer.pixel(x: number, y: number): (number, number, number, number)
	ensureContext()
	if x < 0 or x >= W or y < 0 or y >= H then
		error(("Viewer.pixel: %d,%d is outside the %dx%d picture"):format(x, y, W, H), 2)
	end
	local pixel = GL.ZB.pixelGet(zb, y * zb.linesize + x)
	return
		RED8[rshift(pixel, 11) + 1],
		GREEN8[band(rshift(pixel, 5), 0x3F) + 1],
		BLUE8[band(pixel, 0x1F) + 1],
		255
end

-- ---------------------------------------------------------------------------
-- a demonstration of the whole interface
-- ---------------------------------------------------------------------------

--- Render the scene's establishing view ("01_wide") through render()/present(),
--- time it, and print what the host would see.  `frames` defaults to 20.
function Viewer.demo(frames: number?)
	local view = Views[1]
	assert(view.name == "01_wide", "viewer.demo: the scene's first view is no longer 01_wide")

	local direction = {
		view.at[1] - view.eye[1],
		view.at[2] - view.eye[2],
		view.at[3] - view.eye[3],
	}

	-- one frame up front, so the timing does not include the lazy first time work
	Viewer.render(view.eye, direction)

	local count = frames or 20
	local start = os.clock()
	for _ = 1, count do
		Viewer.render(view.eye, direction)
	end
	local elapsed = os.clock() - start

	local pixels = Viewer.present()

	-- a fingerprint of the presented frame, so two frames can be told apart (or
	-- proved identical) without looking at 1.2 MB of numbers
	local hash = 1469598103
	for i = 0, buffer.len(pixels) - 1 do
		hash = (hash * 33 + buffer.readu8(pixels, i) + 1) % 1000000007
	end

	print(("scene %s, %dx%d, %d frames"):format(view.name, W, H, count))
	print(("per frame %.2f ms   fps %.1f"):format(elapsed / count * 1000, count / elapsed))
	print(("presented %d bytes of %s, pitch %d, digest %d"):format(
		buffer.len(pixels),
		Viewer.FORMAT,
		W * 4,
		hash
	))

	-- corners and centre: proof a real picture came out, and which way up it is (the
	-- floor fills the bottom of the frame, so the bottom corners are the dark end)
	local samples = table.create(5)
	local spots = { { 0, 0 }, { W - 1, 0 }, { 0, H - 1 }, { W - 1, H - 1 }, { W // 2, H // 2 } }
	for i, spot in ipairs(spots) do
		local r, g, b, a = Viewer.pixel(spot[1], spot[2])
		samples[i] = ("%d,%d=rgba(%d,%d,%d,%d)"):format(spot[1], spot[2], r, g, b, a)
	end
	print("  " .. table.concat(samples, "  "))
end

return Viewer
