--!strict
--[[
	ztriangle.luau — port of TinyGL's src/ztriangle.c / src/ztriangle.h.

	All four fillers (flat, smooth/gouraud, textured, textured + perspective
	corrected) share the half-space edge walker of ztriangle.h; C generated them
	by including that file four times with different INTERP_*/PUT_PIXEL/DRAW_LINE
	macros, here they are one function parameterised by `mode`.

	Interpolant sets (exactly like the C #ifdefs):
	  FLAT                 INTERP_Z
	  SMOOTH               INTERP_Z + INTERP_RGB
	  MAPPING              INTERP_Z + INTERP_ST
	  MAPPING_PERSPECTIVE  INTERP_Z + INTERP_STZ

	Deliberate differences from C, all in the "more exact, less clever"
	direction (this port optimises for correctness, speed can come later):

	* The 4x (and, for textures, 8x) unrolled per-scanline writes of ztriangle.h
	  are folded into plain loops; the increments are linear so the pixels are
	  identical.
	* Texture fetches are range checked and wrap (mod the texture size) instead
	  of reading outside the pixmap, which is what GL_REPEAT means anyway.
	  TinyGL's masked index computation already relies on that wrapping.

	Everything else, including the very tricky packed 16 bit RGB accumulator of
	ZB_fillTriangleSmooth, is reproduced operation by operation so this port can
	be pixel-compared against a C build of TinyGL.
]]

local Config = require("./config")
local Util = require("./util")

local buffer = buffer --[[(standard library)]]
local band, bor = bit32.band, bit32.bor
local asr, trunc, idiv, shl, u32 = Util.asr, Util.trunc, Util.idiv, Util.shl, Util.u32

local ZTriangle = {}

ZTriangle.FLAT = 1
ZTriangle.SMOOTH = 2
ZTriangle.MAPPING = 3
ZTriangle.MAPPING_PERSPECTIVE = 4

local ZB_POINT_Z_FRAC_BITS = Config.ZB_POINT_Z_FRAC_BITS
local PSZB = Config.PSZB
local NB_INTERP = 8 -- ztriangle.c's ZB_fillTriangleMappingPerspective

--- RGB_TO_PIXEL from zbuffer.h, blue term unmasked exactly as in C (see the
--- comment in zbuffer.luau)
local function RGB_TO_PIXEL(r: number, g: number, b: number): number
	return bor(bor(band(r, 0xF800), band(asr(g, 5), 0x07E0)), asr(b, 11))
end

--- ztriangle.h's `(x << 16) / dy` (integer arithmetic, truncating)
local function slope16(dx: number, dy: number): number
	if dy > 0 then
		return idiv(shl(dx, 16), dy)
	else
		return 0
	end
end

--[[
	Fill one triangle.

	zb       : the ZBuffer
	p0,p1,p2 : ZBufferPoint records (see zbuffer.luau); they are *not* modified
	           except for the sz/tz scratch fields used by the perspective
	           correct interpolator, which C also writes into them.
	mode     : one of FLAT / SMOOTH / MAPPING / MAPPING_PERSPECTIVE
]]
function ZTriangle.fillTriangle(zb: any, pa: any, pb: any, pc: any, mode: number)
	local p0, p1, p2 = pa, pb, pc

	-- we sort the vertex with increasing y
	if p1.y < p0.y then
		p0, p1 = p1, p0
	end
	if p2.y < p0.y then
		p0, p1, p2 = p2, p0, p1
	elseif p2.y < p1.y then
		p1, p2 = p2, p1
	end

	-- we compute dXdx and dXdy for all interpolated values
	local fdx1 = p1.x - p0.x
	local fdy1 = p1.y - p0.y

	local fdx2 = p2.x - p0.x
	local fdy2 = p2.y - p0.y

	local fz = fdx1 * fdy2 - fdx2 * fdy1
	if fz == 0 then
		return
	end
	fz = 1.0 / fz

	fdx1 *= fz
	fdy1 *= fz
	fdx2 *= fz
	fdy2 *= fz

	-- INTERP_Z
	local d1 = p1.z - p0.z
	local d2 = p2.z - p0.z
	local dzdx = trunc(fdy2 * d1 - fdy1 * d2)
	local dzdy = trunc(fdx1 * d2 - fdx2 * d1)

	-- INTERP_RGB
	local r1, g1, b1 = 0, 0, 0
	local drdx, drdy, dgdx, dgdy, dbdx, dbdy = 0, 0, 0, 0, 0, 0
	if mode == ZTriangle.SMOOTH then
		d1 = p1.r - p0.r
		d2 = p2.r - p0.r
		drdx = trunc(fdy2 * d1 - fdy1 * d2)
		drdy = trunc(fdx1 * d2 - fdx2 * d1)

		d1 = p1.g - p0.g
		d2 = p2.g - p0.g
		dgdx = trunc(fdy2 * d1 - fdy1 * d2)
		dgdy = trunc(fdx1 * d2 - fdx2 * d1)

		d1 = p1.b - p0.b
		d2 = p2.b - p0.b
		dbdx = trunc(fdy2 * d1 - fdy1 * d2)
		dbdy = trunc(fdx1 * d2 - fdx2 * d1)
	end

	-- INTERP_ST
	local s1, t1 = 0, 0
	local dsdx, dsdy, dtdx, dtdy = 0, 0, 0, 0
	if mode == ZTriangle.MAPPING then
		d1 = p1.s - p0.s
		d2 = p2.s - p0.s
		dsdx = trunc(fdy2 * d1 - fdy1 * d2)
		dsdy = trunc(fdx1 * d2 - fdx2 * d1)

		d1 = p1.t - p0.t
		d2 = p2.t - p0.t
		dtdx = trunc(fdy2 * d1 - fdy1 * d2)
		dtdy = trunc(fdx1 * d2 - fdx2 * d1)
	end

	-- INTERP_STZ
	local sz1, tz1 = 0.0, 0.0
	local dszdx, dszdy, dtzdx, dtzdy = 0.0, 0.0, 0.0, 0.0
	if mode == ZTriangle.MAPPING_PERSPECTIVE then
		local zz = p0.z
		p0.sz = p0.s * zz
		p0.tz = p0.t * zz
		zz = p1.z
		p1.sz = p1.s * zz
		p1.tz = p1.t * zz
		zz = p2.z
		p2.sz = p2.s * zz
		p2.tz = p2.t * zz

		d1 = p1.sz - p0.sz
		d2 = p2.sz - p0.sz
		dszdx = fdy2 * d1 - fdy1 * d2
		dszdy = fdx1 * d2 - fdx2 * d1

		d1 = p1.tz - p0.tz
		d2 = p2.tz - p0.tz
		dtzdx = fdy2 * d1 - fdy1 * d2
		dtzdy = fdx1 * d2 - fdx2 * d1
	end

	-- screen coordinates
	local pbaseLine = p0.y * zb.linesize -- pixel index of the start of the line
	local zbaseLine = p0.y * zb.xsize -- depth buffer entry of the start of the line

	-- DRAW_INIT()
	local color = 0
	if mode == ZTriangle.FLAT then
		color = RGB_TO_PIXEL(p2.r, p2.g, p2.b)
	end

	-- ZB_fillTriangleSmooth's DRAW_INIT(): the packed per-pixel colour step. The
	-- SAR_RND_TO_ZERO() of C is a plain integer division, i.e. it truncates the
	-- negative steps towards zero rather than flooring them.
	local _drgbdx = 0
	if mode == ZTriangle.SMOOTH then
		_drgbdx = bor(
			band(u32(shl(idiv(drdx, 64), 22)), 0xFFC00000),
			band(idiv(dgdx, 32), 0x000007FF),
			band(u32(shl(idiv(dbdx, 128), 12)), 0x001FF000)
		)
	end

	local texture: buffer? = nil
	local texSize = 0
	local fdzdx, fndzdx, ndszdx, ndtzdx = 0.0, 0.0, 0.0, 0.0
	if mode == ZTriangle.MAPPING or mode == ZTriangle.MAPPING_PERSPECTIVE then
		texture = zb.currentTexture
		if texture == nil then
			return
		end
		texSize = buffer.len(texture)
		if mode == ZTriangle.MAPPING_PERSPECTIVE then
			fdzdx = dzdx
			fndzdx = NB_INTERP * fdzdx
			ndszdx = NB_INTERP * dszdx
			ndtzdx = NB_INTERP * dtzdx
		end
	end

	-- state that, as in C, lives in the enclosing function scope and therefore
	-- carries over between the two half-triangle parts
	local x1, error, derror, dxdy_min, dxdy_max = 0, 0, 0, 0, 0
	local z1 = 0
	local dzdl_min, dzdl_max = 0, 0
	local drdl_min, drdl_max, dgdl_min, dgdl_max, dbdl_min, dbdl_max = 0, 0, 0, 0, 0, 0
	local dsdl_min, dsdl_max, dtdl_min, dtdl_max = 0, 0, 0, 0
	local dtzdl_min, dtzdl_max, dszdl_min, dszdl_max = 0.0, 0.0, 0.0, 0.0
	local x2, dx2dy2 = 0, 0

	for part = 0, 1 do
		local update_left: number
		local update_right: number
		local l1, l2, pr1, pr2 = p0, p0, p0, p0
		local nb_lines: number

		if part == 0 then
			if fz > 0 then
				update_left = 1
				update_right = 1
				l1 = p0
				l2 = p2
				pr1 = p0
				pr2 = p1
			else
				update_left = 1
				update_right = 1
				l1 = p0
				l2 = p1
				pr1 = p0
				pr2 = p2
			end
			nb_lines = p1.y - p0.y
		else
			-- second part
			if fz > 0 then
				update_left = 0
				update_right = 1
				pr1 = p1
				pr2 = p2
			else
				update_left = 1
				update_right = 0
				l1 = p1
				l2 = p2
			end
			nb_lines = p2.y - p1.y + 1
		end

		-- compute the values for the left edge
		if update_left == 1 then
			local dy1 = l2.y - l1.y
			local dx1 = l2.x - l1.x
			local tmp = slope16(dx1, dy1)
			x1 = l1.x
			error = 0
			derror = band(tmp, 0x0000ffff)
			dxdy_min = asr(tmp, 16)
			dxdy_max = dxdy_min + 1

			z1 = l1.z
			dzdl_min = dzdy + dzdx * dxdy_min
			dzdl_max = dzdl_min + dzdx

			if mode == ZTriangle.SMOOTH then
				r1 = l1.r
				drdl_min = drdy + drdx * dxdy_min
				drdl_max = drdl_min + drdx

				g1 = l1.g
				dgdl_min = dgdy + dgdx * dxdy_min
				dgdl_max = dgdl_min + dgdx

				b1 = l1.b
				dbdl_min = dbdy + dbdx * dxdy_min
				dbdl_max = dbdl_min + dbdx
			end

			if mode == ZTriangle.MAPPING then
				s1 = l1.s
				dsdl_min = dsdy + dsdx * dxdy_min
				dsdl_max = dsdl_min + dsdx

				t1 = l1.t
				dtdl_min = dtdy + dtdx * dxdy_min
				dtdl_max = dtdl_min + dtdx
			end

			if mode == ZTriangle.MAPPING_PERSPECTIVE then
				sz1 = l1.sz
				dszdl_min = dszdy + dszdx * dxdy_min
				dszdl_max = dszdl_min + dszdx

				tz1 = l1.tz
				dtzdl_min = dtzdy + dtzdx * dxdy_min
				dtzdl_max = dtzdl_min + dtzdx
			end
		end

		-- compute values for the right edge
		if update_right == 1 then
			local dx2 = pr2.x - pr1.x
			local dy2 = pr2.y - pr1.y
			dx2dy2 = slope16(dx2, dy2)
			x2 = shl(pr1.x, 16)
		end

		-- we draw all the scan lines of the part
		while nb_lines > 0 do
			nb_lines -= 1

			local n = asr(x2, 16) - x1
			local pofs = (pbaseLine + x1) * PSZB
			local zofs = (zbaseLine + x1) * 2

			local z = z1
			local ss, tt = s1, t1

			if n >= 0 then
				if mode == ZTriangle.FLAT then
					while n >= 0 do
						local zz = asr(z, ZB_POINT_Z_FRAC_BITS)
						if zz >= buffer.readu16(zb.zbuf, zofs) then
							buffer.writeu16(zb.pbuf, pofs, color)
							buffer.writeu16(zb.zbuf, zofs, zz)
						end
						z += dzdx
						n -= 1
						pofs += PSZB
						zofs += 2
					end
				elseif mode == ZTriangle.SMOOTH then
					--[[
						ZB_fillTriangleSmooth's DRAW_LINE(): the three colour channels
						are packed into one 32 bit accumulator:
						  bits 22..30  red   (11 bits of the 16 bit scale)
						  bits 12..20  blue   (9 bits, pre-scaled by 32)
						  bits  0..10  green  (11 bits, pre-shifted by 5)
						and bits 11/21 (the guard bits, 0x00200800) are cleared after
						every addition so a channel can never carry into its neighbour.
						The pixel is then `tmp & 0xF81F07E0` folded in half, which is
						how the 5R6G5B value falls out of the two halves.
						Note that the accumulator advances on *every* pixel, whether the
						depth test passed or not, exactly like C.
					]]
					local rgb = bor(
						band(u32(shl(r1, 16)), 0xFFC00000),
						band(asr(g1, 5), 0x000007FF),
						band(u32(shl(b1, 5)), 0x001FF000)
					)
					local drgbdx = _drgbdx
					while n >= 0 do
						local zz = asr(z, ZB_POINT_Z_FRAC_BITS)
						if zz >= buffer.readu16(zb.zbuf, zofs) then
							local tmp = band(rgb, 0xF81F07E0)
							buffer.writeu16(zb.pbuf, pofs, bor(tmp, asr(tmp, 16)))
							buffer.writeu16(zb.zbuf, zofs, zz)
						end
						z += dzdx
						rgb = band(u32(rgb + drgbdx), 0xFFDFF7FF)
						n -= 1
						pofs += PSZB
						zofs += 2
					end
				elseif mode == ZTriangle.MAPPING then
					local tex = texture :: buffer
					while n >= 0 do
						local zz = asr(z, ZB_POINT_Z_FRAC_BITS)
						if zz >= buffer.readu16(zb.zbuf, zofs) then
							-- texture[((t & 0x3FC00000) | s) >> 14]
							local idx = asr(bor(band(tt, 0x3FC00000), ss), 14) * PSZB
							if idx < 0 or idx >= texSize then
								idx = idx % texSize
								if idx < 0 then
									idx += texSize
								end
							end
							buffer.writeu16(zb.pbuf, pofs, buffer.readu16(tex, idx))
							buffer.writeu16(zb.zbuf, zofs, zz)
						end
						z += dzdx
						ss += dsdx
						tt += dtdx
						n -= 1
						pofs += PSZB
						zofs += 2
					end
				else
					-- ZB_fillTriangleMappingPerspective: the texture coordinates are
					-- recomputed every NB_INTERP pixels with one division each.
					local tex = texture :: buffer
					local s, t = 0, 0
					local sz, tz = sz1, tz1
					local fz2: number = z1
					local zinv = 1.0 / fz2

					while n >= NB_INTERP - 1 do
						do
							local sx = sz * zinv
							local tx = tz * zinv
							s = trunc(sx)
							t = trunc(tx)
							dsdx = trunc((dszdx - sx * fdzdx) * zinv)
							dtdx = trunc((dtzdx - tx * fdzdx) * zinv)
							fz2 += fndzdx
							zinv = 1.0 / fz2
						end
						local k = 0
						while k < NB_INTERP do
							local zz = asr(z, ZB_POINT_Z_FRAC_BITS)
							if zz >= buffer.readu16(zb.zbuf, zofs) then
								-- *(PIXEL*)((char*)texture + ((t & 0x3FC00000) | (s & 0x003FC000)) >> (17 - PSZSH))
								local idx = asr(bor(band(t, 0x3FC00000), band(s, 0x003FC000)), 17 - Config.PSZSH)
								if idx < 0 or idx >= texSize then
									idx = idx % texSize
									if idx < 0 then
										idx += texSize
									end
								end
								buffer.writeu16(zb.pbuf, pofs, buffer.readu16(tex, idx))
								buffer.writeu16(zb.zbuf, zofs, zz)
							end
							z += dzdx
							s += dsdx
							t += dtdx
							n -= 1
							pofs += PSZB
							zofs += 2
							k += 1
						end
						sz += ndszdx
						tz += ndtzdx
					end

					do
						local sx = sz * zinv
						local tx = tz * zinv
						s = trunc(sx)
						t = trunc(tx)
						dsdx = trunc((dszdx - sx * fdzdx) * zinv)
						dtdx = trunc((dtzdx - tx * fdzdx) * zinv)
					end

					while n >= 0 do
						local zz = asr(z, ZB_POINT_Z_FRAC_BITS)
						if zz >= buffer.readu16(zb.zbuf, zofs) then
							local idx = asr(bor(band(t, 0x3FC00000), band(s, 0x003FC000)), 17 - Config.PSZSH)
							if idx < 0 or idx >= texSize then
								idx = idx % texSize
								if idx < 0 then
									idx += texSize
								end
							end
							buffer.writeu16(zb.pbuf, pofs, buffer.readu16(tex, idx))
							buffer.writeu16(zb.zbuf, zofs, zz)
						end
						z += dzdx
						s += dsdx
						t += dtdx
						n -= 1
						pofs += PSZB
						zofs += 2
					end
				end
			end

			-- left edge
			error += derror
			if error > 0 then
				error -= 0x10000
				x1 += dxdy_max
				z1 += dzdl_max
				if mode == ZTriangle.SMOOTH then
					r1 += drdl_max
					g1 += dgdl_max
					b1 += dbdl_max
				elseif mode == ZTriangle.MAPPING then
					s1 += dsdl_max
					t1 += dtdl_max
				elseif mode == ZTriangle.MAPPING_PERSPECTIVE then
					sz1 += dszdl_max
					tz1 += dtzdl_max
				end
			else
				x1 += dxdy_min
				z1 += dzdl_min
				if mode == ZTriangle.SMOOTH then
					r1 += drdl_min
					g1 += dgdl_min
					b1 += dbdl_min
				elseif mode == ZTriangle.MAPPING then
					s1 += dsdl_min
					t1 += dtdl_min
				elseif mode == ZTriangle.MAPPING_PERSPECTIVE then
					sz1 += dszdl_min
					tz1 += dtzdl_min
				end
			end

			-- right edge
			x2 += dx2dy2

			-- screen coordinates
			pbaseLine += zb.linesize
			zbaseLine += zb.xsize
		end
	end
end

return ZTriangle
