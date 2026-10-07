--!strict
--[[
	test_against_c.luau — compares the Luau port with the real TinyGL C library.

	ref/ref_scenes.c renders the scenes in tests/scenes.luau with TinyGL itself and
	ref/make_expected.py stores a per scanline digest of the resulting frame buffer
	plus whatever the scene printed into tests/expected.luau.  This test renders the
	same scenes here and compares.

	Run with:  luau tests/test_against_c.luau  (exit status 0 on success)

	Set ONLY to a scene name substring to debug a single scene.
]]

local H = require("./harness")
local GL = require("../tinygl")
local Expected = require("./expected")
local Scenes = require("./scenes")

local buffer = buffer --[[(standard library)]]

local ZB = GL.ZB

local ONLY: string? = nil

-- the scene table numbers the external pixel formats like the C harness does
local ZBModeOf = {
	[0] = GL.ZB_MODE_5R6G5B,
	[1] = GL.ZB_MODE_RGBA,
	[2] = GL.ZB_MODE_RGB24,
	[3] = GL.ZB_MODE_INDEX,
}
local BytesPerPixelOf = {
	[0] = 2,
	[1] = 4,
	[2] = 3,
	[3] = 1,
}

--- ZB_copyFrameBuffer's linesize convention, which differs per external mode
local function copyLinesize(mode: number, xsize: number): number
	if mode == GL.ZB_MODE_5R6G5B then
		return xsize * 2
	elseif mode == GL.ZB_MODE_RGBA then
		return xsize * 4
	elseif mode == GL.ZB_MODE_RGB24 then
		return xsize * 1 -- C multiplies it by 3 internally
	end
	return xsize * 2 -- INDEX: C halves it for the 8 bit destination
end

local function digestRow(ext: buffer, rowStart: number, count: number, bpp: number): number
	local h = 1469598103
	for i = 0, count * bpp - 1 do
		h = (h * 33 + buffer.readu8(ext, rowStart + i) + 1) % 1000000007
	end
	return h
end

local function findExpected(name: string): any
	for i = 1, #Expected.scenes do
		local s = Expected.scenes[i]
		if s.name == name then
			return s
		end
	end
	return nil
end

local checksBefore = H.passes

for _, scene in ipairs(Scenes.list) do
	if ONLY == nil or string.find(scene.name :: string, ONLY :: string) then
		H.section(scene.name)
		local exp = findExpected(scene.name)
		if exp == nil then
			H.check(false, ("no reference data for scene '%s'"):format(scene.name))
		else
			local zbmode = ZBModeOf[scene.mode :: number] :: number
			local bpp = BytesPerPixelOf[scene.mode :: number] :: number
			local ext = buffer.create(scene.xsize * scene.ysize * bpp)
			for i = 0, buffer.len(ext) - 1 do
				buffer.writeu8(ext, i, 0xAA) -- the C harness pre-fills with 0xAA too
			end

			local zb: any = nil
			local st: any = { xsize = scene.xsize, ysize = scene.ysize, lines = {} }
			local ok: boolean
			local err: any
			ok, err = pcall(function()
				if zbmode == GL.ZB_MODE_INDEX then
					-- the tables TinyGL's own front end would hand to ZB_open
					local indexes = table.create(3 * 256) :: { number }
					for j = 0, 3 * 256 - 1 do
						indexes[j + 1] = j // 3
					end
					zb = ZB.ZB_open(scene.xsize, scene.ysize, GL.ZB_MODE_INDEX, 256, indexes, table.create(256) :: { number }, nil)
				else
					zb = ZB.ZB_open(scene.xsize, scene.ysize, zbmode, 0, nil, nil, nil)
				end
				GL.glInit(zb)
				scene.fn(st)
				st.zb = zb
			end, debug.traceback)

			if not ok then
				H.check(false, ("scene raised: %s"):format(tostring(err)))
			else
				local xsize, ysize = st.xsize :: number, st.ysize :: number

				-- 1. text output (glGet / selection results)
				local expLines = exp.lines :: { string }
				local gotLines = st.lines :: { string }
				for i = 1, math.max(#expLines, #gotLines) do
					H.check(
						expLines[i] == gotLines[i],
						("printed line %d: got [%s], reference [%s]"):format(
							i,
							tostring(gotLines[i]),
							tostring(expLines[i])
						)
					)
				end

				-- 2. the frame buffer itself
				local dstStride = scene.xsize * bpp -- the allocation keeps the original stride
				ZB.ZB_copyFrameBuffer(zb, ext, copyLinesize(zbmode, scene.xsize))

				local bad = 0
				local firstBad = 0
				for y = 0, ysize - 1 do
					local got = digestRow(ext, y * dstStride, xsize, bpp)
					local want = exp.rows[y + 1]
					if got ~= want then
						bad += 1
						if firstBad == 0 then
							firstBad = y + 1
						end
					end
					H.check(got == want, ("scene %s: row %d differs from the C reference"):format(scene.name, y))
				end
				if bad > 0 then
					H.check(
						false,
						("scene %s: %d/%d rows differ from the C reference, first is row %d"):format(
							scene.name,
							bad,
							ysize,
							firstBad - 1
						)
					)
					-- dump the row we got so the difference can be inspected
					local gotRow = {}
					local y = firstBad - 1
					for x = 0, xsize - 1 do
						local o = y * dstStride + x * bpp
						local v = if bpp == 2 then buffer.readu16(ext, o) else buffer.readu8(ext, o)
						table.insert(gotRow, ("%d:%d"):format(x, v))
					end
					print(("  got   %s row %d: "):format(scene.name, y) .. table.concat(gotRow, " "))
					print("  (want  row " .. y .. " digest " .. tostring(exp.rows[firstBad]) .. ")")
				end
				if ysize ~= #exp.rows then
					H.check(false, ("digests %d rows, reference has %d"):format(ysize, #exp.rows))
				end
			end
		end
	end
end

print(("%d row/text digests matched the C reference"):format(H.passes - checksBefore))
H.summary()
