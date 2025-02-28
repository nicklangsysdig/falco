-- Copyright (C) 2019 The Falco Authors.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

--[[
   Compile and install falco rules.

   This module exports functions that are called from falco c++-side to compile and install a set of rules.

--]]

local compiler = require "compiler"
local yaml = require"lyaml"


--[[
   Traverse AST, adding the passed-in 'index' to each node that contains a relational expression
--]]
local function mark_relational_nodes(ast, index)
   local t = ast.type

   if t == "BinaryBoolOp" then
      mark_relational_nodes(ast.left, index)
      mark_relational_nodes(ast.right, index)

   elseif t == "UnaryBoolOp" then
      mark_relational_nodes(ast.argument, index)

   elseif t == "BinaryRelOp" then
      ast.index = index

   elseif t == "UnaryRelOp"  then
      ast.index = index

   else
      error ("Unexpected type in mark_relational_nodes: "..t)
   end
end

function map(f, arr)
   local res = {}
   for i,v in ipairs(arr) do
      res[i] = f(v)
   end
   return res
end


-- Permissive for case and for common abbreviations.
priorities = {
   Emergency=0, Alert=1, Critical=2, Error=3, Warning=4, Notice=5, Informational=6, Debug=7,
   emergency=0, alert=1, critical=2, error=3, warning=4, notice=5, informational=6, debug=7,
   EMERGENCY=0, ALERT=1, CRITICAL=2, ERROR=3, WARNING=4, NOTICE=5, INFORMATIONAL=6, DEBUG=7,
   INFO=6, info=6
}

--[[
   Take a filter AST and set it up in the libsinsp runtime, using the filter API.
--]]
local function create_filter_obj(node, lua_parser, parent_bool_op)
   local t = node.type

   if t == "BinaryBoolOp" then

      -- "nesting" (the runtime equivalent of placing parens in syntax) is
      -- never necessary when we have identical successive operators. so we
      -- avoid it as a runtime performance optimization.
      if (not(node.operator == parent_bool_op)) then
	 err = filter.nest(lua_parser) -- io.write("(")
	 if err ~= nil then
	    return err
	 end
      end

      err = create_filter_obj(node.left, lua_parser, node.operator)
      if err ~= nil then
	 return err
      end

      err = filter.bool_op(lua_parser, node.operator) -- io.write(" "..node.operator.." ")
      if err ~= nil then
	 return err
      end

      err = create_filter_obj(node.right, lua_parser, node.operator)
      if err ~= nil then
	 return err
      end

      if (not (node.operator == parent_bool_op)) then
	 err = filter.unnest(lua_parser) -- io.write(")")
	 if err ~= nil then
	    return err
	 end
      end

   elseif t == "UnaryBoolOp" then
      err = filter.nest(lua_parser) --io.write("(")
      if err ~= nil then
	 return err
      end

      err = filter.bool_op(lua_parser, node.operator) -- io.write(" "..node.operator.." ")
      if err ~= nil then
	 return err
      end

      err = create_filter_obj(node.argument, lua_parser)
      if err ~= nil then
	 return err
      end

      err = filter.unnest(lua_parser) -- io.write(")")
      if err ~= nil then
	 return err
      end

   elseif t == "BinaryRelOp" then
      if (node.operator == "in" or
          node.operator == "intersects" or
	  node.operator == "pmatch") then
	 elements = map(function (el) return el.value end, node.right.elements)
	 err = filter.rel_expr(lua_parser, node.left.value, node.operator, elements, node.index)
	 if err ~= nil then
	    return err
	 end
      else
	 err = filter.rel_expr(lua_parser, node.left.value, node.operator, node.right.value, node.index)
	 if err ~= nil then
	    return err
	 end
      end
      -- io.write(node.left.value.." "..node.operator.." "..node.right.value)

   elseif t == "UnaryRelOp"  then
      err = filter.rel_expr(lua_parser, node.argument.value, node.operator, node.index)
      if err ~= nil then
	 return err
      end
      --io.write(node.argument.value.." "..node.operator)

   else
      return "Unexpected type in create_filter_obj: "..t
   end

   return nil
end

-- This should be keep in sync with parser.lua
defined_comp_operators = {
   ["="]=1,
   ["=="] = 1,
   ["!="] = 1,
   ["<="] = 1,
   [">="] = 1,
   ["<"] = 1,
   [">"] = 1,
   ["contains"] = 1,
   ["icontains"] = 1,
   ["glob"] = 1,
   ["startswith"] = 1,
   ["endswith"] = 1,
   ["in"] = 1,
   ["intersects"] = 1,
   ["pmatch"] = 1
}

defined_list_comp_operators = {
   ["in"] = 1,
   ["intersects"] = 1,
   ["pmatch"] = 1
}

-- Note that the rules_by_name and rules_by_idx refer to the same rule
-- object. The by_name index is used for things like describing rules,
-- and the by_idx index is used to map the relational node index back
-- to a rule.
local state = {macros={}, lists={}, rules_by_name={},
	       skipped_rules_by_name={}, macros_by_name={}, lists_by_name={},
	       n_rules=0, rules_by_idx={}, ordered_rule_names={}, ordered_macro_names={}, ordered_list_names={}}

local function reset_rules(rules_mgr)
   falco_rules.clear_filters(rules_mgr)
   state.n_rules = 0
   state.rules_by_idx = {}
   state.macros = {}
   state.lists = {}
end

-- From http://lua-users.org/wiki/TableUtils
--
function table.val_to_str ( v )
  if "string" == type( v ) then
    v = string.gsub( v, "\n", "\\n" )
    if string.match( string.gsub(v,"[^'\"]",""), '^"+$' ) then
      return "'" .. v .. "'"
    end
    return '"' .. string.gsub(v,'"', '\\"' ) .. '"'
  else
    return "table" == type( v ) and table.tostring( v ) or
      tostring( v )
  end
end

function table.key_to_str ( k )
  if "string" == type( k ) and string.match( k, "^[_%a][_%a%d]*$" ) then
    return k
  else
    return "[" .. table.val_to_str( k ) .. "]"
  end
end

function table.tostring( tbl )
  local result, done = {}, {}
  for k, v in ipairs( tbl ) do
    table.insert( result, table.val_to_str( v ) )
    done[ k ] = true
  end
  for k, v in pairs( tbl ) do
    if not done[ k ] then
      table.insert( result,
        table.key_to_str( k ) .. "=" .. table.val_to_str( v ) )
    end
  end
  return "{" .. table.concat( result, "," ) .. "}"
end

-- Split rules_content by lines and also remember the line numbers for
-- each top -level object. Returns a table of lines and a table of
-- line numbers for objects.

function split_lines(rules_content)
   lines = {}
   indices = {}

   idx = 1
   last_pos = 1
   pos = string.find(rules_content, "\n", 1, true)

   while pos ~= nil do
      line = string.sub(rules_content, last_pos, pos-1)
      if line ~= "" then
	 lines[#lines+1] = line
	 if string.len(line) >= 3 and string.sub(line, 1, 3) == "---" then
	    -- Document marker, skip
         elseif string.sub(line, 1, 1) == '-' then
	    indices[#indices+1] = idx
	 end

	 idx = idx + 1
      end

      last_pos = pos+1
      pos = string.find(rules_content, "\n", pos+1, true)
   end

   if last_pos < string.len(rules_content) then
      line = string.sub(rules_content, last_pos)
      lines[#lines+1] = line
      if string.sub(line, 1, 1) == '-' then
	 indices[#indices+1] = idx
      end

      idx = idx + 1
   end

   -- Add a final index for last line in document
   indices[#indices+1] = idx

   return lines, indices
end

function get_orig_yaml_obj(rules_lines, row)
    idx = row
    local t = {}
    while (idx <= #rules_lines) do
        t[#t + 1] = rules_lines[idx]
        idx = idx + 1

        if idx > #rules_lines or rules_lines[idx] == "" or string.sub(rules_lines[idx], 1, 1) == '-' then
            break
        end
    end
    t[#t + 1] = ""
    local ret = ""
    ret = table.concat(t, "\n")
    return ret
end

function get_lines(rules_lines, row, num_lines)
   local ret = ""

   idx = row
   while (idx < (row + num_lines) and idx <= #rules_lines) do
      ret = ret..rules_lines[idx].."\n"
      idx = idx + 1
   end

   return ret
end

function quote_item(item)

   -- Add quotes if the string contains spaces and doesn't start/end
   -- w/ quotes
   if string.find(item, " ") then
      if string.sub(item, 1, 1) ~= "'" and string.sub(item, 1, 1) ~= '"' then
	 item = "\""..item.."\""
      end
   end

   return item
end

function paren_item(item)
   if string.sub(item, 1, 1) ~= "(" then
      item = "("..item..")"
   end

   return item
end

function build_error(rules_lines, row, num_lines, err)
   local ret = err.."\n---\n"..get_lines(rules_lines, row, num_lines).."---"

   return {ret}
end

function build_error_with_context(ctx, err)
   local ret = err.."\n---\n"..ctx.."---"
   return {ret}
end

function validate_exception_item_multi_fields(rules_mgr, source, eitem, context)

   local name = eitem['name']
   local fields = eitem['fields']
   local values = eitem['values']
   local comps = eitem['comps']

   if comps == nil then
      comps = {}
      for c=1,#fields do
	 table.insert(comps, "=")
      end
      eitem['comps'] = comps
   else
      if #fields ~= #comps then
	 return false, build_error_with_context(context, "Rule exception item "..name..": fields and comps lists must have equal length"), warnings
      end
   end
   for k, fname in ipairs(fields) do
      if not falco_rules.is_defined_field(rules_mgr, source, fname) then
	 return false, build_error_with_context(context, "Rule exception item "..name..": field name "..fname.." is not a supported filter field"), warnings
      end
   end
   for k, comp in ipairs(comps) do
      if defined_comp_operators[comp] == nil then
	 return false, build_error_with_context(context, "Rule exception item "..name..": comparison operator "..comp.." is not a supported comparison operator"), warnings
      end
   end
end

function validate_exception_item_single_field(rules_mgr, source, eitem, context)

   local name = eitem['name']
   local fields = eitem['fields']
   local values = eitem['values']
   local comps = eitem['comps']

   if comps == nil then
      eitem['comps'] = "in"
      comps = eitem['comps']
   else
      if type(fields) ~= "string" or type(comps) ~= "string" then
	 return false, build_error_with_context(context, "Rule exception item "..name..": fields and comps must both be strings"), warnings
      end
   end
   if not falco_rules.is_defined_field(rules_mgr, source, fields) then
      return false, build_error_with_context(context, "Rule exception item "..name..": field name "..fields.." is not a supported filter field"), warnings
   end
   if defined_comp_operators[comps] == nil then
      return false, build_error_with_context(context, "Rule exception item "..name..": comparison operator "..comps.." is not a supported comparison operator"), warnings
   end
end

function load_rules_doc(rules_mgr, doc, load_state)

   local warnings = {}

   -- Iterate over yaml list. In this pass, all we're doing is
   -- populating the set of rules, macros, and lists. We're not
   -- expanding/compiling anything yet. All that will happen in a
   -- second pass
   for i,v in ipairs(doc) do

      load_state.cur_item_idx = load_state.cur_item_idx + 1

      -- Save back the original object as it appeared in the file. Will be used to provide context.
      local context = get_orig_yaml_obj(load_state.lines,
					load_state.indices[load_state.cur_item_idx])

      if (not (type(v) == "table")) then
	 return false, build_error_with_context(context, "Unexpected element of type " ..type(v)..". Each element should be a yaml associative array."), warnings
      end

      v['context'] = context

      if (v['required_engine_version']) then
	 load_state.required_engine_version = v['required_engine_version']
	 if type(load_state.required_engine_version) ~= "number" then
	    return false, build_error_with_context(v['context'], "Value of required_engine_version must be a number")
	 end

	 if falco_rules.engine_version(rules_mgr) < v['required_engine_version'] then
	    return false, build_error_with_context(v['context'], "Rules require engine version "..v['required_engine_version']..", but engine version is "..falco_rules.engine_version(rules_mgr)), warnings
	 end

      elseif (v['required_plugin_versions']) then

	 for _, vobj in ipairs(v['required_plugin_versions']) do
	    if vobj['name'] == nil then
	       return false, build_error_with_context(v['context'], "required_plugin_versions item must have name property"), warnings
	    end

	    if vobj['version'] == nil then
	       return false, build_error_with_context(v['context'], "required_plugin_versions item must have version property"), warnings
	    end

	    -- In the rules yaml, it's a name + version. But it's
	    -- possible, although unlikely, that a single yaml blob
	    -- contains multiple docs, withe each doc having its own
	    -- required_engine_version entry. So populate a map plugin
	    -- name -> list of required plugin versions.
	    if load_state.required_plugin_versions[vobj['name']] == nil then
	       load_state.required_plugin_versions[vobj['name']] = {}
	    end

	    table.insert(load_state.required_plugin_versions[vobj['name']], vobj['version'])
	 end

      elseif (v['macro']) then

	 if (v['macro'] == nil or type(v['macro']) == "table") then
	    return false, build_error_with_context(v['context'], "Macro name is empty"), warnings
	 end

	 if v['source'] == nil then
	    v['source'] = "syscall"
	 end

	 if state.macros_by_name[v['macro']] == nil then
	    state.ordered_macro_names[#state.ordered_macro_names+1] = v['macro']
	 end

	 for j, field in ipairs({'condition'}) do
	    if (v[field] == nil) then
	       return false, build_error_with_context(v['context'], "Macro must have property "..field), warnings
	    end
	 end

	 -- Possibly append to the condition field of an existing macro
	 append = false

	 if v['append'] then
	    append = v['append']
	 end

	 if append then
	    if state.macros_by_name[v['macro']] == nil then
	       return false, build_error_with_context(v['context'], "Macro " ..v['macro'].. " has 'append' key but no macro by that name already exists"), warnings
	    end

	    state.macros_by_name[v['macro']]['condition'] = state.macros_by_name[v['macro']]['condition'] .. " " .. v['condition']

	    -- Add the current object to the context of the base macro
	    state.macros_by_name[v['macro']]['context'] = state.macros_by_name[v['macro']]['context'].."\n"..v['context']

	 else
	    state.macros_by_name[v['macro']] = v
	 end

      elseif (v['list']) then

	 if (v['list'] == nil or type(v['list']) == "table") then
	    return false, build_error_with_context(v['context'], "List name is empty"), warnings
	 end

	 if state.lists_by_name[v['list']] == nil then
	    state.ordered_list_names[#state.ordered_list_names+1] = v['list']
	 end

	 for j, field in ipairs({'items'}) do
	    if (v[field] == nil) then
	       return false, build_error_with_context(v['context'], "List must have property "..field), warnings
	    end
	 end

	 -- Possibly append to an existing list
	 append = false

	 if v['append'] then
	    append = v['append']
	 end

	 if append then
	    if state.lists_by_name[v['list']] == nil then
	       return false, build_error_with_context(v['context'], "List " ..v['list'].. " has 'append' key but no list by that name already exists"), warnings
	    end

	    for j, elem in ipairs(v['items']) do
	       table.insert(state.lists_by_name[v['list']]['items'], elem)
	    end
	 else
	    state.lists_by_name[v['list']] = v
	 end

      elseif (v['rule']) then

	 if (v['rule'] == nil or type(v['rule']) == "table") then
	    return false, build_error_with_context(v['context'], "Rule name is empty"), warnings
	 end

	 -- By default, if a rule's condition refers to an unknown
	 -- filter like evt.type, etc the loader throws an error.
	 if v['skip-if-unknown-filter'] == nil then
	    v['skip-if-unknown-filter'] = false
	 end

	 if v['source'] == nil then
	    v['source'] = "syscall"
	 end

	 -- Add an empty exceptions property to the rule if not defined
	 if v['exceptions'] == nil then
	    v['exceptions'] = {}
	 end

	 -- Possibly append to the condition field of an existing rule
	 append = false

	 if v['append'] then
	    append = v['append']
	 end

	 -- Validate the contents of the rule exception
	 if next(v['exceptions']) ~= nil then

	    -- This validation only applies if append=false. append=true validation is handled below
	    if append == false then

	       for _, eitem in ipairs(v['exceptions']) do

		  if eitem['name'] == nil then
		     return false, build_error_with_context(v['context'], "Rule exception item must have name property"), warnings
		  end

		  if eitem['fields'] == nil then
		     return false, build_error_with_context(v['context'], "Rule exception item "..eitem['name']..": must have fields property with a list of fields"), warnings
		  end

		  if eitem['values'] == nil then
		     -- An empty values array is okay
		     eitem['values'] = {}
		  end

		  -- Different handling if the fields property is a single item vs a list
		  local valid, err
		  if type(eitem['fields']) == "table" then
		     valid, err = validate_exception_item_multi_fields(rules_mgr, v['source'], eitem, v['context'])
		  else
		     valid, err = validate_exception_item_single_field(rules_mgr, v['source'], eitem, v['context'])
		  end

		  if valid == false then
		     return valid, err
		  end
	       end
	    end
	 end

	 if append then

	    if state.rules_by_name[v['rule']] == nil then
	       if state.skipped_rules_by_name[v['rule']] == nil then
		  return false, build_error_with_context(v['context'], "Rule " ..v['rule'].. " has 'append' key but no rule by that name already exists"), warnings
	       end
	    else
          if (v['condition'] == nil and next(v['exceptions']) == nil) then
             return false, build_error_with_context(v['context'], "Appended rule must have exceptions or condition property"), warnings
          end

	       if next(v['exceptions']) ~= nil then

		  for _, eitem in ipairs(v['exceptions']) do

		     if eitem['name'] == nil then
			return false, build_error_with_context(v['context'], "Rule exception item must have name property"), warnings
		     end

		     -- Separate case when a exception name is not found
		     -- This means that a new exception is being appended

		     local new_exception = true
		     for _, rex_item in ipairs(state.rules_by_name[v['rule']]['exceptions']) do
			if rex_item['name'] == eitem['name'] then
			   new_exception = false
			   break
			end
		     end

		     if new_exception then
			local exceptions = state.rules_by_name[v['rule']]['exceptions']
			
			if eitem['fields'] == nil then
			   return false, build_error_with_context(v['context'], "Rule exception new item "..eitem['name']..": must have fields property with a list of fields"), warnings
			end
			if eitem['values'] == nil then
			   return false, build_error_with_context(v['context'], "Rule exception new item "..eitem['name']..": must have values property with a list of values"), warnings
			end
			
			local valid, err
			if type(eitem['fields']) == "table" then
			   valid, err = validate_exception_item_multi_fields(rules_mgr, v['source'], eitem, v['context'])
			else
			   valid, err = validate_exception_item_single_field(rules_mgr, v['source'], eitem, v['context'])
			end
			
			if valid == false then
			   return valid, err, warnings
			end

			-- Insert the complete exception object
			exceptions[#exceptions+1] = eitem
		     else
			-- Appends to existing exception here
		   	-- You can't append exception fields or comps to an existing rule exception
                        if eitem['fields'] ~= nil then
			   return false, build_error_with_context(v['context'], "Can not append exception fields to existing rule, only values"), warnings
                        end

                        if eitem['comps'] ~= nil then
                           return false, build_error_with_context(v['context'], "Can not append exception comps to existing rule, only values"), warnings
                        end

		     	-- You can append values. They are added to the
		     	-- corresponding name, if it exists. If no
		     	-- exception with that name exists, add a
		     	-- warning.
		     	if eitem['values'] ~= nil then
			   local found=false
			   for _, reitem in ipairs(state.rules_by_name[v['rule']]['exceptions']) do
			      if reitem['name'] == eitem['name'] then
			         found=true
			         for _, values in ipairs(eitem['values']) do
				    reitem['values'][#reitem['values'] + 1] = values
			         end
			      end
			   end

			   if found == false then
			      warnings[#warnings + 1] = "Rule "..v['rule'].." with append=true: no set of fields matching name "..eitem['name']
			   end
		        end
		     end
		  end
	       end

	       if v['condition'] ~= nil then
		  state.rules_by_name[v['rule']]['condition'] = state.rules_by_name[v['rule']]['condition'] .. " " .. v['condition']
	       end

	    -- Add the current object to the context of the base rule
	       state.rules_by_name[v['rule']]['context'] = state.rules_by_name[v['rule']]['context'].."\n"..v['context']
	    end

	 else
       local err = nil
	    for j, field in ipairs({'condition', 'output', 'desc', 'priority'}) do
	       if (err == nil and v[field] == nil) then
		       err = build_error_with_context(v['context'], "Rule must have property "..field)
	       end
	    end

       -- Handle spacial case where "enabled" flag is defined only
       if (err ~= nil) then
          if (v['enabled'] == nil) then
            return false, err, warnings
          else 
             if state.rules_by_name[v['rule']] == nil then
                return false, build_error_with_context(v['context'], "Rule " ..v['rule'].. " has 'enabled' key only, but no rule by that name already exists"), warnings
             end
             state.rules_by_name[v['rule']]['enabled'] = v['enabled']
          end
       else
       -- Convert the priority-as-string to a priority-as-number now
	    v['priority_num'] = priorities[v['priority']]

	    if v['priority_num'] == nil then
	       error("Invalid priority level: "..v['priority'])
	    end

	    if v['priority_num'] <= load_state.min_priority then
	       -- Note that we can overwrite rules, but the rules are still
	       -- loaded in the order in which they first appeared,
	       -- potentially across multiple files.
	       if state.rules_by_name[v['rule']] == nil then
		  state.ordered_rule_names[#state.ordered_rule_names+1] = v['rule']
	       end

	       -- The output field might be a folded-style, which adds a
	       -- newline to the end. Remove any trailing newlines.
	       v['output'] = compiler.trim(v['output'])

	       state.rules_by_name[v['rule']] = v
	    else
	       state.skipped_rules_by_name[v['rule']] = v
	    end
       end
	 end
      else
	 local context = v['context']

	 arr = build_error_with_context(context, "Unknown top level object: "..table.tostring(v))
	 warnings[#warnings + 1] = arr[1]
      end
   end

   return true, {}, warnings
end

-- cond and not ((proc.name=apk and fd.directory=/usr/lib/alpine) or (proc.name=npm and fd.directory=/usr/node/bin) or ...)
-- Populates exfields with all fields used
function build_exception_condition_string_multi_fields(eitem, exfields)

    local fields = eitem['fields']
    local comps = eitem['comps']

    local icond = {}

    icond[#icond + 1] = "("

    local lcount = 0
    for i, values in ipairs(eitem['values']) do
        if #fields ~= #values then
            return nil, "Exception item " .. eitem['name'] .. ": fields and values lists must have equal length"
        end

        if lcount ~= 0 then
            icond[#icond + 1] = " or "
        end
        lcount = lcount + 1

        icond[#icond + 1] = "("

        for k = 1, #fields do
            if k > 1 then
                icond[#icond + 1] = " and "
            end
            local ival = values[k]
            local istr = ""

            -- If ival is a table, express it as (titem1, titem2, etc)
            if type(ival) == "table" then
                istr = "("
                for _, item in ipairs(ival) do
                    if istr ~= "(" then
                        istr = istr .. ", "
                    end
                    istr = istr .. quote_item(item)
                end
                istr = istr .. ")"
            else
                -- If the corresponding operator is one that works on lists, possibly add surrounding parentheses.
                if defined_list_comp_operators[comps[k]] then
                    istr = paren_item(ival)
                else
                    -- Quote the value if not already quoted
                    istr = quote_item(ival)
                end
            end

            icond[#icond + 1] = fields[k] .. " " .. comps[k] .. " " .. istr
            exfields[fields[k]] = true
        end

        icond[#icond + 1] = ")"
    end

    icond[#icond + 1] = ")"

    -- Don't return a trivially empty condition string
    local ret = table.concat(icond)
    if ret == "()" then
        return "", nil
    end

    return ret, nil

end

function build_exception_condition_string_single_field(eitem, exfields)

   local icond = ""

   for i, value in ipairs(eitem['values']) do

      if type(value) ~= "string" then
	 return "", "Expected values array for item "..eitem['name'].." to contain a list of strings"
      end

      if icond == "" then
	 icond = "("..eitem['fields'].." "..eitem['comps'].." ("
      else
	 icond = icond..", "
      end

      exfields[eitem['fields']] = true

      icond = icond..quote_item(value)
   end

   if icond ~= "" then
      icond = icond.."))"
   end

   return icond, nil

end

-- Returns:
-- - Load Result: bool
-- - required engine version. will be nil when load result is false
-- - required_plugin_versions. will be nil when load_result is false
-- - List of Errors
-- - List of Warnings
function load_rules(rules_content,
		    rules_mgr,
		    verbose,
		    all_events,
		    extra,
		    replace_container_info,
		    min_priority)

   local warnings = {}

   local load_state = {lines={}, indices={}, cur_item_idx=0, min_priority=min_priority, required_engine_version=0, required_plugin_versions={}}

   load_state.lines, load_state.indices = split_lines(rules_content)

   local status, docs = pcall(yaml.load, rules_content, { all = true })

   if status == false then
      local pat = "^([%d]+):([%d]+): "
      -- docs is actually an error string

      local row = 0
      local col = 0

      row, col = string.match(docs, pat)
      if row ~= nil and col ~= nil then
	 docs = string.gsub(docs, pat, "")
      end

      row = tonumber(row)
      col = tonumber(col)

      return false, nil, nil, build_error(load_state.lines, row, 3, docs), warnings
   end

   if docs == nil then
      -- An empty rules file is acceptable
      return true, load_state.required_engine_version, {}, {}, warnings
   end

   if type(docs) ~= "table" then
      return false, nil, nil, build_error(load_state.lines, 1, 1, "Rules content is not yaml"), warnings
   end

   for docidx, doc in ipairs(docs) do

      if type(doc) ~= "table" then
	 return false, nil, nil, build_error(load_state.lines, 1, 1, "Rules content is not yaml"), warnings
      end

      -- Look for non-numeric indices--implies that document is not array
      -- of objects.
      for key, val in pairs(doc) do
	 if type(key) ~= "number" then
	    return false, nil, nil, build_error(load_state.lines, 1, 1, "Rules content is not yaml array of objects"), warnings
	 end
      end

      res, errors, doc_warnings = load_rules_doc(rules_mgr, doc, load_state)

      if (doc_warnings ~= nil) then
	 for idx, warning in pairs(doc_warnings) do
	    table.insert(warnings, warning)
	 end
      end

      if not res then
	 return res, nil, nil, errors, warnings
      end
   end

   -- We've now loaded all the rules, macros, and lists. Now
   -- compile/expand the rules, macros, and lists. We use
   -- ordered_rule_{lists,macros,names} to compile them in the order
   -- in which they appeared in the file(s).
   reset_rules(rules_mgr)

   for i, name in ipairs(state.ordered_list_names) do

      local v = state.lists_by_name[name]

      -- list items are represented in yaml as a native list, so no
      -- parsing necessary
      local items = {}

      -- List items may be references to other lists, so go through
      -- the items and expand any references to the items in the list
      for i, item in ipairs(v['items']) do
	 if (state.lists[item] == nil) then
	    items[#items+1] = quote_item(item)
	 else
	    state.lists[item].used = true
	    for i, exp_item in ipairs(state.lists[item].items) do
	       items[#items+1] = exp_item
	    end
	 end
      end

      state.lists[v['list']] = {["items"] = items, ["used"] = false}
   end

   for _, name in ipairs(state.ordered_macro_names) do

      local v = state.macros_by_name[name]

      local status, ast = compiler.compile_macro(v['condition'], state.macros, state.lists)

      if status == false then
	 return false, nil, nil, build_error_with_context(v['context'], ast), warnings
      end

      state.macros[v['macro']] = {["ast"] = ast.filter.value, ["used"] = false}
   end

   for _, name in ipairs(state.ordered_rule_names) do

      local v = state.rules_by_name[name]

      local econd = ""

      local exfields = {}

      -- Turn exceptions into condition strings and add them to each
      -- rule's condition
      for _, eitem in ipairs(v['exceptions']) do

	 local icond, err
	 if type(eitem['fields']) == "table" then
	    icond, err = build_exception_condition_string_multi_fields(eitem, exfields)
	 else
	    icond, err = build_exception_condition_string_single_field(eitem, exfields)
	 end

	 if err ~= nil then
	    return false, nil, nil, build_error_with_context(v['context'], err), warnings
	 end

	 if icond ~= "" then
	    econd = econd.." and not "..icond
	 end
      end

      state.rules_by_name[name]['exception_fields'] = exfields

      if econd ~= "" then
	 state.rules_by_name[name]['compile_condition'] = "("..state.rules_by_name[name]['condition']..") "..econd
      else
	 state.rules_by_name[name]['compile_condition'] = state.rules_by_name[name]['condition']
      end

      warn_evttypes = true
      if v['warn_evttypes'] ~= nil then
	 warn_evttypes = v['warn_evttypes']
      end

      local status, filter_ast = compiler.compile_filter(v['rule'], v['compile_condition'],
							 state.macros, state.lists)

      if status == false then
	 return false, nil, nil, build_error_with_context(v['context'], filter_ast), warnings
      end

      if (filter_ast.type == "Rule") then

	 valid = falco_rules.is_source_valid(rules_mgr, v['source'])

	 if valid == false then
	    msg = "Rule "..v['rule']..": warning (unknown-source): unknown source "..v['source']..", skipping"
	    warnings[#warnings + 1] = msg
	    goto next_rule
	 end

	 state.n_rules = state.n_rules + 1

	 state.rules_by_idx[state.n_rules] = v

	 -- Store the index of this formatter in each relational expression that
	 -- this rule contains.
	 -- This index will eventually be stamped in events passing this rule, and
	 -- we'll use it later to determine which output to display when we get an
	 -- event.
	 mark_relational_nodes(filter_ast.filter.value, state.n_rules)

	 if (v['tags'] == nil) then
	    v['tags'] = {}
	 end

	 lua_parser = falco_rules.create_lua_parser(rules_mgr, v['source'])
	 local err = create_filter_obj(filter_ast.filter.value, lua_parser)
	 if err ~= nil then

	    -- If a rule has a property skip-if-unknown-filter: true,
	    -- and the error is about an undefined field, print a
	    -- message but continue.
	    if v['skip-if-unknown-filter'] == true and string.find(err, "filter_check called with nonexistent field") ~= nil then
	       msg = "Rule "..v['rule']..": warning (unknown-field):"
	       warnings[#warnings + 1] = msg
	    else
	       msg = "Rule "..v['rule']..": error "..err
	       return false, nil, nil, build_error_with_context(v['context'], msg), warnings
	    end

	 else
	    num_evttypes = falco_rules.add_filter(rules_mgr, lua_parser, v['rule'], v['source'], v['tags'])
	    if v['source'] == "syscall" and (num_evttypes == 0 or num_evttypes > 100) then
	       if warn_evttypes == true then
		  msg = "Rule "..v['rule']..": warning (no-evttype):\n".."         matches too many evt.type values.\n".."         This has a significant performance penalty."
		  warnings[#warnings + 1] = msg
	       end
	    end
	 end

	 -- Enable/disable the rule
	 if (v['enabled'] == nil) then
	    v['enabled'] = true
	 end

	 if (v['enabled'] == false) then
	    falco_rules.enable_rule(rules_mgr, v['rule'], 0)
	 else
	    falco_rules.enable_rule(rules_mgr, v['rule'], 1)
	 end

	 -- If the format string contains %container.info, replace it
	 -- with extra. Otherwise, add extra onto the end of the format
	 -- string.
	 if v['source'] == "syscall" then
	    if string.find(v['output'], "%container.info", nil, true) ~= nil then

	       -- There may not be any extra, or we're not supposed
	       -- to replace it, in which case we use the generic
	       -- "%container.name (id=%container.id)"
	       if replace_container_info == false then
		  v['output'] = string.gsub(v['output'], "%%container.info", "%%container.name (id=%%container.id)")
		  if extra ~= "" then
		     v['output'] = v['output'].." "..extra
		  end
	       else
		  safe_extra = string.gsub(extra, "%%", "%%%%")
		  v['output'] = string.gsub(v['output'], "%%container.info", safe_extra)
	       end
	    else
	       -- Just add the extra to the end
	       if extra ~= "" then
		  v['output'] = v['output'].." "..extra
	       end
	    end
	 end

	 -- Ensure that the output field is properly formatted by
	 -- creating a formatter from it. Any error will be thrown
	 -- up to the top level.
	 local err = falco_rules.is_format_valid(rules_mgr, v['source'], v['output'])
	 if err ~= nil then
	    return false, nil, nil, build_error_with_context(v['context'], err), warnings
	 end
      else
	 return false, nil, nil, build_error_with_context(v['context'], "Unexpected type in load_rule: "..filter_ast.type), warnings
      end

      ::next_rule::
   end

   -- Print info on any dangling lists or macros that were not used anywhere
   for name, macro in pairs(state.macros) do
      if macro.used == false then
	 msg = "macro "..name.." not refered to by any rule/macro"
	 warnings[#warnings + 1] = msg
      end
   end

   for name, list in pairs(state.lists) do
      if list.used == false then
	 msg = "list "..name.." not refered to by any rule/macro/list"
	 warnings[#warnings + 1] = msg
      end
   end

   io.flush()

   return true, load_state.required_engine_version, load_state.required_plugin_versions, {}, warnings
end

local rule_fmt = "%-50s %s"

-- http://lua-users.org/wiki/StringRecipes, with simplifications and bugfixes
local function wrap(str, limit, indent)
   indent = indent or ""
   limit = limit or 72
   local here = 1
   return str:gsub("(%s+)()(%S+)()",
		   function(sp, st, word, fi)
		      if fi-here > limit then
			 here = st
			 return "\n"..indent..word
		      end
                   end)
end

local function describe_single_rule(name)
   if (state.rules_by_name[name] == nil) then
      error ("No such rule: "..name)
   end

   -- Wrap the description into an multiple lines each of length ~ 60
   -- chars, with indenting to line up with the first line.
   local wrapped = wrap(state.rules_by_name[name]['desc'], 60, string.format(rule_fmt, "", ""))

   local line = string.format(rule_fmt, name, wrapped)
   print(line)
   print()
end

-- If name is nil, describe all rules
function describe_rule(name)

   print()
   local line = string.format(rule_fmt, "Rule", "Description")
   print(line)
   line = string.format(rule_fmt, "----", "-----------")
   print(line)

   if name == nil then
      for rulename, rule in pairs(state.rules_by_name) do
	 describe_single_rule(rulename)
      end
   else
      describe_single_rule(name)
   end
end

local rule_output_counts = {total=0, by_priority={}, by_name={}}

function on_event(rule_id)

   if state.rules_by_idx[rule_id] == nil then
      error ("rule_loader.on_event(): event with invalid rule_id: ", rule_id)
   end

   rule_output_counts.total = rule_output_counts.total + 1
   local rule = state.rules_by_idx[rule_id]

   if rule_output_counts.by_priority[rule.priority] == nil then
      rule_output_counts.by_priority[rule.priority] = 1
   else
      rule_output_counts.by_priority[rule.priority] = rule_output_counts.by_priority[rule.priority] + 1
   end

   if rule_output_counts.by_name[rule.rule] == nil then
      rule_output_counts.by_name[rule.rule] = 1
   else
      rule_output_counts.by_name[rule.rule] = rule_output_counts.by_name[rule.rule] + 1
   end

   -- Prefix output with '*' so formatting is permissive
   output = "*"..rule.output

   -- Also return all fields from all exceptions
   combined_rule = state.rules_by_name[rule.rule]

   if combined_rule == nil then
      error ("rule_loader.on_event(): could not find rule by name: ", rule.rule)
   end

   return rule.rule, rule.priority_num, output, combined_rule.exception_fields, rule.tags
end

function print_stats()
   print("Events detected: "..rule_output_counts.total)
   print("Rule counts by severity:")
   for priority, count in pairs(rule_output_counts.by_priority) do
      print ("   "..priority..": "..count)
   end

   print("Triggered rules by rule name:")
   for name, count in pairs(rule_output_counts.by_name) do
      print ("   "..name..": "..count)
   end
end



