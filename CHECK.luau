--!nocheck
-- CHECK.luau -- Helper module for enabling use of literal values for performance

--[[ Usage example

local CHECK = require("./CHECK")()(require("./gl_constants"))
local GL_TEXTURE_MATRIX		= 0xBA8;	CHECK("GL_TEXTURE_MATRIX",		GL_TEXTURE_MATRIX)
local GL_TEXTURE_MIN_FILTER	= 0x2801;	CHECK("GL_TEXTURE_MIN_FILTER",	GL_TEXTURE_MIN_FILTER)
local GL_TEXTURE_WRAP_S		= 0x2802;	CHECK("GL_TEXTURE_WRAP_S",		GL_TEXTURE_WRAP_S)
local GL_TEXTURE_WRAP_T		= 0x2803;	CHECK("GL_TEXTURE_WRAP_T",		GL_TEXTURE_WRAP_T)

Formatting as such does the following:
- The first function call clears any previously-held profile.
- The 2nd function call accepts a frozen table.
- Writing each CHECK call on the same line as the literal declaration keeps things together.

]]

local profile
local CHECK

CHECK = function(data, value)
    -- Invalid arguments
    if data == nil and value ~= nil then
        error(`CHECK: Invalid arguments provided`)
    end

    -- Profile not installed
    if not profile then
        -- Do nothing
        if data == nil and value == nil then
            return CHECK
        end

        -- Install profile
        assert(type(data) == "table", `CHECK: Table must be provided for installing profile`)
        assert(table.isfrozen(data), `CHECK: Provided table must be frozen to ensure accurate validation`)
        assert(value == nil, `CHECK: 2nd argument provided whilst installing profile`)
        profile = data
        return CHECK
    end

    -- Profile is installed
    if profile then
        -- No data provided
        if data == nil then
            profile = nil
            return CHECK
        end

        -- Checking: Block 'nil' values
        assert(value ~= nil, `CHECK: 'nil' provided for 2nd argument when checking against profile`)

        -- Checking: Perform check.
        assert(profile[data] == value, `CHECK: {data} from {profile} is {profile[data]}, provided value was {value}`)
        return CHECK
    end

    return CHECK
end

return CHECK