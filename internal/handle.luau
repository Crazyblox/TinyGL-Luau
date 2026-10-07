--!strict
--[[
	handle.luau — a tiny "pointer" registry.

	TinyGL's C API passes client arrays and texture images around as `void *`
	inside the `GLParam` op stream, which is fine for C but meaningless (and
	unsafe) to store in a compiled display list in Luau.  So every host object
	(a Luau `buffer`, a table of numbers, a function, ...) handed to the API is
	put in a per context registry and only its integer id travels through the op
	stream / display lists.
]]

local Handle = {}

--- Register `value` and return the id to put in an opcode.
function Handle.alloc(c: any, value: any): number
	if c.pointerFree == nil then
		c.pointerFree = {}
	end
	local id = c.nextPointerId
	c.nextPointerId += 1
	c.pointerTable[id] = value
	return id
end

--- Fetch the object behind an id.
function Handle.get(c: any, id: number): any
	return c.pointerTable[id]
end

--- Release an id (optional; ids are cheap).
function Handle.free(c: any, id: number)
	c.pointerTable[id] = nil
	table.insert(c.pointerFree, id)
end

function Handle.init(c: any)
	c.pointerTable = {}
	c.pointerFree = {}
	c.nextPointerId = 1
end

return Handle
