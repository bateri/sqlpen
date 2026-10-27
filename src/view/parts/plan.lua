-- How a statement is run, as a tree of steps: each with a bar of its share of the whole (of the time
-- it took, where it was run with ANALYZE; of the planner's cost otherwise), what the planner thought
-- it gives and, run, what it gave. A step that reads a whole table is marked: it is where an index is
-- missed most often.

local kit = require("../lib/kit")
local sql = require("../lib/sql")
local b = kit.b

local M = {}

M.PLAN = "plan"

local function reads_all(label)
	return string.match(label, "^Seq Scan") ~= nil or string.match(label, "^SCAN ") ~= nil
end

local function number(value)
	if value == nil then
		return nil
	end
	if value >= 1000 then
		return sql.compact(value)
	end
	if value == math.floor(value) then
		return tostring(math.floor(value))
	end
	return string.format("%.2f", value)
end

local function step_row(step, depth, whole, analyze, rows)
	local share = nil
	if analyze and step.time and whole.time and whole.time > 0 then
		share = step.time / whole.time
	elseif step.cost and whole.cost and whole.cost > 0 then
		share = step.cost / whole.cost
	end
	local warn = reads_all(step.label) and (step.rows or step.actual_rows or 0) >= 1000
	local title = b.div()
		:row()
		:items_center()
		:gap(8)
		:child(kit.icon(warn and "triangle-alert" or "layers", 13, warn and "warning" or "quiet"))
		:child(b.text(step.label):weight(depth == 0 and 650 or 550):truncate():grow(1):min_w(0))
	local figures = {}
	if step.time then
		figures[#figures + 1] = number(step.time) .. " ms"
	end
	if step.actual_rows then
		figures[#figures + 1] = number(step.actual_rows) .. " rows"
	elseif step.rows then
		figures[#figures + 1] = "≈" .. number(step.rows) .. " rows"
	end
	if step.cost then
		figures[#figures + 1] = "cost " .. number(step.cost)
	end
	if #figures > 0 then
		title:child(b.text(table.concat(figures, " · ")):text_size(11):color("dim"):no_shrink())
	end
	local box = b.div():col():gap(3):pl(14 + depth * 18):pr(14):py(5):child(title)
	if share then
		box:child(
			b.div():h(4):w_full():rounded(2):bg("raised2"):child(
				b.div():h_full():w_pct(math.clamp(share * 100, 1, 100)):rounded(2)
					:bg(warn and "warning" or b.alpha("accent", 0.8))
			)
		)
	end
	for _, words in step.detail do
		box:child(b.text(words):text_size(11):color("quiet"):family("terminal"):truncate())
	end
	rows[#rows + 1] = box
	for _, child in step.children do
		step_row(child, depth + 1, whole, analyze, rows)
	end
end

-- The plan `plan` (the program's tree, its root the statement), run with ANALYZE or not.
function M.view(plan, analyze)
	local rows = {}
	local top = plan.children[1] or plan
	for _, step in plan.children do
		step_row(step, 0, top, analyze, rows)
	end
	local list = b.div():id(M.PLAN):col():grow(1):min_h(0):scroll():py(6)
	if #plan.detail > 0 then
		list:child(b.div():px(14):pb(4):child(b.text(table.concat(plan.detail, " · ")):text_size(11):color("dim")))
	end
	list:children(rows)
	if #rows == 0 then
		list:child(b.div():p(14):child(b.text("The database gave no steps for it."):color("dim")))
	end
	return list
end

return M
