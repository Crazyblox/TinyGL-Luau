--!strict
--[[
	dump_scene.luau — render one scene and print its external frame buffer.

Usage:  luau tests/dump_scene.luau [name-substring] > out.txt

	Each line is:
	    SCENE <name> <xsize> <ysize> <mode>
	    ROW <y> <v...>          raw values of the external frame buffer row,
	                            little endian assembled exactly like the C
	                            harness' --rows output
	Then compare against the C reference with:
	    python3 ../ref/rowdiff.py ref_rows.txt out.txt
]]

local GL = require("../tinygl")
local Scenes = require("./scenes")

local buffer = buffer --[[(standard library)]]

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

local function copyLinesize(mode: number, xsize: number): number
	if mode == GL.ZB_MODE_5R6G5B then
		return xsize * 2
	elseif mode == GL.ZB_MODE_RGBA then
		return xsize * 4
	elseif mode == GL.ZB_MODE_RGB24 then
		return xsize * 1
	end
	return xsize * 2
end

--- one pixel of the external frame buffer, little endian, like `od` would show
local function readPixel(ext: buffer, o: number, bpp: number): number
	if bpp == 4 then
		return buffer.readu32(ext, o)
	elseif bpp == 2 then
		return buffer.readu16(ext, o)
	elseif bpp == 3 then
		return buffer.readu8(ext, o) + buffer.readu8(ext, o + 1) * 0x100 + buffer.readu8(ext, o + 2) * 0x10000
	end
	return buffer.readu8(ext, o)
end

-- optional argument: a substring of the scene name to dump
local filter: string? = ...

for _, scene in ipairs(Scenes.list) do
	if filter == nil or string.find(scene.name :: string, filter) then
		local zbmode = ZBModeOf[scene.mode] :: number
		local bpp = BytesPerPixelOf[scene.mode] :: number
		local ext = buffer.create(scene.xsize * scene.ysize * bpp)
		for i = 0, buffer.len(ext) - 1 do
			buffer.writeu8(ext, i, 0xAA)
		end
		local zb: any = nil
		local st: any = { xsize = scene.xsize, ysize = scene.ysize, lines = {} }
		local ok, err = pcall(function()
			if zbmode == GL.ZB_MODE_INDEX then
				local indexes = table.create(3 * 256) :: { number }
				for j = 0, 3 * 256 - 1 do
					indexes[j + 1] = j // 3
				end
				zb = GL.ZB.ZB_open(scene.xsize, scene.ysize, GL.ZB_MODE_INDEX, 256, indexes, table.create(256) :: { number }, nil)
			else
				zb = GL.ZB.ZB_open(scene.xsize, scene.ysize, zbmode, 0, nil, nil, nil)
			end
			GL.glInit(zb)
			scene.fn(st)
		end)
		if not ok then
			print(("SCENE %s %d %d %d ERROR %s"):format(scene.name, scene.xsize, scene.ysize, scene.mode, tostring(err)))
		else
			local xsize, ysize = st.xsize :: number, st.ysize :: number
			print(("SCENE %s %d %d %d"):format(scene.name, xsize, ysize, scene.mode))
			GL.ZB.ZB_copyFrameBuffer(zb, ext, copyLinesize(zbmode, scene.xsize))
			local dstStride = scene.xsize * bpp
			for y = 0, ysize - 1 do
				local parts = table.create(xsize + 1)
				parts[1] = ("ROW %d"):format(y)
				for x = 0, xsize - 1 do
					parts[x + 2] = tostring(readPixel(ext, y * dstStride + x * bpp, bpp))
				end
				print(table.concat(parts, " "))
			end
		end
	end
end
