--------------------------------------------------------------------------
--script for auto_funcs.h and auto_funcs.cpp generation
--expects LuaJIT
--------------------------------------------------------------------------
assert(_VERSION=='Lua 5.1',"Must use LuaJIT")
assert(bit,"Must use LuaJIT")
local script_args = {...}
local COMPILER = script_args[1]
local INTERNAL_GENERATION = script_args[2]:match("internal") and true or false
local FREETYPE_GENERATION = script_args[2]:match("freetype") and true or false
local IMGUI_PATH = os.getenv"IMGUI_PATH" or "../imgui"
local CFLAGS = ""
local CPRE,CTEST
--get implementations
local implementations = {}
for i=3,#script_args do
    if script_args[i]:match(COMPILER == "cl" and "^/" or "^%-") then
        local key, value = script_args[i]:match("^(.+)=(.+)$")
        if key and value then
            CFLAGS = CFLAGS .. " " .. key .. "=\"" .. value:gsub("\"", "\\\"") .. "\"";
        else
            CFLAGS = CFLAGS .. " " .. script_args[i]
        end
    else
        table.insert(implementations,script_args[i])
    end
end

if FREETYPE_GENERATION then
	CFLAGS = CFLAGS .. " -DIMGUI_ENABLE_FREETYPE "
end

if COMPILER == "gcc" or COMPILER == "clang" then
    CPRE = COMPILER..[[ -E -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_API="" -DIMGUI_IMPL_API="" ]] .. CFLAGS
    CTEST = COMPILER.." --version"
elseif COMPILER == "cl" then
    CPRE = COMPILER..[[ /E /DIMGUI_DISABLE_OBSOLETE_FUNCTIONS /DIMGUI_DEBUG_PARANOID /DIMGUI_API="" /DIMGUI_IMPL_API="" ]] .. CFLAGS
    CTEST = COMPILER
else
    print("Working without compiler ")
	error("cant work with "..COMPILER.." compiler")
end
--test compiler present
local HAVE_COMPILER = false

local pipe,err = io.popen(CTEST,"r")
if pipe then
    local str = pipe:read"*a"
    print(str)
    pipe:close()
    if str=="" then
        HAVE_COMPILER = false
    else
        HAVE_COMPILER = true
    end
else
    HAVE_COMPILER = false
    print(err)
end
assert(HAVE_COMPILER,"gcc, clang or cl needed to run script")


print("HAVE_COMPILER",HAVE_COMPILER)
print("INTERNAL_GENERATION",INTERNAL_GENERATION)
print("FREETYPE_GENERATION",FREETYPE_GENERATION)
print("CPRE",CPRE)
--------------------------------------------------------------------------
--this table has the functions to be skipped in generation
--------------------------------------------------------------------------
local cimgui_manuals = {
    igLogText = true,
    ImGuiTextBuffer_appendf = true,
    --igColorConvertRGBtoHSV = true,
    --igColorConvertHSVtoRGB = true
}
--------------------------------------------------------------------------
--this table is a dictionary to force a naming of function overloading (instead of algorythmic generated)
--first level is cimguiname without postfix, second level is the signature of the function, value is the
--desired name
---------------------------------------------------------------------------
local cimgui_overloads = {
    --igPushID = {
        --["(const char*)"] =           "igPushIDStr",
        --["(const char*,const char*)"] = "igPushIDRange",
        --["(const void*)"] =           "igPushIDPtr",
        --["(int)"] =                   "igPushIDInt"
    --},
}

--------------------------header definitions
local cimgui_header = 
[[//This file is automatically generated by generator.lua from https://github.com/cimgui/cimgui
//based on imgui.h file version XXX from Dear ImGui https://github.com/ocornut/imgui
]]
local gdefines = {} --for FLT_MAX and others
--------------------------------------------------------------------------
--helper functions
--------------------------------functions for C generation
--load parser module
local cpp2ffi = require"cpp2ffi"
local read_data = cpp2ffi.read_data
local save_data = cpp2ffi.save_data
local copyfile = cpp2ffi.copyfile
local serializeTableF = cpp2ffi.serializeTableF

local function func_header_impl_generate(FP)

    local outtab = {}
    
    for _,t in ipairs(FP.funcdefs) do
        if t.cimguiname then
            local cimf = FP.defsT[t.cimguiname]
            local def = cimf[t.signature]
			local addcoment = def.comment or ""
			if def.constructor then
				-- it happens with vulkan impl but constructor ImGui_ImplVulkanH_Window is not needed
			    --assert(def.stname ~= "","constructor without struct")
                --table.insert(outtab,"CIMGUI_API "..def.stname.."* "..def.ov_cimguiname ..(empty and "(void)" or --def.args)..";"..addcoment.."\n")
            elseif def.destructor then
                --table.insert(outtab,"CIMGUI_API void "..def.ov_cimguiname..def.args..";"..addcoment.."\n")
			else
                
                if def.stname == "" then --ImGui namespace or top level
                    local empty = def.args:match("^%(%)") --no args
                    table.insert(outtab,"CIMGUI_API".." "..def.ret.." "..def.ov_cimguiname..(empty and "(void)" or def.args)..";"..addcoment.."\n")
                else
					cpp2ffi.prtable(def)
                    error("class function in implementations")
                end
            end
        else --not cimguiname
            table.insert(outtab,t.comment:gsub("%%","%%%%").."\n")-- %% substitution for gsub
        end
    end
    local cfuncsstr = table.concat(outtab)
    cfuncsstr = cfuncsstr:gsub("\n+","\n") --several empty lines to one empty line
    return cfuncsstr
end

local func_header_generate = cpp2ffi.func_header_generate
local func_implementation = cpp2ffi.func_implementation

-------------------functions for getting and setting defines
local function get_defines(t)
    local compiler_cmd = COMPILER == "cl"
                         and COMPILER..[[ /TP /nologo /c /Fo"NUL" /I "]]..IMGUI_PATH..[[" print_defines.cpp]]..CFLAGS
                         or COMPILER..[[ -E -dM -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS -DIMGUI_API="" -DIMGUI_IMPL_API="" ]]..IMGUI_PATH..[[/imgui.h]]..CFLAGS
    print(compiler_cmd)
    local pipe,err = io.popen(compiler_cmd,"r")
    local defines = {}
    local output = { err }
    while true do
        local line = pipe:read"*l"
        if not line then break end
        local key,value = line:match([[^#define%s+(%S+)%s*(.*)]])
        if not key then --or not value then 
            table.insert(output, line)
            --print(line)
        else
            defines[key]=value or ""
        end
    end
    pipe:close()
    -- Might fail if imconfig.h includes headers to other parts of your
    -- project. Try defining IMGUI_DISABLE_INCLUDE_IMCONFIG_H.
    assert(next(defines), table.concat(output, "\n"))
    --require"anima.utils"
    --prtable(defines)
    --FLT_MAX
    local ret = {}
    for i,v in ipairs(t) do
        local aa = defines[v]
        while true do
            local tmp = defines[aa]
            if not tmp then
                break
            else
                aa = tmp
            end
        end
        ret[v] = aa
    end
    return ret
end
  --subtitution of FLT_MAX value for FLT_MAX or FLT_MIN
local function set_defines(fdefs)
	local FLT_MINpat = gdefines.FLT_MIN:gsub("([%.%-])","%%%1")
    for k,defT in pairs(fdefs) do
        for i,def in ipairs(defT) do
            for name,default in pairs(def.defaults) do
                if default == gdefines.FLT_MAX then
                    def.defaults[name] = "FLT_MAX"
                elseif default:match(FLT_MINpat) then
                    def.defaults[name] = default:gsub(FLT_MINpat,"FLT_MIN")
                end
            end
        end
    end
end 
--this creates defsBystruct in case you need to list by struct container
local function DefsByStruct(FP)
    local structs = {}
    for fun,defs in pairs(FP.defsT) do
        local stname = defs[1].stname
        structs[stname] = structs[stname] or {}
        table.insert(structs[stname],defs)--fun)
    end
    FP.defsBystruct = structs
end  

-- function for repairing funcdefs default values
local function repair_defaults(defsT,str_and_enu)
	local function deleteOuterPars(def)
		local w = def:match("^%b()$")
		if w then
			w = w:gsub("^%((.+)%)$","%1")
			return w
		else 
			return def 
		end
	end
	local function CleanImU32(def)
		def = def:gsub("%(ImU32%)","")
		--quitar () de numeros
		def = def:gsub("%((%d+)%)","%1")
		def = deleteOuterPars(def)
		local bb=cpp2ffi.strsplit(def,"|")
		for i=1,#bb do
			local val = deleteOuterPars(bb[i])
			if val:match"<<" then
				local v1,v2 = val:match("(%d+)%s*<<%s*(%d+)")
				val = v1*2^v2
				bb[i] = val
			end
			assert(type(bb[i])=="number")
		end
		local res = 0 
		for i=1,#bb do res = res + bb[i] end 
		return res
	end
	for k,defT in pairs(defsT) do
		for i,def in ipairs(defT) do
			for k,v in pairs(def.defaults) do
				--do only if not a c string
				local is_cstring = v:sub(1,1)=='"' and v:sub(-1,-1) =='"'
				if not is_cstring then
					def.defaults[k] = def.defaults[k]:gsub("%(%(void%s*%*%)0%)","NULL")
					if def.defaults[k]:match"%(ImU32%)" then
						def.defaults[k] = tostring(CleanImU32(def.defaults[k]))
					end
				end
			end
		end
	end
end


--generate cimgui.cpp cimgui.h 
local function cimgui_generation(parser)

--[[
	-- clean ImVector:contains() for not applicable types
	local clean_f = {}
	for k,v in pairs(parser.defsT) do
		if k:match"ImVector" and k:match"contains" then
			--cpp2ffi.prtable(k,v)
			local stname = v[1].stname
			if not(stname:match"float" or stname:match"int" or stname:match"char") then
				parser.defsT[k] = nil
				--delete also from funcdefs
				for i,t in ipairs(parser.funcdefs) do
					if t.cimguiname == k then
						table.remove(parser.funcdefs, i)
						break
					end
				end
			end
		end
	end
--]]
	--------------------------------------------------
    local hstrfile = read_data"./cimgui_template.h"

	local outpre,outpost = parser.structs_and_enums[1],parser.structs_and_enums[2]
	cpp2ffi.prtable(parser.templates)
	cpp2ffi.prtable(parser.typenames)
	

	local  tdt = parser:generate_templates()
	local cstructsstr = outpre..tdt..outpost 
    
	if gdefines.IMGUI_HAS_DOCK then
		cstructsstr = cstructsstr.."\n#define IMGUI_HAS_DOCK       1\n"
	end
	if gdefines.IMGUI_HAS_IMSTR then
		cstructsstr = cstructsstr.."\n#define IMGUI_HAS_IMSTR       1\n"
	end
	
    hstrfile = hstrfile:gsub([[#include "imgui_structs%.h"]],cstructsstr)
    local cfuncsstr = func_header_generate(parser)
    hstrfile = hstrfile:gsub([[#include "auto_funcs%.h"]],cfuncsstr)
    save_data("./output/cimgui.h",cimgui_header,hstrfile)
    
    --merge it in cimgui_template.cpp to cimgui.cpp
    local cimplem = func_implementation(parser)

    local hstrfile = read_data"./cimgui_template.cpp"

    hstrfile = hstrfile:gsub([[#include "auto_funcs%.cpp"]],cimplem)
	local ftdef = FREETYPE_GENERATION and "#define IMGUI_ENABLE_FREETYPE\n" or ""
    save_data("./output/cimgui.cpp",cimgui_header, ftdef, hstrfile)

end
--------------------------------------------------------
-----------------------------do it----------------------
--------------------------------------------------------
--get imgui.h version and IMGUI_HAS_DOCK--------------------------
--defines for the cl compiler must be present in the print_defines.cpp file
gdefines = get_defines{"IMGUI_VERSION","FLT_MAX","FLT_MIN","IMGUI_HAS_DOCK","IMGUI_HAS_IMSTR"}
assert(gdefines.IMGUI_VERSION, "Failed to read IMGUI_VERSION from imgui.h.")

if gdefines.IMGUI_HAS_DOCK then gdefines.IMGUI_HAS_DOCK = true end
if gdefines.IMGUI_HAS_IMSTR then gdefines.IMGUI_HAS_IMSTR = true end

cimgui_header = cimgui_header:gsub("XXX",gdefines.IMGUI_VERSION)
if INTERNAL_GENERATION then
	cimgui_header = cimgui_header..[[//with imgui_internal.h api
]]
end
if FREETYPE_GENERATION then
	cimgui_header = cimgui_header..[[//with imgui_freetype.h api
]]
end
if gdefines.IMGUI_HAS_DOCK then
	cimgui_header = cimgui_header..[[//docking branch
]]
	
end
print("IMGUI_HAS_IMSTR",gdefines.IMGUI_HAS_IMSTR)
print("IMGUI_HAS_DOCK",gdefines.IMGUI_HAS_DOCK)
print("IMGUI_VERSION",gdefines.IMGUI_VERSION)


--funtion for parsing imgui headers
local function parseImGuiHeader(header,names)
	--prepare parser
	local parser = cpp2ffi.Parser()
	
	parser.getCname = function(stname,funcname,namespace)
		local pre = (stname == "") and (namespace and (namespace=="ImGui" and "ig" or namespace.."_") or "ig") or stname.."_"
		return pre..funcname
	end
	parser.cname_overloads = cimgui_overloads
	parser.manuals = cimgui_manuals
	parser.UDTs = {"ImVec2","ImVec4","ImColor","ImRect"}
	--parser.gen_template_typedef = gen_template_typedef --use auto
	
	local defines = parser:take_lines(CPRE..header,names,COMPILER)
	
	return parser
end
--generation
print("------------------generation with "..COMPILER.."------------------------")
local parser1
local headers = [[#include "]]..IMGUI_PATH..[[/imgui.h" 
]]
local headersT = {[[imgui]]}
if INTERNAL_GENERATION then
	headers = headers .. [[#include "]]..IMGUI_PATH..[[/imgui_internal.h"
	]]
	headersT[#headersT + 1] = [[imgui_internal]]
	headersT[#headersT + 1] = [[imstb_textedit]]
end
if FREETYPE_GENERATION then
	headers = headers .. [[
	#include "]]..IMGUI_PATH..[[/misc/freetype/imgui_freetype.h"
	]]
	headersT[#headersT + 1] = [[imgui_freetype]]
end
save_data("headers.h",headers)
local include_cmd = COMPILER=="cl" and [[ /I ]] or [[ -I ]]
local extra_includes = include_cmd.." " ..IMGUI_PATH.." "
local parser1 = parseImGuiHeader(extra_includes .. [[headers.h]],headersT)
os.remove("headers.h")
parser1:do_parse()

save_data("./output/overloads.txt",parser1.overloadstxt)
cimgui_generation(parser1)

----------save struct and enums lua table in structs_and_enums.lua for using in bindings

local structs_and_enums_table = parser1.structs_and_enums_table
structs_and_enums_table.templated_structs = parser1.templated_structs
structs_and_enums_table.typenames = parser1.typenames
structs_and_enums_table.templates_done = parser1.templates_done

save_data("./output/structs_and_enums.lua",serializeTableF(structs_and_enums_table))
save_data("./output/typedefs_dict.lua",serializeTableF(parser1.typedefs_dict))

----------save fundefs in definitions.lua for using in bindings
--DefsByStruct(pFP)
set_defines(parser1.defsT) 
repair_defaults(parser1.defsT, structs_and_enums_table)
save_data("./output/definitions.lua",serializeTableF(parser1.defsT))

--check every function has ov_cimguiname
-- for k,v in pairs(parser1.defsT) do
	-- for _,def in ipairs(v) do
		-- assert(def.ov_cimguiname)
	-- end
-- end

--=================================Now implementations
local backends_folder 
local ff,err = io.open (IMGUI_PATH .. "/examples/imgui_impl_glfw.h" ,"r")
if ff then
	backends_folder = IMGUI_PATH .. "/examples/"
	ff:close()
else
	backends_folder = IMGUI_PATH .. "/backends/"
end
 
local parser2

if #implementations > 0 then
	print("------------------implementations generation with "..COMPILER.."------------------------")
    parser2 = cpp2ffi.Parser()
	
	local config = require"config_generator"
    local impl_str = ""
    for i,impl in ipairs(implementations) do
        local source = backends_folder .. [[imgui_impl_]].. impl .. ".h "
        local locati = [[imgui_impl_]].. impl

		local define_cmd = COMPILER=="cl" and [[ /E /D]] or [[ -E -D]]
		local extra_defines = ""
		if impl == "opengl3" then extra_defines = define_cmd .. "IMGUI_IMPL_OPENGL_LOADER_GL3W " end
		local include_cmd = COMPILER=="cl" and [[ /I ]] or [[ -I ]]
		local extra_includes = include_cmd.." ".. IMGUI_PATH .." "
		if config[impl] then
			for j,inc in ipairs(config[impl]) do
				extra_includes = extra_includes .. include_cmd .. inc .. " "
			end
		end
		
		local defines = parser2:take_lines(CPRE..extra_defines..extra_includes..source, {locati}, COMPILER)
		
		local parser3 = cpp2ffi.Parser()
		parser3:take_lines(CPRE..extra_defines..extra_includes..source, {locati}, COMPILER)
		parser3:do_parse()
		local cfuncsstr = func_header_impl_generate(parser3) 
		local cstructstr1,cstructstr2 = parser3.structs_and_enums[1], parser3.structs_and_enums[2]
		impl_str = impl_str .. "#ifdef CIMGUI_USE_".. string.upper(impl).."\n" .. cstructstr1 .. cstructstr2 .. cfuncsstr .. "\n#endif\n"
    end
	
    parser2:do_parse()

    -- save ./cimgui_impl.h
    --local cfuncsstr = func_header_impl_generate(parser2) 
	--local cstructstr1,cstructstr2 = parser2.structs_and_enums[1], parser2.structs_and_enums[2]
    --save_data("./output/cimgui_impl.h",cstructstr1,cstructstr2,cfuncsstr)
	save_data("./output/cimgui_impl.h",impl_str)

    ----------save fundefs in impl_definitions.lua for using in bindings
    save_data("./output/impl_definitions.lua",serializeTableF(parser2.defsT))

end -- #implementations > 0 then

-------------------------------json saving
--avoid mixed tables (with string and integer keys)
local function json_prepare(defs)
    --delete signatures in function
    for k,def in pairs(defs) do
        for k2,v in pairs(def) do
            if type(k2)=="string" then
                def[k2] = nil
            end
        end
    end
    return defs
end
---[[
local json = require"json"
save_data("./output/definitions.json",json.encode(json_prepare(parser1.defsT),{dict_on_empty={defaults=true}}))
--delete extra info for json
structs_and_enums_table.templated_structs = nil
structs_and_enums_table.typenames = nil
structs_and_enums_table.templates_done = nil
save_data("./output/structs_and_enums.json",json.encode(structs_and_enums_table))
save_data("./output/typedefs_dict.json",json.encode(parser1.typedefs_dict))
if parser2 then
    save_data("./output/impl_definitions.json",json.encode(json_prepare(parser2.defsT),{dict_on_empty={defaults=true}}))
end
--]]
-------------------copy C files to repo root
copyfile("./output/cimgui.h", "../cimgui.h")
copyfile("./output/cimgui.cpp", "../cimgui.cpp")
os.remove("./output/cimgui.h")
os.remove("./output/cimgui.cpp")
print"all done!!"
