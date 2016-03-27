-- KD over UDP network dissector
-- Run with: tshark -X lua_script:kdnet.lua

kdnet_proto = Proto("kdnet", "Windows Kernel Debugger over Network")

local hf = {}
function add_field(proto_field_constructor, name, ...)
    local field_name = "kdnet." .. name
    hf[name] = proto_field_constructor(field_name, ...)
end

-- KD serial protocol?
-- http://articles.sysprogs.org/kdvmware/kdcom.shtml
-- http://gr8os.googlecode.com/svn-history/r66/branches/0.2-devel/kernel/kd.cpp
-- http://www.developerfusion.com/article/84367/kernel-and-remote-debuggers/
-- add_field(ProtoField.string, "leader",  "Packet Leader")
-- add_field(ProtoField.uint16, "type",    "Packet Type", base.HEX_DEC)
-- add_field(ProtoField.uint16, "count",   "Byte Count", base.HEX_DEC)
-- add_field(ProtoField.uint32, "id",      "Packet Id", base.HEX_DEC)
-- add_field(ProtoField.uint32, "checksum", "Checksum", base.HEX)

-- KDNET
-- https://github.com/JumpCallPop/libKDNET
add_field(ProtoField.string, "magic",   "Magic")
add_field(ProtoField.uint8, "version",  "Protocol Version", base.HEX)
--[[Found these values for type (count, value for type field, ip.src):
     69 0x00000001      192.168.2.72
  57838 0x00000000      192.168.2.1
  57843 0x00000000      192.168.2.72
Full, smaller run (windbg-uncut):
    262 0x00000000      192.168.2.1
    265 0x00000000      192.168.2.72
    427 0x00000001      192.168.2.72
--]]--
add_field(ProtoField.uint8, "type",     "Type", base.HEX)
add_field(ProtoField.bytes, "data",     "Encrypted data")
add_field(ProtoField.bytes, "data_dec", "Decrypted data")

-- contents of encrypted blocks --
add_field(ProtoField.bytes,  "field1",  "Zeroes")
add_field(ProtoField.uint16, "uptime",  "Uptime", base.DEC)
add_field(ProtoField.bytes,  "field2",  "Unknown")
add_field(ProtoField.bytes,  "field3",  "Unknown (begin key material)")
add_field(ProtoField.uint16, "seqno",   "Seq no", base.HEX_DEC)
add_field(ProtoField.bytes,  "random",  "Random")
add_field(ProtoField.ipv6,   "src_addr", "Source Addr")
add_field(ProtoField.uint16, "src_port", "Source Port", base.DEC)
add_field(ProtoField.ipv6,   "dst_addr", "Dest   Addr")
add_field(ProtoField.uint16, "dst_port", "Dest   Port", base.DEC)
add_field(ProtoField.ipv6,   "unk_addr", "Unknwn Addr")
add_field(ProtoField.uint16, "unk_port", "Unknwn Port", base.DEC)
add_field(ProtoField.bytes,  "padding",  "Padding")
kdnet_proto.fields = hf

kdnet_proto.prefs.key = Pref.string("Decryption key", "",
    "A 256-bit decryption key formatted as w.x.y.z (components are in base-36)")

-----
-- Decryption routine.
-----
-- For other locations, use: LUA_CPATH=.../luagcrypt/?.so
local gcrypt = require("luagcrypt")
function decrypt(key, data)
    local iv = string.sub(data, -16)
    local ciphertext = string.sub(data, 1, -17)
    local cipher = gcrypt.Cipher(gcrypt.CIPHER_AES256, gcrypt.CIPHER_MODE_CBC)
    cipher:setkey(key)
    cipher:setiv(iv)
    return cipher:decrypt(ciphertext)
end
-----
-- Key preparation
-----
function dotted_key(s)
    local key = '';
    for p in string.gmatch(s, "[0-9a-z]+") do
        local n = tonumber(p, 36);
        assert(n < 2^64, "Invalid key")
        local part = '';
        while n > 0 do
            part = string.char(n % 0x100) .. part;
            n = math.floor(n / 0x100);
        end
        key = key .. part .. string.rep('\0', 8 - string.len(part))
    end
    assert(string.len(key) == 32, "Invalid key format")
    return key
end
function data_key(initial_key, decrypted_data)
    -- key for Debugger -> Debuggee data flows
    local blob = string.sub(decrypted_data, 8+1, 8+322)
    local md = gcrypt.Hash(gcrypt.MD_SHA256)
    md:write(initial_key)
    md:write(blob)
    local key = md:read()
    assert(string.len(key) == 32, "Invalid key format")
    return key
end
----

-- XXX this currently assumes that only a single debugging session is ever
-- present in a packet capture... perhaps it should look at the frame number?
local single_key
function kdnet_stored_key(pinfo, new_key)
    if new_key then
        single_key = new_key
    else
        return single_key
    end
end

function dissect_kdnet_data(tvb, pinfo, pkt_type, tree)
    if tvb:raw(0, 5) ~= '\0\0\0\0\0' then
        return
    end
    if pkt_type == 0x01 then
        dissect_kdnet_init_data(tvb, pinfo, tree)
    end
end
function dissect_kdnet_init_data(tvb, pinfo, tree)
    tree:add(hf.field1, tvb(0, 5))
    tree:add(hf.uptime, tvb(5, 2))
    tree:add(hf.field2, tvb(7, 2))
    tree:add(hf.field3, tvb(9, 1))
    tree:add(hf.seqno, tvb(10, 2))
    tree:add(hf.random, tvb(12, 30))
    tree:add(hf.src_addr, tvb(42, 16))
    tree:add(hf.src_port, tvb(58, 2))
    tree:add(hf.dst_addr, tvb(60, 16))
    tree:add(hf.dst_port, tvb(76, 2))
    tree:add(hf.unk_addr, tvb(78, 16))
    tree:add(hf.unk_port, tvb(90, 2))
    tree:add(hf.padding, tvb(92))
end

function kdnet_proto.dissector(tvb, pinfo, tree)
    -- Ignore packets not starting with "MDBG"
    if tvb(0, 4):uint() ~= 0x4d444247 then
        return 0
    end
    local decryption_key;
    if kdnet_proto.prefs.key ~= "" then
        decryption_key = dotted_key(kdnet_proto.prefs.key);
    end

    pinfo.cols.protocol = "KDNET"
    local subtree = tree:add(kdnet_proto, tvb())
    subtree:add(hf.magic, tvb(0, 4))
    subtree:add(hf.version, tvb(4, 1))
    subtree:add(hf.type, tvb(5, 1))
    subtree:add(hf.data, tvb(6))
    local pkt_type = tvb(5, 1):uint()

    if pkt_type == 0x00 then
        decryption_key = kdnet_stored_key(pinfo)
    end

    if decryption_key then
        local enc_data = tvb:raw(6)
        local decrypted_bytes = decrypt(decryption_key, enc_data)
        if pkt_type == 0x01 then
            local key = data_key(decryption_key, decrypted_bytes)
            kdnet_stored_key(pinfo, key)
        end
        local dec_data = ByteArray.new(decrypted_bytes, true)
            :tvb("Decrypted KDNET data")
        local subtree_dec = subtree:add(hf.data_dec, dec_data())
        dissect_kdnet_data(dec_data, pinfo, pkt_type, subtree_dec)
    end

    -- pinfo.cols.protocol = "KD"
    -- subtree:add(hf.leader, tvb(0, 4))
    -- subtree:add(hf.type, tvb(4, 2))
    -- subtree:add(hf.count, tvb(6, 2))
    -- subtree:add(hf.id, tvb(8, 4))
    -- subtree:add(hf.checksum, tvb(12, 4))
    return tvb:len()
end

local udp_table = DissectorTable.get("udp.port")
--udp_table:add(51111, kdnet_proto)
kdnet_proto:register_heuristic("udp", kdnet_proto.dissector)

-- vim: set sw=4 ts=4 et:
