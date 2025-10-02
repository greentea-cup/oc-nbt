local I = require("inflate")
local N = require("nbt_parser")
local M = {}

---@param tag string gzipped binary nbt of item stack
---@return integer[] binary nbt; decode with decode_nbt_from_bytes
function M.decompress_tag(tag)
	local nbt_bytes, gzip_state = {}, {}
	repeat
		local inflate_status, res = I.gzip_inflate(tag, gzip_state)
		if inflate_status == I.INFLATE_BLOCK then
			for _, v in ipairs(res) do table.insert(nbt_bytes, v) end
		elseif inflate_status == I.INFLATE_GZIP_HEADER then -- ignore header
		elseif inflate_status == I.INFLATE_GZIP_TRAILER then -- ignore trailer
		elseif inflate_status == I.INFLATE_END_OF_DATA then -- do nothing
		elseif inflate_status == I.INFLATE_NOT_ENOUGH_DATA then
			error("Insufficient data to continue decoding") -- break
		end
	until inflate_status == I.INFLATE_END_OF_DATA
	return nbt_bytes
end

---@param tag string gzipped binary nbt of item stack
---@return string|integer|table|nil nbt in a form of lua table
function M.decode_nbt_from_tag(tag)
	local nbt_bytes = M.decompress_tag(tag)
	local _, _, _, nbt = N.parse_nbt(nbt_bytes)
	return nbt
end

return M
