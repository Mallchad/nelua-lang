local re = require 'relabel'
local errorer = require 'nelua.utils.errorer'
local tabler = require 'nelua.utils.tabler'
local metamagic = require 'nelua.utils.metamagic'

local pegger = {}

local double_patt_begin = [[quote <- {~ ''->'"' (quotechar / .)* ''->'"' ~}]] .. '\n'
local single_patt_begin = [[quote <- {~ ''->"'" (quotechar / .)* ''->"'" ~}]] .. '\n'
local quote_patt_begin =  "\
  quotechar <- \
    '\\' -> '\\\\' /  -- backslash \
    '\a' -> '\\a' /   -- audible bell \
    '\b' -> '\\b' /   -- backspace \
    '\f' -> '\\f' /   -- form feed \
    %nl  -> '\\n' /   -- line feed \
    '\r' -> '\\r' /   -- carriege return \
    '\t' -> '\\t' /   -- horizontal tab \
    '\v' -> '\\v' /   -- vertical tab\
"
local single_quote_patt = "\"\'\" -> \"\\'\" /\n"
local double_quote_patt = "'\"' -> '\\\"' /\n"
local lua_quote_patt_end = "\
  [^%g%s] -> to_special_character_lua   -- special characters"
local c_quote_patt_end = "\
  ('??' {[=/'%(%)!<>%-]}) -> '?\\?%1' / -- C trigraphs \
  [^%g%s] -> to_special_character_c     -- special characters"

local quotes_defs = {
  to_special_character_lua = function(s)
    return string.format('\\%03d', string.byte(s))
  end,
  to_special_character_c = function(s)
    return string.format('\\%03o', string.byte(s))
  end
}

local c_double_peg = re.compile(
  double_patt_begin ..
  quote_patt_begin ..
  double_quote_patt ..
  c_quote_patt_end, quotes_defs)
function pegger.double_quote_c_string(str)
  return c_double_peg:match(str)
end

local lua_double_peg = re.compile(
  double_patt_begin ..
  quote_patt_begin ..
  double_quote_patt ..
  lua_quote_patt_end, quotes_defs)
function pegger.double_quote_lua_string(str)
  return lua_double_peg:match(str)
end

local lua_single_peg = re.compile(
  single_patt_begin ..
  quote_patt_begin ..
  single_quote_patt ..
  lua_quote_patt_end, quotes_defs)
function pegger.single_quote_lua_string(str)
  return lua_single_peg:match(str)
end

--[=[
local c_single_peg = re.compile(
  single_patt_begin ..
  quote_patt_begin ..
  single_quote_patt ..
  c_quote_patt_end, quotes_defs)
function pegger.single_quote_c_string(str)
  return c_single_peg:match(str)
end
]=]

local combined_grammar_peg_pat = re.compile([[
pegs       <- {| (comment/peg)+ |}
peg        <- {| peg_head {peg_char*} |}
peg_head   <- %s* {[-_%w]+} %s* '<-' %s*
peg_char   <- !next_peg .
next_peg   <- linebreak %s* [-_%w]+ %s* '<-' %s*
comment    <- %s* '--' (!linebreak .)* linebreak?
]] ..
"linebreak <- [%nl]'\r' / '\r'[%nl] / [%nl] / '\r'"
)
function pegger.split_grammar_patts(combined_patts)
  local pattdescs = combined_grammar_peg_pat:match(combined_patts)
  errorer.assertf(pattdescs, 'invalid multiple pegs patterns syntax: %s', combined_patts)
  return tabler.imap(pattdescs, function(v)
    return {name = v[1], patt = v[2]}
  end)
end

local combined_parser_peg_pat = re.compile([[
pegs       <- {| (comment/peg)+ |}
peg        <- {| peg_head {peg_char*} |}
peg_head   <- %s* '%' {[-_%w]+} %s* '<-' %s*
peg_char   <- !next_peg .
next_peg   <- linebreak %s* '%' [-_%w]+ %s* '<-' %s*
comment    <- %s* '--' (!linebreak .)* linebreak?
]] ..
"linebreak <- [%nl]'\r' / '\r'[%nl] / [%nl] / '\r'"
)
function pegger.split_parser_patts(combined_patts)
  local pattdescs = combined_parser_peg_pat:match(combined_patts)
  errorer.assertf(pattdescs, 'invalid multiple pegs patterns syntax: %s', combined_patts)
  return tabler.imap(pattdescs, function(v)
    return {name = v[1], patt = v[2]}
  end)
end

local substitute_vars = {}
local substitute_defs = { to_var = function(k) return substitute_vars[k] or '' end }
local substitute_patt = re.compile([[
  pat <- {~ (var / .)* ~}
  var <- ('$(' {[_%a]+} ')') -> to_var
]], substitute_defs)
function pegger.substitute(format, vars)
  metamagic.setmetaindex(substitute_vars, vars, true)
  return substitute_patt:match(format)
end

local split_execargs_patt = re.compile[[
  args <- %s* {| arg+ |}
  arg <- ({~ squoted_arg ~} / {~ dquoted_arg ~} / {~ simple_arg ~}) %s*
  simple_arg <- (!%s (squoted_arg / dquoted_arg / .))+
  squoted_arg <- "'"->'' (!"'" .)+ "'"->''
  dquoted_arg <- '"'->'' (!'"' .)+ '"'->''
]]
function pegger.split_execargs(s)
  if not s then return {} end
  return split_execargs_patt:match(s)
end

local filename_to_unitname_patt = re.compile[[
  p <- {~ filebeg? c* ~}
  c <- extend -> '' / [_%w] / (%s+ / [_/\.-]) -> '_' / . -> 'X'
  filebeg <- [./\]+ -> ''
  extend <- '.' [_%w]+ !.
]]

function pegger.filename_to_unitname(s)
  return filename_to_unitname_patt:match(s)
end

--[=[
local template_peg = re.compile([[
  peg           <- {~ (text / code_eq / code)+ ~}
  text          <- '' -> ' render([==[' text_contents  '' -> ']==]) '
  text_contents <- {(!code_open_eq !code_open .)+}
  code_eq       <- code_open_eq -> ' render(tostring(' code_contents ''->')) ' code_close
  code          <- code_open code_contents code_close %nl*
  code_contents <- {(!code_close .)*}
  code_open     <- (' '* '{%' !'=') -> ' '
  code_open_eq  <- ('{%=' ' '*) -> ''
  code_close    <- '%}' -> '' / %{UnclosedCode}
]])

local compat = require 'pl.compat'
function pegger.render_template(text, env)
  if not text or text == '' then return '' end
  local out = {}
  env = env or {}
  env.render = function(s) table.insert(out, s) end
  setmetatable(env, { __index = _G })
  local luacode = assert(template_peg:match(text), 'template peg parse failed')
  local run = assert(compat.load(luacode, nil, "t", env))
  run()
  return table.concat(out)
end
]=]

local c_defines_peg = re.compile([[
  defines   <- %s* {| define* |}
  define    <- '#define ' {| {define_name} (' '+ {define_content} / define_content) |} linebreak?
  define_name <- [_%w]+
  define_content <- (!linebreak .)*
]]..
"linebreak <- [%nl]'\r' / '\r'[%nl] / [%nl] / '\r'")

function pegger.parse_c_defines(text)
  local t = c_defines_peg:match(text)
  local defs = {}
  for _,v in ipairs(t) do
    local name = v[1]
    local value = v[2]
    if not value or value == '' then
      -- define without content, treat as boolean
      value = true
    else
      -- try to convert to a number
      local numvalue = tonumber(value)
      if numvalue and tostring(numvalue) == value then
        value = numvalue
      end
    end
    defs[name] = value
  end
  return defs
end

local crlf_to_lf_peg = re.compile([[
  text <- {~ (linebreak / .)* ~}
]]..
"linebreak <- ([%nl]'\r' / '\r'[%nl] / [%nl] / '\r') -> ln",
{ln = function() return '\n' end})


function pegger.normalize_newlines(text)
  return crlf_to_lf_peg:match(text)
end

return pegger

