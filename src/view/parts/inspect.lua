-- A cell's whole value, over the page: JSON set out and coloured, anything else as it is, with a way
-- to copy it. Escape or a click outside closes it.

local kit = require("../lib/kit")
local b, S = kit.b, kit.S

local M = {}

M.CARD = "inspect"
M.SHADE = "inspect-shade"
M.COPY = "inspect-copy"
M.CLOSE = "inspect-close"

-- The value `value`, read as JSON, set out a level a line: the parts of a rich text, one line each.
local function pretty(value, indent, lines, current, key)
	local pad = string.rep("  ", indent)
	local function push(parts)
		lines[#lines + 1] = parts
	end
	local head = { b.span(pad) }
	if key then
		head[#head + 1] = b.span('"' .. key .. '"'):color("accent")
		head[#head + 1] = b.span(": ")
	end
	local kind = type(value)
	if kind == "table" then
		local is_array = #value > 0 or next(value) == nil
		local open, close = is_array and "[" or "{", is_array and "]" or "}"
		head[#head + 1] = b.span(open)
		push(head)
		local keys = {}
		if is_array then
			for index = 1, #value do
				keys[#keys + 1] = index
			end
		else
			for name in value do
				keys[#keys + 1] = name
			end
			table.sort(keys, function(x, y)
				return tostring(x) < tostring(y)
			end)
		end
		for _, name in keys do
			pretty(value[name], indent + 1, lines, nil, (not is_array) and tostring(name) or nil)
		end
		push({ b.span(pad .. close) })
		return
	end
	if kind == "string" then
		head[#head + 1] = b.span('"' .. value .. '"'):color("success")
	elseif kind == "number" then
		head[#head + 1] = b.span(tostring(value)):color("warning")
	elseif kind == "boolean" then
		head[#head + 1] = b.span(tostring(value)):color("magenta")
	else
		head[#head + 1] = b.span("null"):color("magenta")
	end
	push(head)
end

-- The value as lines of looks: JSON coloured, or nil where it is not JSON.
local function json_lines(value)
	local first = string.match(value, "^%s*(.)")
	if first ~= "{" and first ~= "[" then
		return nil
	end
	local ok, decoded = pcall(b.json.decode, value)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local lines = {}
	pretty(decoded, 0, lines)
	return lines
end

function M.view(width, height)
	local open = S.inspect
	local body = b.div():id("inspect-body"):col():grow(1):min_h(0):scroll():p(14):family("terminal"):text_size(12)
	if open.loading then
		body:child(b.text("Reading the value…"):color("dim"))
	elseif open.value == nil then
		body:child(b.text("NULL"):italic():color("quiet"))
	else
		local lines = json_lines(open.value)
		if lines and #lines <= 4000 then
			for _, parts in lines do
				body:child(b.rich(parts))
			end
		else
			body:child(b.text(open.value):wrap())
		end
	end
	local title = b.div()
		:row()
		:items_center()
		:gap(10)
		:h(44)
		:px(14)
		:no_shrink()
		:child(b.text(open.name or "Value"):weight(700))
		:child(b.text(open.type or ""):color("quiet"):text_size(11))
		:child(b.spacer())
		:child(kit.button(M.COPY, "Copy", { icon = "copy", keys = "cmd+c", compact = true }))
		:child(kit.button(M.CLOSE, "", { icon = "x", label = "Close", keys = "escape", compact = true, px = 7 }))
	local card = b.div()
		:press(M.CARD)
		:col()
		:w(math.min(720, width - 48))
		:max_h(math.max(height - 80, 160))
		:rounded(10)
		:bg("raised2")
		:border(1, "border")
		:shadow(0, 12, 32, b.alpha("shadow", 0.45))
		:motion({ enter = { opacity = 0, dy = 8, seconds = 0.16 }, exit = { opacity = 0, dy = 4, seconds = 0.1 } })
		:child(title)
		:child(kit.rule_x())
		:child(body)
	return b.div()
		:press(M.SHADE)
		:overlay()
		:inset(0, 0, 0, 0)
		:bg(b.alpha("shadow", 0.32))
		:items_center()
		:justify_center()
		:id(M.SHADE)
		:child(card)
end

return M
