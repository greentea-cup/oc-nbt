-- vim: set ft=lua fdm=indent :
local component = require("component")
-- local I = require("inflate")
-- I.debug.all = true
-- local N = require("nbt_parser")
local N = require("oc_nbt")

local M = {}
--- Favor numbers first,
--- then compare values within each type,
--- then compare string representations of different types
function M.default_key_cmp(a, b)
	local ta, tb = type(a), type(b)
	if ta == tb then return a < b
	elseif ta == "number" then return true
	elseif tb == "number" then return false
	end
	return tostring(a) < tostring(b)
end

function M.print_table_recursive(x, params, spacing)
	params = params or {}
	params.spacing_str = params.spacing_str or "  "
	spacing = spacing or 0
	params.key_cmp = params.key_cmp or M.default_key_cmp
	local tx = type(x)
	if tx == "string" then
		io.write(string.format('%q', x:gsub("\\\n", "\\n")))
		return
	elseif tx ~= "table" then
		io.write(x)
		return
	end
	local keys = {}
	for k, _ in pairs(x) do table.insert(keys, k) end
	table.sort(keys, params.key_cmp)
	if #keys == 0 then
		io.write("{}")
	else
		io.write("{\n")
		for i = 1, #keys do
			local k = keys[i]
			local v = x[k]
			for _ = 0, spacing do io.write(params.spacing_str) end
			io.write(k)
			io.write(': ')
			M.print_table_recursive(v, params, spacing + 1)
			io.write(",\n")
		end
		for _ = 1, spacing do io.write(params.spacing_str) end
		io.write("}")
	end
end


-- local compressed_file, err = io.open("complex-tag.gz")
-- if compressed_file == nil then error(err) end
-- local compressed_data = compressed_file:read("*a")
-- compressed_file:close()
local item_stack = component.inventory_controller.getStackInSlot(1, 1)
if item_stack == nil then print("No item present"); goto EOF end
if item_stack.tag == nil then print("No nbt present in item"); goto EOF end

local nbt_table = N.decode_nbt_from_tag(item_stack.tag)
M.print_table_recursive(nbt_table)

::EOF::

