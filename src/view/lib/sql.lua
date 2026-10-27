-- SQL, as the page knows it: the words of a line and what each is (for colours), the statements of a
-- text and the one the caret is in, and what may be written where the caret is (for completions).
-- The terminal's editor knows no language; this is what makes SQL of it.
--
-- The lexer began as the one of pencere's `examples/editor-lua` (Apache-2.0).

local M = {}

local KEYWORDS = {
	"select", "from", "where", "group", "by", "order", "having", "limit", "offset", "insert", "into",
	"values", "update", "set", "delete", "create", "table", "drop", "alter", "join", "left", "right",
	"inner", "outer", "full", "cross", "lateral", "on", "using", "and", "or", "not", "null", "is",
	"in", "as", "distinct", "case", "when", "then", "else", "end", "begin", "commit", "rollback",
	"union", "intersect", "except", "all", "any", "exists", "between", "like", "ilike", "asc", "desc",
	"nulls", "first", "last", "with", "recursive", "returning", "default", "primary", "key",
	"references", "foreign", "unique", "check", "constraint", "index", "view", "materialized",
	"explain", "analyze", "true", "false", "filter", "over", "partition", "window", "rows", "range",
	"fetch", "next", "only", "cast", "if", "replace", "temporary", "temp", "vacuum", "pragma",
	"conflict", "do", "nothing", "glob", "escape", "collate", "interval", "show", "grant", "revoke",
}
local FUNCTIONS = {
	"count", "sum", "avg", "min", "max", "coalesce", "nullif", "lower", "upper", "length", "round",
	"abs", "now", "date", "datetime", "strftime", "date_trunc", "extract", "to_char", "substr",
	"substring", "trim", "concat", "string_agg", "array_agg", "json_extract", "json_object",
	"jsonb_build_object", "row_number", "rank", "dense_rank", "lag", "lead", "greatest", "least",
	"random", "printf", "format", "cast", "total", "group_concat", "generate_series",
}
local IS_KEYWORD, IS_FUNCTION = {}, {}
for _, word in KEYWORDS do
	IS_KEYWORD[word] = true
end
for _, word in FUNCTIONS do
	IS_FUNCTION[word] = true
end
M.KEYWORDS = KEYWORDS

-- The looks of the words, in the roles of the terminal's theme: they follow the theme it wears.
M.LOOKS = {
	keyword = { color = "accent", weight = 650 },
	func = { color = "cyan" },
	string = { color = "success" },
	number = { color = "warning" },
	comment = { color = "dim", italic = true },
	quoted = { color = "magenta" },
	param = { color = "info", italic = true },
}

-- The characters of a text, one string each.
local function chars_of(text)
	local chars = {}
	for _, code in utf8.codes(text) do
		chars[#chars + 1] = utf8.char(code)
	end
	return chars
end
M.chars_of = chars_of

-- The words of a line and what each is: { from =, to =, kind = } in characters from 0 of the line.
-- A line is read alone: a string or a comment that goes on to the next line is not followed there.
function M.lex(line)
	local tokens = {}
	local chars = chars_of(line)
	local at = 1
	local count = #chars
	local function closing(close, from)
		local finish = from
		while finish <= count and chars[finish] ~= close do
			finish += 1
		end
		return math.min(finish, count)
	end
	while at <= count do
		local c = chars[at]
		local after = chars[at + 1]
		if c == "-" and after == "-" then
			tokens[#tokens + 1] = { from = at - 1, to = count, kind = "comment" }
			break
		elseif c == "/" and after == "*" then
			local finish = at + 2
			while finish < count and not (chars[finish] == "*" and chars[finish + 1] == "/") do
				finish += 1
			end
			finish = math.min(finish + 1, count)
			tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "comment" }
			at = finish + 1
		elseif c == "'" then
			local finish = closing("'", at + 1)
			tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "string" }
			at = finish + 1
		elseif c == '"' or c == "`" then
			local finish = closing(c, at + 1)
			tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "quoted" }
			at = finish + 1
		elseif (c == "$" or c == ":" or c == "?") and after and string.match(after, "[%w_]") and (at == 1 or chars[at - 1] ~= ":") then
			local finish = at + 1
			while finish < count and string.match(chars[finish + 1], "[%w_]") do
				finish += 1
			end
			tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "param" }
			at = finish + 1
		elseif string.match(c, "%d") and (at == 1 or not string.match(chars[at - 1], "[%w_]")) then
			local finish = at
			while finish < count and string.match(chars[finish + 1], "[%d%.eE]") do
				finish += 1
			end
			tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "number" }
			at = finish + 1
		elseif string.match(c, "[%a_]") or #c > 1 then
			local finish = at
			while finish < count and (string.match(chars[finish + 1], "[%w_]") or #chars[finish + 1] > 1) do
				finish += 1
			end
			local word = string.lower(table.concat(chars, "", at, finish))
			if IS_KEYWORD[word] then
				tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "keyword" }
			elseif IS_FUNCTION[word] and chars[finish + 1] == "(" then
				tokens[#tokens + 1] = { from = at - 1, to = finish, kind = "func" }
			end
			at = finish + 1
		else
			at += 1
		end
	end
	return tokens
end

-- The statements of a text: { from =, to = } in characters from 0, the end not in it, each without
-- the space and the `;` around it. A `;` in a string, a quoted name or a comment ends nothing.
function M.statements(text)
	local chars = chars_of(text)
	local found = {}
	local start = 1
	local at = 1
	local count = #chars
	local function close(from, to)
		while from <= to and string.match(chars[from], "%s") do
			from += 1
		end
		while to >= from and string.match(chars[to], "%s") do
			to -= 1
		end
		if from <= to then
			found[#found + 1] = { from = from - 1, to = to }
		end
	end
	while at <= count do
		local c = chars[at]
		if c == "-" and chars[at + 1] == "-" then
			while at <= count and chars[at] ~= "\n" do
				at += 1
			end
		elseif c == "/" and chars[at + 1] == "*" then
			at += 2
			while at < count and not (chars[at] == "*" and chars[at + 1] == "/") do
				at += 1
			end
			at += 2
		elseif c == "'" or c == '"' or c == "`" then
			at += 1
			while at <= count and chars[at] ~= c do
				at += 1
			end
			at += 1
		elseif c == ";" then
			close(start, at - 1)
			start = at + 1
			at += 1
		else
			at += 1
		end
	end
	close(start, count)
	return found, chars
end

-- Whether the statement from `from` to `to` of `chars` is nothing but comments.
local function only_comments(chars, from, to)
	local text = table.concat(chars, "", from + 1, to)
	text = string.gsub(text, "%-%-[^\n]*", "")
	text = string.gsub(text, "/%*.-%*/", "")
	return string.match(text, "^%s*$") ~= nil
end

-- The statement the caret at `caret` is in, or the one just before it (a caret after the `;`, or on
-- the empty line after a statement): { from =, to =, text = }; nil in a text of no statement.
function M.statement_at(text, caret)
	local found, chars = M.statements(text)
	local best = nil
	for _, statement in found do
		if not only_comments(chars, statement.from, statement.to) then
			if statement.from <= caret and caret <= statement.to + 1 then
				best = statement
				break
			elseif statement.to < caret then
				best = statement
			end
		end
	end
	if best == nil then
		for _, statement in found do
			if not only_comments(chars, statement.from, statement.to) then
				best = statement
				break
			end
		end
	end
	if best == nil then
		return nil
	end
	-- The comments before a statement are not sent: a mistake's place is counted from its first word.
	local from = best.from + 1
	while from <= best.to do
		if chars[from] == "-" and chars[from + 1] == "-" then
			while from <= best.to and chars[from] ~= "\n" do
				from += 1
			end
		elseif string.match(chars[from], "%s") then
			from += 1
		else
			break
		end
	end
	return { from = from - 1, to = best.to, text = table.concat(chars, "", from, best.to) }
end

-- The end of the word that starts at `at` in `chars` (from 0): where a mistake's mark ends.
function M.word_end(chars, at)
	local finish = at + 1
	while finish <= #chars and (string.match(chars[finish], "[%w_%.]") or #chars[finish] > 1) do
		finish += 1
	end
	return math.max(finish - 1, at + 1)
end

-- --- Completions -------------------------------------------------------------------------------

-- Whether the end of `line` (the text of a line up to the caret) is in a string, a quoted name or a
-- comment: nothing is completed there.
function M.in_words(line)
	local chars = chars_of(line)
	local count = #chars
	for _, token in M.lex(line) do
		if token.to == count then
			if token.kind == "comment" then
				-- A `--` comment goes to the end of the line; a `/* */` one is behind a caret after it.
				return not (chars[1 + token.from] == "/" and count - token.from >= 4 and chars[count - 1] == "*" and chars[count] == "/")
			elseif token.kind == "string" or token.kind == "quoted" then
				-- The opening quote alone, or no closing one: the caret is inside.
				local quote = chars[1 + token.from]
				return not (count - token.from >= 2 and chars[count] == quote)
			end
		end
	end
	return false
end

-- The tables a statement names, by the names it calls them: `from shop.orders o join customers c`
-- is { o = "shop.orders", orders = "shop.orders", c = "customers", customers = "customers" }.
local function names_in(text)
	local names = {}
	local lower = string.lower(text)
	for keyword, table_name, alias in string.gmatch(lower, "(%a+)%s+([%w_%.\"]+)%s*a?s?%s*([%w_]*)") do
		if keyword == "from" or keyword == "join" or keyword == "update" or keyword == "into" then
			local plain = string.gsub(table_name, '"', "")
			local short = string.match(plain, "([%w_]+)$") or plain
			names[short] = plain
			if alias ~= "" and not IS_KEYWORD[alias] then
				names[alias] = plain
			end
		end
	end
	return names
end

-- The table of the schema a name means: `orders`, `shop.orders`.
local function table_named(tables, name)
	for _, entry in tables do
		if entry.name == name or (entry.schema .. "." .. entry.name) == name then
			return entry
		end
	end
	return nil
end

-- What may be written at the caret: `before` is the text of the statement up to the caret, `tables`
-- the schema. { from = (characters back from the caret where the word starts), word =, items = {
-- { word =, kind =, detail = } } }, or nil where nothing is to be offered.
function M.complete(before, tables, forced)
	local word = string.match(before, "([%a_][%w_]*)$") or ""
	local rest = string.sub(before, 1, #before - #word)
	local qualifier = string.match(rest, "([%a_][%w_]*)%.$")
	if word == "" and not qualifier and not forced then
		return nil
	end
	if #word < 2 and not qualifier and not forced then
		return nil
	end
	local lower = string.lower(word)
	local items = {}
	local seen = {}
	-- The kinds come in the order they are offered; within a kind the shortest word first (what
	-- was typed is most of it), then by name.
	local group = 0
	-- `candidate` is what is written; it is found by `name` (its own words where they differ: a
	-- table off the search path is found by its name and written with its schema).
	local function offer(candidate, kind, detail, name)
		local key = string.lower(candidate)
		local found = string.lower(name or candidate)
		if seen[key] or key == lower then
			return
		end
		if lower == "" or string.sub(found, 1, #lower) == lower or string.sub(key, 1, #lower) == lower then
			seen[key] = true
			items[#items + 1] = { word = candidate, kind = kind, detail = detail, group = group }
		end
	end
	-- A table as a statement can name it: by its name where the database finds it so, with its
	-- schema where it is not on the path (PostgreSQL's `search_path`).
	local function offer_table(entry, detail)
		local written = M.quoted(entry.name)
		if entry.visible == false then
			written = M.quoted(entry.schema) .. "." .. written
		end
		offer(written, entry.kind, detail, entry.name)
	end
	local function sorted()
		table.sort(items, function(x, y)
			if x.group ~= y.group then
				return x.group < y.group
			end
			if #x.word ~= #y.word then
				return #x.word < #y.word
			end
			return x.word < y.word
		end)
		return items
	end
	local names = names_in(before)
	if qualifier then
		local lower_qualifier = string.lower(qualifier)
		local named = names[lower_qualifier] or lower_qualifier
		local entry = table_named(tables, named)
		if entry then
			for _, column in entry.columns do
				offer(column.name, "column", column.type)
			end
		else
			-- A schema's name and a dot: its tables.
			for _, schema_entry in tables do
				if string.lower(schema_entry.schema) == lower_qualifier then
					offer(M.quoted(schema_entry.name), schema_entry.kind, schema_entry.rows and (M.compact(schema_entry.rows) .. " rows") or nil)
				end
			end
		end
		return #items > 0 and { from = utf8.len(word), word = word, items = sorted() } or nil
	end
	local previous = string.lower(string.match(rest, "([%a_]+)%s*$") or "")
	local wants_table = previous == "from" or previous == "join" or previous == "into" or previous == "update" or previous == "table"
	if wants_table then
		for _, entry in tables do
			offer_table(entry, entry.rows and (M.compact(entry.rows) .. " rows") or entry.schema)
		end
	else
		-- The columns of the tables the statement names come first: they are what is meant most.
		for _, named in names do
			local entry = table_named(tables, named)
			if entry then
				for _, column in entry.columns do
					offer(column.name, "column", entry.name .. " · " .. column.type)
				end
			end
		end
		local upper = word ~= "" and string.upper(word) == word
		group = 1
		for _, keyword in KEYWORDS do
			offer(upper and string.upper(keyword) or keyword, "keyword", nil)
		end
		group = 2
		for _, name in FUNCTIONS do
			offer(name, "function", nil)
		end
		group = 3
		for _, entry in tables do
			offer_table(entry, entry.schema)
		end
	end
	if #items == 0 then
		return nil
	end
	return { from = utf8.len(word), word = word, items = sorted() }
end

-- A count in few characters: 950, 12.4k, 3.2M.
function M.compact(number)
	if number == nil then
		return ""
	end
	if number < 1000 then
		return tostring(math.floor(number))
	elseif number < 1e6 then
		return (string.gsub(string.format("%.1fk", number / 1e3), "%.0k$", "k"))
	elseif number < 1e9 then
		return (string.gsub(string.format("%.1fM", number / 1e6), "%.0M$", "M"))
	end
	return (string.gsub(string.format("%.1fG", number / 1e9), "%.0G$", "G"))
end

-- A name as a statement can say it: quoted where it is not a plain lower-case word.
function M.quoted(name)
	if string.match(name, "^[a-z_][a-z0-9_]*$") and not IS_KEYWORD[name] then
		return name
	end
	return '"' .. string.gsub(name, '"', '""') .. '"'
end

return M
