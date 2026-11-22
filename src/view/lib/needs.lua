-- What this page asks of the kit it runs in, by the names the kit answers to (`pencere.has`): a host older
-- than that has no `pencere.has` at all, and would stop the page for a role or a method it does not know.
-- The page says so on a screen of its own instead, and does nothing else.

local needs = {}

-- The layer the value's card is (`element.layer`) and the roles it and the grid's edges name
-- (`role.dialog`, `role.none`, `role.slider`).
local NAMES = { "element.layer", "role.dialog", "role.none", "role.slider" }

-- Whether the kit has all of it.
function needs.met()
	if pencere.has == nil then
		return false
	end
	for _, name in NAMES do
		if not pencere.has(name) then
			return false
		end
	end
	return true
end

-- The page of a host that has not: a sentence, and nothing to do.
function needs.screen()
	local function render()
		return pencere.div():size_full():items_center():justify_center():p(24):child(
			pencere.text("This version of sqlpen needs a newer version of the application: please update it.")
		),
			false,
			nil
	end
	return {
		render = render,
		handle = function()
			return nil
		end,
		settle = function() end,
	}
end

return needs
