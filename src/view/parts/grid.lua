-- The grid of a result: its columns as wide as what is in them (and as the person drags them), its
-- rows as many as there are with only those near what is in view made, a window at a time read from
-- the program as they come into view. NULL is not an empty string, numbers stand to the right, and
-- the header goes across with the rows. A cell is chosen with the pointer or the arrows; its whole
-- value opens with a double click or ↩.

local kit = require("../lib/kit")
local b, S, SIZE = kit.b, kit.S, kit.SIZE
local layout = b.layout

local M = {}

M.GRID = "grid"
-- How many rows a read from the program asks for, and how far past what is in view.
local WINDOW = 400

-- How tall the grid's box was laid out (`settle` keeps it).
M.view_h = 400

-- The width of `count` characters of the grid's words.
local function chars(count)
	return count * SIZE.char
end

local function length(text)
	return utf8.len(text) or #text
end

-- How wide a column is for what is in it: its name, its type, the longest of the rows that are here,
-- within `most` points.
local function fit(shown, index, most)
	local column = shown.columns[index]
	local longest = math.max(length(column.name) + 2, length(column.type or ""))
	for row = 1, math.min(shown.total, 1000) do
		local values = shown.rows[row]
		local value = values and values[index]
		longest = math.max(longest, value and length(value) or 4)
	end
	return math.clamp(chars(longest) + 18, 64, most)
end

-- The widths of a result's columns: as wide as what is in them, within bounds; the person's own
-- where they dragged one.
function M.widths(shown)
	if shown.widths then
		return shown.widths
	end
	local widths = {}
	for index = 1, #shown.columns do
		widths[index] = fit(shown, index, 380)
	end
	shown.widths = widths
	return widths
end

-- The column as wide as what is in it, the whole of the longest value (a double click on its
-- edge), up to a wide screen's worth.
function M.fit_column(shown, index)
	M.widths(shown)[index] = fit(shown, index, 1200)
end

-- The width of the column of row numbers.
local function numbers_width(shown)
	return chars(math.max(#tostring(shown.total), 2)) + 20
end

-- The width of all of a result's columns together.
local function content_width(shown)
	local total = numbers_width(shown)
	for _, width in M.widths(shown) do
		total += width
	end
	return total
end

-- The order the rows are shown in: as they came, or sorted by a column where all of them are here.
local function order_of(shown)
	if not shown.sort then
		return nil
	end
	if shown.order then
		return shown.order
	end
	local column, descending = shown.sort.column, shown.sort.descending
	local numeric = shown.columns[column].numeric
	local order = {}
	for index = 1, shown.total do
		-- Sorted once every row is here (they are asked for when the sort is).
		if shown.rows[index] == nil then
			return nil
		end
		order[index] = index
	end
	table.sort(order, function(a, c)
		local x, y = shown.rows[a][column], shown.rows[c][column]
		if x == nil or y == nil then
			-- NULL last, whichever way.
			if x == nil and y == nil then
				return a < c
			end
			return y == nil
		end
		if numeric then
			x, y = tonumber(x) or 0, tonumber(y) or 0
		end
		if x == y then
			return a < c
		end
		if descending then
			return x > y
		end
		return x < y
	end)
	shown.order = order
	return order
end

-- The row of the result shown at place `index` of the grid.
function M.row_at(shown, index)
	local order = order_of(shown)
	return order and order[index] or index
end

-- The most rows the grid sorts itself: past them, ORDER BY is the way.
M.SORTS = 1000

-- Whether the grid can sort the result itself: all of it came, and it is not long.
function M.complete(shown)
	return not shown.cut and shown.total <= M.SORTS
end

-- Asks the program for the rows from `first` to `last` that are not here yet: from the first that is
-- missing, as many as a read gives (the program sends fewer of a wide table), one read at a time;
-- what it did not send is asked for when the page is made again.
function M.need(shown, first, last)
	if not shown.result or last < first or shown.reading then
		return
	end
	local missing = nil
	for index = first, last do
		if shown.rows[index] == nil then
			missing = index
			break
		end
	end
	if not missing then
		return
	end
	shown.reading = missing
	b.call("rows", { result = shown.result, from = missing - 1, count = WINDOW }, function(answer, error)
		shown.reading = nil
		if error or S.shown ~= shown then
			return false
		end
		for offset, row in answer.rows do
			shown.rows[answer.from + offset] = row
		end
		shown.order = nil
		return true
	end)
end

function M.head_of(id)
	local column = string.match(id, "^head:(%d+)$")
	return column and tonumber(column)
end

function M.edge_of(id)
	local column = string.match(id, "^edge:(%d+)$")
	return column and tonumber(column)
end

-- A cell: its value as one text, as wide as its column (a grid has thousands of them in view and
-- ahead of it, and a cell that is one element is a page made in its time).
local function cell_text(value, column, width)
	local text
	if value == nil then
		text = b.text("NULL"):italic():color("quiet")
	else
		local kind = column.type or ""
		if kind == "bool" or kind == "boolean" then
			text = b.text(value == "t" and "true" or value == "f" and "false" or value):color("magenta")
		else
			text = b.text(value)
			local first = string.sub(value, 1, 1)
			if (first == "{" or first == "[") and (kind == "json" or kind == "jsonb" or kind == "") then
				text:color("cyan")
			elseif column.numeric and first == "-" then
				text:color("red")
			end
		end
	end
	return M.fit(text, width, column.numeric)
end

-- The room of a cell's words inside its column: 8 points each side, the same as the header's. A text
-- is drawn from the edge of its own box (it has no padding of its own), so the room is its margins.
local PAD = 8
function M.fit(text, width, numeric)
	text:w(math.max(width - PAD * 2, 1)):ml(PAD):mr(PAD):truncate():no_shrink()
	if numeric then
		text:align("end")
	end
	return text
end

-- The row a row's name says, and the column of a row at `x` points into it (nil on its number).
function M.row_of(id)
	local row = string.match(id, "^row:(%d+)$")
	return row and tonumber(row)
end

function M.column_at(shown, x)
	local left = numbers_width(shown)
	if x < left then
		return nil
	end
	for index, width in M.widths(shown) do
		if x < left + width then
			return index
		end
		left += width
	end
	return #shown.columns
end

-- How the grid scrolls. The host scrolls a box at once, before the page is asked anything, so the
-- grid is two boxes that the host scrolls, and nothing of it waits for the page to move:
--
-- * the outer one (`ACROSS`) goes across, and holds the header and the rows: the names of the
--   columns go with their values in the same frame;
-- * the inner one (`GRID`) goes down and holds the rows alone: the header stays where it is.
--
-- The wheel turns the innermost box that can go its way: down is the rows', across the outer's.
M.ACROSS = "grid-across"

-- How wide and how tall the outer box was laid out (`settle` keeps them).
M.view_w = 800
M.across_h = 420

-- The columns to build with the grid scrolled `x` across: those in view and two views of them each
-- way, for the host scrolls across before the page is made again; and where the first starts.
local function columns_near(shown, widths, x)
	local view = M.view_w
	local from, to = x - view * 2, x + view * 3
	local left = numbers_width(shown)
	local first, last, start = nil, 0, left
	for index, width in widths do
		if left + width > from and left < to then
			if not first then
				first, start = index, left
			end
			last = index
		end
		left += width
	end
	shown.built_x = x
	return first or 1, last, start
end

-- A column's name over its type, as a database client shows them: the name in the words of the
-- cells, the type small and quiet under it. Between the columns a hairline, inset from the top and
-- the bottom; the handle that widens a column is that line's place, the width of a finger, and
-- shows only under the pointer (a line of the accent, and the pointer that says it can be dragged).
local function header(shown, widths, first, last, start, room)
	-- As wide as the room: the header's ground goes to the edge of the view, past the last column.
	local row = b.div():row():h(SIZE.head):w(room):no_shrink():bg("raised1")
	row:child(
		b.div():w(start):h_full():no_shrink():row():items_end():justify_end():pr(10):pb(6)
			:child(b.text("#"):text_size(10.5):color("quiet"))
	)
	for index = first, last do
		local column = shown.columns[index]
		local id = "head:" .. index
		local sort = shown.sort and shown.sort.column == index and shown.sort or nil
		local hover = kit.hovered(id)
		local name = b.div():row():items_center():gap(4):min_w(0)
			:child(b.text(column.name):weight(600):truncate():min_w(0):color(hover and "foreground" or b.mix("dim", "foreground", 0.75)))
		if sort then
			name:child(b.text(sort.descending and "↓" or "↑"):color("accent"):weight(700))
		end
		local words = b.div():col():gap(1):min_w(0):grow(1):child(name)
		if column.type and column.type ~= "" then
			-- In lower case, whichever way the database writes it (SQLite says what the table was
			-- created with: `INTEGER`), so that one header reads like the next.
			words:child(b.text(string.lower(column.type)):text_size(10.5):color("quiet"):truncate():min_w(0))
		end
		if column.numeric then
			words:items_end()
		end
		local head = b.div()
			:press(id)
			:row()
			:items_center()
			:w(widths[index])
			:h_full()
			:px(8)
			:no_shrink()
			:bg(hover and b.alpha("raised3", 0.6) or nil)
			:motion({ seconds = 0.12, color = true })
			:tip(column.name .. (column.type ~= "" and (" · " .. column.type) or "") .. (M.complete(shown) and " — click to sort" or ""))
			:child(words)
		-- The line between this column and the next, and the handle over it.
		local edge = "edge:" .. index
		local dragging = S.dragging and S.dragging.kind == "column" and S.dragging.column == index
		local active = kit.hovered(edge) or dragging
		-- The line is placed by its insets inside the handle, from its top and its bottom: a height
		-- of the whole and a margin besides would run it past the header into the rows.
		local inset = active and 0 or 10
		head:child(
			b.div()
				:press(edge)
				:absolute()
				:inset(0, 0, 0, nil)
				:w(7)
				:child(
					b.div()
						:id("edge-line:" .. index)
						:absolute()
						:inset(inset, 0, inset, nil)
						:w(active and 2 or 1)
						:bg(active and "accent" or b.alpha("border", 0.7))
						:motion({ seconds = 0.12, color = true })
				)
		)
		row:child(head)
	end
	return row
end

-- The grid of `shown`, a result with rows.
function M.view(shown)
	local widths = M.widths(shown)
	local y = layout.scroll_offset(M.GRID)
	local _, x = layout.scroll_offset(M.ACROSS)
	local first_column, last_column, start = columns_near(shown, widths, x)
	local rows = b.Rows.even(shown.total, SIZE.row)
	shown.built = shown.built or b.Built.new()
	local first, last = shown.built:span(rows, y, M.view_h)
	M.need(shown, first, last)
	local width = content_width(shown)
	-- At least as wide as the view: the rows' scroll bar stands at the view's edge where the
	-- columns do not fill it.
	local room = math.max(width, M.view_w)
	-- As tall as the outer box under the header, said in points: what a box that scrolls holds is
	-- not held to its height, and rows that grew to their whole length would not scroll at all.
	local body = b.div()
		:id(M.GRID)
		:col()
		:w(room)
		:h(math.max(M.across_h - SIZE.head - 1, SIZE.row * 2))
		:no_shrink()
		:scroll()
		:focusable()
	body:child(b.div():h(rows:top(first)):w(width):no_shrink())
	local chosen = S.cell
	for place = first, last do
		local index = M.row_at(shown, place)
		local values = shown.rows[index]
		local row_id = "row:" .. place
		local line = b.div():press(row_id):row():items_center():h(SIZE.row):w(room):no_shrink()
		if kit.hovered(row_id) then
			line:bg(b.alpha("raised2", 0.9))
		elseif place % 2 == 0 then
			line:bg(b.alpha("raised1", 0.45))
		end
		line:child(
			b.div():w(numbers_width(shown)):h_full():no_shrink():row():items_center():justify_end():pr(10)
				:child(b.text(tostring(place)):color("quiet"):text_size(11))
		)
		if start > numbers_width(shown) then
			line:child(b.div():w(start - numbers_width(shown)):h_full():no_shrink())
		end
		for column = first_column, last_column do
			local spec = shown.columns[column]
			local cell
			if values then
				cell = cell_text(values[column], spec, widths[column])
			else
				cell = M.fit(b.text("·"):color("quiet"), widths[column], false)
			end
			if chosen and chosen.row == place and chosen.column == column then
				-- The chosen cell, alone, a box around its text.
				local values_ = values and values[column]
				cell = b.div():id("chosen"):w(widths[column]):h_full():no_shrink():row():items_center()
					:bg(b.alpha("accent", S.focus == "grid" and 0.22 or 0.12))
					:border(1, b.alpha("accent", S.focus == "grid" and 0.9 or 0.45))
					:child(values and cell_text(values_, spec, widths[column] - 2) or cell)
			end
			line:child(cell)
		end
		body:child(line)
	end
	body:child(b.div():h(rows:total() - rows:top(last + 1)):w(width):no_shrink())
	if S.focus == "grid" then
		body:focused(true)
	end
	return b.div()
		:id(M.ACROSS)
		:col()
		:grow(1)
		:min_h(0)
		:min_w(0)
		:scroll()
		:family("terminal")
		:text_size(12)
		:child(header(shown, widths, first_column, last_column, start, room))
		:child(b.div():h(1):w(room):no_shrink():bg("border"))
		:child(body)
end

-- Whether the grid is to be made again for a box of it the host scrolled: new rows come near the
-- view going down, or columns going across past what was built.
function M.stale(shown, id, y, x)
	if id == M.ACROSS then
		return shown.built_x == nil or math.abs(x - shown.built_x) > M.view_w
	end
	if not shown.built then
		return true
	end
	return shown.built:stale(b.Rows.even(shown.total, SIZE.row), y, M.view_h)
end

-- Scrolls the least that shows the chosen cell: down in the rows, across in the outer box.
function M.reveal(shown)
	local cell = S.cell
	if not cell then
		return
	end
	local y = layout.scroll_offset(M.GRID)
	local _, x = layout.scroll_offset(M.ACROSS)
	local top = (cell.row - 1) * SIZE.row
	if top < y then
		layout.scroll_to(M.GRID, { y = top })
	elseif top + SIZE.row > y + M.view_h then
		layout.scroll_to(M.GRID, { y = top + SIZE.row - M.view_h })
	end
	local numbers = numbers_width(shown)
	local left = numbers
	local widths = M.widths(shown)
	for index = 1, cell.column - 1 do
		left += widths[index]
	end
	local right = left + widths[cell.column]
	if left - numbers < x then
		layout.scroll_to(M.ACROSS, { x = math.max(left - numbers, 0) })
	elseif right > x + M.view_w then
		layout.scroll_to(M.ACROSS, { x = right - M.view_w })
	end
end

-- Both boxes back to the start, for a new result.
function M.home()
	layout.scroll_to(M.GRID, { x = 0, y = 0 })
	layout.scroll_to(M.ACROSS, { x = 0, y = 0 })
end

-- The chosen cell moved by `dr` rows and `dc` columns, kept on the grid.
function M.move(shown, dr, dc)
	local cell = S.cell or { row = 1, column = 1 }
	S.cell = {
		row = math.clamp(cell.row + dr, 1, math.max(shown.total, 1)),
		column = math.clamp(cell.column + dc, 1, #shown.columns),
	}
	M.reveal(shown)
end

-- The value of the chosen cell as it is here (cut where it is long), or nil.
function M.value(shown, cell)
	cell = cell or S.cell
	if not cell then
		return nil
	end
	local values = shown.rows[M.row_at(shown, cell.row)]
	return values and values[cell.column]
end

-- The rows that are here, as tab-separated text, at most `most` bytes of it.
function M.as_text(shown, most)
	local lines = {}
	local names = {}
	for _, column in shown.columns do
		names[#names + 1] = column.name
	end
	lines[1] = table.concat(names, "\t")
	local size = #lines[1]
	for place = 1, shown.total do
		local values = shown.rows[M.row_at(shown, place)]
		if not values then
			break
		end
		local cells = {}
		for column = 1, #shown.columns do
			local value = values[column]
			cells[column] = value == nil and "" or string.gsub(value, "[\t\n]", " ")
		end
		local line = table.concat(cells, "\t")
		size += #line + 1
		if size > most then
			break
		end
		lines[#lines + 1] = line
	end
	return table.concat(lines, "\n"), #lines - 1
end

-- Sorts by `column`: up, then down, then as it came.
function M.sort(shown, column)
	local sort = shown.sort
	if sort and sort.column == column then
		if sort.descending then
			shown.sort = nil
		else
			shown.sort = { column = column, descending = true }
		end
	else
		shown.sort = { column = column, descending = false }
	end
	shown.order = nil
end

return M
