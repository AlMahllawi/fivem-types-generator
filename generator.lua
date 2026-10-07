--[[
Copyright (C) 2026 Mohammad AlMahllawi
SPDX-License-Identifier: GPL-3.0-or-later
]]

local isJson = false
local customResourceName = nil
local args = {}
local i = 1
while i <= #arg do
    local v = arg[i]
    if v == "--json" then
        isJson = true
    elseif v == "--name" then
        i = i + 1
        customResourceName = arg[i]
    else
        table.insert(args, v)
    end
    i = i + 1
end
local resource_dir = args[1]
local out_dir = args[2]

local jsonOutput = { success = true, warnings = {}, errors = {} }
local function escapeJsonString(str)
    return tostring(str):gsub('["\\\b\f\n\r\t]', {
        ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'
    })
end
local function printJson()
    local out = '{"success":' .. tostring(jsonOutput.success) .. ',"warnings":['
    for i, w in ipairs(jsonOutput.warnings) do
        if i > 1 then out = out .. ',' end
        out = out .. '{"file":"' .. escapeJsonString(w.file) .. '","line":' .. w.line .. ',"message":"' .. escapeJsonString(w.message) .. '"}'
    end
    out = out .. '],"errors":['
    for i, e in ipairs(jsonOutput.errors) do
        if i > 1 then out = out .. ',' end
        out = out .. '{"message":"' .. escapeJsonString(e.message) .. '"}'
    end
    out = out .. ']}'
    print(out)
end

if not resource_dir then
    if isJson then
        jsonOutput.success = false
        table.insert(jsonOutput.errors, { message = "No resource directory provided" })
        printJson()
    else
        io.stderr:write("Usage: lua-language-server generator.lua [--json] <resource_dir> [out_dir]\n")
    end
    os.exit(1)
end

local sys = require 'bee.sys'
local luals_dir = sys.exe_path():parent_path():parent_path():string()

package.path = package.path .. ";" .. luals_dir .. "/script/?.lua;" .. luals_dir .. "/script/?/init.lua"

local fs = require 'bee.filesystem'
ROOT = fs.absolute(fs.path(luals_dir))
LOGPATH = (ROOT / 'log'):string()
METAPATH = (ROOT / 'meta'):string()

require 'config.env'
local util = require 'utility'
util.enableCloseFunction()
util.enableFormatString()

_G.log = require 'log'
log.init(ROOT, fs.path(LOGPATH) / 'service.log')

local lclient   = require 'lclient'()
local furi      = require 'file-uri'
local ws        = require 'workspace'
local files     = require 'files'
local config    = require 'config.config'
local provider  = require 'provider'
local await     = require 'await'
local guide     = require 'parser.guide'
local vm        = require 'vm'

-- Definitions are written here first and only moved to the output directory on success
local stagingPathFs

local function errorhandler(err)
    if stagingPathFs and fs.exists(stagingPathFs) then
        pcall(fs.remove_all, stagingPathFs)
    end
    if isJson then
        jsonOutput.success = false
        table.insert(jsonOutput.errors, { message = tostring(err) .. "\n" .. tostring(debug.traceback()) })
        printJson()
    else
        io.stderr:write(tostring(err) .. "\n" .. tostring(debug.traceback()) .. "\n")
    end
    os.exit(1)
end

local function getResourceManifest(rootPath)
    local manifestPath = fs.path(rootPath) / 'fxmanifest.lua'
    if not fs.exists(manifestPath) then
        manifestPath = fs.path(rootPath) / '__resource.lua'
    end
    
    local collected = { exports = {}, server_exports = {}, client_exports = {}, generate_definitions = {}, copy_definitions = {} }
    if fs.exists(manifestPath) then
        local content = util.loadFile(manifestPath:string())
        if content then
            local function makeAdder(listName)
                local lastAdded = {}
                local function f(...)
                    local args = {...}
                    if #args == 1 and type(args[1]) == 'string' and #lastAdded > 0 then
                        for _, entry in ipairs(lastAdded) do
                            collected[listName][entry] = args[1]
                        end
                        lastAdded = {}
                        return f
                    end
                    lastAdded = {}
                    for _, v in ipairs(args) do
                        if type(v) == 'table' then
                            for _, entry in ipairs(v) do
                                if type(entry) == 'string' then 
                                    collected[listName][entry] = true 
                                    table.insert(lastAdded, entry)
                                end
                            end
                        elseif type(v) == 'string' then
                            collected[listName][v] = true
                            table.insert(lastAdded, v)
                        end
                    end
                    return f
                end
                return f
            end
            
            local env = setmetatable({}, {
                __index = function(t, k)
                    if k == 'export' or k == 'exports' then return makeAdder('exports')
                    elseif k == 'server_export' or k == 'server_exports' then return makeAdder('server_exports')
                    elseif k == 'client_export' or k == 'client_exports' then return makeAdder('client_exports')
                    elseif k == 'generate_definition' or k == 'generate_definitions' then return makeAdder('generate_definitions')
                    elseif k == 'copy_definition' or k == 'copy_definitions' then return makeAdder('copy_definitions')
                    end
                    local function dummy(...) return dummy end
                    return dummy
                end
            })
            local fn = load(content, "fxmanifest", "t", env)
            if fn then pcall(fn) end
        end
    end
    return collected
end

local function asDocFunction(source, uri, outLines)
    local _, _, num = vm.countReturnsOfFunction(source)
    local returns = {}
    for i = 1, num do
        local rtn = vm.getReturnOfFunction(source, i)
        local t = rtn and vm.getInfer(rtn):view(uri) or 'any'
        table.insert(returns, t)
    end
    
    local argList = {}
    if source.args then
        for i, arg in ipairs(source.args) do
            local name = arg.name and arg.name[1] or guide.getKeyName(arg) or ('arg' .. i)
            local t = vm.getInfer(arg):view(uri)
            table.insert(outLines, "---@param " .. name .. " " .. t)
            table.insert(argList, name)
        end
    end
    
    if #returns > 0 then
        if #returns == 1 then table.insert(outLines, "---@return " .. returns[1])
        else table.insert(outLines, "---@return " .. table.concat(returns, ", ")) end
    end
    
    return table.concat(argList, ", ")
end

local rootPath = fs.absolute(fs.path(resource_dir)):lexically_normal():string()
if rootPath:sub(-1) == "/" or rootPath:sub(-1) == "\\" then
    rootPath = rootPath:sub(1, -2)
end
local rootUri = furi.encode(rootPath):gsub("/$", "")

local outPathStr = out_dir
if type(outPathStr) ~= 'string' then outPathStr = rootPath .. '/definitions' end
outPathStr = fs.absolute(fs.path(outPathStr)):lexically_normal():string()
if outPathStr:sub(-1) == "/" or outPathStr:sub(-1) == "\\" then
    outPathStr = outPathStr:sub(1, -2)
end
local outPathFs = fs.path(outPathStr)

if outPathStr == rootPath then
    errorhandler("Output directory cannot be the resource directory itself.")
end
local rootPrefix = rootPath:sub(1, #outPathStr + 1)
if rootPrefix == outPathStr .. "/" or rootPrefix == outPathStr .. "\\" then
    errorhandler("Output directory cannot contain the resource directory.")
end

-- Replacing the output directory would wipe synced definitions if the two overlap
local syncConfigPath = fs.path(rootPath) / 'lua-definitions.json'
if fs.exists(syncConfigPath) then
    local content = util.loadFile(syncConfigPath:string())
    local ok, syncConfig = pcall(require('json').decode, content or "")
    if ok and type(syncConfig) == 'table' then
        -- Same default as sync.sh / sync.ps1
        local targetDir = type(syncConfig.target_dir) == 'string' and syncConfig.target_dir or './definitions_vendor'
        local syncPathStr = fs.absolute(fs.path(rootPath) / targetDir):lexically_normal():string()
        if syncPathStr:sub(-1) == "/" or syncPathStr:sub(-1) == "\\" then
            syncPathStr = syncPathStr:sub(1, -2)
        end
        local function contains(parent, child)
            local prefix = child:sub(1, #parent + 1)
            return child == parent or prefix == parent .. "/" or prefix == parent .. "\\"
        end
        if contains(outPathStr, syncPathStr) or contains(syncPathStr, outPathStr) then
            errorhandler("Output directory overlaps the sync target_dir '" .. targetDir .. "' in lua-definitions.json. Use separate folders, e.g. the default './definitions_vendor'.")
        end
    end
end

-- Stage next to the output directory so the final swap is a same-filesystem rename
local stagingPrefix = '.' .. outPathFs:filename():string() .. '.tmp-'
math.randomseed(os.time())
stagingPathFs = outPathFs:parent_path() / string.format('%s%d-%d', stagingPrefix, os.time(), math.random(100000, 999999))

-- Clean up staging directories left behind by interrupted runs
if fs.exists(outPathFs:parent_path()) then
    for entry in fs.pairs(outPathFs:parent_path()) do
        if entry:filename():string():sub(1, #stagingPrefix) == stagingPrefix then
            pcall(fs.remove_all, entry)
        end
    end
end

if not isJson then
    print("Generating FiveM lua definitions for: " .. rootPath)
    print("Output directory: " .. outPathStr)
end

local manifest = getResourceManifest(rootPath)

local success = xpcall(lclient.start, errorhandler, lclient, function (client)
    await.disable()
    client:registerFakers()
    client:initialize { rootUri = rootUri }
    
    config.set(nil, 'Lua.diagnostics.enable', false)
    
    local nonstandard = config.get(rootUri, 'Lua.runtime.nonstandardSymbol')
    local requiredSymbols = {
        "++", "+=", "-=", "*=", "/=", "//=", "%=", "<<=", ">>=", "&=", "|=", "^=", "`", "!!"
    }
    if type(nonstandard) == 'table' then
        for _, sym in ipairs(requiredSymbols) do
            local found = false
            for _, v in ipairs(nonstandard) do
                if v == sym then found = true; break end
            end
            if not found then table.insert(nonstandard, sym) end
        end
    else
        config.set(rootUri, 'Lua.runtime.nonstandardSymbol', requiredSymbols)
    end
    
    if not config.get(rootUri, 'Lua.runtime.version') then
        config.set(rootUri, 'Lua.runtime.version', 'Lua 5.4')
    end

    provider.updateConfig(rootUri)
    
    local ignores = config.get(rootUri, 'Lua.workspace.ignoreDir')
    local defaultIgnores = { '.git', '.svn', '.idea', '.vscode', '.vs', '*~', 'node_modules' }
    
    if type(ignores) == 'table' then
        if outPathStr:sub(1, #rootPath) == rootPath then
            local rel = outPathStr:sub(#rootPath + 2)
            if rel ~= "" then ignores[#ignores + 1] = rel end
        end
    else
        local newIgnores = {}
        for _, v in ipairs(defaultIgnores) do table.insert(newIgnores, v) end
        if outPathStr:sub(1, #rootPath) == rootPath then
            local rel = outPathStr:sub(#rootPath + 2)
            if rel ~= "" then table.insert(newIgnores, rel) end
        end
        config.set(rootUri, 'Lua.workspace.ignoreDir', newIgnores)
    end
    
    local timer = require 'timer'
    local keepAlive = timer.loop(1, function()
        if client and type(client) == 'table' and client.tick then
            client.tick = 0
        end
    end)
    
    ws.awaitReady(rootUri)
    
    if keepAlive then keepAlive:remove() end
    
    local resourceName = customResourceName or fs.path(rootPath):filename():string()
    local unresolved = {}
    local exportLines = {
        "---@meta",
        "",
        "exports = exports or {}",
        "local Exports = {}",
        ""
    }    
    local shareableFiles = {}
    local shareableOutput = {}
    local addedExports = {}
    
    local glob = require 'glob'
    local generateMatchers = {}
    for p, outPath in pairs(manifest.generate_definitions) do
        table.insert(generateMatchers, { matcher = glob.glob(p), outPath = outPath })
    end
    
    local copyMatchers = {}
    for p, outPath in pairs(manifest.copy_definitions) do
        table.insert(copyMatchers, { matcher = glob.glob(p), outPath = outPath })
    end
    
    for _, uri in ipairs(files.getChildFiles(rootUri)) do
        if files.isLibrary(uri) then goto continue end
        local fpath = furi.decode(uri)
        if fpath:sub(1, #outPathStr) == outPathStr then goto continue end
        
        local relPath = fpath:sub(#rootPath + 2):gsub('\\', '/')
        
        local matchedCopy = false
        local copyOutPath = true
        for _, m in ipairs(copyMatchers) do
            if m.matcher(relPath) then
                matchedCopy = true
                if type(m.outPath) == 'string' then copyOutPath = m.outPath end
            end
        end
        
        if matchedCopy then
            local destPath
            if type(copyOutPath) == 'string' then
                destPath = stagingPathFs / copyOutPath
            else
                destPath = stagingPathFs / relPath
            end
            
            local pStr = destPath:string()
            if not shareableOutput[pStr] then shareableOutput[pStr] = {} end
            
            local content = util.loadFile(fpath)
            if content then table.insert(shareableOutput[pStr], content) end
        end
        
        local state = files.getState(uri)
        if not state or not state.ast then goto continue end
        
        local fileLines = {}
        for line in state.lua:gmatch("([^\r\n]*)\r?\n?") do
            table.insert(fileLines, line)
        end
        
        local matched = false
        local matchOutPath = true
        for _, m in ipairs(generateMatchers) do
            if m.matcher(relPath) then
                matched = true
                if type(m.outPath) == 'string' then matchOutPath = m.outPath end
            end
        end
        if matched then shareableFiles[uri] = matchOutPath end
        
        guide.eachSourceType(state.ast, 'call', function(node)
            local callee = node.node
            if callee.type == 'getglobal' and callee[1] == 'exports' then
                if node.args and node.args[1] then
                    local nameNode = node.args[1]
                    if nameNode.type == 'string' then
                        local name = nameNode[1]
                        if addedExports[name] then return end
                        addedExports[name] = true
                        
                        local foundFunc = false
                        if node.args[2] then
                            local defs = vm.getDefs(node.args[2])
                            for _, def in ipairs(defs) do
                                local funcNode = def
                                if def.type == 'setlocal' or def.type == 'local' or def.type == 'setglobal' then
                                    funcNode = def.value
                                end
                                if funcNode and (funcNode.type == 'function' or funcNode.type == 'doc.type.function') then
                                    local lines = {}
                                    local argStr = asDocFunction(funcNode, uri, lines)
                                    for _, l in ipairs(lines) do table.insert(exportLines, l) end
                                    table.insert(exportLines, "function Exports:" .. name .. "(" .. argStr .. ") end\n")
                                    foundFunc = true
                                    break
                                end
                            end
                        end
                        if not foundFunc then table.insert(exportLines, "function Exports:" .. name .. "(...) end\n") end
                    else
                        if nameNode.type ~= 'table' then
                            local row = guide.rowColOf(nameNode.start)
                            local prevLine = fileLines[row]
                            if not (prevLine and prevLine:find("---@definitions-generator-ignore", 1, true)) then
                                table.insert(unresolved, {uri = uri, line = row})
                            end
                        end
                    end
                end
            end
        end)
        
        guide.eachSourceType(state.ast, 'setglobal', function(node)
            local name = node[1]
            if manifest.exports[name] or manifest.server_exports[name] or manifest.client_exports[name] then
                if addedExports[name] then return end
                addedExports[name] = true
                local val = node.value
                if val and (val.type == 'function' or val.type == 'doc.type.function') then
                    local lines = {}
                    local argStr = asDocFunction(val, uri, lines)
                    for _, l in ipairs(lines) do table.insert(exportLines, l) end
                    table.insert(exportLines, "function Exports:" .. name .. "(" .. argStr .. ") end\n")
                else
                    table.insert(exportLines, "function Exports:" .. name .. "(...) end\n")
                end
            end
        end)
        
        ::continue::
    end
    
    if resourceName:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
        table.insert(exportLines, "exports." .. resourceName .. " = Exports")
    else
        table.insert(exportLines, string.format('exports[%q] = Exports', resourceName))
    end
    local function writeOutput(pStr, content)
        fs.create_directories(fs.path(pStr):parent_path())
        local ok, err = util.saveFile(pStr, content)
        if not ok then
            error("Failed to write " .. pStr .. ": " .. tostring(err))
        end
    end

    local exportsPath = stagingPathFs / 'exports.d.lua'
    writeOutput(exportsPath:string(), table.concat(exportLines, "\n") .. "\n")
    
    for uri, customOutPath in pairs(shareableFiles) do
        local state = files.getState(uri)
        if state and state.ast then
            local fileLines = {}
            for line in state.lua:gmatch("([^\r\n]*)\r?\n?") do
                table.insert(fileLines, line)
            end
            
            local function extractDocGroup(node)
                local minRow, maxRow = math.huge, -1
                if node.bindGroup then
                    for _, doc in ipairs(node.bindGroup) do
                        local startRow = guide.rowColOf(doc.start)
                        local finishRow = guide.rowColOf(doc.finish)
                        if startRow < minRow then minRow = startRow end
                        if finishRow > maxRow then maxRow = finishRow end
                    end
                else
                    minRow = guide.rowColOf(node.start)
                    maxRow = guide.rowColOf(node.finish)
                end
                
                if node.type == 'doc.enum' and node.bindSource and node.bindSource.type == 'table' then
                    local bStartRow = guide.rowColOf(node.bindSource.start)
                    local bFinishRow = guide.rowColOf(node.bindSource.finish)
                    if bStartRow < minRow then minRow = bStartRow end
                    if bFinishRow > maxRow then maxRow = bFinishRow end
                end
                
                local out = {}
                for i = minRow, maxRow do table.insert(out, fileLines[i + 1]) end
                return table.concat(out, "\n")
            end
            
            local function extractDocsFromNode(node)
                local docs = node.bindDocs or (node.value and node.value.bindDocs)
                if not docs then return "" end
                local minRow, maxRow = math.huge, -1
                local function checkDoc(d)
                    local startRow = guide.rowColOf(d.start)
                    local finishRow = guide.rowColOf(d.finish)
                    if startRow < minRow then minRow = startRow end
                    if finishRow > maxRow then maxRow = finishRow end
                    if d.bindGroup then
                        for _, bgDoc in ipairs(d.bindGroup) do
                            local r1 = guide.rowColOf(bgDoc.start)
                            local r2 = guide.rowColOf(bgDoc.finish)
                            if r1 < minRow then minRow = r1 end
                            if r2 > maxRow then maxRow = r2 end
                        end
                    end
                end
                for _, doc in ipairs(docs) do checkDoc(doc) end
                if minRow > maxRow then return "" end
                local out = {}
                for i = minRow, maxRow do table.insert(out, fileLines[i + 1]) end
                return table.concat(out, "\n")
            end
            
            local lines = { "---@meta", "" }
            
            for _, typ in ipairs({'doc.class', 'doc.alias', 'doc.enum'}) do
                guide.eachSourceType(state.ast, typ, function(node)
                    if node.bindSource and node.bindSource.type == 'setglobal' then return end
                    table.insert(lines, extractDocGroup(node))
                end)
            end
            
            guide.eachSourceType(state.ast, 'setglobal', function(node)
                local name = node[1]
                local docsStr = extractDocsFromNode(node)
                if docsStr ~= "" then table.insert(lines, docsStr) end
                
                local val = node.value
                if val and (val.type == 'function' or val.type == 'doc.type.function') then
                    local argStr = "..."
                    if docsStr == "" then
                        local tempLines = {}
                        argStr = asDocFunction(val, uri, tempLines)
                        for _, l in ipairs(tempLines) do table.insert(lines, l) end
                    else
                        local tempLines = {}
                        argStr = asDocFunction(val, uri, tempLines)
                    end
                    table.insert(lines, "function " .. name .. "(" .. argStr .. ") end\n")
                else
                    if docsStr == "" then
                        local t = vm.getInfer(node):view(uri)
                        if t ~= 'any' then table.insert(lines, "---@type " .. t) end
                    end
                    table.insert(lines, name .. " = nil\n")
                end
            end)
            
            local outPath
            if type(customOutPath) == 'string' then
                outPath = stagingPathFs / customOutPath
            else
                local relPath = furi.decode(uri):sub(#rootPath + 2):gsub('\\', '/')
                local dName = relPath:gsub("%.lua$", ".d.lua")
                outPath = stagingPathFs / dName
            end
            
            local pStr = outPath:string()
            if not shareableOutput[pStr] then
                shareableOutput[pStr] = {}
            end
            
            if #shareableOutput[pStr] == 0 then
                table.insert(shareableOutput[pStr], table.concat(lines, "\n"))
            else
                local toAdd = {}
                local skipMeta = true
                for i, l in ipairs(lines) do
                    if skipMeta and i <= 2 and (l == "---@meta" or l == "") then
                        -- skip
                    else
                        skipMeta = false
                        table.insert(toAdd, l)
                    end
                end
                if #toAdd > 0 then
                    table.insert(shareableOutput[pStr], table.concat(toAdd, "\n"))
                end
            end
        end
    end

    for pStr, contents in pairs(shareableOutput) do
        writeOutput(pStr, table.concat(contents, "\n\n") .. "\n")
    end

    -- Everything generated, so swap the staged output in for the previous one
    if fs.exists(outPathFs) then
        local ok, err = pcall(fs.remove_all, outPathFs)
        if not ok then
            error("Failed to clear output directory: " .. tostring(err))
        end
    end
    fs.create_directories(outPathFs:parent_path())
    local ok, err = pcall(fs.rename, stagingPathFs, outPathFs)
    if not ok then
        error("Failed to move generated definitions into place: " .. tostring(err))
    end
    
    if #unresolved > 0 then
        if isJson then
            for _, u in ipairs(unresolved) do
                table.insert(jsonOutput.warnings, { file = furi.decode(u.uri), line = u.line + 1, message = "Could not resolve dynamic export name" })
            end
        else
            io.stderr:write("WARNING: Could not resolve the following dynamic export names:\n")
            for _, u in ipairs(unresolved) do io.stderr:write("  - " .. furi.decode(u.uri) .. " at line " .. (u.line + 1) .. "\n") end
            io.stderr:write("  (Use `---@definitions-generator-ignore` on the preceding line to suppress this warning)\n")
        end
    end
    
    local hasParseErrs = false
    for _, uri in ipairs(files.getChildFiles(rootUri)) do
        if files.isLibrary(uri) then goto chkcontinue end
        local state = files.getState(uri)
        if state and state.errs and #state.errs > 0 then
            if isJson then
                table.insert(jsonOutput.warnings, { file = furi.decode(uri), line = 0, message = "Parse errors occurred (" .. #state.errs .. " errors)" })
            else
                if not hasParseErrs then
                    io.stderr:write("WARNING: Parse errors occurred:\n")
                    hasParseErrs = true
                end
                io.stderr:write("  - " .. furi.decode(uri) .. " (" .. #state.errs .. " errors)\n")
            end
        end
        ::chkcontinue::
    end
    
    if isJson then printJson() end
    os.exit(0, true)
end)

if not success then os.exit(1, true) end
