--
--  Copyright 2016 diacritic <https://diacritic.io>
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.

local wssdl = {}

local deepcopy = function() end

deepcopy = function (o)
  if type(o) == 'table' then
    local copy = {}
    for k, v in pairs(o) do
      copy[k] = deepcopy(v)
    end
    setmetatable(copy, getmetatable(o))
    return copy
  else
    return o
  end
end

wssdl.init = function (self, env)
  self.env = env
end

wssdl.field_type = function (type, basesz)
  local o = {
    _imbue = function (field, s)
      field._size = s * basesz
      field.type = type
      return field
    end
  }
  return o
end

wssdl.field_type_sized = function (type, size)
  local o = {
    _imbue = function (field)
      field._size = size
      field.type = type
      return field
    end
  }
  return o
end

wssdl.field_types = {
  bits  = wssdl.field_type("bits",      1);
  bytes = wssdl.field_type("bytes",     8);
  sint  = wssdl.field_type("signed",    1);
  uint  = wssdl.field_type("unsigned",  1);
  float = wssdl.field_type("float",     8);

  bit = wssdl.field_type_sized("bits", 1);

  i8  = wssdl.field_type_sized("signed", 8);
  i16 = wssdl.field_type_sized("signed", 16);
  i32 = wssdl.field_type_sized("signed", 32);
  i64 = wssdl.field_type_sized("signed", 64);

  u8  = wssdl.field_type_sized("unsigned", 8);
  u16 = wssdl.field_type_sized("unsigned", 16);
  u32 = wssdl.field_type_sized("unsigned", 32);
  u64 = wssdl.field_type_sized("unsigned", 64);

  f32 = wssdl.field_type_sized("float", 32);
  f64 = wssdl.field_type_sized("float", 64);
}

wssdl._packet = {

  _properties = {
    padding = 0,  -- Padding, in bytes.
    size = 0,     -- Static size, in bytes.
  };

  _create = function(pkt, def)
    local newpacket = {}

    newpacket = {
      _definition = def,
      _values = {},
      _properties = pkt._properties,

      _imbue = function (field, ...)
        local pkt = newpacket:eval({...})
        field.type    = "packet"
        field.packet  = pkt
        field._size   = #pkt
        return field
      end;

      eval = function (pkt, params)
        if next(params) == nil then
          return pkt
        end

        if not params._noclone then
          pkt = deepcopy(pkt)
          params['_noclone'] = nil
        end

        for i, v in ipairs(pkt._definition) do
          local def = v:_eval(params)
          if def == nil then
            table.remove(pkt._definition, i)
          else
            pkt._definition[i] = def
          end
        end

        -- Recompute lookup
        pkt._lookup = {}
        for i, v in ipairs(pkt._definition) do
          pkt._lookup[v.name] = i
        end

        return pkt
      end;
    }

    newpacket._lookup = {}
    for i, v in ipairs(def) do
      newpacket._lookup[v.name] = i
    end

    newpacket.fields = {}
    setmetatable(newpacket.fields, {

      __index = function(_, k)
        local idx = newpacket._lookup[k]
        if idx ~= nil then
          return newpacket._definition[idx]
        end
      end

    })

    setmetatable(newpacket, {
      __len = pkt._calcsize;
    })

    return newpacket
  end;

  padding = function(pkt, pad)
    pkt._properties.padding = pad
    return pkt
  end;

  size = function(pkt, sz)
    pkt._properties.size = sz
    return pkt
  end;

  _calcsize = function(pkt)
    local sz = 0
    if pkt._properties.size > 0 then
      sz = tonumber(pkt.size)
    else
      for _, v in ipairs(pkt._definition) do
        sz = sz + #v
      end
    end
    if pkt._properties.padding > 0 then
      -- no bitwise ops, we align up the old way
      local rem = sz % pkt._properties.padding
      if rem > 0 then
        sz = sz - rem + pkt._properties.padding
      end
    end
    return sz
  end;

}

setmetatable(wssdl._packet, {

  __call = function(pkt, ...)
    -- Restore the original global metatable
    setmetatable(_G, nil)
    return pkt._create(pkt, ...)
  end;

})

local placeholder_metatable = {}

local do_eval = function (v, values)
  if type(v) == 'table' and v._eval ~= nil then
    return v:_eval(values)
  else
    return v
  end
end

local new_placeholder = function (eval)
  local obj = { _eval = eval }
  setmetatable(obj, placeholder_metatable)
  return obj
end

local new_binop_placeholder = function(eval)
  return function(lhs, rhs)
    local ph = new_placeholder(eval)
    ph.rhs = rhs
    ph.lhs = lhs
    return ph
  end
end

local new_valued_placeholder = function(eval)
  return function(value)
    local ph = new_placeholder(eval)
    ph.value = value
    return ph
  end
end

local new_funcall_placeholder = function(func, ...)
  local ph = new_placeholder (function(self, values)
      return self.func(unpack(self.params))
    end)
  ph.func = func
  ph.params = {...}
  return ph
end

local new_field_placeholder = function(id)
  local ph = new_placeholder (function(self, values)
      local val = values[self.id]
      if val ~= nil then
        return val
      else
        return new_field_placeholder(self.id)
      end
    end)
  ph.id = id
  return ph
end

local new_subscript_placeholder = function(parent, subscript)
  local ph = new_placeholder (function(self, values)
      return do_eval(self.parent, values)[self.subscript]
    end)
  ph.parent = parent
  ph.subscript = subscript
  return ph
end

local new_unm_placeholder = new_valued_placeholder (function(self, values)
    return -do_eval(self.value, values)
  end)

local new_add_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) + do_eval(self.rhs, values)
  end)

local new_sub_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) - do_eval(self.rhs, values)
  end)

local new_mul_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) * do_eval(self.rhs, values)
  end)

local new_div_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) / do_eval(self.rhs, values)
  end)

local new_pow_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) ^ do_eval(self.rhs, values)
  end)

local new_mod_placeholder = new_binop_placeholder (function(self, values)
    return do_eval(self.lhs, values) % do_eval(self.rhs, values)
  end)

placeholder_metatable = {
  __index = function(t, k)
    return new_subscript_placeholder(t, k)
  end;

  __unm = function(val)
    return new_unm_placeholder(val)
  end;

  __add = function(lhs, rhs)
    return new_add_placeholder(lhs, rhs)
  end;

  __sub = function(lhs, rhs)
    return new_sub_placeholder(lhs, rhs)
  end;

  __mul = function(lhs, rhs)
    return new_mul_placeholder(lhs, rhs)
  end;

  __div = function(lhs, rhs)
    return new_div_placeholder(lhs, rhs)
  end;

  __pow = function(lhs, rhs)
    return new_pow_placeholder(lhs, rhs)
  end;

  __mod = function(lhs, rhs)
    return new_mod_placeholder(lhs, rhs)
  end;
}

local packetdef_metatable = {}

local fieldresolver_metatable = {

  __index = function(field, k)
    local type = rawget(wssdl.field_types, k)
    if type == nil then
      type = rawget(wssdl.env, k)
    end
    if type == nil then
      return nil
    end

    local fieldtype = {}
    setmetatable(fieldtype, {
      __call = function(ft, f, ...)
        -- We finished processing the packet contents ({ field : type() ... })
        -- Restore the packet definition metatable.
        setmetatable(_G, packetdef_metatable)
        return type._imbue(field, ...)
      end
    })

    -- Inside a field definition, we switch the resolver
    setmetatable(_G, {
      __index = function(t, k)
        return new_field_placeholder(k)
      end;
    })
    return fieldtype
  end;

  __len = function (field)
    return field._size
  end;

}

packetdef_metatable = {

  __index = function(t, k)
    local o = {
      name = k;

      -- Evaluate the field with concrete values
      _eval = function(field, params)
        for k, v in pairs(field) do
          field[k] = do_eval(v, params)
        end
        return field
      end
    }
    setmetatable(o, fieldresolver_metatable)
    return o
  end;

}

setmetatable(wssdl, {

  __index = function(t, k)
    if k == 'packet' then
      -- Create a new packet factory based off wssdl._packet
      local newpacket = {}
      for k, v in pairs(wssdl._packet) do newpacket[k] = v end

      local newprops = {}
      for k, v in pairs(wssdl._packet._properties) do newprops[k] = v end
      newpacket._properties = newprops
      setmetatable(newpacket, getmetatable(wssdl._packet))

      -- Switch to the packet definition metatable
      setmetatable(_G, packetdef_metatable)
      return newpacket
    end
  end;

})

return wssdl