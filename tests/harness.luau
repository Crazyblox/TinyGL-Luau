--!strict
--[[
	harness.luau — a minimal test framework for the TinyGL Luau port.

	`io` is not available in every Luau host (the standalone `luau` CLI has no
	`io` library at all), so PPM output is returned as a string by H.dumpPPM and
	writing it to disk is left to whoever has a filesystem.
]]

local H = {}

H.passes = 0
H.failures = {}
H.currentSection = "?"
H.verbose = false

function H.section(name: string)
	H.currentSection = name
	if H.verbose then
		print("-- " .. name)
	end
end

function H.check(cond: any, msg: string)
	if cond then
		H.passes += 1
	else
		table.insert(H.failures, H.currentSection .. ": " .. msg)
		print("FAIL " .. H.currentSection .. ": " .. msg)
	end
end

function H.eq(actual: any, expected: any, msg: string?)
	local m = msg or ("expected " .. tostring(expected) .. ", got " .. tostring(actual))
	H.check(actual == expected, m)
end

function H.ne(actual: any, expected: any, msg: string?)
	local m = msg or ("expected something other than " .. tostring(expected))
	H.check(actual ~= expected, m)
end

function H.near(actual: number, expected: number, eps: number?, msg: string?)
	eps = eps or 1e-6
	local ok = math.abs(actual - expected) <= eps
	local m = msg or ("expected " .. tostring(expected) .. " +/- " .. tostring(eps) .. ", got " .. tostring(actual))
	H.check(ok, m)
end

--- Fails when `count` differs from `expected`; used a lot for pixel coverage.
function H.countEquals(count: number, expected: number, msg: string)
	H.check(count == expected, msg .. " (expected " .. expected .. " pixels, got " .. count .. ")")
end

function H.countNear(count: number, expected: number, tolerance: number, msg: string)
	H.check(
		math.abs(count - expected) <= tolerance,
		msg .. " (expected about " .. expected .. " +/- " .. tolerance .. " pixels, got " .. count .. ")"
	)
end

--- Run f, returning (ok, errorMessage).  Used by the "this must raise" tests.
function H.raises(f: () -> ()): (boolean, string)
	local ok, err = pcall(f)
	return ok, tostring(err)
end

function H.checkRaises(f: () -> (), msg: string)
	local ok, err = H.raises(f)
	-- the message is not checked: TinyGL's own assertions are worded per call
	-- site ("glShadeModel: bad mode", "TinyGL: glViewport: size too small"), and
	-- what matters here is that the port refuses the call instead of drawing
	-- something or crashing on a nil value later
	H.check(not ok, msg .. " (expected an error, none raised)" .. (if ok then "" else " [got: " .. err .. "]"))
end

--[[
	PPM dumping, for eyeballing a picture.  These read the internal 16 bit pixel
	(the same value ZB.pixelGet returns, whatever the external display mode is)
	and expand 5R6G5B to 888 the way examples/gallery.luau does, so they do not go
	through ZB_copyFrameBuffer: that converts to the format the *external* buffer
	has, which is not 24 bit RGB unless the frame buffer was opened as ZB_MODE_RGB24.
	Row 0 of the frame buffer is the top of the window, like a PPM.
]]
local ZBuffer = require("../internal/zbuffer")

local function rgbOf(zb: any, x: number, y: number): (number, number, number)
	local v = ZBuffer.pixelGet(zb, y * zb.linesize + x)
	local r = bit32.rshift(v, 11)
	local g = bit32.band(bit32.rshift(v, 5), 0x3F)
	local b = bit32.band(v, 0x1F)
	-- spread the short fields over 8 bits; the green field is 6 bits wide
	return r * 8 + r // 4, g * 4 + g // 16, b * 8 + b // 4
end

--- Render the frame buffer as an RGB PPM (P6) string.
function H.dumpPPM(zb: any): string
	local out = { ("P6\n%d %d\n255\n"):format(zb.xsize, zb.ysize) }
	local bytes = table.create(zb.ysize * zb.xsize * 3)
	local n = 1
	for y = 0, zb.ysize - 1 do
		for x = 0, zb.xsize - 1 do
			local r, g, b = rgbOf(zb, x, y)
			bytes[n] = string.char(r)
			bytes[n + 1] = string.char(g)
			bytes[n + 2] = string.char(b)
			n += 3
		end
	end
	table.insert(out, table.concat(bytes))
	return table.concat(out)
end

--- Same, but as text (one RGB triple per line), for golden output in tests.
function H.dumpPPMText(zb: any): string
	local out = { ("P3\n%d %d\n255\n"):format(zb.xsize, zb.ysize) }
	for y = 0, zb.ysize - 1 do
		local row = {}
		for x = 0, zb.xsize - 1 do
			local r, g, b = rgbOf(zb, x, y)
			table.insert(row, ("%d %d %d"):format(r, g, b))
		end
		table.insert(out, table.concat(row, " "))
	end
	return table.concat(out, "\n")
end

function H.summary()
	if #H.failures > 0 then
		print(("\n%d checks passed, %d FAILED:"):format(H.passes, #H.failures))
		for i, f in ipairs(H.failures) do
			print("  " .. tostring(i) .. ". " .. f)
		end
		error(("TinyGL test suite: %d failure(s)"):format(#H.failures), 1)
	else
		print(("%d checks passed"):format(H.passes))
	end
end

return H
