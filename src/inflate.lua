-- vim: set ft=lua fdm=indent :
--[[ !
	Partially ported code from zlib, original license is preserved in ZLIB_LICENSE
	Source is at: https://github.com/madler/zlib
]]--

local M = {}
M.debug = {}

M.debug.all = false
M.debug.gzip_header = false
M.debug.block_header = false
M.debug.backref = false
M.debug.backref_verbose = false
M.debug.codelens = false
M.debug.tables = false
M.debug.block_dynamic = false
M.debug.block_decode = false
M.debug.block_decode_verbose = false

M.INFLATE_BACKBUFFER_CAPACITY = 32768

M.INFLATE_GZIP_HEADER = 1
M.INFLATE_GZIP_TRAILER = 2
M.INFLATE_BLOCK = 3
M.INFLATE_END_OF_DATA = 4
M.INFLATE_NOT_ENOUGH_DATA = -1

M.GZIP_HEADER = 101
M.GZIP_TRAIL = 111
M.BLOCK_HEADER = 1
M.BLOCK_RAW = 2
M.BLOCK_FIXED = 3
M.BLOCK_DYNAMIC = 4
M.BLOCK_DECODE = 5
M.DATA_END = 6

M.FTEXT     = 1 << 0 -- 0b00000001
M.FHCRC     = 1 << 1 -- 0b00000010
M.FEXTRA    = 1 << 2 -- 0b00000100
M.FNAME     = 1 << 3 -- 0b00001000
M.FCOMMENT  = 1 << 4 -- 0b00010000
M.FRESERVED = 7 << 5 -- 0b11100000

--[[
	1 inflate() call = read next deflate block
	* can hanlde gzip/zlib headers and trailers
	* can start/stop mid-byte and return because of end-of-block

	call #1: gzip_header (with full info) returned (possibly header crc16 checked)
	call #2..m: decompressed blocks returned (need ref to already decompressed data across all blocks)
	call #m+1: gzip trailer parsed, gzip crc32 compared, not sure where to apply isize, returned gzip-member-end or smth (with crc and/or error)
	(repeat from call #1 for next block)
	call #N: end-of-stream returned or smth, not very important right now
]]--

local lencodes = {
	--[[ [value - 256] = {extra_bits, length_start} ]]
	{0, 3},
	{0, 4},
	{0, 5},
	{0, 6},
	{0, 7},
	{0, 8},
	{0, 9},
	{0, 10},
	{1, 11},
	{1, 13},
	{1, 15},
	{1, 17},
	{2, 19},
	{2, 23},
	{2, 27},
	{2, 31},
	{3, 35},
	{3, 43},
	{3, 51},
	{3, 59},
	{4, 67},
	{4, 83},
	{4, 99},
	{4, 115},
	{5, 131},
	{5, 163},
	{5, 195},
	{5, 227},
	{0, 258},
}
local distcodes = {
	--[[ [value + 1] = {extra_bits, dist_start} ]]
	{0, 1},
	{0, 2},
	{0, 3},
	{0, 4},
	{1, 5},
	{1, 7},
	{2, 9},
	{2, 13},
	{3, 17},
	{3, 25},
	{4, 33},
	{4, 49},
	{5, 65},
	{5, 97},
	{6, 129},
	{6, 193},
	{7, 257},
	{7, 385},
	{8, 513},
	{8, 769},
	{9, 1025},
	{9, 1537},
	{10, 2049},
	{10, 3073},
	{11, 4097},
	{11, 6145},
	{12, 8193},
	{12, 12289},
	{13, 16385},
	{13, 24577},
}
-- used in dynamic block decoding
local order = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function format_byte(value)
	if value == nil then
		return "nil"
	elseif value >= 0x20 and value <= 0x7e then
		return string.char(value)
	else
		return string.format("0x%02x", value)
	end
end

local function binary(code, len)
	local res = ""
	len = len - 1
	while len >= 0 do
		local bit = (code >> len) & 1
		res = res .. (bit == 1 and "1" or "0")
		len = len - 1
	end
	return res
end

local function reverse_bits(n, len)
	local x = 0
	for _ = 1, len do
		x, n = (x << 1) | (n & 1), n >> 1
	end
	return x
end

local fixed_bl_count = {
	[0] = 0,
	--[[ 1-6 ]] 0, 0, 0, 0, 0, 0,
	--[[ 7 ]] (279 - 256 + 1),
	--[[ 8 ]] (143 - 0 + 1) + (287 - 280 + 1),
	--[[ 9 ]] (255 - 144 + 1),
	n = 9,
}
local fixed_tree, fixed_dtree, fixed_dist_dtree = nil, nil, nil
local function fill_fixed_table()
	if fixed_tree ~= nil then return end
	-- 1) Count number of codes for each code length
	-- nothing to do
	-- 2) Find numerical value of the smallest code for each code length
	local x_code = 0
	local next_code = {}
	for bits = 1, 9 do
		x_code = (x_code + fixed_bl_count[bits-1]) << 1
		next_code[bits] = x_code
	end
	-- 3) Assign consecutive numerical values to all used codes
	local tree = {}
	-- tree of lengths with reversed codes and respective values
	-- first key is code length, second key is reversed code mapped to value
	local dtree = {{}, {}, {}, {}, {}, {}, {}, {}, {}}
	for n = 0, 287 do
		local len
		if n >= 0 and n <= 143 then len = 8
		elseif n >= 144 and n <= 255 then len = 9
		elseif n >= 256 and n <= 279 then len = 7
		elseif n >= 280 and n <= 287 then len = 8
		end
		-- if (len ~= 0) then
		local code = next_code[len]
		local rcode = reverse_bits(code, len)
		tree[n] = { len = len, code = code, rcode = rcode }
		dtree[len][rcode] = n
		next_code[len] = next_code[len] + 1
		-- end
	end
	-- fill dummy distance code dtree
	local dist_dtree = {{}, {}, {}, {}, {}}
	for n = 0, 29 do
		dist_dtree[5][reverse_bits(n, 5)] = n
	end
	fixed_tree = tree
	fixed_dtree = dtree
	fixed_dist_dtree = dist_dtree
end
fill_fixed_table()

local function store_block(state, block, len)
	len = len or #block
	local p = state.prev_blocks
	if len < p.N then
		local x = p.start + len - 1
		if x <= p.N then
			table.move(block, 1, len, p.start, p)
			p.start = x + 1
			if p.start > p.N then p.start = p.start - p.N end
		else
			table.move(block, 1, p.N - p.start + 1, p.start, p)
			table.move(block, p.N - p.start + 2, len, 1, p)
			p.start = len - p.N + p.start
		end
	else -- for insertion of huge blocks in case the will be some
		p.start = 1
		table.move(block, len - p.N + 1, len, 1, p)
	end
end

local function insert_backref(state, cur_block, cur_len, distance, len)
	local DEBUG0 = M.debug.all or M.debug.backref or M.debug.backref_verbose
	local DEBUG1 = M.debug.all or M.debug.backref_verbose
	if DEBUG0 then
		print("backref", "distance", distance, "len", len)
		print("", "from", "=", "to", "=", "this", "ndst", "rest")
	end
	local p = state.prev_blocks
	local e = cur_len
	if len > 0 and (distance > cur_len + p.start) then -- right side of buffer
		local rfrom = p.start - distance + cur_len + p.N
		local rto = rfrom + len - 1
		if rto > p.N then
			distance = p.start + cur_len - 1
			rto = p.N
		end
		len = len - rto + rfrom - 1
		if DEBUG0 then
			print("right", rfrom, format_byte(p[rfrom]), rto, format_byte(p[rto]), rto - rfrom + 1, distance, len)
		end
		for i = rfrom, rto do
			if DEBUG1 then
				local value = p[i]
				io.write("inserted: ")
				print(format_byte(value))
			end
			cur_block[e + 1], e = p[i], e + 1
		end
	end
	if len > 0 and (distance > cur_len) then -- left side of buffer
		local lfrom = p.start - distance + cur_len
		local lto = lfrom + len - 1
		if lto >= p.start then
			distance = cur_len
			lto = p.start - 1
		end
		len = len - lto + lfrom - 1
		if DEBUG0 then
			print("left", lfrom, format_byte(p[lfrom]), lto, format_byte(p[lto]), lto - lfrom + 1, distance, len)
		end
		for i = lfrom, lto do
			if DEBUG1 then
				local value = p[i]
				io.write("inserted: ")
				print(format_byte(value))
			end
			cur_block[e + 1], e = p[i], e + 1
		end
	end
	if len > 0 then -- current block
		local cfrom = cur_len - distance + 1
		local cto = cfrom + len - 1
		len = len - cto + cfrom - 1
		if DEBUG0 then
			print("curr", cfrom, format_byte(cur_block[cfrom]), cto, format_byte(cur_block[cto]), cto - cfrom + 1, distance, len)
		end
		for i = cfrom, cto do
			if DEBUG1 then
				local value = cur_block[i]
				io.write("inserted: ")
				print(format_byte(value))
			end
			cur_block[e + 1], e = cur_block[i], e + 1
		end
	end
end

function M.gzip_inflate0(s, state)
	local in_pos, out_pos, hold, hold_bits, is_final_block
	local function bits(n) return hold & ((1 << n) - 1) end
	local function need_bits(n)
		while hold_bits < n do
			local m = s:byte(in_pos)
			if m == nil then error(M.INFLATE_NOT_ENOUGH_DATA) end
			hold = hold + (m << hold_bits)
			in_pos = in_pos + 1
			hold_bits = hold_bits + 8
		end
		return bits(n)
	end
	local function drop_bits(n) hold = hold >> n; hold_bits = hold_bits - n end
	local function drop_all() hold = 0; hold_bits = 0 end
	local function drop_to_byte() hold = hold >> (hold_bits & 7); hold_bits = hold_bits - (hold_bits & 7) end
	local function consume_all(n)
		local b = need_bits(n)
		drop_all()
		return b
	end
	local function consume_bits(n)
		local b = need_bits(n)
		drop_bits(n)
		return b
	end

	local function parse_codelens(total, min_bl, max_bl, dtree)
		local DEBUG0 = M.debug.all or M.debug.codelens
		local codelens = {}
		local n = 0
		while n <= total do
			local value
			for bl = min_bl, max_bl do
				value = dtree[bl][need_bits(bl)]
				if value ~= nil then drop_bits(bl); break end
			end
			if value <= 15 then
				if DEBUG0 then print(n, value) end
				codelens[n] = value
				n = n + 1
			elseif value == 16 then
				local repeat_times = consume_bits(2) + 2
				if DEBUG0 then print(n, "repeat prev", repeat_times) end
				local prev = codelens[n-1]
				for j = n, n + repeat_times do codelens[j] = prev end
				n = n + repeat_times + 1
			elseif value == 17 then
				local repeat_0 = consume_bits(3) + 2
				if DEBUG0 then print(n, "repeat zero short", repeat_0) end
				for j = n, n + repeat_0 do codelens[j] = 0
				end
				n = n + repeat_0 + 1
			elseif value == 18 then
				local repeat_0 = consume_bits(7) + 10
				if DEBUG0 then print(n, "repeat zero long", repeat_0) end
				for j = n, n + repeat_0 do codelens[j] = 0 end
				n = n + repeat_0 + 1
			end
		end

		-- print code length table
		if DEBUG0 then
			print("resulting table:")
			print("code", "bitlen")
			for code = 0, total do
				if codelens[code] ~= 0 then
					print(code, codelens[code])
				end
			end
		end
		return codelens
	end

	local function parse_table(total, codelens)
		local DEBUG0 = M.debug.all or M.debug.tables
		-- 1) Count number of codes for each code length
		local bl_count = {[0] = 0}
		local min_bl, max_bl = 100, 0
		for i = 0, total do
			local j = codelens[i]
			if j ~= nil then
				local x = bl_count[j] or 0
				bl_count[j] = x + 1
				if j > max_bl then max_bl = j end
				if j > 0 and j < min_bl then min_bl = j end
			end
		end
		-- fill unused lengths with zeros
		for bl = 0, max_bl do
			if bl_count[bl] == nil then
				bl_count[bl] = 0
			end
		end

		-- print bitlen counts
		if DEBUG0 then
			print("bitlen", "count")
			for bl = 0, max_bl do
				print(bl, bl_count[bl])
			end
		end

		-- 2) Find numerical value of the smallest code for each code length
		local x_code = 0
		local next_code = {}
		for nbits = 1, max_bl do
			x_code = (x_code + bl_count[nbits-1]) << 1
			next_code[nbits] = x_code
		end

		-- 3) Assign consecutive numerical values to all used codes
		local dtree = {}
		for bitlen = 1, max_bl do dtree[bitlen] = {} end
		for n = 0, total do
			local len = codelens[n]
			if len ~= 0 then
				local code = next_code[len]
				local rcode = reverse_bits(code, len)
				dtree[len][rcode] = n
				next_code[len] = code + 1
			end
		end
		-- print
		if DEBUG0 then
			print("dtree:")
			print("len", "rcode", "sym")
			for len, v in pairs(dtree) do
				for rcode, n in pairs(v) do
					print(len, binary(rcode, len), n)
				end
			end
		end
		return min_bl, max_bl, dtree
	end

	if state == nil then error("gzip_inflate: provide a valid state"); return nil end
	state.mode = state.mode or M.GZIP_HEADER
	state.in_pos = state.in_pos or 1
	state.out_pos = state.out_pos or 1
	state.hold = state.hold or 0
	state.hold_bits = state.hold_bits or 0
	state.prev_blocks = state.prev_blocks or {}
	state.prev_blocks.N = state.prev_blocks.N or M.INFLATE_BACKBUFFER_CAPACITY
	state.prev_blocks.start = state.prev_blocks.start or 1

	in_pos = state.in_pos
	out_pos = state.out_pos
	hold = state.hold
	hold_bits = state.hold_bits
	is_final_block = state.is_final_block
	local mode = state.mode
	local flags = 0
	local mtime = 0
	local extra_flags = 0
	local os_mark = 255
	local extra, fname, fcomment, header_crc16

	local function local_to_state()
		state.mode = mode
		state.in_pos = in_pos
		state.out_pos = out_pos
		state.hold = hold
		state.hold_bits = hold_bits
		state.flags = flags
		state.extra_flags = extra_flags
		state.is_final_block = is_final_block
	end

	while true do
		if mode == M.GZIP_HEADER then
			local DEBUG0 = M.debug.all or M.debug.gzip_header
			local gzip_header = consume_all(16)
			if gzip_header ~= 0x8b1f then
				error(string.format("gzip_inflate: invalid gzip header, got 0x%04x", gzip_header))
			end
			local cm = consume_all(8)
			if cm ~= 0x08 then
				error(string.format("gzip_inflate: unsupported compression method (0x%02x)", cm))
			end
			flags = consume_all(8)
			mtime = consume_all(32)
			extra_flags = consume_all(8)
			os_mark = consume_all(8)
			if flags & M.FEXTRA ~= 0 then extra, in_pos = string.unpack("z", s, in_pos) end
			if flags & M.FNAME ~= 0 then fname, in_pos = string.unpack("z", s, in_pos) end
			if flags & M.FCOMMENT ~= 0 then fcomment, in_pos = string.unpack("z", s, in_pos) end
			if flags & M.FHCRC ~= 0 then header_crc16 = consume_all(16) end
			if flags & M.FRESERVED ~= 0 then
				error("gzip_inflate: gzip header contains set reserved bit flags")
			end
			mode = M.BLOCK_HEADER -- what to expect next
			local_to_state()
			local header = {
				flags = flags,
				mtime = mtime,
				extra_flags = extra_flags,
				os = os_mark,
				header_crc16 = header_crc16, --[[ can be nil ]]
				filename = fname, --[[ can be nil ]]
				comment = fcomment, --[[ can be nil ]]
				extra = extra, --[[ can be nil ]]
			}
			if DEBUG0 then
				print("gzip_inflate: gzip header")
				for k, v in pairs(header) do
					print(k, v)
				end
			end
			return M.INFLATE_GZIP_HEADER, header
		elseif mode == M.BLOCK_HEADER then
			local DEBUG0 = M.debug.all or M.debug.block_header
			is_final_block = consume_bits(1) == 1 and true or false
			local block_type = consume_bits(2)
			if DEBUG0 then
				print("gzip_inflate: block header")
				print("is final block?", is_final_block)
				print("block type", block_type)
			end
			if block_type == 0 then mode = M.BLOCK_RAW
			elseif block_type == 1 then mode = M.BLOCK_FIXED
			elseif block_type == 2 then mode = M.BLOCK_DYNAMIC
			else error("gzip_inflate: bad block type")
			end
			state.is_final_block = is_final_block
		elseif mode == M.BLOCK_RAW then
			-- untested since i cannot produce such a block with gzip
			print("gzip_inflate: warning: block type 0b00 ('raw' aka 'stored') is not tested,\n"
				.. "expect bugs and send me your gzip file containing such a block")
			drop_to_byte()
			local block_len, nlen
			block_len = consume_all(16)
			nlen = consume_all(16)
			if block_len + nlen ~= 0xffff then error("gzip_inflate: raw block length mismatch") end
			--[[ i am not sure in which order len and nlen come so expect
			     the following code to fail due to out of bounds index ]]
			local block = table.pack(s:byte(in_pos, in_pos + block_len))
			in_pos = in_pos + block_len
			store_block(state, block, block_len)
			mode = is_final_block and M.GZIP_TRAIL or M.BLOCK_HEADER
			local_to_state()
			return M.INFLATE_BLOCK, block
		elseif mode == M.BLOCK_FIXED then
			fill_fixed_table()
			state.tree = fixed_tree
			state.l2_dtree = fixed_dtree
			state.dist_dtree = fixed_dist_dtree
			state.min_l2_bl = 7
			state.max_l2_bl = 9
			state.min_dist_bl = 5
			state.max_dist_bl = 5
			mode = M.BLOCK_DECODE
		elseif mode == M.BLOCK_DYNAMIC then
			-- decode tables
			local DEBUG0 = M.debug.all or M.debug.block_dynamic
			local hlit, hdist, hclen
			local hlit_total, hdist_total, hclen_total
			hlit = consume_bits(5)
			hdist = consume_bits(5)
			hclen = consume_bits(4)
			hlit_total = hlit + 256
			hdist_total = hdist + 0
			hclen_total = hclen + 4
			if DEBUG0 then
				print("hlit", hlit, "hdist", hdist, "hclen", hclen)
				print("hlit_total", hlit_total, "hdist_total", hdist_total, "hclen_total", hclen_total)
				print(binary(need_bits(hclen_total * 3), hclen_total * 3))
			end
			-- lengths of table codes for lengths of literal/length codes
			-- 0..=18
			local codelenlens = {[0] = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
			for i = 1, hclen_total do
				codelenlens[order[i]] = consume_bits(3)
			end
			-- print
			if DEBUG0 then
				for i = 0, 18 do
					if codelenlens[i] ~= 0 then
						print(i, codelenlens[i])
					end
				end
			end
			-- code length tree
			local min_tclen_bl, max_tclen_bl, tclen_dtree = parse_table(18, codelenlens)
			if DEBUG0 then
				print("tclen_dtree", min_tclen_bl, max_tclen_bl)
				for bl, v in pairs(tclen_dtree) do
					for k1, v1 in pairs(v) do
						print(bl, binary(k1, bl), v1)
					end
				end
			end
			-- literal/length tree
			local l2lens = parse_codelens(hlit_total, min_tclen_bl, max_tclen_bl, tclen_dtree)
			local min_l2_bl, max_l2_bl, l2_dtree = parse_table(hlit_total, l2lens)
			if DEBUG0 then
				print("l2_dtree", min_l2_bl, max_l2_bl)
				for bl, v in pairs(l2_dtree) do
					for k1, v1 in pairs(v) do
						print(bl, binary(k1, bl), v1)
					end
				end
			end
			state.l2_dtree = l2_dtree
			state.min_l2_bl = min_l2_bl
			state.max_l2_bl = max_l2_bl
			-- distance tree
			local distlens = parse_codelens(hdist_total, min_tclen_bl, max_tclen_bl, tclen_dtree)
			local min_dist_bl, max_dist_bl, dist_dtree = parse_table(hdist_total, distlens)
			if DEBUG0 then
				print("dist_dtree", min_dist_bl, max_dist_bl)
				for bl, v in pairs(dist_dtree) do
					for k1, v1 in pairs(v) do
						print(bl, binary(k1, bl), v1)
					end
				end
			end
			state.dist_dtree = dist_dtree
			state.min_dist_bl = min_dist_bl
			state.max_dist_bl = max_dist_bl
			mode = M.BLOCK_DECODE
		elseif mode == M.BLOCK_DECODE then
			local DEBUG0 = M.debug.all or M.debug.block_decode or M.debug.block_decode_verbose
			local DEBUG1 = M.debug.all or M.debug.block_decode_verbose
			-- find smallest used code bitlength
			local min_l2_bl, max_l2_bl = state.min_l2_bl, state.max_l2_bl
			local min_dist_bl, max_dist_bl = state.min_dist_bl, state.max_dist_bl
			local block, block_len = {}, 0
			while true do
				local value
				for bl = min_l2_bl, max_l2_bl do
					value = state.l2_dtree[bl][need_bits(bl)]
					if value ~= nil then drop_bits(bl); break end
				end
				if value == nil then error("gzip_inflate: cannot decode code in dynamic block") end
				if value <= 255 then
					block[block_len+1] = value
					block_len = block_len + 1
					if DEBUG1 then
						io.write("literal: ")
						print(format_byte(value))
					end
				elseif value == 256 then
					if DEBUG0 then
						print("end of block")
					end
					break --[[ end of block ]]
				elseif value <= 287 then
					if DEBUG1 then
						print(string.format("length code %d", value))
					end
					local extra_len_bits, base_len = table.unpack(lencodes[value - 256])
					local exact_len = base_len + consume_bits(extra_len_bits)
					local dist_value
					for bl = min_dist_bl, max_dist_bl do
						dist_value = state.dist_dtree[bl][need_bits(bl)]
						if dist_value ~= nil then drop_bits(bl); break end
					end
					if DEBUG1 then
						print(string.format("distance code %d", dist_value))
					end
					if dist_value > 29 then
						error("gzip_inflate: invalid distance code %d", dist_value)
					end
					local extra_dist_bits, base_dist = table.unpack(distcodes[dist_value+1])
					local exact_dist = base_dist + consume_bits(extra_dist_bits)
					if DEBUG1 then
						print("len", exact_len, "dist", exact_dist)
					end
					insert_backref(state, block, block_len, exact_dist, exact_len)
					block_len = block_len + exact_len
				else
					error(string.format("gzip_inflate: unknown code %d in dynamic block", value))
				end
			end
			store_block(state, block, block_len)
			mode = is_final_block and M.GZIP_TRAIL or M.BLOCK_HEADER
			local_to_state()
			return M.INFLATE_BLOCK, block
		elseif mode == M.GZIP_TRAIL then
			drop_to_byte()
			local crc32 = consume_all(32)
			local isize = consume_all(32)
			mode = M.INFLATE_GZIP_HEADER
			if s:byte(in_pos+1) == nil then mode = M.DATA_END end
			local_to_state()
			return M.INFLATE_GZIP_TRAILER, {crc32 = crc32, isize = isize}
		elseif mode == M.DATA_END then
			return M.INFLATE_END_OF_DATA
		else
			return M.INFLATE_END_OF_DATA
		end
	end
end

function M.gzip_inflate(s, state)
	local status, retcode, res = pcall(M.gzip_inflate0, s, state)
	if not status and retcode ~= M.INFLATE_NOT_ENOUGH_DATA then
		error(retcode)
	end
	return retcode, res
end

return M
