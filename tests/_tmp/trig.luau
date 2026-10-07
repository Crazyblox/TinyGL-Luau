--!strict
local b8 = buffer.create(8)
local b4 = buffer.create(4)
local function dbl(tag: string, d: number)
	buffer.writeu64(b8, 0, d)
	buffer.writef32(b4, 0, d)
	print(("%s %016x %08x"):format(tag, buffer.readu64(b8, 0), buffer.readu32(b4, 0)))
end
local function arg(kind: string, x: number)
	dbl(kind .. " x", x)
	dbl(kind .. " sin", math.sin(x))
	dbl(kind .. " cos", math.cos(x))
end
local pi = math.pi
dbl("pi          v", pi)
for _, sp in { { 12, 16 }, { 11, 14 }, { 9, 12 } } do
	local stacks, slices = sp[1], sp[2]
	for i = 0, stacks - 1 do
		arg(("t[%d/%d]"):format(i, stacks), -pi / 2 + pi * i / stacks)
	end
	for j = 0, slices - 1 do
		arg(("p[%d/%d]"):format(j, slices), 2 * pi * j / slices)
	end
end
for i = 0, 13 do
	arg(("f%.2d"):format(i), i * 0.8)
	arg(("g%.2d"):format(i), i * 0.6)
end
for s = 1, 4 do
	arg(("pyr%d"):format(s), s * 1.3)
end
dbl("tan46       v", math.tan(46.0 * pi / 180.0 / 2.0))
