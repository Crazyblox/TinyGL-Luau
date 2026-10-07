--!strict
--[[
	zmath.luau — port of TinyGL's src/zmath.c / src/zmath.h.

	Vector and 4x4 matrix maths.

	Layout notes (important, the whole port relies on these):

	* V3 / V4 are arrays of 3 / 4 numbers.  `a[1]` is C's `a.X` (a.v[0]),
	  `a[4]` is C's `a.W`.
	* M4 is an array of four row arrays: `m[i][j]` is C's `m->m[i-1][j-1]`.
	  C's flattened pointer arithmetic (`float *m = &matrix.m[0][0]; m[5]` etc.)
	  maps to `m[1 + (i // 4)][1 + (i % 4)]`.
	* Because tables are references in Luau, every C statement that *copies* a
	  struct must use the explicit copy helpers below (gl_M4_Move,
	  gl_MoveV3, v4Copy, ...) instead of `=`.
]]

local ZMath = {}

-- (Luau array types are written { T }; the element counts below are documentation)
export type V3 = { number } -- 3 elements
export type V4 = { number } -- 4 elements
export type M4Row = { number } -- 4 elements
export type M4 = { { number } } -- 4 rows x 4 columns

function ZMath.v3New(x: number, y: number, z: number): V3
	return { x, y, z }
end

function ZMath.v4New(x: number, y: number, z: number, w: number): V4
	return { x, y, z, w }
end

function ZMath.v3Copy(a: V3, b: { number })
	a[1] = b[1]
	a[2] = b[2]
	a[3] = b[3]
end

function ZMath.v4Copy(a: V4, b: { number })
	a[1] = b[1]
	a[2] = b[2]
	a[3] = b[3]
	a[4] = b[4]
end

--- Fresh 4x4 matrix, all zeroes (what gl_zalloc gives you before glLoadIdentity).
function ZMath.m4New(): M4
	return { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
end

--- Fresh 4x4 identity matrix.
function ZMath.m4Identity(): M4
	return { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
end

function ZMath.gl_M4_Id(a: M4)
	for i = 1, 4 do
		local row = a[i]
		for j = 1, 4 do
			if i == j then
				row[j] = 1
			else
				row[j] = 0
			end
		end
	end
end

function ZMath.gl_M4_IsId(a: M4): boolean
	for i = 1, 4 do
		local row = a[i]
		for j = 1, 4 do
			if i == j then
				if row[j] ~= 1 then
					return false
				end
			elseif row[j] ~= 0 then
				return false
			end
		end
	end
	return true
end

--- a = b (C: memcpy(a, b, sizeof(M4)))
function ZMath.gl_M4_Move(a: M4, b: M4)
	for i = 1, 4 do
		local from = b[i]
		local to = a[i]
		to[1] = from[1]
		to[2] = from[2]
		to[3] = from[3]
		to[4] = from[4]
	end
end

function ZMath.gl_MoveV3(a: V3, b: V3)
	a[1] = b[1]
	a[2] = b[2]
	a[3] = b[3]
end

--- a = b * c, treating c as a point (w = 1, so the translation column is added)
function ZMath.gl_MulM4V3(a: V3, b: M4, c: V3)
	local cx, cy, cz = c[1], c[2], c[3]
	local b0, b1, b2 = b[1], b[2], b[3]
	a[1] = b0[1] * cx + b0[2] * cy + b0[3] * cz + b0[4]
	a[2] = b1[1] * cx + b1[2] * cy + b1[3] * cz + b1[4]
	a[3] = b2[1] * cx + b2[2] * cy + b2[3] * cz + b2[4]
end

--- a = b * c, treating c as a direction (no translation column)
function ZMath.gl_MulM3V3(a: V3, b: M4, c: V3)
	local cx, cy, cz = c[1], c[2], c[3]
	local b0, b1, b2 = b[1], b[2], b[3]
	a[1] = b0[1] * cx + b0[2] * cy + b0[3] * cz
	a[2] = b1[1] * cx + b1[2] * cy + b1[3] * cz
	a[3] = b2[1] * cx + b2[2] * cy + b2[3] * cz
end

function ZMath.gl_M4_MulV4(a: V4, b: M4, c: V4)
	local cx, cy, cz, cw = c[1], c[2], c[3], c[4]
	local b0, b1, b2, b3 = b[1], b[2], b[3], b[4]
	a[1] = b0[1] * cx + b0[2] * cy + b0[3] * cz + b0[4] * cw
	a[2] = b1[1] * cx + b1[2] * cy + b1[3] * cz + b1[4] * cw
	a[3] = b2[1] * cx + b2[2] * cy + b2[3] * cz + b2[4] * cw
	a[4] = b3[1] * cx + b3[2] * cy + b3[3] * cz + b3[4] * cw
end

--- transposition of a 4x4 matrix
function ZMath.gl_M4_Transpose(a: M4, b: M4)
	for i = 1, 4 do
		local row = a[i]
		for j = 1, 4 do
			row[j] = b[j][i]
		end
	end
end

--- inversion of an orthogonal matrix of type Y = M.X + P
function ZMath.gl_M4_InvOrtho(a: M4, b: M4)
	for i = 1, 3 do
		local row = a[i]
		for j = 1, 3 do
			row[j] = b[j][i]
		end
	end
	a[4][1] = 0
	a[4][2] = 0
	a[4][3] = 0
	a[4][4] = 1
	for i = 1, 3 do
		local s = 0.0
		for j = 1, 3 do
			s = s - b[j][i] * b[j][4]
		end
		a[i][4] = s
	end
end

--- c = a * b
function ZMath.gl_M4_Mul(c: M4, a: M4, b: M4)
	for i = 1, 4 do
		local ai = a[i]
		local a1, a2, a3, a4 = ai[1], ai[2], ai[3], ai[4]
		local ci = c[i]
		for j = 1, 4 do
			-- C accumulates into a `float s`; here it is a double throughout
			local s = a1 * b[1][j] + a2 * b[2][j] + a3 * b[3][j] + a4 * b[4][j]
			ci[j] = s
		end
	end
end

--- c = c * b
function ZMath.gl_M4_MulLeft(c: M4, b: M4)
	for i = 1, 4 do
		local ci = c[i]
		local a1, a2, a3, a4 = ci[1], ci[2], ci[3], ci[4]
		for j = 1, 4 do
			local s = a1 * b[1][j] + a2 * b[2][j] + a3 * b[3][j] + a4 * b[4][j]
			ci[j] = s
		end
	end
end

--[[
	Inversion of a general n x n matrix.  Note that, as in the C version, `m`
	is destroyed.  Straight translation of Matrix_Inv() (Gauss-Jordan with
	partial pivoting), operating on nested rows.
]]
function ZMath.Matrix_Inv(r: { { number } }, m: { { number } }, n: number): number
	local max: number
	local tmp: number

	-- identity in r
	for i = 1, n do
		local ri = r[i]
		for j = 1, n do
			ri[j] = if i == j then 1 else 0
		end
	end

	for j = 1, n do
		-- search for the number with the biggest module in column j
		max = m[j][j]
		local k = j
		for i = j + 1, n do
			if math.abs(m[i][j]) > math.abs(max) then
				k = i
				max = m[i][j]
			end
		end

		-- non invertible matrix
		if max == 0 then
			return 1
		end

		-- swap lines j and k
		if k ~= j then
			for i = 1, n do
				tmp = m[j][i]
				m[j][i] = m[k][i]
				m[k][i] = tmp

				tmp = r[j][i]
				r[j][i] = r[k][i]
				r[k][i] = tmp
			end
		end

		-- multiply line j by 1/max
		max = 1 / max
		for i = 1, n do
			m[j][i] = m[j][i] * max
			r[j][i] = r[j][i] * max
		end

		for l = 1, n do
			if l ~= j then
				local t = m[l][j]
				for i = 1, n do
					m[l][i] = m[l][i] - m[j][i] * t
					r[l][i] = r[l][i] - r[j][i] * t
				end
			end
		end
	end

	return 0
end

local scratchInv: { { number } }? = nil
local scratchInvSrc: { { number } }? = nil

local function invScratch(n: number): ({ { number } }, { { number } })
	local oldR, oldM = scratchInv, scratchInvSrc
	if oldR ~= nil and oldM ~= nil and #oldR == n then
		return oldR, oldM
	end
	local r = table.create(n) :: { { number } }
	local m = table.create(n) :: { { number } }
	for i = 1, n do
		r[i] = table.create(n) :: { number }
		m[i] = table.create(n) :: { number }
	end
	scratchInv = r
	scratchInvSrc = m
	return r, m
end

--- inversion of a 4x4 matrix.  In C this memcpy()s b into a temporary first
--- because Matrix_Inv destroys its input; we copy the same way.
function ZMath.gl_M4_Inv(a: M4, b: M4)
	local r, m = invScratch(4)
	for i = 1, 4 do
		local bi, mi = b[i], m[i]
		for j = 1, 4 do
			mi[j] = bi[j]
		end
	end
	ZMath.Matrix_Inv(r, m, 4)
	for i = 1, 4 do
		local ri, ai = r[i], a[i]
		for j = 1, 4 do
			ai[j] = ri[j]
		end
	end
end

--- build in `a` a rotation of `t` radians around axis `u` (0=x, 1=y, 2=z)
function ZMath.gl_M4_Rotate(a: M4, t: number, u: number)
	-- C calls libm's double sin()/cos() and stores the results into floats;
	-- Luau's numbers are doubles, so the sin/cos results are kept as they are
	local s, c = math.sin(t), math.cos(t)
	-- exactly as in C: v and w are 0 based axis numbers derived from u by
	-- wrapping (u=0 -> v=1,w=2 / u=1 -> v=2,w=0 / u=2 -> v=0,w=1)
	local v = u + 1
	if v > 2 then
		v = 0
	end
	local w = v + 1
	if w > 2 then
		w = 0
	end
	ZMath.gl_M4_Id(a)
	-- a->m[v][v] = c ... in the 1 based nested representation
	local vv, ww = v + 1, w + 1
	a[vv][vv] = c
	a[vv][ww] = -s
	a[ww][vv] = s
	a[ww][ww] = c
end

--- inversion of a 3x3 matrix (present in zmath.c, unused by TinyGL)
function ZMath.gl_M3_Inv(a: { { number } }, m: { { number } })
	local function detOf(): number
		local d = m[1][1] * m[2][2] * m[3][3] - m[1][1] * m[2][3] * m[3][2]
		d = d - m[2][1] * m[1][2] * m[3][3]
		d = d + m[2][1] * m[1][3] * m[3][2]
		d = d + m[3][1] * m[1][2] * m[2][3]
		d = d - m[3][1] * m[1][3] * m[2][2]
		return d
	end
	local det = detOf()

	a[1][1] = (m[2][2] * m[3][3] - m[2][3] * m[3][2]) / det
	a[1][2] = -(m[1][2] * m[3][3] - m[1][3] * m[3][2]) / det
	a[1][3] = (m[1][2] * m[2][3] - m[1][3] * m[2][2]) / det

	a[2][1] = -(m[2][1] * m[3][3] - m[2][3] * m[3][1]) / det
	a[2][2] = (m[1][1] * m[3][3] - m[1][3] * m[3][1]) / det
	a[2][3] = -(m[1][1] * m[2][3] - m[1][3] * m[2][1]) / det

	a[3][1] = (m[2][1] * m[3][2] - m[2][2] * m[3][1]) / det
	a[3][2] = -(m[1][1] * m[3][2] - m[1][2] * m[3][1]) / det
	a[3][3] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det
end

--- normalise in place; returns 1 when the vector has zero length (and leaves
--- it untouched), 0 on success — same contract as gl_V3_Norm().
function ZMath.gl_V3_Norm(a: V3): number
	local n = math.sqrt(a[1] * a[1] + a[2] * a[2] + a[3] * a[3])
	if n == 0 then
		return 1
	end
	a[1] = a[1] / n
	a[2] = a[2] / n
	a[3] = a[3] / n
	return 0
end

--- flatten a nested 4x4 into 16 consecutive values, row major (C: `&m[0][0]`)
function ZMath.m4FlatRow(m: M4, i: number): number
	return m[1 + (i // 4)][1 + (i % 4)]
end

function ZMath.m4FlatSetRow(m: M4, i: number, v: number)
	m[1 + (i // 4)][1 + (i % 4)] = v
end

return ZMath
