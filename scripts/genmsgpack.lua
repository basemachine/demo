lpeg = require('lpeg')
mpack = require('mpack')

-- lpeg grammar for building api metadata from a set of header files. It
-- ignores comments and preprocessor commands and parses a very small subset
-- of C prototypes with a limited set of types
P, R, S = lpeg.P, lpeg.R, lpeg.S
C, Ct, Cc, Cg = lpeg.C, lpeg.Ct, lpeg.Cc, lpeg.Cg

any = P(1) -- (consume one character)
letter = R('az', 'AZ') + S('_$')
num = R('09')
alpha = letter + num
nl = P('\r\n') + P('\n')
not_nl = any - nl
ws = S(' \t') + nl
fill = ws ^ 0
c_comment = P('//') * (not_nl ^ 0)
c_preproc = P('#') * (not_nl ^ 0)
typed_container =
  (P('ArrayOf(') + P('DictionaryOf(')) * ((any - P(')')) ^ 1) * P(')')
c_id = (
  typed_container +
  (letter * (alpha ^ 0))
)
c_void = P('void')
c_param_type = (
  ((P('Error') * fill * P('*') * fill) * Cc('error')) +
  (C(c_id) * (ws ^ 1))
  )
c_type = (C(c_void) * (ws ^ 1)) + c_param_type
c_param = Ct(c_param_type * C(c_id))
c_param_list = c_param * (fill * (P(',') * fill * c_param) ^ 0)
c_params = Ct(c_void + c_param_list)
c_proto = Ct(
  Cg(c_type, 'return_type') * Cg(c_id, 'name') *
  fill * P('(') * fill * Cg(c_params, 'parameters') * fill * P(')') *
  Cg(Cc(false), 'async') *
  (fill * Cg((P('FUNC_API_SINCE(') * C(num ^ 1)) * P(')'), 'since') ^ -1) *
  (fill * Cg((P('FUNC_API_ASYNC') * Cc(true)), 'async') ^ -1) *
  (fill * Cg((P('FUNC_API_NOEXPORT') * Cc(true)), 'noexport') ^ -1) *
  (fill * Cg((P('FUNC_API_NOEVAL') * Cc(true)), 'noeval') ^ -1) *
  fill * P(';')
  )
grammar = Ct((c_proto + c_comment + c_preproc + ws) ^ 1)

-- we need at least 4 arguments since the last two are output files
if arg[1] == '--help' then
  print('Usage: genmsgpack.lua args')
  print('Args: 1: source directory')
  print('      2: dispatch output file (dispatch_wrappers.generated.h)')
  print('      3: functions metadata output file (funcs_metadata.generated.h)')
  print('      4: API metadata output file (api_metadata.mpack)')
  print('      5: lua C bindings output file (msgpack_lua_c_bindings.generated.c)')
  print('      rest: C files where API functions are defined')
end
assert(#arg >= 4)
functions = {}

local nvimsrcdir = arg[1]
package.path = nvimsrcdir .. '/?.lua;' .. package.path

-- names of all headers relative to the source root (for inclusion in the
-- generated file)
headers = {}

-- output h file with generated dispatch functions
dispatch_outputf = arg[2]
-- output h file with packed metadata
funcs_metadata_outputf = arg[3]
-- output metadata mpack file, for use by other build scripts
mpack_outputf = arg[4]
lua_c_bindings_outputf = arg[5]

-- set of function names, used to detect duplicates
function_names = {}

-- read each input file, parse and append to the api metadata
for i = 6, #arg do
  local full_path = arg[i]
  local parts = {}
  for part in string.gmatch(full_path, '[^/]+') do
    parts[#parts + 1] = part
  end
  headers[#headers + 1] = parts[#parts - 1]..'/'..parts[#parts]

  local input = io.open(full_path, 'rb')
  local tmp = grammar:match(input:read('*all'))
  for i = 1, #tmp do
    local fn = tmp[i]
    if not fn.noexport then
      functions[#functions + 1] = tmp[i]
      function_names[fn.name] = true
      if #fn.parameters ~= 0 and fn.parameters[1][2] == 'channel_id' then
        -- this function should receive the channel id
        fn.receives_channel_id = true
        -- remove the parameter since it won't be passed by the api client
        table.remove(fn.parameters, 1)
      end
      if #fn.parameters ~= 0 and fn.parameters[#fn.parameters][1] == 'error' then
        -- function can fail if the last parameter type is 'Error'
        fn.can_fail = true
        -- remove the error parameter, msgpack has it's own special field
        -- for specifying errors
        fn.parameters[#fn.parameters] = nil
      end
    end
  end
  input:close()
end

local function shallowcopy(orig)
  local copy = {}
  for orig_key, orig_value in pairs(orig) do
    copy[orig_key] = orig_value
  end
  return copy
end

local function startswith(String,Start)
  return string.sub(String,1,string.len(Start))==Start
end

-- Export functions under older deprecated names.
-- These will be removed eventually.
local deprecated_aliases = require("api.dispatch_deprecated")
for i,f in ipairs(shallowcopy(functions)) do
  local ismethod = false
  if startswith(f.name, "nvim_") then
    if f.since == nil then
      print("Function "..f.name.." lacks since field.\n")
      os.exit(1)
    end
    f.since = tonumber(f.since)
    if startswith(f.name, "nvim_buf_") then
      ismethod = true
    elseif startswith(f.name, "nvim_win_") then
      ismethod = true
    elseif startswith(f.name, "nvim_tabpage_") then
      ismethod = true
    end
  else
    f.noeval = true
    f.since = 0
    f.deprecated_since = 1
  end
  f.method = ismethod
  local newname = deprecated_aliases[f.name]
  if newname ~= nil then
    if function_names[newname] then
      -- duplicate
      print("Function "..f.name.." has deprecated alias\n"
            ..newname.." which has a separate implementation.\n"..
            "Please remove it from src/nvim/api/dispatch_deprecated.lua")
      os.exit(1)
    end
    local newf = shallowcopy(f)
    newf.name = newname
    if newname == "ui_try_resize" then
      -- The return type was incorrectly set to Object in 0.1.5.
      -- Keep it that way for clients that rely on this.
      newf.return_type = "Object"
    end
    newf.impl_name = f.name
    newf.noeval = true
    newf.since = 0
    newf.deprecated_since = 1
    functions[#functions+1] = newf
  end
end

-- don't expose internal attributes like "impl_name" in public metadata
exported_attributes = {'name', 'parameters', 'return_type', 'method',
                       'since', 'deprecated_since'}
exported_functions = {}
for _,f in ipairs(functions) do
  local f_exported = {}
  for _,attr in ipairs(exported_attributes) do
    f_exported[attr] = f[attr]
  end
  exported_functions[#exported_functions+1] = f_exported
end


funcs_metadata_output = io.open(funcs_metadata_outputf, 'wb')
funcs_metadata_output:write([[
static const uint8_t funcs_metadata[] = {
]])

-- serialize the API metadata using msgpack and embed into the resulting
-- binary for easy querying by clients
packed_exported_functions = mpack.pack(exported_functions)
for i = 1, #packed_exported_functions do
  funcs_metadata_output:write(string.byte(packed_exported_functions, i)..', ')
  if i % 10 == 0 then
    funcs_metadata_output:write('\n  ')
  end
end
funcs_metadata_output:write([[
};
]])
funcs_metadata_output:close()

-- start building the dispatch wrapper output
output = io.open(dispatch_outputf, 'wb')

local function real_type(type)
  local rv = type
  if typed_container:match(rv) then
    if rv:match('Array') then
      rv = 'Array'
    else
      rv = 'Dictionary'
    end
  end
  return rv
end

local function attr_name(rt)
  if rt == 'Float' then
    return 'floating'
  else
    return rt:lower()
  end
end

-- start the handler functions. Visit each function metadata to build the
-- handler function with code generated for validating arguments and calling to
-- the real API.
for i = 1, #functions do
  local fn = functions[i]
  if fn.impl_name == nil then
    local args = {}

    output:write('Object handle_'..fn.name..'(uint64_t channel_id, Array args, Error *error)')
    output:write('\n{')
    output:write('\n  Object ret = NIL;')
    -- Declare/initialize variables that will hold converted arguments
    for j = 1, #fn.parameters do
      local param = fn.parameters[j]
      local converted = 'arg_'..j
      output:write('\n  '..param[1]..' '..converted..';')
    end
    output:write('\n')
    output:write('\n  if (args.size != '..#fn.parameters..') {')
    output:write('\n    snprintf(error->msg, sizeof(error->msg), "Wrong number of arguments: expecting '..#fn.parameters..' but got %zu", args.size);')
    output:write('\n    error->set = true;')
    output:write('\n    goto cleanup;')
    output:write('\n  }\n')

    -- Validation/conversion for each argument
    for j = 1, #fn.parameters do
      local converted, convert_arg, param, arg
      param = fn.parameters[j]
      converted = 'arg_'..j
      local rt = real_type(param[1])
      if rt ~= 'Object' then
        if rt:match('^Buffer$') or rt:match('^Window$') or rt:match('^Tabpage$') then
          -- Buffer, Window, and Tabpage have a specific type, but are stored in integer
          output:write('\n  if (args.items['..(j - 1)..'].type == kObjectType'..rt..' && args.items['..(j - 1)..'].data.integer >= 0) {')
          output:write('\n    '..converted..' = (handle_T)args.items['..(j - 1)..'].data.integer;')
        else
          output:write('\n  if (args.items['..(j - 1)..'].type == kObjectType'..rt..') {')
          output:write('\n    '..converted..' = args.items['..(j - 1)..'].data.'..attr_name(rt)..';')
        end
        if rt:match('^Buffer$') or rt:match('^Window$') or rt:match('^Tabpage$') or rt:match('^Boolean$') then
          -- accept nonnegative integers for Booleans, Buffers, Windows and Tabpages
          output:write('\n  } else if (args.items['..(j - 1)..'].type == kObjectTypeInteger && args.items['..(j - 1)..'].data.integer >= 0) {')
          output:write('\n    '..converted..' = (handle_T)args.items['..(j - 1)..'].data.integer;')
        end
        output:write('\n  } else {')
        output:write('\n    snprintf(error->msg, sizeof(error->msg), "Wrong type for argument '..j..', expecting '..param[1]..'");')
        output:write('\n    error->set = true;')
        output:write('\n    goto cleanup;')
        output:write('\n  }\n')
      else
        output:write('\n  '..converted..' = args.items['..(j - 1)..'];\n')
      end

      args[#args + 1] = converted
    end

    -- function call
    local call_args = table.concat(args, ', ')
    output:write('\n  ')
    if fn.return_type ~= 'void' then
      -- has a return value, prefix the call with a declaration
      output:write(fn.return_type..' rv = ')
    end

    -- write the function name and the opening parenthesis
    output:write(fn.name..'(')

    if fn.receives_channel_id then
      -- if the function receives the channel id, pass it as first argument
      if #args > 0 or fn.can_fail then
        output:write('channel_id, '..call_args)
      else
        output:write('channel_id')
      end
    else
      output:write(call_args)
    end

    if fn.can_fail then
      -- if the function can fail, also pass a pointer to the local error object
      if #args > 0 then
        output:write(', error);\n')
      else
        output:write('error);\n')
      end
      -- and check for the error
      output:write('\n  if (error->set) {')
      output:write('\n    goto cleanup;')
      output:write('\n  }\n')
    else
      output:write(');\n')
    end

    if fn.return_type ~= 'void' then
      output:write('\n  ret = '..string.upper(real_type(fn.return_type))..'_OBJ(rv);')
    end
    output:write('\n\ncleanup:');

    output:write('\n  return ret;\n}\n\n');
  end
end

-- Generate a function that initializes method names with handler functions
output:write([[
void msgpack_rpc_init_method_table(void)
{
  methods = map_new(String, MsgpackRpcRequestHandler)();

]])

for i = 1, #functions do
  local fn = functions[i]
  output:write('  msgpack_rpc_add_method_handler('..
               '(String) {.data = "'..fn.name..'", '..
               '.size = sizeof("'..fn.name..'") - 1}, '..
               '(MsgpackRpcRequestHandler) {.fn = handle_'..  (fn.impl_name or fn.name)..
               ', .async = '..tostring(fn.async)..'});\n')

end

output:write('\n}\n\n')
output:close()

mpack_output = io.open(mpack_outputf, 'wb')
mpack_output:write(mpack.pack(functions))
mpack_output:close()

local function include_headers(output, headers)
  for i = 1, #headers do
    if headers[i]:sub(-12) ~= '.generated.h' then
      output:write('\n#include "nvim/'..headers[i]..'"')
    end
  end
end

local function write_shifted_output(output, str)
  str = str:gsub('\n  ', '\n')
  str = str:gsub('^  ', '')
  str = str:gsub(' +$', '')
  output:write(str)
end

-- start building lua output
output = io.open(lua_c_bindings_outputf, 'wb')

output:write([[
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "nvim/func_attr.h"
#include "nvim/api/private/defs.h"
#include "nvim/api/private/helpers.h"
#include "nvim/viml/executor/converter.h"
]])
include_headers(output, headers)
output:write('\n')

lua_c_functions = {}

local function process_function(fn)
  lua_c_function_name = ('nlua_msgpack_%s'):format(fn.name)
  write_shifted_output(output, string.format([[

  static int %s(lua_State *lstate)
  {
    Error err = {.set = false};
    if (lua_gettop(lstate) != %i) {
      api_set_error(&err, Validation, "Expected %i argument%s");
      lua_pushstring(lstate, err.msg);
      return lua_error(lstate);
    }
  ]], lua_c_function_name, #fn.parameters, #fn.parameters,
      (#fn.parameters == 1) and '' or 's'))
  lua_c_functions[#lua_c_functions + 1] = {
    binding=lua_c_function_name,
    api=fn.name
  }
  local cparams = ''
  local free_code = {}
  for j = #fn.parameters,1,-1 do
    param = fn.parameters[j]
    cparam = string.format('arg%u', j)
    param_type = real_type(param[1])
    lc_param_type = param_type:lower()
    write_shifted_output(output, string.format([[
    const %s %s = nlua_pop_%s(lstate, &err);

    if (err.set) {
      %s
      lua_pushstring(lstate, err.msg);
      return lua_error(lstate);
    }
    ]], param[1], cparam, param_type, table.concat(free_code, '\n      ')))
    free_code[#free_code + 1] = ('api_free_%s(%s);'):format(lc_param_type, cparam)
    cparams = cparam .. ', ' .. cparams
  end
  if fn.receives_channel_id then
    cparams = 'INTERNAL_CALL, ' .. cparams
  end
  if fn.can_fail then
    cparams = cparams .. '&err'
  else
    cparams = cparams:gsub(', $', '')
  end
  free_at_exit_code = table.concat(free_code, '\n    ')
  if fn.return_type ~= 'void' then
    if fn.return_type:match('^ArrayOf') then
      return_type = 'Array'
    else
      return_type = fn.return_type
    end
    write_shifted_output(output, string.format([[
    const %s ret = %s(%s);
    %s
    if (err.set) {
      lua_pushstring(lstate, err.msg);
      return lua_error(lstate);
    }
    nlua_push_%s(lstate, ret);
    api_free_%s(ret);
    return 1;
    ]], fn.return_type, fn.name, cparams, free_at_exit_code, return_type,
        return_type:lower()))
  else
    write_shifted_output(output, string.format([[
    %s(%s);
    %s
    if (err.set) {
      lua_pushstring(lstate, err.msg);
      return lua_error(lstate);
    }
    return 0;
    ]], fn.name, cparams, free_at_exit_code))
  end
  write_shifted_output(output, [[
  }
  ]])
end

for _, fn in ipairs(functions) do
  if not fn.noeval then
    process_function(fn)
  end
end

output:write(string.format([[
void nlua_add_api_functions(lua_State *lstate)
  FUNC_ATTR_NONNULL_ALL
{
  lua_createtable(lstate, 0, %u);
]], #lua_c_functions))
for _, func in ipairs(lua_c_functions) do
  output:write(string.format([[

  lua_pushcfunction(lstate, &%s);
  lua_setfield(lstate, -2, "%s");]], func.binding, func.api))
end
output:write([[

  lua_setfield(lstate, -2, "api");
}
]])

output:close()
