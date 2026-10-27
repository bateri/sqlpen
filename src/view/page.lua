-- The page of sqlpen: a SQL client, drawn by the terminal in its own font and theme.
--
-- At the left the tables of the database; above, the terminal's editor, made SQL by this page
-- (colours, completions of keywords and of the database's own names, the statement under the caret);
-- below, what the statement gave: its rows in a grid, its plan, or what was wrong with it, marked in
-- the editor where the database pointed. The program does the database's part.

local kit = require("./lib/kit")
local sql = require("./lib/sql")
local schema = require("./parts/schema")
local grid = require("./parts/grid")
local plan = require("./parts/plan")
local inspect = require("./parts/inspect")

local b, ui, S, SIZE = kit.b, kit.ui, kit.S, kit.SIZE
local layout = b.layout

local SQL = "sql"
local POPUP = "completions"
local SPLIT = "split"

-- How many completions the popup shows at once.
local SHOWN = 8

-- --- The editor's language ---------------------------------------------------------------------

-- The colours of the lines `from` to `to` (from 0), as one ask of the layer "syntax".
local function colour(from, to)
	local lines = layout.editor_lines(SQL)
	if not lines or lines == 0 then
		return nil
	end
	to = math.min(to, lines - 1)
	from = math.max(from, 0)
	if from > to then
		return nil
	end
	local length = layout.editor_length(SQL)
	local start = layout.line_start(SQL, from)
	local finish = (to + 1 < lines) and (layout.line_start(SQL, to + 1) - 1) or length
	local decorations = {}
	for line = from, to do
		local base = layout.line_start(SQL, line)
		local after = (line + 1 < lines) and (layout.line_start(SQL, line + 1) - 1) or length
		for _, token in sql.lex(layout.editor_text(SQL, base, after) or "") do
			local look = sql.LOOKS[token.kind]
			decorations[#decorations + 1] = {
				from = base + token.from,
				to = base + token.to,
				color = look.color,
				weight = look.weight,
				italic = look.italic,
			}
		end
	end
	return {
		decorate = "syntax",
		version = layout.editor_version(SQL),
		from = start,
		to = finish,
		decorations = decorations,
	}
end

-- Each statement of more than one line, a region that folds.
local function folds()
	local length = layout.editor_length(SQL) or 0
	local text = layout.editor_text(SQL, 0, length) or ""
	local regions = {}
	local found = sql.statements(text)
	for _, statement in found do
		local first = layout.line_of(SQL, statement.from)
		local last = layout.line_of(SQL, math.max(statement.to - 1, statement.from))
		if first and last and last > first then
			regions[#regions + 1] = { from = statement.from, to = statement.to, fold = true }
		end
	end
	return { decorate = "folds", version = layout.editor_version(SQL), from = 0, to = length, decorations = regions }
end

-- The mark of a mistake, where the database pointed in the statement it was given, or none.
local marked = false
local function mark(failure, statement, version)
	if not (failure and failure.position and statement) then
		return nil
	end
	local length = layout.editor_length(SQL) or 0
	local text = layout.editor_text(SQL, statement.from, math.min(statement.to, length)) or ""
	local chars = sql.chars_of(text)
	local at = math.min(failure.position, math.max(#chars - 1, 0))
	local from = statement.from + at
	local to = statement.from + sql.word_end(chars, at)
	marked = true
	return {
		decorate = "diagnostics",
		version = version,
		from = 0,
		to = length,
		decorations = {
			{ from = from, to = to, underline = { wavy = "error" }, background = b.alpha("error", 0.12) },
			{ from = from, to = to, gutter = "error" },
		},
	}
end

local function unmark()
	if not marked then
		return nil
	end
	marked = false
	return { decorate = "diagnostics", version = layout.editor_version(SQL), from = 0, to = layout.editor_length(SQL) or 0, decorations = {} }
end

-- What the editor holds when sqlpen opens: a statement or two for the database it is looking at.
local function starter()
	local info = S.info or {}
	local lines = {
		"-- sqlpen · " .. (info.database or "") .. " · " .. (info.version or ""),
		"-- ⌘Enter runs the statement under the caret (or what is selected) · ⌘E shows how it would run",
		"-- Tab completes a word: tables, columns, keywords",
		"",
	}
	local orders = nil
	for _, entry in S.tables do
		if entry.name == "orders" then
			orders = entry
		end
	end
	if info.engine == "sqlite" and orders and info.database == "demo" then
		lines[#lines + 1] = "select c.country, count(*) as orders, round(sum(o.total), 2) as revenue"
		lines[#lines + 1] = "from orders o"
		lines[#lines + 1] = "join customers c on c.id = o.customer_id"
		lines[#lines + 1] = "where o.status <> 'refunded'"
		lines[#lines + 1] = "group by c.country"
		lines[#lines + 1] = "order by revenue desc;"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "select * from revenue_by_month;"
		lines[#lines + 1] = ""
		lines[#lines + 1] = "select id, at, kind, payload from events order by at desc limit 200;"
	else
		local first = S.tables[1]
		if first then
			lines[#lines + 1] = "select * from " .. (info.engine == "postgres" and (sql.quoted(first.schema) .. ".") or "") .. sql.quoted(first.name) .. " limit 100;"
		else
			lines[#lines + 1] = "select 1;"
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

-- The first text of the editor, once both the editor has said it is there (`viewport`) and the
-- program has said what the database holds: as a reply, or nil while either is still to come.
local function first_load()
	if S.loaded or not S.seen_editor or not S.tables_known then
		return nil
	end
	S.loaded = true
	return { redraw = true, editor = { [SQL] = { load = starter() } }, keyboard = { field = SQL } }
end

-- --- Completions -------------------------------------------------------------------------------

local function close_popup()
	local had = S.popup ~= nil
	S.popup = nil
	return had
end

-- Opens the popup for the word before the caret (or for nothing yet, where `forced`).
local function complete(forced)
	local line = layout.line_of(SQL, S.caret)
	local line_start = line and layout.line_start(SQL, line) or S.caret
	if sql.in_words(layout.editor_text(SQL, line_start, S.caret) or "") then
		return close_popup()
	end
	local start = math.max(0, S.caret - 4000)
	local before = layout.editor_text(SQL, start, S.caret) or ""
	-- Only the statement the caret is in: what is after its `;` before it.
	before = string.match(before, "[^;]*$") or before
	local found = sql.complete(before, S.tables, forced)
	if not found then
		return close_popup()
	end
	S.popup = {
		items = found.items,
		chosen = 1,
		top = 1,
		from = S.caret - found.from,
		version = S.version,
	}
	return true
end

local function accept()
	local popup = S.popup
	local item = popup.items[popup.chosen]
	S.popup = nil
	S.typed = nil
	return {
		redraw = true,
		editor = { [SQL] = { change = { { from = popup.from, to = S.caret, insert = item.word } }, base = S.version } },
	}
end

-- Tab after a word: the word completed if one fits, the popup if several do, else the indent Tab
-- would have put.
local function tab()
	if complete(true) and S.popup then
		if #S.popup.items == 1 then
			return accept()
		end
		return true
	end
	return {
		redraw = true,
		editor = { [SQL] = { change = { { from = S.caret, to = S.caret, insert = "  " } }, base = S.version } },
	}
end

local function choose(step)
	local popup = S.popup
	popup.chosen = (popup.chosen - 1 + step) % #popup.items + 1
	if popup.chosen < popup.top then
		popup.top = popup.chosen
	elseif popup.chosen >= popup.top + SHOWN then
		popup.top = popup.chosen - SHOWN + 1
	end
	return true
end

local KIND_SIGN = {
	column = { "c", "cyan" },
	table = { "T", "blue" },
	view = { "V", "magenta" },
	keyword = { "k", "accent" },
	["function"] = { "f", "green" },
}

local function popup_view()
	local popup = S.popup
	local list = b.div()
		:id(POPUP)
		:anchor(b.caret_of(SQL), "below", { gap = 4 })
		:col()
		:w(320)
		:p(4)
		:rounded(8)
		:bg("raised2")
		:border(1, "border")
		:shadow(0, 8, 24, b.alpha("shadow", 0.4))
		:family("terminal")
	local last = math.min(popup.top + SHOWN - 1, #popup.items)
	for index = popup.top, last do
		local item = popup.items[index]
		local sign = KIND_SIGN[item.kind] or { "·", "dim" }
		local chosen = index == popup.chosen
		local row = b.div()
			:press("completion:" .. index)
			:row()
			:items_center()
			:gap(8)
			:h(24)
			:px(6)
			:rounded(5)
			:bg(chosen and "selection" or (kit.hovered("completion:" .. index) and "raised3" or nil))
			:child(
				b.div():w(16):h(16):rounded(4):bg(b.alpha(sign[2], 0.18)):items_center():justify_center()
					:child(b.text(sign[1]):text_size(10.5):weight(700):color(sign[2]))
			)
			:child(b.text(item.word):truncate():grow(1):min_w(0):weight(chosen and 600 or 400))
		if item.detail then
			row:child(b.text(item.detail):text_size(11):color("quiet"):truncate():max_w(130))
		end
		list:child(row)
	end
	if #popup.items > SHOWN then
		list:child(b.div():px(8):pt(2):child(b.text(popup.chosen .. " of " .. #popup.items .. "  ·  Tab or Enter puts it in"):text_size(10.5):color("quiet")))
	else
		list:child(b.div():px(8):pt(2):child(b.text("Tab or Enter puts it in · Esc closes"):text_size(10.5):color("quiet")))
	end
	return list
end

-- --- The program ---------------------------------------------------------------------------------

local load_schema

-- What a run gave, kept for the page to show.
local function shown_of(answer, statement)
	if answer.error then
		return { kind = "error", error = answer.error, sql = statement and statement.text }
	end
	if #answer.columns > 0 then
		local rows = {}
		for index, row in answer.rows do
			rows[index] = row
		end
		return {
			kind = "rows",
			result = answer.result,
			columns = answer.columns,
			rows = rows,
			total = answer.total,
			cut = answer.cut,
			tag = answer.tag,
			ms = answer.ms,
			sql = statement and statement.text,
		}
	end
	return { kind = "done", tag = answer.tag, ms = answer.ms, sql = statement and statement.text }
end

local WRITES = { INSERT = true, UPDATE = true, DELETE = true, CREATE = true, DROP = true, ALTER = true }

-- Runs `statement` ({ from =, to =, text = }; from and to the places of the editor's text it was, or
-- nil for one the page made), or shows how it would run (`how` "explain" or "analyze").
local function run(statement, how)
	if S.running then
		b.cancel(S.running.id)
	end
	local version = S.version
	local asked = statement.from and statement or nil
	local method = how and "explain" or "run"
	local params = { sql = statement.text }
	if how then
		params.analyze = how == "analyze"
	end
	local state = { method = method, how = how, started = S.now, sql = statement.text }
	state.id = b.call(method, params, function(answer, error)
		-- An answer for a run that was stopped, or that another took the place of, is not shown.
		if S.running ~= state then
			return false
		end
		S.running = nil
		local asks = {}
		if error then
			S.shown = { kind = "error", error = { message = error.message or error.code }, sql = statement.text }
		elseif how then
			if answer.error then
				S.shown = { kind = "error", error = answer.error, sql = statement.text }
			else
				S.shown = { kind = "plan", plan = answer.plan, analyze = how == "analyze", sql = statement.text }
			end
		else
			S.shown = shown_of(answer, statement)
			S.cell = nil
			if S.shown.kind == "rows" then
				grid.home()
			end
			local verb = string.match(answer.tag or "", "^(%u+)")
			if verb and WRITES[verb] then
				load_schema()
			end
		end
		if S.shown.kind == "error" then
			asks[#asks + 1] = mark(S.shown.error, asked, version)
		end
		if #asks > 0 then
			return { redraw = true, editor = { [SQL] = asks } }
		end
		return true
	end)
	S.running = state
	S.statement = asked
	close_popup()
	return true
end

-- The statement the caret is in, run (or explained).
local function run_here(how)
	local length = layout.editor_length(SQL) or 0
	local statement = nil
	local selected = S.selection
	if selected and selected.to > selected.from then
		-- What is selected is what runs: a part of a statement, or several of them.
		local text = layout.editor_text(SQL, selected.from, selected.to) or ""
		local lead = #(string.match(text, "^%s*") or "")
		local body = string.gsub(string.gsub(text, "^%s+", ""), "[%s;]+$", "")
		if body ~= "" then
			statement = { from = selected.from + (utf8.len(string.sub(text, 1, lead)) or lead), text = body }
			statement.to = statement.from + (utf8.len(body) or #body)
		end
	end
	if not statement then
		local text = layout.editor_text(SQL, 0, length) or ""
		statement = sql.statement_at(text, S.caret)
	end
	if not statement then
		kit.say("There is no statement to run here", "warning")
		return true
	end
	local asks = { unmark() }
	run(statement, how)
	return { redraw = true, editor = #asks > 0 and { [SQL] = asks } or nil }
end

local function stop()
	if not S.running then
		return nil
	end
	b.cancel(S.running.id)
	S.running = nil
	kit.say("Stopped", "info")
	return true
end

-- The rows of a table, without touching what the person wrote.
local function preview(entry)
	local name = sql.quoted(entry.name)
	if S.info and S.info.engine == "postgres" then
		name = sql.quoted(entry.schema) .. "." .. name
	end
	return run({ text = "select * from " .. name .. " limit 1000" })
end

function load_schema()
	b.call("schema", {}, function(answer, error)
		if error then
			S.schema_error = error.message or error.code
		else
			S.schema_error = nil
			S.tables = answer.tables
		end
		S.tables_known = true
		return first_load() or true
	end)
end

-- --- The page --------------------------------------------------------------------------------------

local function header(narrow)
	local info = S.info
	local row = b.div():row():items_center():gap(10):h(SIZE.header):px(14):no_shrink()
	row:child(kit.icon("database", 16, "accent"))
	row:child(b.text("sqlpen"):weight(800):text_size(13.5))
	if info then
		row:child(b.text(info.database):weight(600):truncate():min_w(0))
		if not narrow then
			row:child(b.text(info.place):color("dim"):truncate():min_w(0))
		end
		row:child(kit.pill(info.version, info.engine == "postgres" and "blue" or "cyan"))
		if info.read_only then
			row:child(kit.pill("READ ONLY", "warning"):tip("Statements cannot change this database: run sqlpen with --write to let them"))
		else
			row:child(kit.pill("WRITE", "red"):tip("Statements can change this database"))
		end
	end
	row:child(b.spacer())
	if S.running then
		local seconds = S.now - S.running.started
		row:child(b.text(string.format("%s %.1f s", S.running.how and "Planning" or "Running", seconds)):color("dim"))
		row:child(kit.button("stop", "Stop", { icon = "square", keys = "cmd+.", tip = "Stop the statement" }))
	else
		if not narrow then
			row:child(kit.button("explain", "Explain", { icon = "layers", keys = "cmd+e", tip = "How it would run" }))
		end
		row:child(kit.button("run", "Run", { icon = "play", keys = "cmd+enter", tone = "primary", tip = "Run the statement under the caret" }))
	end
	return row
end

local function editor_view()
	local options = {
		comment = "--",
		pairs = "()''\"\"",
		hint = "Write SQL here…",
		tab_width = 2,
		-- Rows as airy as the rest of the page's: SQL here is read more than it is typed.
		line_height = 1.7,
		padding = 8,
		-- As Zed keeps it: three rows about the caret when the keys move it near an edge.
		scroll_margin = 3,
		-- The caret's line across the gutter and the text, as Zed and VS Code draw it.
		current_line = "all",
	}
	local editor = b.editor(SQL, options):grow(1):min_h(0):bg("background")
	if S.focus == "editor" then
		editor:focused(true)
	end
	-- Tab completes, as it does in a shell, where the caret is at the end of a word (with nothing
	-- selected: a selection is indented); elsewhere it is the editor's indent. ⌃Space does it too,
	-- where the Mac does not take it for the next input source.
	editor:command("complete", "Complete the word", "ctrl+space")
	if S.after_word and not S.popup and not (S.selection and S.selection.to > S.selection.from) then
		editor:command("complete-tab", "Complete the word", "tab")
	end
	if S.popup then
		editor = editor
			:command("completion-next", "Next completion", "down")
			:command("completion-previous", "Previous completion", "up")
			:command("completion-accept", "Accept the completion", "enter")
			:command("completion-take", "Take the completion", "tab")
			:command("completion-close", "Close the completions", "escape")
			:child(popup_view())
	end
	return editor
end

local function split_view()
	local hover = kit.hovered(SPLIT) or (S.dragging and S.dragging.kind == "split")
	return b.div()
		:press(SPLIT)
		:h(7)
		:w_full()
		:no_shrink()
		:col()
		:justify_center()
		:child(b.div():h(hover and 2 or 1):w_full():bg(hover and "accent" or "border"):motion({ seconds = 0.12, color = true }))
end

local function number_words(n)
	local text = tostring(math.floor(n))
	local grouped = string.reverse(string.gsub(string.reverse(text), "(%d%d%d)", "%1,"))
	return (string.gsub(grouped, "^,", ""))
end

local function toolbar()
	local shown = S.shown
	local row = b.div():row():items_center():gap(10):h(SIZE.toolbar):px(14):no_shrink():bg("raised1")
	if not shown then
		row:child(b.text("Results"):weight(700))
		return row
	end
	if shown.kind == "rows" then
		row:child(b.text("Results"):weight(700))
		local count = number_words(shown.total) .. (shown.cut and "+ rows" or (shown.total == 1 and " row" or " rows"))
		row:child(kit.pill(count, shown.cut and "warning" or "green"))
		row:child(b.text(string.format("%.0f ms", shown.ms or 0)):color("dim"))
		if shown.cut then
			row:child(b.text("only the first " .. number_words(shown.total) .. " are kept"):color("quiet"):truncate():min_w(0))
		end
	elseif shown.kind == "plan" then
		row:child(b.text(shown.analyze and "Plan, run" or "Plan"):weight(700))
	elseif shown.kind == "error" then
		row:child(kit.icon("triangle-alert", 14, "error"))
		row:child(b.text("It did not run"):weight(700):color("error"))
	elseif shown.kind == "done" then
		row:child(kit.icon("circle-check", 14, "success"))
		row:child(b.text(shown.tag or "Done"):weight(700))
		row:child(b.text(string.format("%.0f ms", shown.ms or 0)):color("dim"))
	end
	if shown.sql then
		row:child(b.text(string.gsub(shown.sql, "%s+", " ")):family("terminal"):text_size(11.5):color("quiet"):truncate():grow(1):min_w(0))
	else
		row:child(b.spacer())
	end
	if shown.kind == "rows" then
		row:child(kit.button("copy", "Copy", { icon = "copy", tip = "Copy the rows here as text", h = 24, px = 8 }))
		row:child(kit.button("export", "CSV", { icon = "download", tip = "Save the result as a CSV file here", h = 24, px = 8 }))
	end
	return row
end

local function welcome()
	local box = b.div():col():grow(1):items_center():justify_center():gap(10):p(20)
	box:child(kit.icon("database", 30, "quiet"))
	box:child(b.text("Write a statement and run it with ⌘Enter"):weight(600))
	local tips = {
		"Tab completes a word — the database's tables and columns too",
		"⌘E shows how it would run; select a part of the text to run only that",
		"Double-click a table to see its rows; drop a .sql file here to open it",
	}
	for _, tip in tips do
		box:child(b.text(tip):color("dim"):text_size(12))
	end
	return box
end

local function failure_view(failure)
	local box = b.div():id("failure"):col():grow(1):min_h(0):scroll():gap(8):p(16)
	box:child(
		b.div():row():gap(8):items_start()
			:child(kit.icon("triangle-alert", 16, "error"))
			:child(b.text(failure.message or "It failed"):wrap():weight(600):color("error"):grow(1):min_w(0))
	)
	if failure.detail then
		box:child(b.text(failure.detail):wrap():color("foreground"):pl(24))
	end
	if failure.hint then
		box:child(b.div():row():gap(8):pl(24):child(kit.icon("info", 13, "info")):child(b.text(failure.hint):wrap():color("info"):grow(1):min_w(0)))
	end
	if failure.code then
		box:child(b.text(failure.code):text_size(11):color("quiet"):family("terminal"):pl(24))
	end
	if failure.position and S.statement then
		box:child(b.text("The mistake is marked in the statement."):text_size(11):color("dim"):pl(24))
	end
	return box
end

local function results()
	local shown = S.shown
	local body
	if not shown then
		body = welcome()
	elseif shown.kind == "rows" and shown.total == 0 then
		local names = {}
		for _, column in shown.columns do
			names[#names + 1] = column.name
		end
		body = b.div():col():grow(1):items_center():justify_center():gap(6):p(20)
			:child(b.text("No rows"):weight(600))
			:child(b.text(table.concat(names, " · ")):color("quiet"):text_size(11.5):family("terminal"):truncate():max_w(600))
	elseif shown.kind == "rows" then
		body = grid.view(shown)
	elseif shown.kind == "plan" then
		body = plan.view(shown.plan, shown.analyze)
	elseif shown.kind == "error" then
		body = failure_view(shown.error)
	else
		body = b.div():col():grow(1):items_center():justify_center():child(b.text(shown.tag or "Done"):color("dim"))
	end
	return b.div():col():grow(1):min_h(0):child(toolbar()):child(kit.rule_x()):child(body)
end

local function status_bar(narrow)
	local row = b.div():row():items_center():gap(14):h(SIZE.status):px(14):no_shrink():bg("raised1"):text_size(11):color("quiet")
	local hints = narrow and { { "⌘Enter", "run" }, { "Tab", "complete" } }
		or { { "⌘Enter", "run" }, { "Tab", "complete" }, { "⌘E", "plan" }, { "⇧⌘E", "plan, run" }, { "⌘.", "stop" } }
	for _, hint in hints do
		row:child(b.div():row():gap(4):child(b.text(hint[1]):color("dim")):child(b.text(hint[2])))
	end
	row:child(b.spacer())
	local line = layout.line_of(SQL, S.caret)
	if line then
		local column = S.caret - (layout.line_start(SQL, line) or 0)
		row:child(b.text(string.format("Ln %d, Col %d", line + 1, column + 1)))
	end
	if S.info then
		row:child(b.text(S.info.engine == "postgres" and "PostgreSQL" or "SQLite"))
	end
	return row
end

local function toast_view()
	local toast = S.toast
	local color = toast.kind == "error" and "error" or toast.kind == "warning" and "warning" or "accent"
	return b.div()
		:id("toast")
		:overlay()
		:inset(nil, 16, SIZE.status + 12, nil)
		:row()
		:items_center()
		:gap(8)
		:px(12)
		:h(32)
		:rounded(8)
		:bg("raised3")
		:border(1, b.alpha(color, 0.5))
		:shadow(0, 6, 18, b.alpha("shadow", 0.35))
		:motion({ enter = { opacity = 0, dy = 6, seconds = 0.16 }, exit = { opacity = 0, seconds = 0.2 } })
		:child(b.div():w(6):h(6):rounded(3):bg(color))
		:child(b.text(toast.words))
end

local function render(size, now)
	S.now, S.width, S.height = now, size.w, size.h
	local narrow = size.w < 760
	if S.toast and now >= S.toast.until_ then
		S.toast = nil
	end
	local available = size.h - SIZE.header - SIZE.status - 2
	local editor_h = math.clamp(math.floor(available * S.split), 80, math.max(available - 140, 80))
	local main = b.div():col():grow(1):min_w(0):min_h(0)
		:child(b.div():col():h(editor_h):no_shrink():child(editor_view()))
		:child(split_view())
		:child(results())
	local body = b.div():row():grow(1):min_h(0)
	if not narrow then
		body:child(schema.view(math.min(SIZE.sidebar, math.floor(size.w * 0.28)))):child(kit.rule_y())
	end
	body:child(main)
	local root = b.div()
		:size_full()
		:col()
		:bg("background")
		:command("run", "Run the statement", "cmd+enter")
		:command("explain", "Show how the statement would run", "cmd+e")
		:command("analyze", "Run the statement and show how it went", "cmd+shift+e")
		:command("stop", "Stop the statement", "cmd+.", S.running ~= nil)
		:child(header(narrow))
		:child(kit.rule_x())
		:child(body)
		:child(kit.rule_x())
		:child(status_bar(narrow))
	if S.inspect then
		root:child(inspect.view(size.w, size.h))
	end
	if S.toast then
		root:child(toast_view())
	end
	local wake = nil
	if S.running then
		wake = now + 0.1
	end
	if S.toast then
		wake = wake and math.min(wake, S.toast.until_) or S.toast.until_
	end
	return root, false, wake
end

local function settle()
	local changed = false
	local rows = layout.scroll_extent(grid.GRID)
	if rows and rows.view ~= grid.view_h then
		grid.view_h = rows.view
		changed = true
	end
	local across = layout.scroll_extent(grid.ACROSS)
	if across and (across.view_w ~= grid.view_w or across.view ~= grid.across_h) then
		grid.view_w, grid.across_h = across.view_w, across.view
		changed = true
	end
	return changed
end

-- --- What the person does ------------------------------------------------------------------------

local function to_editor()
	S.focus = "editor"
	return { redraw = true, keyboard = { field = SQL } }
end

-- Opens the whole value of the chosen cell.
local function open_cell()
	local shown = S.shown
	if not (shown and shown.kind == "rows" and S.cell) then
		return nil
	end
	local column = shown.columns[S.cell.column]
	local row = grid.row_at(shown, S.cell.row)
	S.inspect = { name = column.name, type = column.type, value = grid.value(shown), loading = true }
	b.call("cell", { result = shown.result, row = row - 1, column = S.cell.column - 1 }, function(answer, error)
		if S.inspect then
			S.inspect.loading = false
			if not error then
				S.inspect.value = answer.value
			end
		end
		return true
	end)
	return true
end

local function copy_cell()
	local shown = S.shown
	if S.inspect then
		return { copy = S.inspect.value or "" }
	end
	if not (shown and shown.kind == "rows" and S.cell) then
		return nil
	end
	local value = grid.value(shown)
	-- The grid holds a value cut where it is long: the whole of it is the program's.
	if value and (utf8.len(value) or #value) >= 160 then
		b.call("cell", { result = shown.result, row = grid.row_at(shown, S.cell.row) - 1, column = S.cell.column - 1 }, function(answer, error)
			if error then
				kit.say("It could not be copied: " .. (error.message or error.code), "error")
				return true
			end
			kit.say("Copied the cell", "info", 1.6)
			return { redraw = true, copy = answer.value or "" }
		end)
		return true
	end
	kit.say("Copied the cell", "info", 1.6)
	return { redraw = true, copy = value or "" }
end

local function click(id, event)
	if id == "run" then
		return run_here(nil)
	elseif id == "explain" then
		return run_here("explain")
	elseif id == "stop" then
		return stop()
	elseif id == "copy" and S.shown and S.shown.kind == "rows" then
		b.call("text", { result = S.shown.result }, function(answer, error)
			if error then
				kit.say("It could not be copied: " .. (error.message or error.code), "error")
				return true
			end
			local words = answer.rows < answer.of and string.format("Copied %d of %d rows (what the pasteboard takes; CSV saves them all)", answer.rows, answer.of)
				or string.format("Copied %d rows", answer.rows)
			kit.say(words, "info", 3)
			return { redraw = true, copy = answer.text }
		end)
		return true
	elseif id == "export" and S.shown and S.shown.kind == "rows" then
		b.call("export", { result = S.shown.result }, function(answer, error)
			if error then
				kit.say("It was not saved: " .. (error.message or error.code), "error", 5)
			else
				kit.say("Saved " .. answer.path, "info", 5)
			end
			return true
		end)
		return true
	elseif id == inspect.CLOSE or id == inspect.SHADE then
		S.inspect = nil
		return true
	elseif id == inspect.COPY then
		kit.say("Copied the value", "info", 1.6)
		return { redraw = true, copy = S.inspect and S.inspect.value or "" }
	end
	local completion = string.match(id, "^completion:(%d+)$")
	if completion and S.popup then
		S.popup.chosen = tonumber(completion)
		return accept()
	end
	local entry = schema.table_of(id)
	if entry then
		local key = entry.schema .. "." .. entry.name
		if S.press_count == 2 then
			return preview(entry)
		end
		S.open[key] = not S.open[key] or nil
		return true
	end
	local owner, column = schema.column_of(id)
	if owner then
		S.focus = "editor"
		return {
			redraw = true,
			keyboard = { field = SQL },
			editor = { [SQL] = { change = { { from = S.caret, to = S.caret, insert = sql.quoted(column.name) } }, base = S.version } },
		}
	end
	local head = grid.head_of(id)
	if head and S.shown and S.shown.kind == "rows" then
		if grid.complete(S.shown) then
			grid.need(S.shown, 1, S.shown.total)
			grid.sort(S.shown, head)
		else
			kit.say("Only part of the result is here: sort it with ORDER BY", "warning")
		end
		return true
	end
	return nil
end

local function pointer_moved(event)
	local at = { x = event.x, y = event.y }
	local drag = S.dragging
	if drag and drag.kind == "split" then
		local available = S.height - SIZE.header - SIZE.status - 2
		S.split = math.clamp(drag.split + (event.y - drag.y) / math.max(available, 1), 0.12, 0.85)
		return { redraw = true, cursor = "resize_vertical" }
	elseif drag and drag.kind == "column" and S.shown and S.shown.widths then
		S.shown.widths[drag.column] = math.clamp(drag.width + (event.x - drag.x), 48, 1400)
		return { redraw = true, cursor = "resize_horizontal" }
	end
	local changed = ui:point(layout, at)
	local over = ui.hover
	local cursor = "arrow"
	if event.place then
		-- Over the editor: the shape of a place to type, whatever the pointer was over before.
		cursor = "text"
	elseif over == SPLIT then
		cursor = "resize_vertical"
	elseif over and grid.edge_of(over) then
		cursor = "resize_horizontal"
	elseif over and (string.match(over, "^table:") or string.match(over, "^column:") or over == "run" or over == "explain") then
		cursor = "pointer"
	end
	if changed then
		return { redraw = true, cursor = cursor }
	end
	return { cursor = cursor }
end

local function pressed(event)
	local at = { x = event.x, y = event.y }
	local hit = ui:press(layout, at)
	-- A release says no count: the click is the press's, a double click by its second press.
	S.press_count = event.count or 1
	if hit == SPLIT then
		S.dragging = { kind = "split", y = event.y, split = S.split }
		return { redraw = true, cursor = "resize_vertical" }
	end
	local edge = hit and grid.edge_of(hit)
	if edge and S.shown and S.shown.kind == "rows" and event.count == 2 then
		grid.fit_column(S.shown, edge)
		return { redraw = true, cursor = "resize_horizontal" }
	elseif edge and S.shown and S.shown.kind == "rows" then
		S.dragging = { kind = "column", column = edge, x = event.x, width = grid.widths(S.shown)[edge] }
		return { redraw = true, cursor = "resize_horizontal" }
	end
	local row, column = nil, nil
	if hit and S.shown and S.shown.kind == "rows" then
		row = grid.row_of(hit)
		local bounds = row and layout.bounds(hit)
		if bounds then
			column = grid.column_at(S.shown, event.x - bounds.x) or 1
		end
	end
	if row and column then
		S.cell = { row = row, column = column }
		S.focus = "grid"
		close_popup()
		if event.count == 2 then
			open_cell()
		end
		return { redraw = true, keyboard = "page" }
	end
	if hit and S.popup and not string.match(hit, "^completion:") then
		close_popup()
	end
	return true
end

local function released(event)
	local at = { x = event.x, y = event.y }
	if S.dragging then
		S.dragging = nil
		ui:release(layout, at)
		return true
	end
	local clicked = ui:release(layout, at)
	if clicked then
		return click(clicked, event)
	end
	return nil
end

-- A key the page has (the editor has not the keyboard): the grid's, or the open value's.
local function key(event)
	local name, mods = event.key, event.mods or {}
	if S.inspect then
		if name == "escape" then
			S.inspect = nil
			return true
		elseif name == "c" and mods.command then
			return copy_cell()
		end
		return nil
	end
	local shown = S.shown
	if S.focus == "grid" and shown and shown.kind == "rows" then
		local page = math.max(math.floor(grid.view_h / SIZE.row) - 1, 1)
		local moves = {
			up = { -1, 0 },
			down = { 1, 0 },
			left = { 0, -1 },
			right = { 0, 1 },
			page_up = { -page, 0 },
			page_down = { page, 0 },
		}
		local move = moves[name]
		if move then
			grid.move(shown, move[1], move[2])
			return true
		elseif name == "home" then
			grid.move(shown, -shown.total, 0)
			return true
		elseif name == "end" then
			grid.move(shown, shown.total, 0)
			return true
		elseif name == "enter" then
			return open_cell()
		elseif name == "c" and mods.command then
			return copy_cell()
		elseif name == "escape" or name == "tab" then
			return to_editor()
		end
	elseif name == "escape" or name == "tab" or (string.len(name) == 1 and not mods.command) then
		return to_editor()
	end
	return nil
end

local function editor_event(event)
	local kind = event.type
	if kind == "viewport" then
		S.first_line, S.last_line = event.first, event.last
		S.seen_editor = true
		local loading = first_load()
		if loading then
			return loading
		end
		local asks = {}
		asks[#asks + 1] = colour(S.first_line, S.last_line)
		return { editor = { [SQL] = asks } }
	elseif kind == "edit" then
		S.version = event.version
		local asks = {}
		if event.origin == "load" then
			asks[#asks + 1] = colour(S.first_line, S.last_line)
			asks[#asks + 1] = folds()
			S.typed = nil
			close_popup()
		else
			local first_change = event.changes[1]
			local line = layout.line_of(SQL, first_change and first_change.from or 0) or S.first_line
			asks[#asks + 1] = colour(math.min(line, S.first_line), math.max(line + 1, S.last_line))
			asks[#asks + 1] = folds()
			asks[#asks + 1] = unmark()
			-- One word character typed: what follows it may be completed; anything else closes it.
			local insert = first_change and first_change.insert or ""
			if event.origin == "person" and #event.changes == 1 and string.match(insert, "^[%w_%.]$") then
				S.typed = event.version
			elseif event.origin == "person" or event.origin == "undo" or event.origin == "redo" then
				S.typed = nil
				close_popup()
			end
		end
		return { editor = { [SQL] = asks } }
	elseif kind == "selection" then
		local main = event.ranges[event.main]
		S.caret = main.head
		S.selection = { from = math.min(main.anchor, main.head), to = math.max(main.anchor, main.head) }
		S.composing = event.composing
		local before = layout.editor_text(SQL, math.max(0, S.caret - 1), S.caret) or ""
		S.after_word = string.match(before, "[%w_%.]$") ~= nil
		if S.composing then
			return true
		end
		if S.typed and S.typed == event.version then
			complete(false)
		elseif S.popup and (event.version ~= S.popup.version or S.caret < S.popup.from) then
			close_popup()
		end
		return true
	elseif kind == "editor_refused" then
		close_popup()
		if event.reason ~= "stale-version" then
			kit.say("The editor did not do it: " .. event.reason, "warning")
		end
		return true
	end
	return nil
end

local function command(id)
	if id == "run" then
		return run_here(nil)
	elseif id == "explain" then
		return run_here("explain")
	elseif id == "analyze" then
		-- SQLite says how it would run a statement and nothing of how it went.
		if S.info and S.info.engine == "sqlite" then
			kit.say("SQLite shows how it would run a statement, not how it went", "info")
			return run_here("explain")
		end
		return run_here("analyze")
	elseif id == "stop" then
		return stop()
	elseif id == "complete" then
		return complete(true)
	elseif id == "complete-tab" then
		return tab()
	elseif S.popup and id == "completion-next" then
		return choose(1)
	elseif S.popup and id == "completion-previous" then
		return choose(-1)
	elseif S.popup and (id == "completion-accept" or id == "completion-take") then
		return accept()
	elseif id == "completion-close" then
		return close_popup()
	end
	return nil
end

local function handle(event)
	local kind = event.type
	if kind == "move" then
		return pointer_moved(event)
	elseif kind == "leave" then
		return ui:point(layout, nil)
	elseif kind == "press" then
		return pressed(event)
	elseif kind == "release" then
		return released(event)
	elseif kind == "scrolled" then
		local shown = S.shown
		for _, box in event.boxes do
			local mine = box.id == grid.GRID or box.id == grid.ACROSS
			if mine and shown and shown.kind == "rows" and grid.stale(shown, box.id, box.y, box.x) then
				return true
			end
		end
		return false
	elseif kind == "key" then
		return key(event)
	elseif kind == "command" then
		return command(event.id)
	elseif kind == "focus" then
		if event.field == SQL then
			S.focus = "editor"
		elseif S.focus == "editor" then
			S.focus = S.cell and "grid" or "page"
			close_popup()
		end
		return true
	elseif kind == "files" then
		for _, path in event.paths do
			if string.match(string.lower(path), "%.sql$") then
				b.call("open_file", { path = path }, function(answer, error)
					if error then
						kit.say(error.message or "It could not be read", "error", 5)
						return true
					end
					kit.say("Opened " .. (answer.name or path), "info")
					return { redraw = true, editor = { [SQL] = { load = answer.text } }, keyboard = { field = SQL } }
				end)
				return true
			end
		end
		kit.say("Only a .sql file can be opened here", "warning")
		return true
	elseif kind == "edit" or kind == "selection" or kind == "viewport" or kind == "editor_refused" then
		if event.editor == SQL then
			return editor_event(event)
		end
	end
	return nil
end

-- What the program says the database is, then what is in it: the page starts there.
b.call("info", {}, function(answer, error)
	if error then
		S.schema_error = error.message or error.code
		return true
	end
	S.info = answer
	load_schema()
	return true
end)

return { render = render, settle = settle, handle = handle }
