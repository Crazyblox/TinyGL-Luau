--!strict
--[[
	msghandling.luau — port of TinyGL's src/msghandling.c/.h.

	C builds TinyGL with NDEBUG defined, so tgl_warning/tgl_trace/tgl_fixme are
	compiled out there.  Here they are gated by `MSH.enabled` (default off, same
	behaviour as the C build) and go through `MSH.output`, which defaults to
	`print` because `io` is not available in every Luau host.  Set them from the
	host application to plug into its own logging.
]]

-- (typed as any so the annotated fields below are simple to write)
local MSH: any = {}

MSH.enabled = false
-- host supplied sink; C writes to stderr
MSH.output = print

-- one argument, like C's tgl_warning("... %d", x) after the formatting
local function emit(msg: string)
	if MSH.enabled then
		MSH.output(msg)
	end
end

--- tgl_warning
function MSH.warning(fmt: string, ...)
	emit("*WARNING* " .. (if select("#", ...) > 0 then (fmt):format(...) else fmt))
end

--- tgl_trace
function MSH.trace(fmt: string, ...)
	emit("*DEBUG* " .. (if select("#", ...) > 0 then (fmt):format(...) else fmt))
end

--- tgl_fixme
function MSH.fixme(fmt: string, ...)
	emit("*FIXME* " .. (if select("#", ...) > 0 then (fmt):format(...) else fmt))
end

return MSH
