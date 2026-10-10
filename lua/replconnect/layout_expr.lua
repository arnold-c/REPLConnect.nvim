-- A small, non-evaluating parser for layout strings.
-- Precedence (tightest first): @ size, \ alternatives, / stack, | columns.
-- Alternatives compile to a collapsible container plus layout-local groups.
local M = {}

function M.parse(source, path)
	path = path or "layout"
	local tokens, pos = {}, 1
	local function fail(message, at)
		error(("%s at character %d: %s"):format(path, at or pos, message), 0)
	end
	while pos <= #source do
		local rest = source:sub(pos)
		local spaces = rest:match("^%s+")
		local name = rest:match("^[%a_][%w_]*")
		local number = rest:match("^%d+%.?%d*") or rest:match("^%.%d+")
		local symbol = rest:sub(1, 1)
		if spaces then
			pos = pos + #spaces
		elseif name or number then
			local value = name or number
			tokens[#tokens + 1] = { kind = name and "name" or "number", value = value, at = pos }
			pos = pos + #value
		elseif symbol:match("^[|/\\()@%%]$") then
			tokens[#tokens + 1] = { kind = symbol, at = pos }
			pos = pos + 1
		else
			fail("unexpected character " .. string.format("%q", symbol))
		end
	end
	tokens[#tokens + 1] = { kind = "end", at = #source + 1 }
	local index = 1
	local function peek() return tokens[index].kind end
	local function take(kind)
		local token = tokens[index]
		if token.kind ~= kind then fail("expected " .. kind .. ", got " .. token.kind, token.at) end
		index = index + 1
		return token
	end
	local expression
	local function primary()
		local node
		if peek() == "(" then
			take("(")
			node = expression()
			take(")")
		else
			node = { name = take("name").value }
		end
		if peek() == "@" then
			local annotation = take("@")
			if node.size then fail("region already has a size", annotation.at) end
			local token = take("number")
			local value = tonumber(token.value)
			if not value or value <= 0 or value == math.huge then fail("size must be positive and finite", token.at) end
			if peek() == "%" then
				take("%")
				if value > 100 then fail("percentage must be at most 100%", token.at) end
				node.size = value / 100
			else
				if value % 1 ~= 0 then fail("cell size must be an integer; use % for percentages", token.at) end
				node.size, node.size_cells = value, true
			end
		end
		return node
	end
	local function chain(next_parser, symbol, dir)
		local first = next_parser()
		if peek() ~= symbol then return first end
		local children = { first }
		while peek() == symbol do
			take(symbol)
			children[#children + 1] = next_parser()
		end
		return { dir = dir, children = children }
	end
	local function alternatives() return chain(primary, "\\", "choice") end
	local function stack() return chain(alternatives, "/", "col") end
	expression = function() return chain(stack, "|", "row") end
	local root = expression()
	take("end")

	local groups = {}
	local function compile(node)
		if node.name then return node end
		if node.dir == "choice" then
			local group, children = {}, {}
			local function append(child)
				if child.name and child.name ~= "editor" and not child.size then
					group[#group + 1] = child.name
					children[#children + 1] = child
				elseif child.dir == "choice" and not child.size then
					for _, alternative in ipairs(child.children) do append(alternative) end
				else
					fail("\\ alternatives must be unsized pane names other than editor; size the whole (a \\ b) region", 1)
				end
			end
			for _, child in ipairs(node.children) do append(child) end
			groups[#groups + 1] = group
			return { dir = "col", children = children, size = node.size, size_cells = node.size_cells, alternatives = true }
		end
		for i, child in ipairs(node.children) do node.children[i] = compile(child) end
		return node
	end
	return compile(root), groups
end

return M
