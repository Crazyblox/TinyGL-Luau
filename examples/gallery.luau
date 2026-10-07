--!strict
--[[
	gallery.luau — render examples/scene_room.luau and print its frame buffers
	as hex, for examples/hexdump_to_ppm.py to turn into .ppm (and .png) files.

	The standalone `luau` host has no filesystem, which is why the pictures go out
	as text:

	    luau examples/gallery.luau > /tmp/out.txt
	    python3 examples/hexdump_to_ppm.py /tmp/out.txt <output dir>

	To render a single view, pass a substring of its name after the CLI's `-a`
	separator:  luau examples/gallery.luau -a 01_wide

	Pass a substring of one view's name to render only that one.
]]

local Scene = require("./scene_room")

local GL = require("../tinygl")

local buffer = buffer --[[(standard library)]]
local band, rshift = bit32.band, bit32.rshift

type Camera = Scene.Camera

local W, H = Scene.W :: number, Scene.H :: number
local Views = Scene.Views :: { Camera }
local renderView = Scene.renderView :: (cam: Camera) -> ()

local HEX = table.create(256)
for i = 0, 255 do
	HEX[i + 1] = string.format("%02x", i)
end

local filter: string? = ...

for _, cam in ipairs(Views) do
	if filter == nil or string.find(cam.name :: string, filter :: string) then
		local zb = GL.ZB.ZB_open(W, H, GL.ZB_MODE_5R6G5B, 0, nil, nil, nil)
		GL.glInit(zb)
		-- xpcall's second result is typed from the protected function's return
		-- value, and renderView returns nothing, so the traceback is caught by the
		-- handler instead of by a second result
		local message: string? = nil
		local ok = xpcall(function()
			renderView(cam)
		end, function(msg: any): string
			message = tostring(msg)
			return message :: string
		end)
		if not ok then
			print(("ERROR %s %s"):format(cam.name, tostring(message)))
		else
			local ext = buffer.create(W * H * 2)
			GL.ZB.ZB_copyFrameBuffer(zb, ext, W * 2)
			print(("PPM %s %d %d"):format(cam.name, W, H))
			local row = table.create(W * 3)
			-- TinyGL's viewport mapping has scale.Y negative, so frame buffer row 0
			-- holds the top of the window; a PPM also starts with its top row, so the
			-- rows go out in order.
			for y = 0, H - 1 do
				local n = 0
				for x = 0, W - 1 do
					local v = buffer.readu16(ext, (y * W + x) * 2)
					-- 565 back to 888, spreading the short fields over 8 bits
					n += 1
					row[n] = HEX[rshift(v, 11) * 8 + 1]
					n += 1
					row[n] = HEX[band(rshift(v, 5), 0x3F) * 4 + 1]
					n += 1
					row[n] = HEX[band(v, 0x1F) * 8 + 1]
				end
				print(table.concat(row))
			end
		end
		GL.ZB.ZB_close(zb)
		GL.glClose()
	end
end
