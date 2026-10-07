--!strict
--[[
	viewer_demo.luau — drive examples/viewer.luau from the command line: render the
	room scene's establishing view ("01_wide") through the position/direction
	interface and print what a host would be handed.

	    luau examples/viewer_demo.luau -a 50
	    luau --codegen examples/viewer_demo.luau -a 50

	The frame count has to come after the CLI's `-a` separator, which is where the
	`luau` host puts program arguments.

	Beyond Viewer.demo() this exercises the two things a host actually does with the
	interface: presenting into a buffer it already owns, at a pitch wider than a row,
	and being refused when it asks for something the scene cannot draw.
]]

local Viewer = require("./viewer")

local buffer = buffer --[[(the standard library)]]

local frames = tonumber((...)) or 20

-- ---------------------------------------------------------------------------
-- one frame, timed
-- ---------------------------------------------------------------------------
Viewer.demo(frames)

-- ---------------------------------------------------------------------------
-- present() into a host buffer with a padded pitch
-- ---------------------------------------------------------------------------
local W, H = Viewer.W :: number, Viewer.H :: number
local PITCH = Viewer.PITCH :: number

--[[
	A host that uploads the frame into a texture usually cannot give TinyGL a tight
	buffer: rows are aligned to 16, 32 or 64 bytes.  Present into exactly that, then
	read the image back out of it and check it is the same picture a tight present
	gives.
]]
local padding = 64
local hostPitch = PITCH + padding
local hostBuffer = buffer.create(H * hostPitch)
for i = 0, buffer.len(hostBuffer) - 1 do
	buffer.writeu8(hostBuffer, i, 0x77) -- a fill value that is not in the picture
end

Viewer.present(hostBuffer, hostPitch)

--- a rolling digest over the image part of a presented buffer, so a padded and an
--- unpadded present of the same frame can be compared
local function digest(image: buffer, pitch: number): number
	local hash = 1469598103
	for y = 0, H - 1 do
		for x = 0, W * 4 - 1 do
			hash = (hash * 33 + buffer.readu8(image, y * pitch + x) + 1) % 1000000007
		end
	end
	return hash
end

local tight = Viewer.present()
print(("\npresent into a padded host buffer, pitch %d (%d bytes, %d of them picture)"):format(
	hostPitch,
	buffer.len(hostBuffer),
	H * PITCH
))
print(("  digest, tight pitch     %d"):format(digest(tight, PITCH)))
print(("  digest, padded pitch    %d   %s"):format(
	digest(hostBuffer, hostPitch),
	if digest(tight, PITCH) == digest(hostBuffer, hostPitch) then "matches" else "DOES NOT MATCH"
))
-- the untouched padding still holds the fill value, which is what "bytes the row
-- does not reach are left alone" means
local tailHeld = true
for y = 0, H - 1 do
	for o = PITCH, hostPitch - 1 do
		if buffer.readu8(hostBuffer, y * hostPitch + o) ~= 0x77 then
			tailHeld = false
		end
	end
end
print(("  the %d padding bytes of each row were left alone: %s"):format(
	padding,
	if tailHeld then "yes" else "no"
))
--[[
	The byte order, checked against the port's own idea of a pixel rather than
	against a guess: Viewer.pixel() expands the internal 5R6G5B pixel into the four
	eight bit channels, so if the buffer really is RGBA8888 then byte 0 of a pixel is
	the r that helper returns, byte 1 its g, byte 2 its b, byte 3 an opaque alpha.
	A rotated or shifted packing (the BGRA ZB_copyFrameBuffer's ZB_MODE_RGBA gives,
	with an empty alpha) fails this on any pixel with colour in it.
]]
local function byteOrderIsRgba(image: buffer, pitch: number): (boolean, string)
	local checked, mismatch = 0, ""
	for y = 0, H - 3, 7 do
		for x = 0, W - 3, 11 do
			local r, g, b, a = Viewer.pixel(x, y)
			local o = y * pitch + x * 4
			if
				buffer.readu8(image, o) ~= r
				or buffer.readu8(image, o + 1) ~= g
				or buffer.readu8(image, o + 2) ~= b
				or buffer.readu8(image, o + 3) ~= a
			then
				if mismatch == "" then
					mismatch = ("at %d,%d the buffer holds %d,%d,%d,%d and the renderer says %d,%d,%d,%d"):format(
						x,
						y,
						buffer.readu8(image, o),
						buffer.readu8(image, o + 1),
						buffer.readu8(image, o + 2),
						buffer.readu8(image, o + 3),
						r,
						g,
						b,
						a
					)
				end
			end
			checked += 1
		end
	end
	return mismatch == "", ("%d pixels checked, %s"):format(checked, if mismatch == "" then "all RGBA" else mismatch)
end

local ordered, orderReport = byteOrderIsRgba(tight, PITCH)
print(("  byte order, tight present:   %s (%s)"):format(if ordered then "RGBA8888" else "WRONG", orderReport))
local orderedPadded, orderReportPadded = byteOrderIsRgba(hostBuffer, hostPitch)
print(("  byte order, padded present:  %s (%s)"):format(if orderedPadded then "RGBA8888" else "WRONG", orderReportPadded))

-- ---------------------------------------------------------------------------
-- what the interface refuses
-- ---------------------------------------------------------------------------
print("\nwhat Viewer.render refuses, and what it says")
local attempts: { { what: string, direction: any } } = {
	{ what = "a direction of zero length", direction = { 0, 0, 0 } },
	{ what = "looking straight up", direction = { 0, 100, 0 } },
	{ what = "looking straight down", direction = { 0, -1, 0 } },
	{ what = "a direction with two components", direction = { 1, 2 } },
	{ what = "a direction that is not a vector", direction = "behind the sofa" },
}
for _, attempt in attempts do
	local ok, message = pcall(Viewer.render, { 7.2, 4.2, 8.6 }, attempt.direction)
	print(("  %s: %s%s"):format(
		attempt.what,
		if ok then "accepted, which it should not have been" else "refused",
		if ok then "" else "\n      " .. tostring(message)
	))
end

-- and what it accepts: a host's own vector type has fields rather than indices, and
-- a direction of any length, so long as it is not straight up or straight down
local accepted = pcall(Viewer.render, { 7.2, 4.2, 8.6 }, { x = -7.3, y = -3.5, z = -8.9 })
print(("  a { x = ..., y = ..., z = ... } direction: %s, and it drew a frame"):format(
	if accepted then "accepted" else "refused"
))

Viewer.close()
print("\nclosed; the buffer present() handed out belongs to the host, not to the renderer")
print(("  that frame's centre pixel is still rgba(%d,%d,%d,%d)"):format(
	buffer.readu8(tight, ((H // 2) * PITCH + (W // 2) * 4)),
	buffer.readu8(tight, ((H // 2) * PITCH + (W // 2) * 4) + 1),
	buffer.readu8(tight, ((H // 2) * PITCH + (W // 2) * 4) + 2),
	buffer.readu8(tight, ((H // 2) * PITCH + (W // 2) * 4) + 3)
))
