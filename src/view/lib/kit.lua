-- What every file of the page shares: the kit's builders, the one `Ui` that remembers the pointer,
-- the page's state, and the few pieces the page is made of more than once (a button, a pill, the
-- keys of a command).

local b = pencere
local ui = b.Ui.new()

-- The page's state. What the program said and what the person did, in one place, so that `render`
-- is a function of it.
local S = {
	now = 0,
	width = 1000,
	height = 700,
	-- What the program says the database is (`info`), and what is in it (`schema`).
	info = nil,
	tables = {},
	schema_error = nil,
	-- The tables opened in the list, by "schema.name".
	open = {},
	-- The editor: the version it was last told of, the main caret, whether an input method composes.
	version = 0,
	caret = 0,
	composing = false,
	first_line = 0,
	last_line = 0,
	loaded = false,
	-- The version a person's typing came to, while what they typed is a word: completions follow it.
	typed = nil,
	-- The popup of completions: { items =, chosen =, from =, version = }.
	popup = nil,
	-- What runs now: { id =, kind = "run" | "explain" | "rows", started =, sql = }.
	running = nil,
	-- What came of the last statement: { kind = "rows" | "done" | "error" | "plan", ... }.
	shown = nil,
	-- The part of the editor's text the shown statement was, for the marks of a mistake.
	statement = nil,
	-- The grid: the cell chosen ({ row =, column = }), the widths of its columns.
	cell = nil,
	widths = {},
	-- The cell whose whole value is open: { name =, type =, value =, loading = }.
	inspect = nil,
	-- Where the keyboard is for the page's own keys: "editor" or "grid".
	focus = "editor",
	-- The share of the room above the results that the editor takes, and a drag of the line between.
	split = 0.42,
	dragging = nil,
	-- A word that says what just happened, gone after a while: { words =, kind =, until = }.
	toast = nil,
	-- What the keyboard was sent to, to send it there once.
	keyboard = nil,
}

local SIZE = {
	header = 40,
	status = 24,
	sidebar = 248,
	toolbar = 34,
	row = 24,
	head = 40, -- the grid's header: a column's name, and its type under it
	-- How wide one character of the grid's words is, points: the terminal's face is monospaced, and
	-- the kit's text is drawn as large as the terminal's (12.5 points to its size).
	char = 7.4,
}

-- Whether the pointer is over the element named `id`.
local function hovered(id)
	return ui.hover == id
end

-- One of the pictures of src/assets/icons (Lucide's, ISC), `size` points, in a colour of the theme.
local function icon(name, size, role)
	size = size or 14
	return b.image("assets/icons/" .. name .. ".svg"):size(size, size):tint(role or "dim"):no_shrink()
end

-- The keys of a command, as a person reads them: "⌘ Enter".
-- The modifiers by the signs a Mac writes them in; the keys by their names, which every person
-- reads (⎋ and ⇥ are signs few know).
local KEY_SIGNS = {
	cmd = "⌘",
	shift = "⇧",
	alt = "⌥",
	ctrl = "⌃",
	enter = " Enter",
	escape = "Esc",
	tab = "Tab",
	space = " Space",
}
local function keys_of(words)
	if not words then
		return nil
	end
	local signs = {}
	for _, part in string.split(words, "+") do
		signs[#signs + 1] = KEY_SIGNS[part] or string.upper(part)
	end
	return table.concat(signs)
end

-- The keys of a command, set small beside its words.
local function kbd(words)
	return b.div():px(5):py(1):rounded(4):bg("raised3"):child(b.text(keys_of(words)):text_size(10.5):color("dim"))
end

-- A button: a name the pointer answers to, its words, and the keys that do the same. `tone` is
-- "primary" for the one action that matters most, nil for the rest.
local function button(id, words, options)
	options = options or {}
	local off = options.disabled == true
	local primary = options.tone == "primary"
	local ground = primary and "accent" or (hovered(id) and "raised3" or "raised2")
	if primary and hovered(id) then
		ground = b.mix("accent", "foreground", 0.12)
	end
	local ink = primary and "background" or "foreground"
	local element = b.div()
		:press(id)
		:row()
		:items_center()
		:gap(6)
		:h(options.h or 26)
		:px(options.px or 10)
		:rounded(6)
		:bg(ground)
		:motion({ seconds = 0.12, color = true })
		:label(options.label or words)
		:role("button")
	if options.icon then
		element:child(icon(options.icon, 14, primary and ink or "dim"))
	end
	if words ~= "" then
		element:child(b.text(words):color(ink):weight(primary and 650 or 500))
	end
	if options.keys and not options.compact then
		element:child(b.text(keys_of(options.keys)):text_size(11):color(primary and b.alpha(ink, 0.72) or "quiet"))
	end
	if options.keys then
		element:tip(options.tip or words, keys_of(options.keys))
	end
	if off then
		element:disabled(true):opacity(0.45)
	end
	return element
end

-- A pill: a few words on a ground of their colour.
local function pill(words, color, options)
	options = options or {}
	return b.div()
		:row()
		:items_center()
		:gap(5)
		:px(8)
		:h(options.h or 20)
		:rounded(10)
		:bg(b.alpha(color, 0.16))
		:child(b.text(words):color(color):text_size(options.size or 11):weight(650))
end

-- A line across or down, in the theme's colour of rules.
local function rule_x()
	return b.div():h(1):w_full():no_shrink():bg("border")
end
local function rule_y()
	return b.div():w(1):h_full():no_shrink():bg("border")
end

-- Says a few words at the bottom of the page for a while.
local function say(words, kind, seconds)
	S.toast = { words = words, kind = kind or "info", until_ = S.now + (seconds or 3.5) }
end

return {
	b = b,
	ui = ui,
	S = S,
	SIZE = SIZE,
	hovered = hovered,
	icon = icon,
	keys_of = keys_of,
	kbd = kbd,
	button = button,
	pill = pill,
	rule_x = rule_x,
	rule_y = rule_y,
	say = say,
}
