--!strict
--[[
	light.luau — port of TinyGL's src/light.c.

	Materials, lights, the light model and the (unoptimized) per vertex lighting
	used by gl_shade_vertex().

	Handlers follow TinyGL's convention: `p[0]` is the opcode and `p[1] .. p[n]`
	are the opcode's parameters, exactly like C's `GLParam *p`.
]]

local Config = require("./config")
local ZMath = require("./zmath")
local Matrix = require("./matrix")
local SpecBuf = require("./specbuf")
local Util = require("./util")
local MSH = require("./msghandling")

local clampf = Util.clampf
local trunc = Util.trunc
local M_PI = Util.M_PI

local MAX_LIGHTS = Config.MAX_LIGHTS
local SPECULAR_BUFFER_SIZE = Config.SPECULAR_BUFFER_SIZE
local SPECULAR_BUFFER_RESOLUTION = Config.SPECULAR_BUFFER_RESOLUTION

-- Constants hoisted into this module's own scope: a local is a register read where
-- GL.GL_AMBIENT was a table lookup, and glopMaterial, glopLight and
-- gl_shade_vertex are what the lighting path spends its time in.  CHECK validates
-- each literal against the frozen table it stands for as this module loads, so one
-- that drifts is an error naming both values here rather than a material property
-- written to the wrong slot.
-- CHECK.luau is --!nocheck, and takes one argument to install a profile or
-- two to check against it, which no single type says: hence the cast.
-- CHECK(table) installs a profile, dropping whatever the module loaded
-- before it installed.
-- See CHECK.luau.
local CHECK = require("../CHECK") :: (any?, any?) -> any
CHECK()(require("../gl_constants"))
local GL_AMBIENT = 0x1200; CHECK("GL_AMBIENT", GL_AMBIENT)
local GL_AMBIENT_AND_DIFFUSE = 0x1602; CHECK("GL_AMBIENT_AND_DIFFUSE", GL_AMBIENT_AND_DIFFUSE)
local GL_BACK = 0x405; CHECK("GL_BACK", GL_BACK)
local GL_CONSTANT_ATTENUATION = 0x1207; CHECK("GL_CONSTANT_ATTENUATION", GL_CONSTANT_ATTENUATION)
local GL_DIFFUSE = 0x1201; CHECK("GL_DIFFUSE", GL_DIFFUSE)
local GL_EMISSION = 0x1600; CHECK("GL_EMISSION", GL_EMISSION)
local GL_FRONT = 0x404; CHECK("GL_FRONT", GL_FRONT)
local GL_FRONT_AND_BACK = 0x408; CHECK("GL_FRONT_AND_BACK", GL_FRONT_AND_BACK)
local GL_LIGHT0 = 0x4000; CHECK("GL_LIGHT0", GL_LIGHT0)
local GL_LIGHT_MODEL_AMBIENT = 0xB53; CHECK("GL_LIGHT_MODEL_AMBIENT", GL_LIGHT_MODEL_AMBIENT)
local GL_LIGHT_MODEL_LOCAL_VIEWER = 0xB51; CHECK("GL_LIGHT_MODEL_LOCAL_VIEWER", GL_LIGHT_MODEL_LOCAL_VIEWER)
local GL_LIGHT_MODEL_TWO_SIDE = 0xB52; CHECK("GL_LIGHT_MODEL_TWO_SIDE", GL_LIGHT_MODEL_TWO_SIDE)
local GL_LINEAR_ATTENUATION = 0x1208; CHECK("GL_LINEAR_ATTENUATION", GL_LINEAR_ATTENUATION)
local GL_POSITION = 0x1203; CHECK("GL_POSITION", GL_POSITION)
local GL_QUADRATIC_ATTENUATION = 0x1209; CHECK("GL_QUADRATIC_ATTENUATION", GL_QUADRATIC_ATTENUATION)
local GL_SHININESS = 0x1601; CHECK("GL_SHININESS", GL_SHININESS)
local GL_SPECULAR = 0x1202; CHECK("GL_SPECULAR", GL_SPECULAR)
local GL_SPOT_CUTOFF = 0x1206; CHECK("GL_SPOT_CUTOFF", GL_SPOT_CUTOFF)
local GL_SPOT_DIRECTION = 0x1204; CHECK("GL_SPOT_DIRECTION", GL_SPOT_DIRECTION)
local GL_SPOT_EXPONENT = 0x1205; CHECK("GL_SPOT_EXPONENT", GL_SPOT_EXPONENT)

local Light = {}

local function assert(cond: any, msg: string)
	if not cond then
		error("TinyGL: " .. msg, 3)
	end
end

--- glopMaterial
function Light.glopMaterial(c: any, p: { number })
	local mode = p[1]
	local mtype = p[2]

	if mode == GL_FRONT_AND_BACK then
		p[1] = GL_FRONT
		Light.glopMaterial(c, p)
		mode = GL_BACK
	end

	local m: any = if mode == GL_FRONT then c.materials[1] else c.materials[2]

	if mtype == GL_EMISSION then
		for i = 0, 3 do
			m.emission[i + 1] = p[3 + i]
		end
	elseif mtype == GL_AMBIENT then
		for i = 0, 3 do
			m.ambient[i + 1] = p[3 + i]
		end
	elseif mtype == GL_DIFFUSE then
		for i = 0, 3 do
			m.diffuse[i + 1] = p[3 + i]
		end
	elseif mtype == GL_SPECULAR then
		for i = 0, 3 do
			m.specular[i + 1] = p[3 + i]
		end
	elseif mtype == GL_SHININESS then
		m.shininess = p[3]
		-- C keeps the bucket index in an `int`, so the product is truncated: every
		-- shininess in [b * 128 / RES, (b + 1) * 128 / RES) shares one table.
		-- C's m->shininess_i is an int field, so the bucket index is truncated.
		-- Nothing can see the difference: the tables themselves are computed from
		-- the exact shininess, the index only says which table is reused, and over
		-- one bucket of 0.125 the 5 bit specular table moves by about 0.01 of a
		-- step, never enough to round differently.  It is truncated because that is
		-- what the field is.
		m.shininess_i = trunc(m.shininess / 128.0 * SPECULAR_BUFFER_RESOLUTION)
	elseif mtype == GL_AMBIENT_AND_DIFFUSE then
		for i = 0, 3 do
			m.diffuse[i + 1] = p[3 + i]
		end
		for i = 0, 3 do
			m.ambient[i + 1] = p[3 + i]
		end
	else
		assert(false, "glopMaterial: illegal type")
	end
end

--- glopColorMaterial
function Light.glopColorMaterial(c: any, p: { number })
	c.currentColorMaterialMode = p[1]
	c.currentColorMaterialType = p[2]
end

--- glopLight
function Light.glopLight(c: any, p: { number })
	local light = p[1]
	local ltype = p[2]

	assert(light >= GL_LIGHT0 and light < GL_LIGHT0 + MAX_LIGHTS, "glopLight: illegal light")

	local l: any = c.lights[light - GL_LIGHT0 + 1]

	local v = { p[3], p[4], p[5], p[6] }

	if ltype == GL_AMBIENT then
		ZMath.v4Copy(l.ambient, v)
	elseif ltype == GL_DIFFUSE then
		ZMath.v4Copy(l.diffuse, v)
	elseif ltype == GL_SPECULAR then
		ZMath.v4Copy(l.specular, v)
	elseif ltype == GL_POSITION then
		local pos = { 0, 0, 0, 0 } :: ZMath.V4
		ZMath.gl_M4_MulV4(pos, Matrix.top(c, 0), v) -- C: c->matrix_stack_ptr[0]
		ZMath.v4Copy(l.position, pos)
		if l.position[4] == 0 then
			l.normPosition[1] = pos[1]
			l.normPosition[2] = pos[2]
			l.normPosition[3] = pos[3]
			ZMath.gl_V3_Norm(l.normPosition)
		end
	elseif ltype == GL_SPOT_DIRECTION then
		for i = 0, 2 do
			l.spotDirection[i + 1] = v[i + 1]
			l.normSpotDirection[i + 1] = v[i + 1]
		end
		ZMath.gl_V3_Norm(l.normSpotDirection)
	elseif ltype == GL_SPOT_EXPONENT then
		l.spotExponent = v[1]
	elseif ltype == GL_SPOT_CUTOFF then
		local a = v[1]
		assert(a == 180 or (a >= 0 and a <= 90), "glopLight: illegal spot cutoff")
		l.spotCutoff = a
		if a ~= 180 then
			l.cosSpotCutoff = math.cos(a * M_PI / 180.0)
		end
	elseif ltype == GL_CONSTANT_ATTENUATION then
		l.attenuation[1] = v[1]
	elseif ltype == GL_LINEAR_ATTENUATION then
		l.attenuation[2] = v[1]
	elseif ltype == GL_QUADRATIC_ATTENUATION then
		l.attenuation[3] = v[1]
	else
		assert(false, "glopLight: illegal type")
	end
end

--- glopLightModel
function Light.glopLightModel(c: any, p: { number })
	local pname = p[1]

	if pname == GL_LIGHT_MODEL_AMBIENT then
		for i = 0, 3 do
			c.ambientLightModel[i + 1] = p[2 + i]
		end
	elseif pname == GL_LIGHT_MODEL_LOCAL_VIEWER then
		c.localLightModel = math.floor(p[2])
	elseif pname == GL_LIGHT_MODEL_TWO_SIDE then
		c.lightModelTwoSide = math.floor(p[2])
	else
		MSH.warning(("glopLightModel: illegal pname: 0x%x"):format(pname))
	end
end

--- gl_enable_disable_light(): keeps a linked list of the enabled lights so that
--- gl_shade_vertex() does not have to walk all 16 slots.
function Light.gl_enable_disable_light(c: any, light: number, v: number)
	local l: any = c.lights[light + 1]
	if v ~= 0 and l.enabled == 0 then
		l.enabled = 1
		l.next = c.firstLight
		c.firstLight = l
		l.prev = nil
	elseif v == 0 and l.enabled ~= 0 then
		l.enabled = 0
		if l.prev == nil then
			c.firstLight = l.next
		else
			l.prev.next = l.next
		end
		if l.next ~= nil then
			l.next.prev = l.prev
		end
	end
end

--[[
	non optimized lightening model — gl_shade_vertex()

	Notes:
	* C always uses materials[0] (the front material).
	* the "half vector" computation keeps TinyGL's upstream typo, which reuses
	  vcoord.X for the Y and Z components.  It is wrong but it is what the C
	  renderer does, and the specular buffer lookup assumes it.
	* the arithmetic here is Luau's doubles, where C does it in floats.  Every local
	  of C's function is a float and every operation spills back into one, so the two
	  round differently.  Spelling the rounding out operation by operation does agree
	  with C more closely, but each of those was a buffer write and a buffer read, and
	  what it buys is a handful of pixels: the room of examples/scene_room.luau — the
	  one scene in this tree with a positional light and a quadratic falloff — comes
	  out of the double renderer 16 pixels different from the C render out of
	  1 843 200, three of the six views touched, none of them more than a shade of a
	  highlight.  The specular tables of specbuf.luau are built in doubles for the
	  same reason: they are cached, so they are cheap either way, and a step of
	  1/256 accumulated in double still walks the same 257 sample points.
]]
function Light.gl_shade_vertex(c: any, vtx: any)
	local m: any = c.materials[1]
	local twoside = c.lightModelTwoSide

	local n = vtx.normal

	local R = m.emission[1] + m.ambient[1] * c.ambientLightModel[1]
	local G = m.emission[2] + m.ambient[2] * c.ambientLightModel[2]
	local B = m.emission[3] + m.ambient[3] * c.ambientLightModel[3]
	local A = clampf(m.diffuse[4], 0, 1)

	local l: any = c.firstLight
	while l ~= nil do
		-- ambient
		local lR = l.ambient[1] * m.ambient[1]
		local lG = l.ambient[2] * m.ambient[2]
		local lB = l.ambient[3] * m.ambient[3]

		local dX, dY, dZ, att

		if l.position[4] == 0 then
			-- light at infinity
			dX = l.normPosition[1]
			dY = l.normPosition[2]
			dZ = l.normPosition[3]
			att = 1
		else
			-- distance attenuation
			dX = l.position[1] - vtx.ec[1]
			dY = l.position[2] - vtx.ec[2]
			dZ = l.position[3] - vtx.ec[3]
			local dist = math.sqrt(dX * dX + dY * dY + dZ * dZ)
			if dist > 1e-10 then
				local tmp = 1 / dist
				dX *= tmp
				dY *= tmp
				dZ *= tmp
			end
			att = 1.0 / (l.attenuation[1] + dist * (l.attenuation[2] + dist * l.attenuation[3]))
		end

		local dot = dX * n[1] + dY * n[2] + dZ * n[3]
		if twoside ~= 0 and dot < 0 then
			dot = -dot
		end

		-- `contribute` stands for C's `continue`: when the spot light misses, that
		-- light adds nothing at all, not even its ambient term.
		local contribute = true

		if dot > 0 then
			-- diffuse light
			lR += dot * l.diffuse[1] * m.diffuse[1]
			lG += dot * l.diffuse[2] * m.diffuse[2]
			lB += dot * l.diffuse[3] * m.diffuse[3]

			-- spot light
			if l.spotCutoff ~= 180 then
				local dot_spot = -(dX * l.normSpotDirection[1] + dY * l.normSpotDirection[2] + dZ * l.normSpotDirection[3])
				if twoside ~= 0 and dot_spot < 0 then
					dot_spot = -dot_spot
				end
				if dot_spot < l.cosSpotCutoff then
					-- no contribution
					contribute = false
				elseif l.spotExponent > 0 then
					-- TODO: optimize (TinyGL's own comment)
					att = att * (dot_spot ^ l.spotExponent)
				end
			end

			if contribute then
				-- specular light
				local sX, sY, sZ
				if c.localLightModel ~= 0 then
					local vX, vY, vZ = vtx.ec[1], vtx.ec[2], vtx.ec[3]
					local nn = math.sqrt(vX * vX + vY * vY + vZ * vZ)
					if nn ~= 0 then
						vX, vY, vZ = vX / nn, vY / nn, vZ / nn
					end
					sX = dX - vX
					sY = dY - vX -- upstream TinyGL uses vcoord.X here as well
					sZ = dZ - vX -- upstream TinyGL uses vcoord.X here as well
				else
					sX = dX
					sY = dY
					sZ = dZ + 1.0
				end

				local dot_spec = n[1] * sX + n[2] * sY + n[3] * sZ
				if twoside ~= 0 and dot_spec < 0 then
					dot_spec = -dot_spec
				end

				if dot_spec > 0 then
					local tmp = math.sqrt(sX * sX + sY * sY + sZ * sZ)
					if tmp > 1e-3 then
						dot_spec = dot_spec / tmp
					end
					local specbuf = SpecBuf.specbuf_get_buffer(c, m.shininess_i, m.shininess)
					local idx = trunc(dot_spec * SPECULAR_BUFFER_SIZE)
					if idx > SPECULAR_BUFFER_SIZE then
						idx = SPECULAR_BUFFER_SIZE
					end
					dot_spec = specbuf.buf[idx + 1]
					lR += dot_spec * l.specular[1] * m.specular[1]
					lG += dot_spec * l.specular[2] * m.specular[2]
					lB += dot_spec * l.specular[3] * m.specular[3]
				end
			end

		end

		if contribute then
			R += att * lR
			G += att * lG
			B += att * lB
		end

		l = l.next
	end

	vtx.color[1] = clampf(R, 0, 1)
	vtx.color[2] = clampf(G, 0, 1)
	vtx.color[3] = clampf(B, 0, 1)
	vtx.color[4] = A
end

--- A fresh GLLight, with the defaults glInit() installs.
function Light.newLight(): any
	return {
		ambient = { 0, 0, 0, 1 },
		diffuse = { 1, 1, 1, 1 },
		specular = { 1, 1, 1, 1 },
		position = { 0, 0, 1, 0 },
		normPosition = { 0, 0, 1 },
		spotDirection = { 0, 0, -1 },
		normSpotDirection = { 0, 0, -1 },
		spotExponent = 0,
		spotCutoff = 180,
		attenuation = { 1, 0, 0 },
		-- precomputed
		cosSpotCutoff = 0,
		enabled = 0,
		next = nil,
		prev = nil,
	}
end

--- A fresh GLMaterial with glInit()'s defaults.
function Light.newMaterial(): any
	return {
		emission = { 0, 0, 0, 1 },
		ambient = { 0.2, 0.2, 0.2, 1 },
		diffuse = { 0.8, 0.8, 0.8, 1 },
		specular = { 0, 0, 0, 1 },
		shininess = 0,
		shininess_i = 0,
		do_specular = 0,
	}
end

return Light
