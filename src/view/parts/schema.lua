-- The list of what is in the database, at the left: its tables and views, by schema where there is
-- more than one, each with how many rows it has, opened to its columns. A click opens a table, a
-- double click shows its rows; a column's name goes into the statement where the caret is.

local kit = require("../lib/kit")
local sql = require("../lib/sql")
local b, S, SIZE = kit.b, kit.S, kit.SIZE

local M = {}

M.LIST = "schema"

-- The name of a table's row in the list, and of a column's.
function M.table_id(entry)
	return "table:" .. entry.schema .. "." .. entry.name
end
function M.column_id(entry, column)
	return "column:" .. entry.schema .. "." .. entry.name .. ":" .. column.name
end

-- The table a row of the list is, by its name.
function M.table_of(id)
	for _, entry in S.tables do
		if M.table_id(entry) == id then
			return entry
		end
	end
	return nil
end

function M.column_of(id)
	for _, entry in S.tables do
		for _, column in entry.columns do
			if M.column_id(entry, column) == id then
				return entry, column
			end
		end
	end
	return nil
end

local function table_row(entry, many_schemas)
	local id = M.table_id(entry)
	local key = entry.schema .. "." .. entry.name
	local open = S.open[key] == true
	local hover = kit.hovered(id)
	local row = b.div()
		:press(id)
		:row()
		:items_center()
		:gap(6)
		:h(26)
		:px(8)
		:ml(6)
		:mr(6)
		:rounded(5)
		:bg(hover and "raised2" or nil)
		:motion({ seconds = 0.12, color = true })
		:expanded(open)
		:tip(entry.kind == "view" and "A view: double-click to see its rows" or "Double-click to see its rows")
		:child(kit.icon(open and "chevron-down" or "chevron-right", 12, "quiet"))
		:child(kit.icon(entry.kind == "view" and "eye" or "table", 14, entry.kind == "view" and "magenta" or "blue"))
		:child(b.text(entry.name):truncate():grow(1):min_w(0):weight(open and 600 or 400))
	if entry.rows then
		row:child(b.text(sql.compact(entry.rows)):text_size(11):color("quiet"):no_shrink())
	end
	local box = b.div():col():child(row)
	if open then
		local columns = b.div():col():pl(30):pr(8):pb(4)
		for _, column in entry.columns do
			local cid = M.column_id(entry, column)
			columns:child(
				b.div()
					:press(cid)
					:row()
					:items_center()
					:gap(6)
					:h(22)
					:px(6)
					:rounded(4)
					:bg(kit.hovered(cid) and "raised2" or nil)
					:tip("Put " .. column.name .. " where the caret is")
					:child(column.key and kit.icon("key-round", 11, "warning") or b.div():w(11):h(11))
					:child(b.text(column.name):truncate():grow(1):min_w(0):text_size(12))
					:child(b.text(column.type):truncate():max_w(96):text_size(11):color("quiet"))
			)
		end
		box:child(columns)
	end
	return box
end

-- The list, `width` points wide.
function M.view(width)
	local list = b.div():id(M.LIST):col():grow(1):min_h(0):scroll():pt(4):pb(10)
	local schemas, count = {}, 0
	for _, entry in S.tables do
		if not schemas[entry.schema] then
			schemas[entry.schema] = true
			count += 1
		end
	end
	local many = count > 1
	local last_schema = nil
	if S.schema_error then
		list:child(b.div():p(12):child(b.text(S.schema_error):wrap():color("error")))
	elseif #S.tables == 0 then
		list:child(b.div():p(12):child(b.text(S.info and "No tables here yet." or "Reading the database…"):color("dim")))
	end
	for _, entry in S.tables do
		if many and entry.schema ~= last_schema then
			last_schema = entry.schema
			list:child(
				b.div():px(14):pt(10):pb(4):child(b.text(string.upper(entry.schema)):text_size(10.5):weight(700):color("quiet"))
			)
		end
		list:child(table_row(entry, many))
	end
	local tables, views = 0, 0
	for _, entry in S.tables do
		if entry.kind == "view" then
			views += 1
		else
			tables += 1
		end
	end
	local title = b.div()
		:row()
		:items_center()
		:justify_between()
		:h(32)
		:px(14)
		:no_shrink()
		:child(b.text("Tables"):weight(700):text_size(12))
		:child(b.text(views > 0 and string.format("%d · %d views", tables, views) or tostring(tables)):text_size(11):color("quiet"))
	return b.div():col():w(width):no_shrink():h_full():bg("raised1"):child(title):child(list)
end

return M
