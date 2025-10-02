---@diagnostic disable unused-local
---@diagnostic disable unused-function

--[[
       Lit Value    Bits   |    Codes
       ---------    ----   |    -----
         0 - 143     8     |    00110000 through
                           |    10111111
       144 - 255     9     |    110010000 through
                           |    111111111
       256 - 279     7     |    0000000 through
                           |    0010111
       280 - 287     8     |    11000000 through
                           |    11000111
]]

--[[
The Huffman codes used for each alphabet in the "deflate" format have two additional rules:

    All codes of a given bit length have lexicographically consecutive values, in the same order as the symbols they represent;
    Shorter codes lexicographically precede longer codes. 

We could recode the example above to follow this rule as follows, assuming that the order of the alphabet is ABCD:

Symbol  Code
------  ----
A       10
B       0
C       110
D       111

I.e., 0 precedes 10 which precedes 11x, and 110 and 111 are lexicographically consecutive.

Given this rule, we can define the Huffman code for an alphabet just by giving the bit lengths of the codes for each symbol of the alphabet in order; this is sufficient to determine the actual codes. In our example, the code is completely defined by the sequence of bit lengths (2, 1, 3, 3). The following algorithm generates the codes as integers, intended to be read from most- to least-significant bit. The code lengths are initially in tree[I].Len; the codes are produced in tree[I].Code.

1) Count the number of codes for each code length. Let bl_count[N] be the number of codes of length N, N >= 1.
]]
local bl_count = {
	[0] = 0,
	--[[ 1-6 ]] 0, 0, 0, 0, 0, 0,
	--[[ 7 ]] (279 - 256 + 1),
	--[[ 8 ]] (143 - 0 + 1) + (287 - 280 + 1),
	--[[ 9 ]] (255 - 144 + 1),
}
--[[
2) Find the numerical value of the smallest code for each code length:

    code = 0;
    bl_count[0] = 0;
    for (bits = 1; bits <= MAX_BITS; bits++) {
        code = (code + bl_count[bits-1]) << 1;
        next_code[bits] = code;
    }
]]
local code = 0
local next_code = {}
for bits = 1, 9 do
	code = (code + bl_count[bits-1]) << 1
	next_code[bits] = code
end
--[[
3) Assign numerical values to all codes, using consecutive values for all codes of the same length with the base values determined at step 2. Codes that are never used (which have a bit length of zero) must not be assigned a value.

    for (n = 0;  n <= max_code; n++) {
        len = tree[n].Len;
        if (len != 0) {
            tree[n].Code = next_code[len];
            next_code[len]++;
        }
    }
]]
--[[
         0 - 143     8     |    00110000 through
                           |    10111111
       144 - 255     9     |    110010000 through
                           |    111111111
       256 - 279     7     |    0000000 through
                           |    0010111
       280 - 287     8     |    11000000 through
                           |    11000111
]]
local tree = {}
for n = 0, 287 do
	local len
	if n >= 0 and n <= 143 then len = 8
	elseif n >= 144 and n <= 255 then len = 9
	elseif n >= 256 and n <= 279 then len = 7
	elseif n >= 280 and n <= 287 then len = 8
	end
	if (len ~= 0) then
		tree[n] = {len = len, code = next_code[len]}
		next_code[len] = next_code[len] + 1
	end
end
local function binary(t)
	local code, len = t.code, t.len
	local res = ""
	len = len - 1
	while len >= 0 do
		local bit = (code >> len) & 1
		res = res .. (bit == 1 and "1" or "0")
		len = len - 1
	end
	return res
end
print("value", "len", "code")
for i = 0, 287 do
	print(i, tree[i].len, binary(tree[i]))
end
--[[
Example:

Consider the alphabet ABCDEFGH, with bit lengths (3, 3, 3, 3, 3, 2, 4, 4). After step 1, we have:

N      bl_count[N]
-      -----------
2      1
3      5
4      2

Step 2 computes the following next_code values:

N      next_code[N]
-      ------------
1      0
2      0
3      2
4      14

Step 3 produces the following code values:

Symbol Length   Code
------ ------   ----
A       3        010
B       3        011
C       3        100
D       3        101
E       3        110
F       2         00
G       4       1110
H       4       1111
]]
