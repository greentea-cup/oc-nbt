-- vim: set ft=lua fdm=indent :
local M = {}

M.TAG_End        = 0x00
M.TAG_Byte       = 0x01
M.TAG_Short      = 0x02
M.TAG_Int        = 0x03
M.TAG_Long       = 0x04
M.TAG_Float      = 0x05
M.TAG_Double     = 0x06
M.TAG_Byte_Array = 0x07
M.TAG_String     = 0x08
M.TAG_List       = 0x09
M.TAG_Compound   = 0x0a
M.TAG_Int_Array  = 0x0b
M.TAG_Long_Array = 0x0c

local tag_sizes = {
	[M.TAG_End] = 0,
	1, 2, 4, 8, --[[byte, short, int, long]]
	4, 8, --[[float, double]]
	1, --[[byte array]]
	-1, -1, -1, --[[dynamic containers]]
	4, 8, --[[int array, long array]]
}

---@param s integer[]
---@param pos integer?
---@param slen integer?
---@param inside_list integer? set tag_id and skip tag_id + name
---@return integer|nil
---@return integer|nil
---@return string|nil
---@return string|integer|table|nil
function M.parse_nbt(s, pos, slen, inside_list)
	local function b(n)
		local x = 0
		for _ = 1, n do
			x, pos = (x << 8) | s[pos], pos + 1
		end
		return x
	end
	if s == nil then return nil end
	pos = pos or 1
	slen = slen or #s
	local tag_id, name_size, name, payload
	if inside_list then
		tag_id = inside_list
	else
		tag_id = b(1)
		if tag_id ~= M.TAG_End then
			name_size = b(2)
			if name_size > 0 then
				name = string.char(table.unpack(s, pos, pos+name_size-1))
				pos = pos + name_size
			end
		end
	end
	if tag_id == M.TAG_End then return pos, M.TAG_End, nil, nil
	elseif tag_id == M.TAG_Byte then payload = b(1)
	elseif tag_id == M.TAG_Short then payload = b(2)
	elseif tag_id == M.TAG_Int then payload = b(4)
	elseif tag_id == M.TAG_Long then payload = b(8)
	elseif tag_id == M.TAG_Float then
		local x = string.pack(">I4", b(4))
		payload = string.unpack(">f", x)
	elseif tag_id == M.TAG_Double then
		local x = string.pack(">I8", b(8))
		payload = string.unpack(">d", x)
	elseif tag_id == M.TAG_String then
		local len = b(2)
		payload = string.char(table.unpack(s, pos, pos+len-1))
		pos = pos + len
	elseif tag_id == M.TAG_List then
		local list_type = b(1)
		local len = b(4)
		payload = {n = len}
		for i = 1, len do
			local tag_payload
			---@diagnostic disable-next-line cast-local-type pos
			pos, _, _, tag_payload = M.parse_nbt(s, pos, slen, list_type)
			payload[i] = tag_payload
		end
	elseif tag_id == M.TAG_Compound then
		local inner_id, inner_name, inner_payload
		payload = {}
		while true do
			---@diagnostic disable-next-line cast-local-type pos
			pos, inner_id, inner_name, inner_payload = M.parse_nbt(s, pos, slen)
			if inner_id == M.TAG_End or inner_name == nil then break end
			payload[inner_name] = inner_payload
		end
	elseif tag_id == M.TAG_Byte_Array or
		tag_id == M.TAG_Int_Array or
		tag_id == M.TAG_Long_Array then
		local payload_size = tag_sizes[tag_id]
		local len = b(4)
		payload = {n = len}
		for i = 1, len do payload[i] = b(payload_size) end
	end
	return pos, tag_id, name, payload
end

return M
