--!strict
--[[
	bench.luau — time the renderer on the first view of examples/scene_room.luau.

	Renders shot 01_wide N times and prints how long that took, so the per frame
	time and frame rate fall out of it.  Nothing is written or printed per frame:
	the point is the cost of the renderer, not of producing pictures.

	The `luau` CLI needs its `-a` separator before program arguments:

	    luau --codegen examples/bench.luau -a 50

	Run it both with and without --codegen to see what native code generation is
	worth here.  The Z buffer and the context are created once, before the clock
	starts, the way an application would keep them across frames.

	os.clock() is process CPU time, so this measures rendering work rather than
	wall clock time.
]]

local Scene = require("./scene_room")
local GL = require("../tinygl")

local W, H = Scene.W :: number, Scene.H :: number
local Views = Scene.Views :: { any }
local renderView = Scene.renderView :: (cam: { any }) -> ()

local frames = tonumber((...)) or 50

local cam = Views[1]

-- one frame buffer and one context, reused by every frame
local zb = GL.ZB.ZB_open(W, H, GL.ZB_MODE_5R6G5B, 0, nil, nil, nil)
GL.glInit(zb)

-- one frame first, so the timing does not include the lazy first time work
-- (texture tables, specular buffers, allocated vertex pools)
renderView(cam)

local start = os.clock()
for _ = 1, frames do
	renderView(cam)
end
local elapsed = os.clock() - start

print(("scene %s, %dx%d, %d frames"):format(cam.name :: string, W, H, frames))
print(("total     %.4f s"):format(elapsed))
print(("per frame %.2f ms"):format(elapsed / frames * 1000))
print(("fps       %.1f"):format(frames / elapsed))
