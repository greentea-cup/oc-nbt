# Binary NBT decoder for OpenComputers
It seems that `itemStack.tag` stores nbt in internal format and OC does not provide a proper way to read it (outside creative debud card). So I made an attempt to solve this problem.

There's also a data card but it uses *slightly different* algorithm (namely, zlib inflate) which is incompatible in terms of input data as is.

## Installation
to be done when I make a first release

## Usage
```lua
local N = require("nbt")
local item_tag = "some binary gzipped nbt" -- obtain tag with inventory controller upgrade and getStackInSlot for example
local nbt_table = N.decode_nbt_from_tag(item_tag)
-- work with it like with normal lua table
-- P.S. does not provide functionality to write nbt
-- for now you need to convert table to snbt yourself
```

## Notes
- Tested only with GTNH fork of opencomputers. No warranty that it will work for you.
- Uses Lua 5.3 features. May break with LuaJIT or other versions.
- Feel free to open an issue / pull request if you encounter problems.

## Limitations
Although gunzip is outputting data in chunks, current implementation of `decode_nbt_from_tag` cannot work with partial data, so you need to have a decent amount of memory in case you deal with huge nbt items.
May work slower than native gunzip implementations, which is expected.
gunzip provides crc data but does not perform actual crc checking. Nor does nbt parser. May be a bit irrelevant since minecaft does not store useful data in gzip header for itemStack nbt.

## Credits
- [zlib](http://www.zlib.org) for the deflate/inflate algorithm [github repo](https://github.com/madler/zlib)
- [lua-compress-deflatelua](https://github.com/davidm/lua-compress-deflatelua) as a viable implementation of gzip inflate in pure Lua (I found it only after gone so far in the project)
- [Minecraft Wiki](https://minecraft.wiki/w/NBT_format#binary_format) for documenting the NBT format
- existing binary nbt lua parsers out there
- GTNH discord for support

## License
Some code were rewritten from original zlib C implementation.
License for the zlib version used during development (github commit 5a82f71ed1dfc0bec044d9702463dbdf84ea3b71) is placed here at `ZLIB_LICENSE`.

