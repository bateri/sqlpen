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

-- Places are the kit's: a byte of the text, counted from 1, and a range `[from, to)` whose end is not
-- in it, so that `string.sub(text, from, to - 1)` is what it holds (the kit's specification, §2.7).
-- Everything here reads the bytes of the text as they are: the bytes of a character that is more than
-- one are all 128 or more, none of them is a quote, a `;` or a space, and in a name they count as letters.

local function is_digit(byte)
	return byte >= 48 and byte <= 57
end

local function is_letter(byte)
	return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
end

-- A byte of a word: a letter, a digit, `_`, or a part of a character that is more than one byte.
local function is_word(byte)
	return is_letter(byte) or is_digit(byte) or byte >= 128
end

local function is_space(byte)
	return byte == 32 or (byte >= 9 and byte <= 13)
end

local DOLLAR, COLON, QUESTION, DASH, SLASH, STAR = 36, 58, 63, 45, 47, 42
local QUOTE, DOUBLE, TICK, SEMI, NEWLINE, DOT = 39, 34, 96, 59, 10, 46

-- The words of a line and what each is: { from =, to =, kind = } in bytes of the line from 1, the
-- end not in it. A line is read alone: a string or a comment that goes on to the next line is not
-- followed there.
function M.lex(line)
	local tokens = {}
	local count = #line
	local at = 1
	local function closing(close, from)
		local finish = from
		while finish <= count and string.byte(line, finish) ~= close do
			finish += 1
		end
		return math.min(finish, count)
	end
	-- A word of `kind` from `at` to `finish`, the last byte in it.
	local function token(kind, finish)
		tokens[#tokens + 1] = { from = at, to = finish + 1, kind = kind }
	end
	while at <= count do
		local c = string.byte(line, at)
		local after = string.byte(line, at + 1)
		if c == DASH and after == DASH then
			token("comment", count)
			break
		elseif c == SLASH and after == STAR then
			local finish = at + 2
			while finish < count and not (string.byte(line, finish) == STAR and string.byte(line, finish + 1) == SLASH) do
				finish += 1
			end
			finish = math.min(finish + 1, count)
			token("comment", finish)
			at = finish + 1
		elseif c == QUOTE then
			local finish = closing(QUOTE, at + 1)
			token("string", finish)
			at = finish + 1
		elseif c == DOUBLE or c == TICK then
			local finish = closing(c, at + 1)
			token("quoted", finish)
			at = finish + 1
		elseif
			(c == DOLLAR or c == COLON or c == QUESTION)
			and after
			and (is_letter(after) or is_digit(after))
			and (at == 1 or string.byte(line, at - 1) ~= COLON)
		then
			local finish = at + 1
			while finish < count and (is_letter(string.byte(line, finish + 1)) or is_digit(string.byte(line, finish + 1))) do
				finish += 1
			end
			token("param", finish)
			at = finish + 1
		elseif is_digit(c) and (at == 1 or not (is_letter(string.byte(line, at - 1)) or is_digit(string.byte(line, at - 1)))) then
			local finish = at
			while finish < count do
				local next_byte = string.byte(line, finish + 1)
				if not (is_digit(next_byte) or next_byte == DOT or next_byte == 101 or next_byte == 69) then
					break
				end
				finish += 1
			end
			token("number", finish)
			at = finish + 1
		elseif is_letter(c) or c >= 128 then
			local finish = at
			while finish < count and is_word(string.byte(line, finish + 1)) do
				finish += 1
			end
			local word = string.lower(string.sub(line, at, finish))
			if IS_KEYWORD[word] then
				token("keyword", finish)
			elseif IS_FUNCTION[word] and string.byte(line, finish + 1) == 40 then
				token("func", finish)
			end
			at = finish + 1
		else
			at += 1
		end
	end
	return tokens
end

-- The statements of a text: { from =, to = } in bytes from 1, the end not in it, each without the
-- space and the `;` around it. A `;` in a string, a quoted name or a comment ends nothing.
function M.statements(text)
	local found = {}
	local start = 1
	local at = 1
	local count = #text
	local function close(from, to)
		while from <= to and is_space(string.byte(text, from)) do
			from += 1
		end
		while to >= from and is_space(string.byte(text, to)) do
			to -= 1
		end
		if from <= to then
			found[#found + 1] = { from = from, to = to + 1 }
		end
	end
	while at <= count do
		local c = string.byte(text, at)
		if c == DASH and string.byte(text, at + 1) == DASH then
			while at <= count and string.byte(text, at) ~= NEWLINE do
				at += 1
			end
		elseif c == SLASH and string.byte(text, at + 1) == STAR then
			at += 2
			while at < count and not (string.byte(text, at) == STAR and string.byte(text, at + 1) == SLASH) do
				at += 1
			end
			at += 2
		elseif c == QUOTE or c == DOUBLE or c == TICK then
			at += 1
			while at <= count and string.byte(text, at) ~= c do
				at += 1
			end
			at += 1
		elseif c == SEMI then
			close(start, at - 1)
			start = at + 1
			at += 1
		else
			at += 1
		end
	end
	close(start, count)
	return found
end

-- Whether the statement from `from` to `to` (the end not in it) of `text` is nothing but comments.
local function only_comments(text, from, to)
	local body = string.sub(text, from, to - 1)
	body = string.gsub(body, "%-%-[^\n]*", "")
	body = string.gsub(body, "/%*.-%*/", "")
	return string.match(body, "^%s*$") ~= nil
end

-- The statement the caret at `caret` (a place) is in, or the one just before it (a caret after the
-- `;`, or on the empty line after a statement): { from =, to =, text = }; nil in a text of no
-- statement.
function M.statement_at(text, caret)
	local found = M.statements(text)
	local best = nil
	for _, statement in found do
		if not only_comments(text, statement.from, statement.to) then
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
			if not only_comments(text, statement.from, statement.to) then
				best = statement
				break
			end
		end
	end
	if best == nil then
		return nil
	end
	-- The comments before a statement are not sent: a mistake's place is counted from its first word.
	local from = best.from
	while from < best.to do
		if string.byte(text, from) == DASH and string.byte(text, from + 1) == DASH then
			while from < best.to and string.byte(text, from) ~= NEWLINE do
				from += 1
			end
		elseif is_space(string.byte(text, from)) then
			from += 1
		else
			break
		end
	end
	return { from = from, to = best.to, text = string.sub(text, from, best.to - 1) }
end

-- The end of the word that starts at the place `at` of `text`: where a mistake's mark ends (the end
-- is not in the mark, and the mark is a byte at least).
function M.word_end(text, at)
	local finish = at
	while finish <= #text do
		local byte = string.byte(text, finish)
		if not (is_letter(byte) or is_digit(byte) or byte == DOT or byte >= 128) then
			break
		end
		finish += 1
	end
	return math.max(finish, at + 1)
end

-- --- Completions -------------------------------------------------------------------------------

-- Whether the end of `line` (the text of a line up to the caret) is in a string, a quoted name or a
-- comment: nothing is completed there.
function M.in_words(line)
	local count = #line
	for _, token in M.lex(line) do
		if token.to == count + 1 then
			local size = token.to - token.from
			if token.kind == "comment" then
				-- A `--` comment goes to the end of the line; a `/* */` one is behind a caret after it.
				return not (string.byte(line, token.from) == SLASH and size >= 4 and string.sub(line, -2) == "*/")
			elseif token.kind == "string" or token.kind == "quoted" then
				-- The opening quote alone, or no closing one: the caret is inside.
				local quote = string.byte(line, token.from)
				return not (size >= 2 and string.byte(line, count) == quote)
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
-- the schema. { from = (bytes back from the caret where the word starts), word =, items = {
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
		return #items > 0 and { from = #word, word = word, items = sorted() } or nil
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
	return { from = #word, word = word, items = sorted() }
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
