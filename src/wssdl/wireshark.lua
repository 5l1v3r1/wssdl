--
--  Copyright 2016 diacritic <https://diacritic.io>
--
--  This file is part of wssdl <https://github.com/diacritic/wssdl>.
--
--  wssdl is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  wssdl is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with wssdl.  If not, see <http://www.gnu.org/licenses/>.

local ws = {}

local utils = require 'wssdl.utils'

local known_dissectors = {}

do
  local dissectors = DissectorTable.list()
  for i, v in ipairs(dissectors) do
    known_dissectors[v] = true
  end
end

ws.make_fields = function (fields, pkt, prefix)
  local prefix = prefix or ''

  for i, field in ipairs(pkt._definition) do
    local ftype = nil
    if field._type == 'packet' then
      -- No need to deepcopy the packet definition since the parent was cloned
      local pkt = field._packet
      pkt._properties.noclone = true
      ws.make_fields(fields, pkt, prefix .. field._name .. '.')
      ftype = ftypes.STRING
    elseif field._type == 'payload' then
      ftype = ftypes.PROTOCOL
    elseif field._type == 'string' then
      local tname = 'STRING'
      if type(field._size) == 'number' and field._size == 0 then
        tname = tname .. 'Z'
      end
      ftype = ftypes[tname]
    elseif field._type == 'address' then
      if field._size == 32 then
        ftype = ftypes.IPv4
      else
        -- Older versions of wireshark does not support ipv6 protofields in
        -- their lua API. See https://code.wireshark.org/review/#/c/18442/
        -- for a follow up on the patch to address this
        if utils.semver(get_version()) >= utils.semver('2.3.0') then
          ftype = ftypes.IPv6
        else
          ftype = ftypes.STRING
        end
      end
    elseif field._type == 'bits' then
      local len = #field
      if type(len) == 'number' then
        local tname = 'UINT' .. tostring(math.ceil(len / 8) * 8)
        ftype = ftypes[tname]
      else
        ftype = ftypes.UINT64
      end
    elseif field._type == 'float' then
      local len = #field
      if type(len) ~= 'number' then
        error('wssdl: Cannot compute size of primitive ' .. utils.quote(field._name) .. ' field.')
      end
      if len == 4 then
        ftype = ftypes.FLOAT
      else
        ftype = ftypes.DOUBLE
      end
    else
      local corr = {
        signed   = 'INT',
        unsigned = 'UINT',
        bytes    = 'BYTES',
        bool     = 'BOOLEAN',
      }

      local tname = corr[field._type]
      if field._type == 'signed' or field._type == 'unsigned' then
        local len = #field
        if type(len) ~= 'number' then
          error('wssdl: Cannot compute size of primitive ' .. utils.quote(field._name) .. ' field.')
        end
        tname = tname .. tostring(len)
      end

      ftype = ftypes[tname]
    end

    local format = nil
    if field._format ~= nil then
      local corr = {
        decimal = base.DEC,
        hexadecimal = base.HEX,
        octal = base.OCT,
      }
      format = corr[field._format]
    end

    fields[prefix .. field._name] = ProtoField.new(
        field._displayname or field._name,
        prefix .. field._name,
        ftype,
        nil,
        format,
        nil,
        field._description)

    field._ftype = ftype
  end
end

local dissect_int_base = function(char, mname)
  return function (field, buf, raw, idx, sz)
    if idx % 8 > 0 then
      if sz > 64 then
        error('wssdl: Unaligned ' .. mname .. ' field ' .. utils.quote(field._name) ..
        ' is larger than 64 bits, which is not supported by wireshark.')
      end

      local fmt = (field._le and '<' or '>') .. char .. tostring(math.ceil(sz / 8))

      local packed = Struct.pack('>I' .. tostring(math.ceil(sz / 8)), raw:bitfield(idx % 8, sz))
      return raw, Struct.unpack(fmt, packed), sz
    else
      return raw, raw[(field._le and 'le_' or '') .. mname .. (sz > 32 and '64' or '')](raw), sz
    end
  end
end

local dissect_type = {

  bits = function (field, buf, raw, idx, sz)
    if sz > 64 then
      error('wssdl: "' .. field._type .. '" field ' .. field._name ..
            ' is larger than 64 bits, which is not supported by wireshark.')
    end
    return raw, raw:bitfield(idx % 8, sz), sz
  end;

  string = function (field, buf, raw, idx, sz)
    local mname = 'string'
    if not field._size or field._size == 0 then
      raw = buf(math.floor(idx / 8))
      mname = mname .. 'z'
    end
    if field._basesz == 2 then
      mname = 'u' .. mname
    end
    local val = raw[mname](raw)
    sz = #val * 8

    if not field._size or field._size == 0 then
      sz = sz + field._basesz * 8
    end
    return raw, val, sz
  end;

  address = function (field, buf, raw, idx, sz)
    local mname = sz == 32 and 'ipv4' or 'ipv6'
    local val

    -- Older versions of wireshark does not support ipv6 protofields in
    -- their lua API. See https://code.wireshark.org/review/#/c/18442/
    -- for a follow up on the patch to address this
    if utils.semver(get_version()) < utils.semver('2.3.0') and mname == 'ipv6' then
      val = utils.tvb_ipv6(raw)
      label = {(field._displayname or field._name) .. ': ', val}
    else
      val = raw[mname](raw)
    end
    return raw, val, sz, label
  end;

  bytes = function (field, buf, raw, idx, sz)
    if idx % 8 > 0 then
      error('wssdl: field ' .. utils.quote(field._name) ..
            ' is an unaligned "bytes" field, which is not supported.')
    end
    return raw, tostring(raw:bytes()), sz
  end;

  signed = dissect_int_base('i', 'int');

  unsigned = dissect_int_base('I', 'uint');

  float = function (field, buf, raw, idx, sz)
    if idx % 8 > 0 then
      if sz > 64 then
        error('wssdl: Unaligned float field ' .. field._name ..
              ' is larger than 64 bits, which is not supported by wireshark.')
      end

      local fmt = (field._le and '<' or '>') .. 'f'
      local packed = Struct.pack('>I' .. tostring(math.ceil(sz / 8)), raw:bitfield(idx % 8, sz))
      return raw, Struct.unpack(fmt, packed), sz
    else
      local val = field._le and raw:le_float() or raw:float()
      return raw, val, sz
    end
  end;

  default = function (field, buf, raw, idx, sz)
    error('wssdl: Unknown "' .. field._type .. '" field ' .. field._name .. '.')
  end;

}

dissect_type.bool = dissect_type.bits;

ws.dissector = function (pkt, proto)

  local function tree_add_fields(pkt, prefix, tree, pktval)
    for i, field in ipairs(pkt._definition) do
      local protofield = proto.fields[prefix .. field._name]
      local labels = pktval.label[field._name] or {}
      local val = pktval.val[field._name]
      local raw = pktval.buf[field._name]

      if field._type == 'packet' then
        local pktval = { buf = raw, label = labels, val = val }
        node = tree:add(protofield, raw._self, '', unpack(labels))
        tree_add_fields(field._packet, prefix .. field._name .. '.', node, pktval)
      else
        node = tree:add(protofield, raw, val, unpack(labels))
      end
    end
  end

  local function dissect_pkt(pkt, start, buf, pinfo)

    local idx = start
    local pktval = {
      buf = {},
      val = {},
      label = {}
    }
    local subdissect = {}

    local function size_of(field, idx)
      local sz = #field

      if sz and type(sz) ~= 'number' then
        pkt:eval(pktval.val)
        sz = #field
      end

      if sz and type(sz) ~= 'number' then
        error('wssdl: Cannot evaluate size of ' .. utils.quote(field._name) ..
              ' field.')
      end

      if sz == nil then
        sz = buf:len() * 8 - idx
      end

      return sz
    end

    local function dissect_field(field, idx)
      local sz = nil
      local raw = nil
      local val = nil
      local label = nil
      local sdiss = nil

      if field._type == 'packet' then
        raw = buf(math.floor(idx / 8))
        local res, err = dissect_pkt(field._packet, idx % 8, raw:tvb(), pinfo)
        -- Handle errors
        if err then
          return nil, err
        end

        sz, val, sdiss = unpack(res, 1, 3)
        val.buf._self = buf(math.floor(idx / 8), math.ceil((sz + idx % 8) / 8))
        raw = val.buf
        label = val.label
        val = val.val
        for k, v in pairs(sdiss) do
          subdissect[#subdissect + 1] = v
        end
      else
        sz = size_of(field, idx)

        local offlen = math.ceil((sz + idx % 8) / 8)
        local needed = math.floor(idx / 8) + offlen

        raw = buf(0,0)
        if sz > 0 and needed > buf:len() then
          return nil, {needed = needed}
        end

        if needed <= buf:len() and sz > 0 then
          raw = buf(math.floor(idx / 8), offlen)
        end

        if field._type == 'payload' then
          local dtname = field._dt_name or
              table.concat({string.lower(proto.name),
                            unpack(field._dissection_criterion)}, '.')

          local dt = DissectorTable.get(dtname)
          local val = pktval.val
          for i, v in pairs(field._dissection_criterion) do
            val = val[v]
            if not val then
              error('wssdl: Dissection criterion for ' .. utils.quote(field._name) ..
                    ' does not match a real field.')
            end
          end
          subdissect[#subdissect + 1] = {dt = dt, tvb = raw:tvb(), val = val}
        else
          local df = dissect_type[field._type] or dissect_type.default
          raw, val, sz, label = df(field, buf, raw, idx, sz)
        end
      end

      return {raw, val, sz, label}
    end

    for i, field in ipairs(pkt._definition) do

      local res, err = dissect_field(field, idx)
      if err then
        if err.needed > 0 then
          if pkt._properties.desegment then
            local desegment = (err.needed - buf:len()) * 8
            for j = i + 1, #pkt._definition do
              local len = #pkt._definition[j]
              if type(len) ~= 'number' then
                err.desegment = DESEGMENT_ONE_MORE_SEGMENT
                return nil, err
              end
              desegment = desegment + len
            end
            err.desegment = math.ceil(desegment / 8)
          else
            err.expert = proto.experts.too_short
          end
        end
        return nil, err
      end

      local raw, val, sz, label = unpack(res, 1, 4)

      pktval.buf[field._name] = raw
      pktval.val[field._name] = val
      pktval.label[field._name] = label

      idx = idx + sz
    end

    return {idx - start, pktval, subdissect}
  end

  local function dissect_proto(pkt, buf, pinfo, root)
    local pkt = utils.deepcopy(pkt)

    -- Don't clone the packet definition further when evaluating
    pkt._properties.noclone = true

    local res, err = dissect_pkt(pkt, 0, buf, pinfo)
    if err and err.desegment then
      return len, desegment
    end

    pinfo.cols.protocol = proto.name
    local tree = root:add(proto, buf(), proto.description)

    if err then
      if err.expert then
        tree:add_proto_expert_info(err.expert)
      end
      return -1, 0
    end

    local len, val, subdissect = unpack(res, 1, 3)
    tree_add_fields(pkt, string.lower(proto.name) .. '.', tree, val)

    for k, v in pairs(subdissect) do
      if v.tvb:len() > 0 then
        v.dt:try(v.val, v.tvb, pinfo, root)
      end
    end

    return math.ceil(len / 8), desegment
  end

  return function(buf, pinfo, root)
    local pktlen = buf:len()
    local consumed = 0

    if pkt._properties.desegment then
      while consumed < pktlen do
        local result, desegment = dissect_proto(pkt, buf(consumed):tvb(), pinfo, root)
        if result > 0 then
          consumed = consumed + result
        elseif result == 0 then
          return 0
        elseif desegment ~= 0 then
          pinfo.desegment_offset = consumed
          pinfo.desegment_len = desegment
          return pktlen
        else
          return
        end
      end
    else
      local result = dissect_proto(pkt, buf, pinfo, root)
      if result < 0 then
        return
      end
      return result
    end
    return consumed
  end
end

ws.proto = function (pkt, name, description)
  local proto = Proto.new(name, description)
  ws.make_fields(proto.fields, pkt, string.lower(name) .. '.')

  proto.experts.too_short = ProtoExpert.new(
      string.lower(name) .. '.too_short.expert',
      name .. ' message too short',
      expert.group.MALFORMED, expert.severity.ERROR)

  for i, field in ipairs(pkt._definition) do
    if field._type == 'payload' then
      local dtname = field._dt_name or
          table.concat({string.lower(proto.name),
                        unpack(field._dissection_criterion)}, '.')

      local criterion = field._dissection_criterion
      local target = pkt
      local j = 1
      for k, v in pairs(criterion) do
        local tfield = target._definition[target._lookup[v]]
        if j < #criterion then
          if tfield._type ~= 'packet' then
            error('wssdl: DissectorTable key ' .. utils.quote(dtname) .. ' does not match a field', 2)
          end
          target = tfield._packet
        else
          target = tfield
        end
        j = j + 1
      end
      if not known_dissectors[dtname] then
        DissectorTable.new(dtname, nil, target._ftype)
        known_dissectors[dtname] = true
      end
    end
  end

  proto.dissector = ws.dissector(pkt, proto)
  return proto
end

return ws
