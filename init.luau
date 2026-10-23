local Instrument = (function()
local Instrument = {}
local keywords = {}
for word in string.gmatch("and break continue do else elseif end false for function if in local nil not or repeat return then true until while", "%S+") do keywords[word] = true end

local function tokens(source)
    local result, index, length = {}, 1, #source
    local function longEnd(at)
        if string.sub(source, at, at) ~= "[" then return nil end
        local cursor = at + 1
        while string.sub(source, cursor, cursor) == "=" do cursor += 1 end
        if string.sub(source, cursor, cursor) ~= "[" then return nil end
        local equals = string.rep("=", cursor - at - 1)
        local _, finish = string.find(source, "]" .. equals .. "]", cursor + 1, true)
        assert(finish, "Unterminated long string/comment")
        return finish + 1
    end
    while index <= length do
        local first, char = index, string.sub(source, index, index)
        if string.match(char, "%s") then index += 1
        elseif string.sub(source, index, index + 1) == "--" then
            local finish = longEnd(index + 2)
            index = finish or (string.find(source, "\n", index + 2, true) or length + 1)
        elseif char == "'" or char == '"' or char == "`" then
            index += 1
            while index <= length do
                local current = string.sub(source, index, index)
                if current == "\\" then index += 2
                elseif current == char then index += 1; break
                else index += 1 end
            end
            table.insert(result, {value = string.sub(source, first, index - 1), first = first, after = index, kind = "string"})
        elseif char == "[" and longEnd(index) then
            index = longEnd(index)
            table.insert(result, {value = string.sub(source, first, index - 1), first = first, after = index, kind = "string"})
        elseif string.match(char, "[%a_]") then
            index += 1
            while index <= length and string.match(string.sub(source, index, index), "[%w_]") do index += 1 end
            table.insert(result, {value = string.sub(source, first, index - 1), first = first, after = index, kind = "name"})
        else
            index += 1
            table.insert(result, {value = char, first = first, after = index, kind = "symbol"})
        end
    end
    return result
end

function Instrument.Transform(source)
    assert(type(source) == "string", "Port source must be text")
    local list, pairsAt, stack, edits = tokens(source), {}, {}, {}
    for index, token in ipairs(list) do
        if token.kind ~= "string" then
            if token.value == "(" or token.value == "[" or token.value == "{" then table.insert(stack, index)
            elseif token.value == ")" or token.value == "]" or token.value == "}" then
                local start = table.remove(stack)
                assert(start, "Unbalanced source delimiters")
                pairsAt[index], pairsAt[start] = start, index
            end
        end
    end
    local prefixStart
    local function canEnd(token)
        return token and ((token.kind == "name" and not keywords[token.value]) or token.value == ")" or token.value == "]")
    end
    prefixStart = function(index)
        local token = list[index]
        if not token then return nil end
        local start
        if token.value == ")" or token.value == "]" then
            start = pairsAt[index]
            if not start then return nil end
            if canEnd(list[start - 1]) then start = prefixStart(start - 1) or start end
        elseif token.kind == "name" and not keywords[token.value] then start = index
        else return nil end
        local previous = list[start - 1]
        if previous and (previous.value == "." or previous.value == ":") then start = prefixStart(start - 2) or start end
        return start
    end
    local function edit(first, after, replacement, priority)
        table.insert(edits, {first = first, after = after, replacement = replacement, priority = priority or 0})
    end
    local methods = {
        Connect = "Connect", connect = "Connect", Once = "Once", Clone = "Clone", Destroy = "Remove", destroy = "Remove", Remove = "Remove", remove = "Remove",
        WaitForChild = "WaitForChild", GetService = "GetService", HttpGet = "HttpGet", HttpGetAsync = "HttpGet", GetObjects = "GetObjects",
        BindToRenderStep = "BindToRenderStep", UnbindFromRenderStep = "UnbindFromRenderStep",
        BindAction = "BindAction", BindActionAtPriority = "BindActionAtPriority", BindCoreAction = "BindCoreAction", BindCoreActionAtPriority = "BindCoreActionAtPriority",
        UnbindAction = "UnbindAction", UnbindCoreAction = "UnbindCoreAction", SetCoreGuiEnabled = "SetCoreGuiEnabled",
    }
    for index, token in ipairs(list) do
        if token.value == ":" and list[index + 1] and list[index + 2] and list[index + 2].value == "(" then
            local method, opening = methods[list[index + 1].value], index + 2
            local start, finish = prefixStart(index - 1), pairsAt[opening]
            local backendCall = start == index - 1 and list[start] and list[start].value == "__BP"
            if method and start and finish and not backendCall and not (list[start - 1] and list[start - 1].value == "function") then
                edit(list[start].first, list[start].first, "__BP:" .. method .. "(", -100 - (list[finish].after - list[start].first))
                local empty = finish == opening + 1
                edit(token.first, list[opening].after, empty and "" or ", ")
            end
        elseif token.value == "Instance" and list[index + 1] and list[index + 1].value == "." and list[index + 2] and list[index + 2].value == "new" and list[index + 3] and list[index + 3].value == "(" then
            local finish = pairsAt[index + 3]
            if finish and not (list[index - 1] and list[index - 1].value == "function") then
                edit(token.first, token.first, "__BP:Own(", 10)
                edit(list[finish].after, list[finish].after, ")", -10)
            end
        end
    end
    table.sort(edits, function(a, b)
        if a.first ~= b.first then return a.first < b.first end
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.after < b.after
    end)
    local output, cursor = {}, 1
    for _, change in ipairs(edits) do
        assert(change.first >= cursor, "Overlapping source instrumentation")
        table.insert(output, string.sub(source, cursor, change.first - 1))
        table.insert(output, change.replacement)
        cursor = change.after
    end
    table.insert(output, string.sub(source, cursor))
    return table.concat(output), #edits
end

return Instrument

end)()
local Backend = (function()
-- Backend for the original Bloxy Paradox ports. No substitute GUI is built here.
local Backend = {}
local Scope = {}
Scope.__index = Scope

function Scope.new(controller, id)
    return setmetatable({controller = controller, id = id, alive = true, resources = {}, owned = {}, connections = {}, threads = {}, connectionCount = 0, patches = {}, modules = {}, actions = {}, bindings = {}, children = {}}, Scope)
end
function Scope:Fork(key)
    if self.children[key] then self.children[key]:Destroy() end
    local child = self.controller:NewScope(self.id)
    self.children[key] = child
    if not self.alive then child:Destroy() end
    return child
end
function Scope:Drop(key)
    if self.children[key] then self.children[key]:Destroy(); self.children[key] = nil end
end
function Scope:Add(callback)
    if self.alive then table.insert(self.resources, callback) else pcall(callback) end
end
function Scope:Own(object)
    if self.owned[object] then return object end
    if not self.alive then object:Destroy(); return object end
    local previous = self.controller.owners[object]
    if previous and previous ~= self then previous.owned[object] = nil end
    self.controller.owners[object] = self
    self.owned[object] = true
    return object
end
function Scope:Clone(object)
    local copy = object:Clone()
    if copy and (self.controller.host.environment.typeof or typeof)(copy) == "Instance" then
        self:Own(copy)
        for _, descendant in ipairs(copy:GetDescendants()) do self:Own(descendant) end
    end
    return copy
end
function Scope:Patch(object, property, value)
    if not self.alive then return end
    if self.owned[object] then object[property] = value; return end
    local record = self.patches[object]
    if not record then record = {}; self.patches[object] = record end
    if not record[property] then record[property] = {old = object[property]} end
    object[property] = value
    record[property].last = value
end
function Scope:Remove(object)
    if getmetatable(object) == Scope then object:Destroy(); return end
    local kind = self.controller.host.environment.typeof or typeof or type
    if kind(object) ~= "Instance" then
        local destroy = object.Destroy or object.Remove or object.remove
        assert(type(destroy) == "function", "Object has no removal method")
        return destroy(object)
    end
    if self.owned[object] then
        self.owned[object] = nil
        self.controller.owners[object] = nil
        for _, descendant in ipairs(object:GetDescendants()) do self.owned[descendant] = nil; self.controller.owners[descendant] = nil end
        object:Destroy(); return
    end
    -- Legacy ports may remove native UI; retain it for restoration on unload.
    if object:IsA("CoreScript") then return end
    self:Patch(object, "Parent", nil)
end
function Scope:Fail(problem)
    if not self.alive then return end
    self.controller.failed[self.id] = tostring(problem)
    self.controller:Report(self.id, "Error", tostring(problem))
    if self.id == "wizard" then return end
    local active = self.controller.active[self.id]
    if active and active.scope ~= self then active.scope:Destroy() else self:Destroy() end
    self.controller:RefreshInterop()
end
function Scope:Guard(callback)
    return function(...)
        if not self.alive then return end
        local result = table.pack(xpcall(callback, debug.traceback, ...))
        if not result[1] then self:Fail(result[2]); return end
        return table.unpack(result, 2, result.n)
    end
end
function Scope:Connect(signal, callback, ...)
    if getmetatable(signal) == Scope then return signal:Connect(callback, ...) end
    assert(self.alive, "Port has been unloaded")
    local connection = signal:Connect(self:Guard(callback))
    if connection == nil then return nil end
    self.connections[connection] = true
    self.connectionCount += 1
    if self.connectionCount % 128 == 0 then
        for previous in pairs(self.connections) do
            local ok, connected = pcall(function() return previous.Connected end)
            if ok and connected == false then self.connections[previous] = nil end
        end
    end
    return connection
end
function Scope:Once(signal, callback, ...)
    if getmetatable(signal) == Scope then return signal:Once(callback, ...) end
    local connection
    connection = self:Connect(signal, function(...) connection:Disconnect(); callback(...) end)
    return connection
end
function Scope:WaitForChild(parent, name, timeout, ...)
    if getmetatable(parent) == Scope then return parent:WaitForChild(name, timeout, ...) end
    assert(self.alive, "Port has been unloaded")
    local result = parent:FindFirstChild(name) or parent:WaitForChild(name, timeout or 12)
    assert(self.alive, "Port was unloaded while waiting for " .. name)
    assert(result, self.id .. ": missing " .. name .. " below " .. parent:GetFullName())
    return result
end
function Scope:GetService(receiver, name)
    if receiver ~= self.controller.host.game then return receiver:GetService(name) end
    return self.controller:GetService(name)
end
function Scope:HttpGet(_, url)
    assert(self.alive, "Port has been unloaded")
    return self.controller:GetSource(url)
end
function Scope:GetObjects(receiver, url)
    local objects = receiver:GetObjects(url)
    for _, object in ipairs(objects) do
        self:Own(object)
        for _, descendant in ipairs(object:GetDescendants()) do self:Own(descendant) end
    end
    assert(self.alive, "Port was unloaded while loading an asset")
    return objects
end
function Scope:Spawn(mode, callback, ...)
    assert(self.alive, "Port has been unloaded")
    local arguments = table.pack(...)
    local hostTask, thread = self.controller.host.task, nil
    local guarded = self:Guard(function()
        if type(callback) == "thread" then
            local ok, problem = coroutine.resume(callback, table.unpack(arguments, 1, arguments.n))
            assert(ok, problem)
        else callback(table.unpack(arguments, 1, arguments.n)) end
    end)
    local wrapped = function()
        local result = table.pack(guarded())
        self.threads[coroutine.running()] = nil
        return table.unpack(result, 1, result.n)
    end
    if mode == "delay" then
        local duration = arguments[1]
        arguments = table.pack(table.unpack(arguments, 2, arguments.n))
        thread = hostTask.delay(duration, wrapped)
    else thread = hostTask[mode](wrapped) end
    if coroutine.status(thread) ~= "dead" then self.threads[thread] = true end
    return thread
end
function Scope:BindToRenderStep(service, name, priority, callback)
    local key = "BloxyParadox/" .. self.id .. "/" .. name
    self.bindings[name] = key
    service:BindToRenderStep(key, priority, self:Guard(callback))
    self:Add(function() service:UnbindFromRenderStep(key) end)
end
function Scope:UnbindFromRenderStep(service, name) service:UnbindFromRenderStep(self.bindings[name] or name) end
local function bindAction(self, service, method, name, callback, ...)
    local key = "BloxyParadox/" .. self.id .. "/" .. name
    local unbind = string.find(method, "Core", 1, true) and "UnbindCoreAction" or "UnbindAction"
    self.actions[name] = key
    service[method](service, key, self:Guard(function(_, ...) return callback(name, ...) end), ...)
    self:Add(function() service[unbind](service, key) end)
end
function Scope:BindAction(service, ...) return bindAction(self, service, "BindAction", ...) end
function Scope:BindActionAtPriority(service, ...) return bindAction(self, service, "BindActionAtPriority", ...) end
function Scope:BindCoreAction(service, ...) return bindAction(self, service, "BindCoreAction", ...) end
function Scope:BindCoreActionAtPriority(service, ...) return bindAction(self, service, "BindCoreActionAtPriority", ...) end
function Scope:UnbindAction(service, name) service:UnbindAction(self.actions[name] or name) end
function Scope:UnbindCoreAction(service, name) service:UnbindCoreAction(self.actions[name] or name) end
function Scope:SetCoreGuiEnabled(service, kind, enabled)
    if kind.Name == "All" then
        for _, item in ipairs(Enum.CoreGuiType:GetEnumItems()) do if item.Name ~= "All" then self:SetCoreGuiEnabled(service, item, enabled) end end
        return
    end
    self.controller:SetCoreGuiRequest(self, service, kind, enabled)
end
function Scope:FindPath(root, paths)
    for _, path in ipairs(paths) do
        local cursor = root
        for _, name in ipairs(path) do cursor = cursor and cursor:FindFirstChild(name) end
        if cursor then return cursor end
    end
end
function Scope:Hide(object)
    if not object then return end
    if object:IsA("LayerCollector") then self:Patch(object, "Enabled", false)
    elseif object:IsA("GuiObject") then self:Patch(object, "Visible", false) end
end
function Scope:HideNativeMenu()
    local core = self.controller:GetService("CoreGui")
    self:Hide(self:FindPath(core, {{"RobloxGui", "SettingsClippingShield"}}))
end
function Scope:HideModernTopbar()
    local core = self.controller:GetService("CoreGui")
    local function apply(object)
        if object.Name == "TopBarApp" and not self.owned[object] and object.Parent == core then self:Hide(object) end
    end
    for _, object in ipairs(core:GetChildren()) do apply(object) end
    self:Connect(core.ChildAdded, apply)
end
function Scope:Run(source, name, environment)
    local fn, problem = self:Compile(source, name, environment)
    assert(fn, problem)
    return fn()
end
function Scope:Compile(source, name, environment)
    if self.controller.patchModule then source = self.controller.patchModule(source, self) end
    local ok, transformed = pcall(self.controller.instrument.Transform, source)
    if not ok then return nil, tostring(transformed) end
    local fn, problem = self.controller.host.loadstring(transformed, name or ("@BloxyParadox/" .. self.id))
    if not fn then return nil, problem end
    self.controller.host.setfenv(fn, environment or self.environment)
    return fn
end
function Scope:Destroy()
    if not self.alive then return end
    self.alive = false
    for key, child in pairs(self.children) do self.children[key] = nil; child:Destroy() end
    for connection in pairs(self.connections) do pcall(function() connection:Disconnect() end) end
    table.clear(self.connections)
    for thread in pairs(self.threads) do
        if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then pcall(self.controller.host.task.cancel, thread) end
    end
    table.clear(self.threads)
    for index = #self.resources, 1, -1 do pcall(self.resources[index]) end
    table.clear(self.resources)
    self.controller:ReleaseCoreGuiRequests(self)
    -- Detach borrowed native objects before destroying any of our GUI roots.
    for object, properties in pairs(self.patches) do
        local record = properties.Parent
        if record then pcall(function() if object.Parent == record.last then object.Parent = record.old end end) end
    end
    for object, properties in pairs(self.patches) do
        for property, record in pairs(properties) do
            if property ~= "Parent" then pcall(function() if object[property] == record.last then object[property] = record.old end end) end
        end
    end
    for object in pairs(self.owned) do
        if self.controller.owners[object] == self then self.controller.owners[object] = nil; pcall(function() object:Destroy() end) end
    end
    table.clear(self.patches)
    table.clear(self.owned)
end

local Controller = {}
Controller.__index = Controller
local function coreGuiValue(record)
    local selected, priority, sequence = record.base, -1, -1
    for scope, request in pairs(record.requests) do
        local rank = ((record.kind.Name == "Backpack" and scope.id == "backpack") or (record.kind.Name == "EmotesMenu" and scope.id == "emotes") or (record.kind.Name == "Chat" and scope.id == "topbar")) and 2 or 1
        if rank > priority or (rank == priority and request.sequence > sequence) then selected, priority, sequence = request.value, rank, request.sequence end
    end
    return selected
end
function Controller:SetCoreGuiRequest(scope, service, kind, enabled)
    local record = self.coreGui[kind]
    if not record then record = {base = service:GetCoreGuiEnabled(kind), service = service, kind = kind, requests = {}}; self.coreGui[kind] = record end
    self.coreSequence += 1
    record.requests[scope] = {value = enabled, sequence = self.coreSequence}
    local desired = coreGuiValue(record)
    service:SetCoreGuiEnabled(kind, desired)
    record.last = desired
end
function Controller:ReleaseCoreGuiRequests(scope)
    for kind, record in pairs(self.coreGui) do
        if record.requests[scope] then
            record.requests[scope] = nil
            pcall(function()
                if record.service:GetCoreGuiEnabled(kind) == record.last then
                    record.last = coreGuiValue(record)
                    record.service:SetCoreGuiEnabled(kind, record.last)
                end
            end)
            if next(record.requests) == nil then self.coreGui[kind] = nil end
        end
    end
end
function Controller:RefreshInterop()
    local topbar, backpack = self.active.topbar, self.active.backpack
    local gui = topbar and topbar.scope.alive and topbar.scope.environment.LegacyGui
    if gui then
        local starter = self:GetService("StarterGui")
        local record = self.coreGui[Enum.CoreGuiType.Backpack]
        local baseline = if record then record.base else starter:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
        gui:SetAttribute("BackpackEnabled", baseline and not (backpack and backpack.scope.alive))
    end
end
function Controller:GetService(name)
    if not self.services[name] then self.services[name] = self.host.game:GetService(name) end
    return self.services[name]
end
function Controller:Report(id, state, message)
    self.status[id] = {state = state, message = tostring(message)}
    table.insert(self.log, id .. " | " .. state .. " | " .. tostring(message))
    if #self.log > 80 then table.remove(self.log, 1) end
    if state == "Error" then self.host.warn("[Bloxy Paradox / " .. id .. "] " .. tostring(message)) end
    if self.onStatus then self.onStatus(id, state, tostring(message)) end
end
function Controller:GetSource(url)
    local canonical = self.aliases[url] or url
    if self.sources[canonical] then return self.sources[canonical] end
    local cachedScript = self.scriptUrls[url] or self.scriptUrls[canonical] or string.match(canonical,"%.lua[u]?$")
    if cachedScript and self.httpCache[canonical] then return self.httpCache[canonical] end
    local body = self.host.game:HttpGet(canonical)
    assert(type(body) == "string" and #body > 0, "Empty response: " .. canonical)
    assert(not string.match(string.lower(body), "^%s*<!doctype") and not string.match(string.lower(body), "^%s*<html"), "Expected source, received HTML: " .. canonical)
    if self.sourcePatches[canonical] then body = self.sourcePatches[canonical](body) end
    if cachedScript then self.httpCache[canonical] = body end
    return body
end
function Controller:NewScope(id)
    local scope = Scope.new(self, id)
    local host = self.host
    local environment = setmetatable({__BP = scope}, {__index = host.environment})
    scope.environment = environment
    environment.getgenv = function() return environment end
    environment._G = environment
    environment.Instance = setmetatable({new = function(...) return scope:Own(host.environment.Instance.new(...)) end}, {__index = host.environment.Instance})
    environment.loadstring = function(source, name) return scope:Compile(source, name) end
    environment.task = table.clone(host.task)
    environment.task.spawn = function(callback, ...) return scope:Spawn("spawn", callback, ...) end
    environment.task.defer = function(callback, ...) return scope:Spawn("defer", callback, ...) end
    environment.task.delay = function(duration, callback, ...) return scope:Spawn("delay", callback, duration, ...) end
    environment.task.cancel = function(thread)
        host.task.cancel(thread)
        scope.threads[thread] = nil
    end
    environment.task.wait = function(duration)
        assert(scope.alive, "Port has been unloaded")
        local elapsed = host.task.wait(duration)
        assert(scope.alive, "Port has been unloaded")
        return elapsed
    end
    environment.wait = function(duration)
        assert(scope.alive, "Port has been unloaded")
        if host.environment.wait then
            local values = table.pack(host.environment.wait(duration))
            assert(scope.alive, "Port has been unloaded")
            return table.unpack(values, 1, values.n)
        end
        return environment.task.wait(duration), os.clock()
    end
    environment.spawn, environment.delay = environment.task.spawn, environment.task.delay
    environment.cloneref = host.environment.cloneref or function(object) return object end
    environment.gethui = function()
        if host.environment.gethui then
            local ok, parent = pcall(host.environment.gethui)
            if ok and parent then return parent end
        end
        local core = self:GetService("CoreGui")
        local ok = pcall(function() return core:GetChildren() end)
        return ok and core or self:GetService("Players").LocalPlayer:WaitForChild("PlayerGui", 12)
    end
    return scope
end
function Controller:Preflight(descriptor)
    for _, name in ipairs(descriptor.requires or {}) do assert(type(self.host.environment[name]) == "function", descriptor.title .. " needs " .. name) end
    if descriptor.models then
        assert(type(self.host.environment.getcustomasset or self.host.environment.getsynasset) == "function", descriptor.title .. " needs getcustomasset or getsynasset")
        for _, name in ipairs({"isfile", "isfolder", "readfile", "writefile", "makefolder"}) do assert(type(self.host.environment[name]) == "function", descriptor.title .. " needs " .. name .. " for its original model loader") end
    end
    if descriptor.rig then
        local player = self:GetService("Players").LocalPlayer
        local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
        assert(not humanoid or humanoid.RigType.Name == descriptor.rig, descriptor.title .. " needs " .. descriptor.rig)
    end
    for _, url in ipairs(descriptor.dependencies or {}) do
        self.scriptUrls[url] = true
        local body = self:GetSource(url)
        local transformed = self.instrument.Transform(body)
        local fn, problem = self.host.loadstring(transformed, "@BloxyParadox/dependency")
        assert(fn, problem)
    end
    local source = self.portSources[descriptor.source]
    assert(source, "Missing original port: " .. descriptor.source)
    local transformed = self.instrument.Transform(source)
    local fn, problem = self.host.loadstring(transformed, "@BloxyParadox/" .. descriptor.source)
    assert(fn, problem)
end
function Controller:Apply(selections)
    if not self.alive or self.busy then return false, {"An apply is already running or the script is unloaded"} end
    local requested = {}
    for _, category in ipairs(self.order) do
        local value = selections[category]
        if type(value) == "boolean" then value = tostring(value) end
        if value and value ~= "none" and value ~= "false" and value ~= "normal" then
            local id = self.map[category] and self.map[category][value]
            if not id or not self.descriptors[id] then return false, {"Unknown selection: " .. category .. " = " .. tostring(value)} end
            requested[category] = {id = id, value = value}
        end
    end
    self.busy = true
    local failures = {}
    -- Compile/capability checks happen before any active port is stopped.
    for _, category in ipairs(self.order) do
        local target = requested[category]
        if target and (self.applied[category] ~= target.value or self.failed[category]) then
            self:Report(category, "Checking", self.descriptors[target.id].title)
            local ok, problem = xpcall(function() self:Preflight(self.descriptors[target.id]) end, debug.traceback)
            if not ok then self:Report(category, "Error", problem); table.insert(failures, category .. ": " .. tostring(problem)); requested[category] = false end
        end
    end
    for _, category in ipairs(self.order) do
        if not self.alive then break end
        local target, active = requested[category], self.active[category]
        if target ~= false and (not target or self.applied[category] ~= target.value or self.failed[category]) then
            local previous = active and {id = active.id, value = active.value}
            if active then active.scope:Destroy(); self.active[category] = nil end
            self.applied[category], self.failed[category] = nil, nil
            if target then
                local ok, problem = self:Start(category, target)
                if not ok then
                    table.insert(failures, category .. ": " .. tostring(problem))
                    if previous and self.alive then self:Start(category, previous) end
                    self:Report(category, "Error", problem)
                end
            else self:Report(category, "Default", "Original port disabled") end
        end
    end
    self.busy = false
    self:RefreshInterop()
    return #failures == 0, failures
end
function Controller:Start(category, selection)
    self:Report(category, "Loading", self.descriptors[selection.id].title)
    local scope = self:NewScope(category)
    local descriptor = self.descriptors[selection.id]
    local entry = {scope = scope, id = selection.id, value = selection.value}
    self.active[category] = entry
    local ok, problem = xpcall(function()
        if descriptor.prepare then descriptor.prepare(scope, self) end
        scope:Run(self.portSources[descriptor.source], "@BloxyParadox/" .. selection.id)
        assert(scope.alive, self.failed[category] or "Port stopped during startup")
    end, debug.traceback)
    if not ok then scope:Destroy(); if self.active[category] == entry then self.active[category] = nil end; return false, problem end
    self.applied[category] = selection.value
    local status = self.status[category]
    if not (status and status.state == "Fallback") then
        self:Report(category, "Started", descriptor.title .. "; in-game validation pending")
    end
    return true
end
function Controller:Unload()
    if not self.alive then return end
    self.alive = false
    for _, entry in pairs(self.active) do entry.scope:Destroy() end
    table.clear(self.active)
    if self.ui then self.ui:Destroy() end
    if self.utilities then self.utilities:Destroy() end
end
function Controller:Stop(category)
    local entry = self.active[category]
    if entry then entry.scope:Destroy() end
    self.active[category], self.applied[category], self.failed[category] = nil, nil, nil
    self:Report(category, "Default", "Port closed")
    self:RefreshInterop()
end
function Controller:CanReload()
    return true
end
function Controller:Diagnostics()
    local lines = {"Bloxy Paradox — original ports / rewritten backend"}
    for _, line in ipairs(self.log) do table.insert(lines, line) end
    local result = table.concat(lines, "\n")
    if self.host.environment.setclipboard then pcall(self.host.environment.setclipboard, result) else print(result) end
    return result
end
function Backend.new(host, instrument, config)
    assert(type(host.loadstring) == "function" and type(host.setfenv) == "function", "Bloxy Paradox needs loadstring and setfenv")
    local self = setmetatable({host = host, instrument = instrument, alive = true, busy = false, services = {}, owners = setmetatable({}, {__mode = "k"}), sources = config.sources, sourcePatches = config.sourcePatches or {}, patchModule = config.patchModule, aliases = config.aliases, portSources = config.portSources, descriptors = config.descriptors, map = config.map, order = config.order, active = {}, applied = {}, failed = {}, status = {}, log = {}, httpCache = {}, scriptUrls = {}, coreGui = {}, coreSequence = 0}, Controller)
    self.ui = self:NewScope("wizard")
    return self
end
Backend.Scope = Scope
Backend.Controller = Controller
return Backend

end)()
local Adapters = (function()
-- Compatibility adapters: retain the original classic assets and their public APIs.
local Adapters = {}
function Adapters.Install(Backend)
    local Scope = Backend.Scope
    function Scope:SnapshotGui(root)
        self.guiSnapshots = self.guiSnapshots or setmetatable({}, {__mode = "k"})
        if self.guiSnapshots[root] then return end
        self.guiSnapshots[root] = true
        local properties = {"Active","Selectable","Position","Size","AnchorPoint","Rotation","BackgroundColor3","BackgroundTransparency","BorderSizePixel","ZIndex","Image","ImageColor3","ImageTransparency","ImageRectOffset","ImageRectSize","ScaleType","SliceCenter","Text","TextColor3","TextTransparency","TextSize","Font","TextEditable","AutoButtonColor","CornerRadius","Color","Transparency","Thickness"}
        local function capture(object)
            if self.controller.owners[object] or not (object:IsA("GuiObject") or object:IsA("UICorner") or object:IsA("UIStroke")) then return end
            local records = self.patches[object] or {}
            self.patches[object] = records
            for _, property in ipairs(properties) do
                local ok, value = pcall(function() return object[property] end)
                if ok and value ~= nil and not records[property] then records[property] = {old = value, last = value} end
            end
            self:Connect(object.Changed, function(property)
                if records[property] then records[property].last = object[property] end
            end)
        end
        capture(root)
        for _, object in ipairs(root:GetDescendants()) do capture(object) end
        self:Connect(root.DescendantAdded, capture)
    end
    function Scope:InstallUtilities(folder)
        local controller = self.controller
        if not controller.utilities then controller.utilities = controller:NewScope("utilities") end
        for _, serviceFolder in ipairs(folder:GetChildren()) do
            local service = controller:GetService(serviceFolder.Name)
            for _, object in ipairs(serviceFolder:GetChildren()) do
                if not service:FindFirstChild(object.Name) then
                    self.owned[object] = nil
                    controller.utilities:Own(object)
                    for _, descendant in ipairs(object:GetDescendants()) do controller.utilities:Own(descendant) end
                    object.Parent = service
                end
            end
        end
    end
    function Scope:TryHiddenProperty(object, name, value)
        local env = self.controller.host.environment
        if not env.gethiddenproperty or not env.sethiddenproperty then return false end
        local readable, before = pcall(env.gethiddenproperty, object, name)
        if not readable then return false end
        local written = pcall(env.sethiddenproperty, object, name, value)
        if not written then return false end
        self:Add(function()
            local ok, current = pcall(env.gethiddenproperty, object, name)
            if ok and current == value then pcall(env.sethiddenproperty, object, name, before) end
        end)
        return true
    end
    function Scope:ForCharacters(callback)
        local player, current = self.controller:GetService("Players").LocalPlayer, nil
        local function bind(character)
            current = character
            local generation = self:Fork("character")
            generation:Spawn("defer", function()
                local humanoid = generation:WaitForChild(character, "Humanoid", 12)
                if generation.alive and player.Character == character then callback(character, humanoid, generation) end
            end)
        end
        self:Connect(player.CharacterAdded, bind)
        self:Connect(player.CharacterRemoving, function(character) if current == character then current = nil; self:Drop("character") end end)
        if player.Character then bind(player.Character) end
    end
    function Scope:SendChat(text)
        local service = self.controller:GetService("TextChatService")
        local input = service:FindFirstChildOfClass("ChatInputBarConfiguration")
        local channels = service:FindFirstChild("TextChannels")
        local channel = input and input.TargetTextChannel or (channels and channels:FindFirstChild("RBXGeneral"))
        assert(channel and channel:IsA("TextChannel"), "No available TextChatService channel")
        local response = channel:SendAsync(text)
        assert(response.Status == Enum.TextChatMessageStatus.Success, "Chat rejected the message: " .. response.Status.Name)
        return response
    end
    function Scope:LoadSuite()
        if not self.environment.Suite then
            self.environment.Suite = self:Run(self.controller.sources.suite, "@BloxyParadox/rbxm-suite")
        end
        return self.environment.Suite
    end
    function Scope:LoadLegacyAsset()
        local suite = self:LoadSuite()
        local path = suite.download("yeku/legacy@1.1.0", "Legacy.rbxm")
        return suite.launch(path, {runscripts = false, debug = true}), suite
    end
    function Scope:ClassicBackpack()
        local model, suite = self:LoadLegacyAsset()
        assert(model and model:FindFirstChild("Core"), "Legacy asset has no Core folder")
        self:InstallUtilities(model.Utility)
        local client = self:WaitForChild(model.Core, "2016")
        local gui = self:WaitForChild(client, "NewRobloxGui")
        local module = self:WaitForChild(self:WaitForChild(gui, "Modules"), "BackpackScript")
        gui.Name, gui.ResetOnSpawn = "BloxyParadoxClassicBackpack", false
        self.environment.__BPBackpackGui = gui
        gui:SetAttribute("BackpackEnabled", true)
        gui.Parent = self.controller:GetService("CoreGui")
        local api = suite.require(module)
        assert(type(api) == "table" and type(api.OpenClose) == "function", "Classic backpack did not expose OpenClose")
        self.environment.BackpackApi = api
        self:SetCoreGuiEnabled(self.controller:GetService("StarterGui"), Enum.CoreGuiType.Backpack, false)
        self.controller:Report("backpack", "Fallback", "Original mobile loader is unavailable; using the full 2016 Legacy backpack")
        return api
    end
    function Scope:OpenInventory()
        local entry = self.controller.active.backpack
        local api = entry and entry.scope.environment.BackpackApi
        if api and api.OpenClose then api.OpenClose(); return end
        local legacy = self.environment.LegacyGui
        if legacy then
            local modules = legacy:FindFirstChild("Modules")
            local module = modules and modules:FindFirstChild("BackpackScript")
            if module and self.environment.Suite then
                local ok, result = pcall(self.environment.Suite.require, module)
                if ok and result.OpenClose then result.OpenClose(); return end
            end
        end
        local ok, input = pcall(function() return self.controller:GetService("VirtualInputManager") end)
        assert(ok and input, "This inventory exposes no OpenClose API and VirtualInputManager is unavailable")
        input:SendKeyEvent(true, Enum.KeyCode.Backquote, false, self.controller.host.game)
        input:SendKeyEvent(false, Enum.KeyCode.Backquote, false, self.controller.host.game)
    end
    function Scope:NativeMenuButton()
        return self:FindPath(self.controller:GetService("CoreGui"), {
            {"TopBarApp", "TopBarApp", "MenuIconHolder", "TriggerPoint", "IconHitArea"},
            {"TopBarApp", "TopBarApp", "UnibarLeftFrame", "UnibarMenu", "TriggerPoint", "IconHitArea"},
        })
    end
end
return Adapters

end)()
local Patches = (function()
local Patches = {}
function Patches.Replace(source, before, after, required)
    local output, cursor, count = {}, 1, 0
    while true do
        local first, last = string.find(source, before, cursor, true)
        if not first then break end
        table.insert(output, string.sub(source, cursor, first - 1)); table.insert(output, after)
        cursor, count = last + 1, count + 1
    end
    assert(not required or count > 0, "Upstream source changed; compatibility patch did not match: " .. string.sub(before, 1, 90))
    table.insert(output, string.sub(source, cursor))
    return table.concat(output)
end

function Patches.Legacy(source)
    local R = Patches.Replace
    source = R(source, 'local ChatBubbles = CoreGui:WaitForChild("ExperienceChat"):WaitForChild("bubbleChat")', 'local ChatBubbles = __BP:FindPath(CoreGui, {{"ExperienceChat", "bubbleChat"}, {"ExperienceChat", "BubbleChat"}})', true)
    source = R(source, 'Suite.download("yeku/legacy@latest", "Legacy.rbxm")', 'Suite.download("yeku/legacy@1.1.0", "Legacy.rbxm")', true)
    source = R(source, 'local LegacyGui = Suite.require(Legacy):Start(Settings.Year, Settings.SafeChat)', 'local LegacyGui = Suite.require(Legacy):Start(Settings.Year, Settings.SafeChat)\ngetgenv().LegacyGui = LegacyGui\ngetgenv().LegacyAsset = Legacy', true)
    source = R(source, 'RobloxGui.Enabled = false', '__BP:HideNativeMenu()\n__BP:HideModernTopbar()', true)
    source = R(source, 'RobloxGui.NotificationFrame.Parent = LegacyGui', 'local Notifications = RobloxGui:FindFirstChild("NotificationFrame")\nif Notifications then __BP:Patch(Notifications, "Parent", LegacyGui) end', true)
    source = R(source, 'Object[Property] = Value', '__BP:Patch(Object, Property, Value)', true)
    source = R(source, 'task.spawn(sethiddenproperty, Lighting, "Technology", Enum.Technology.Compatibility)', '__BP:TryHiddenProperty(Lighting, "Technology", Enum.Technology.Compatibility)', true)
    source = R(source, [[for _, Hidden in next, Lighting:QueryDescendants("> DepthOfFieldEffect, > SunRaysEffect, > BloomEffect, > BlurEffect, > ColorCorrectionEffect, > Atmosphere") do]], 'for _, Hidden in next, Lighting:GetChildren() do\n        if Hidden:IsA("PostEffect") or Hidden:IsA("Atmosphere") then', true)
    source = R(source, '\t\t\tForce(Hidden, "Enabled", false)\n\t\tend\n\tend', '\t\t\tForce(Hidden, "Enabled", false)\n\t\tend\n        end\n\tend', true)
    source = R(source, '\tCreate("ColorGradingEffect", { TonemapperPreset = Enum.TonemapperPreset.Retro })', '\tpcall(function() Create("ColorGradingEffect", { TonemapperPreset = Enum.TonemapperPreset.Retro, Parent = Lighting }) end)', true)
    source = R(source, 'for _, Object in next, ChatBubbles:QueryDescendants(`#Caret, #DistantBubble`) do\n\t\tConvert(Object)\n\tend\n\n\tChatBubbles.DescendantAdded:Connect(Convert)', 'if ChatBubbles then\n        for _, Object in ipairs(ChatBubbles:GetDescendants()) do\n            if Object.Name == "Caret" or Object.Name == "DistantBubble" then Convert(Object) end\n        end\n        ChatBubbles.DescendantAdded:Connect(Convert)\n    end', true)
    local start = string.find(source, 'task.spawn(function()\n\tlocal TopBarApp = ', 1, true)
    assert(start, 'Legacy native-GUI setup changed')
    -- Replace nil-prone native paths; the classic model and its era layouts stay intact.
    source = string.sub(source, 1, start - 1) .. [[
__BP:HideModernTopbar()
__BP:HideNativeMenu()
local NativeControls = RobloxGui:FindFirstChild("ControlFrame")
if NativeControls then __BP:Hide(NativeControls) end
]]
    return source
end

function Patches.Settings(source)
    local R = Patches.Replace
    for _, property in ipairs({"Visible", "Active", "Selectable", "AutoButtonColor", "BackgroundTransparency", "ImageTransparency", "TextTransparency"}) do
        local value = (property == "Visible" or property == "Active" or property == "Selectable" or property == "AutoButtonColor") and "false" or "1"
        source = R(source, "Object." .. property .. " = " .. value, '__BP:Patch(Object, "' .. property .. '", ' .. value .. ")", true)
    end
    source = R(source, '\tlocal TopBarApp = CoreGui:FindFirstChild("TopBarApp")\n\tTopBarApp = TopBarApp and TopBarApp:FindFirstChild("TopBarApp")\n\tlocal Holder = TopBarApp and TopBarApp:FindFirstChild("MenuIconHolder")\n\tlocal Hit = Holder and Holder:FindFirstChild("TriggerPoint") and Holder.TriggerPoint:FindFirstChild("IconHitArea")', '\tlocal Hit = __BP:NativeMenuButton()', true)
    source = R(source, 'Spawn(HookNativeMenu)', 'Spawn(HookNativeMenu)\nConnect(GuiService.MenuOpened, function() HideNativeSettingsMenu(); SetVisibility(true) end)', true)
    source = R(source, 'SetVisibility = function(Visible, NoAnimation, CustomPage)', 'local VisibilityChanged = Instance.new("BindableEvent")\nSetVisibility = function(Visible, NoAnimation, CustomPage)', true)
    source = R(source, '\tHub.Visible = Visible\n', '\tHub.Visible = Visible\n\tVisibilityChanged:Fire(Visible)\n', true)
    source = R(source, '\tSetGameplayInputLocked(Visible)', '\tSetGameplayInputLocked(Visible)\n    if not Visible then pcall(function() GuiService:SetMenuIsOpen(false) end) end', true)
    source = R(source, 'Api.Instance = Hub', 'Api.VisibilityChanged = VisibilityChanged.Event\nApi.Instance = Hub', true)
    source = R(source, 'getgenv().Settings2016 = Api', 'getgenv().Settings2016 = Api\n__BP:Add(function() Api:SetVisibility(false, true) end)', true)
    return source
end

function Patches.SafeChat(source)
    source = Patches.Replace(source, [[local textChannel = TextChatService:FindFirstChild("RBXGeneral", true)
					if textChannel and textChannel:IsA("TextChannel") then
						textChannel:SendAsync(label)
					end]], [[local sent, problem = pcall(function() return __BP:SendChat(label) end)
                    if not sent then
                        __BP.controller:Report("safechat", "Message rejected", problem)
                        return
                    end]], true)
    return Patches.Replace(source, 'script.Enabled = false', '__BP.controller:Stop("safechat")', true)
end

function Patches.Emotes(source)
    -- Retain the full upstream editor. Recoloring and image enforcement need not
    -- traverse the entire native wheel on every rendered frame.
    source = Patches.Replace(source, '    return true, emotesWheel\nend', '    __BP:SnapshotGui(emotesWheel)\n    return true, emotesWheel\nend', true)
    source = Patches.Replace(source, [[RunService.Heartbeat:Connect(function()
    if not State.isGUICreated then
        checkAndRecreateGUI()
    else
        updateGUIColors()
        enforceImages()
    end
end)]], [[local styleElapsed = 0
RunService.Heartbeat:Connect(function(delta)
    styleElapsed += delta
    if styleElapsed < 0.1 then return end
    styleElapsed = 0
    if not State.isGUICreated then
        checkAndRecreateGUI()
    else
        local exists, wheel = checkEmotesMenuExists()
        if not exists then State.isGUICreated = false; return end
        if wheel.Visible or State.hudEditorActive then updateGUIColors(); enforceImages() end
    end
end)]], true)
    return source .. [[
__BP:Add(function()
    if exitHUDEditor then pcall(exitHUDEditor) end
    if stopCurrentEmote then pcall(stopCurrentEmote) end
    pcall(function() GuiService:SetEmotesMenuOpen(false) end)
end)
]]
end

function Patches.Suite(source)
    local R = Patches.Replace
    source = R(source, 'local pathToUrl = getcustomasset or getsynasset or error("Failed to load model! (No custom asset loader found)")', 'local pathToUrl = getcustomasset or getsynasset', true)
    source = R(source, '\tfunction github.download(user, repo, tag, asset)', '\tfunction github.download(user, repo, tag, asset)\n        assert(pathToUrl and isfolder and makefolder and writefile and readfile and isfile, "File/custom-asset APIs are required to download this classic model")\n        init()', true)
    source = R(source, '\n\tinit()\nend\n\n-- Module resolution', '\nend\n\n-- Module resolution', true)
    source = R(source, 'return game:GetObjects(pathToUrl(url))', 'return game:GetObjects(assert(pathToUrl, "A custom-asset API is needed for this file path")(url))', true)
    return source
end

function Patches.AssetModule(source, scope)
    local R = Patches.Replace
    -- Preserve Legacy's model scripts, but route copied service utilities through one lifetime.
    source = R(source, [[Legacy:CreateUtilities()
]], [[__BP:InstallUtilities(Utility)
]], false)
    local utilityMove = '\tfor _, ServiceFolder in next, Utility:GetChildren() do\n\t\tlocal Service = game:GetService(ServiceFolder.Name)\n\t\t\n\t\tfor _, Object in next, ServiceFolder:GetChildren() do\n\t\t\tObject.Parent = Service\n\t\tend\n\tend'
    source = R(source, utilityMove, '__BP:InstallUtilities(Utility)', false)
    source = R(source, 'StarterGui:SetCoreGuiEnabled(Item, false)', 'if not (getgenv().SkipClassicChat and Item == Enum.CoreGuiType.Chat) then StarterGui:SetCoreGuiEnabled(Item, false) end', false)
    source = R(source, 'task.spawn(require, LocalScript)', 'if not (getgenv().SkipClassicChat and (LocalScript.Name == "Chat" or LocalScript.Name == "ChatScript")) then task.spawn(require, LocalScript) end', false)
    if scope.id == "backpack" and scope.environment.__BPBackpackGui then
        source = R(source, [[CoreGui:WaitForChild('NewRobloxGui')]], 'getgenv().__BPBackpackGui', false)
        source = R(source, [[CoreGui:FindFirstChild("NewRobloxGui")]], 'getgenv().__BPBackpackGui', false)
        source = R(source, 'CoreGui.NewRobloxGui', 'getgenv().__BPBackpackGui', false)
    end
    return source
end
return Patches

end)()
Adapters.Install(Backend)
local Ports = {
    ["Anims_R15_2008"] = [============[-- Resolve the original presets; retain per-state entries and both idle variants.
local preset = getgenv().AnimationPreset
local resolved = {}
local function resolve(id)
    if resolved[id] then return resolved[id] end
    local ok, objects = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
    local actual
    if ok then
        for _, object in ipairs(objects) do
            local animation = object:IsA("Animation") and object or object:FindFirstChildWhichIsA("Animation", true)
            if animation then actual = animation.AnimationId end
            object:Destroy()
        end
    end
    resolved[id] = actual or "rbxassetid://" .. id
    return resolved[id]
end
__BP:ForCharacters(function(character, humanoid, generation)
    assert(humanoid.RigType.Name == getgenv().ExpectedRig, "Animation preset does not match the new character's rig")
    local animate = generation:WaitForChild(character, "Animate", 12)
    local count = 0
    for name, ids in pairs(preset) do
        local folder = animate:FindFirstChild(name)
        if folder then
            local values = {}
            for _, value in ipairs(folder:GetChildren()) do if value:IsA("Animation") then table.insert(values, value) end end
            table.sort(values, function(a, b) return a.Name < b.Name end)
            for index, value in ipairs(values) do
                local id = ids[math.min(index, #ids)]
                local actual = getgenv().ResolvePresetAssets and resolve(id) or "rbxassetid://" .. id
                if not generation.alive then return end
                generation:Patch(value, "AnimationId", actual); count += 1
            end
        end
    end
    assert(count > 0, "Animate contains no matching preset entries")
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then for _, track in ipairs(animator:GetPlayingAnimationTracks()) do if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Movement or track.Priority == Enum.AnimationPriority.Idle then track:Stop(0.15) end end end
    if not animate.Disabled then generation:Patch(animate, "Disabled", true); generation:Patch(animate, "Disabled", false) end
end)
]============],
    ["Anims_R15_Old"] = [============[-- Resolve the original presets; retain per-state entries and both idle variants.
local preset = getgenv().AnimationPreset
local resolved = {}
local function resolve(id)
    if resolved[id] then return resolved[id] end
    local ok, objects = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
    local actual
    if ok then
        for _, object in ipairs(objects) do
            local animation = object:IsA("Animation") and object or object:FindFirstChildWhichIsA("Animation", true)
            if animation then actual = animation.AnimationId end
            object:Destroy()
        end
    end
    resolved[id] = actual or "rbxassetid://" .. id
    return resolved[id]
end
__BP:ForCharacters(function(character, humanoid, generation)
    assert(humanoid.RigType.Name == getgenv().ExpectedRig, "Animation preset does not match the new character's rig")
    local animate = generation:WaitForChild(character, "Animate", 12)
    local count = 0
    for name, ids in pairs(preset) do
        local folder = animate:FindFirstChild(name)
        if folder then
            local values = {}
            for _, value in ipairs(folder:GetChildren()) do if value:IsA("Animation") then table.insert(values, value) end end
            table.sort(values, function(a, b) return a.Name < b.Name end)
            for index, value in ipairs(values) do
                local id = ids[math.min(index, #ids)]
                local actual = getgenv().ResolvePresetAssets and resolve(id) or "rbxassetid://" .. id
                if not generation.alive then return end
                generation:Patch(value, "AnimationId", actual); count += 1
            end
        end
    end
    assert(count > 0, "Animate contains no matching preset entries")
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then for _, track in ipairs(animator:GetPlayingAnimationTracks()) do if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Movement or track.Priority == Enum.AnimationPriority.Idle then track:Stop(0.15) end end end
    if not animate.Disabled then generation:Patch(animate, "Disabled", true); generation:Patch(animate, "Disabled", false) end
end)
]============],
    ["Anims_R6_2006"] = [============[-- Resolve the original presets; retain per-state entries and both idle variants.
local preset = getgenv().AnimationPreset
local resolved = {}
local function resolve(id)
    if resolved[id] then return resolved[id] end
    local ok, objects = pcall(function() return game:GetObjects("rbxassetid://" .. id) end)
    local actual
    if ok then
        for _, object in ipairs(objects) do
            local animation = object:IsA("Animation") and object or object:FindFirstChildWhichIsA("Animation", true)
            if animation then actual = animation.AnimationId end
            object:Destroy()
        end
    end
    resolved[id] = actual or "rbxassetid://" .. id
    return resolved[id]
end
__BP:ForCharacters(function(character, humanoid, generation)
    assert(humanoid.RigType.Name == getgenv().ExpectedRig, "Animation preset does not match the new character's rig")
    local animate = generation:WaitForChild(character, "Animate", 12)
    local count = 0
    for name, ids in pairs(preset) do
        local folder = animate:FindFirstChild(name)
        if folder then
            local values = {}
            for _, value in ipairs(folder:GetChildren()) do if value:IsA("Animation") then table.insert(values, value) end end
            table.sort(values, function(a, b) return a.Name < b.Name end)
            for index, value in ipairs(values) do
                local id = ids[math.min(index, #ids)]
                local actual = getgenv().ResolvePresetAssets and resolve(id) or "rbxassetid://" .. id
                if not generation.alive then return end
                generation:Patch(value, "AnimationId", actual); count += 1
            end
        end
    end
    assert(count > 0, "Animate contains no matching preset entries")
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then for _, track in ipairs(animator:GetPlayingAnimationTracks()) do if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Movement or track.Priority == Enum.AnimationPriority.Idle then track:Stop(0.15) end end end
    if not animate.Disabled then generation:Patch(animate, "Disabled", true); generation:Patch(animate, "Disabled", false) end
end)
]============],
    ["Anims_R6_2008"] = [============[-- Original 2008 desired-angle moveset, without the two startup deaths.
__BP:ForCharacters(function(character, humanoid, generation)
    assert(humanoid.RigType==Enum.HumanoidRigType.R6,"The 2008 R6 port requires R6")
    generation.environment.Char=character
    generation:Run([==========[local function waitForChild(parent, childName) return __BP:WaitForChild(parent, childName, 12) end

__BP:Patch(waitForChild(Char, "Animate"), "Disabled", true)

task.wait(1)

-- ANIMATION

-- declarations

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Figure = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Torso = waitForChild(Figure, "Torso")
local RightShoulder = waitForChild(Torso, "Right Shoulder")
local LeftShoulder = waitForChild(Torso, "Left Shoulder")
local RightHip = waitForChild(Torso, "Right Hip")
local LeftHip = waitForChild(Torso, "Left Hip")
local Neck = waitForChild(Torso, "Neck")
local Humanoid = waitForChild(Figure, "Humanoid")
local pose = "Standing"

local toolAnim = "None"
local toolAnimTime = 0

local jumpMaxLimbVelocity = 0.75

-- functions

function onRunning(speed)
if speed>0 then
pose = "Running"
else
pose = "Standing"
end
end

function onDied()
pose = "Dead"
end

function onJumping()
pose = "Jumping"
end

function onClimbing()
pose = "Climbing"
end

function onGettingUp()
pose = "GettingUp"
end

function onFreeFall()
pose = "FreeFall"
end

function onFallingDown()
pose = "FallingDown"
end

function onSeated()
pose = "Seated"
end

function onPlatformStanding()
pose = "PlatformStanding"
end

function onSwimming(speed)
if speed>0 then
pose = "Climbing"
else
pose = "Running"
end
end

function moveJump()
RightShoulder.MaxVelocity = 0.5
LeftShoulder.MaxVelocity = 0.5
RightShoulder:SetDesiredAngle(3.14)
LeftShoulder:SetDesiredAngle(-3.14)
RightHip:SetDesiredAngle(0)
LeftHip:SetDesiredAngle(0)
end


-- same as jump for now

function moveFreeFall()
RightShoulder.MaxVelocity = 0.5
LeftShoulder.MaxVelocity = 0.5
RightShoulder:SetDesiredAngle(3.14)
LeftShoulder:SetDesiredAngle(-3.14)
RightHip:SetDesiredAngle(0)
LeftHip:SetDesiredAngle(0)
end

function moveSit()
RightShoulder.MaxVelocity = 0.5
LeftShoulder.MaxVelocity = 0.5
RightShoulder:SetDesiredAngle(3.14 /2)
LeftShoulder:SetDesiredAngle(-3.14 /2)
RightHip:SetDesiredAngle(3.14 /2)
LeftHip:SetDesiredAngle(-3.14 /2)
end

function getTool()
for _, kid in ipairs(Figure:GetChildren()) do
if kid.className == "Tool" then return kid end
end
return nil
end

function getToolAnim(tool)
for _, c in ipairs(tool:GetChildren()) do
if c.Name == "toolanim" and c.className == "StringValue" then
return c
end
end
return nil
end

function animateTool()

if (toolAnim == "None") then
RightShoulder:SetDesiredAngle(1.57)
return
end

if (toolAnim == "Slash") then
RightShoulder.MaxVelocity = 0.5
RightShoulder:SetDesiredAngle(0)
return
end

if (toolAnim == "Lunge") then
RightShoulder.MaxVelocity = 0.5
LeftShoulder.MaxVelocity = 0.5
RightHip.MaxVelocity = 0.5
LeftHip.MaxVelocity = 0.5
RightShoulder:SetDesiredAngle(1.57)
LeftShoulder:SetDesiredAngle(1.0)
RightHip:SetDesiredAngle(1.57)
LeftHip:SetDesiredAngle(1.0)
return
end
end

function move(time)
local amplitude
local frequency

if (pose == "Jumping") then
moveJump()
return
end

if (pose == "FreeFall") then
moveFreeFall()
return
end

if (pose == "Seated") then
moveSit()
return
end

local climbFudge = 0

if (pose == "Running") then
RightShoulder.MaxVelocity = 0.08
LeftShoulder.MaxVelocity = 0.08
amplitude = 0.66
frequency = 8
elseif (pose == "Climbing") then
RightShoulder.MaxVelocity = 0.4
LeftShoulder.MaxVelocity = 0.4
amplitude = 0.66
frequency = 9
climbFudge = 3.14
else
amplitude = 0.07
frequency = 1
end

desiredAngle = amplitude * math.sin(time*frequency)

RightShoulder:SetDesiredAngle(desiredAngle + climbFudge)
LeftShoulder:SetDesiredAngle(desiredAngle - climbFudge)
RightHip:SetDesiredAngle(-desiredAngle)
LeftHip:SetDesiredAngle(-desiredAngle)


local tool = getTool()

if tool then

animStringValueObject = getToolAnim(tool)

if animStringValueObject then
toolAnim = animStringValueObject.Value
-- message recieved, delete StringValue
__BP:Patch(animStringValueObject, "Parent", nil)
toolAnimTime = time + .3
end

if time > toolAnimTime then
toolAnimTime = 0
toolAnim = "None"
end

animateTool()

else
toolAnim = "None"
toolAnimTime = 0
end
end


-- connect events

Humanoid.Died:Connect(onDied)
Humanoid.Running:Connect(onRunning)
Humanoid.Jumping:Connect(onJumping)
Humanoid.Climbing:Connect(onClimbing)
Humanoid.GettingUp:Connect(onGettingUp)
Humanoid.FreeFalling:Connect(onFreeFall)
Humanoid.FallingDown:Connect(onFallingDown)
Humanoid.Seated:Connect(onSeated)
Humanoid.PlatformStanding:Connect(onPlatformStanding)
Humanoid.Swimming:Connect(onSwimming)
-- main program

local runService = game:service("RunService");

while Figure.Parent~=nil do
wait(0.1)
move(os.clock())
end
]==========],"@BloxyParadox/2008-moveset")
end)
]============],
    ["Backpack_Advanced"] = [============[-- The original 38376 endpoint and raw mirror are unavailable.
-- Keep this selection usable with the complete same-era Legacy backpack.
-- The unavailable original has not been deobfuscated or silently replaced.
__BP:ClassicBackpack()
]============],
    ["Backpack_Simple"] = [============[-- Readable rewrite of the recovered Simple backpack (not a replacement design).
-- Original visuals: backpack_layout.luau. Recovery evidence: reverse/RECOVERY.md.
local makeLayout = (function()
-- Original Simple backpack: 68 instances, 381 explicit properties.
-- Recovered from the quarantined original; see reverse/RECOVERY.md.
return function(coreGui)
    local function make(class, parent, properties)
        local object = Instance.new(class)
        for name, value in pairs(properties) do object[name] = value end
        object.Parent = parent
        return object
    end
    local inventoryGui = make("ScreenGui", coreGui, {
        IgnoreGuiInset = false,
        Name = "Inventory",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    local screen = make("Frame", inventoryGui, {
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 0.9900000095367432,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Name = "Frame",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local verticalLayout = make("UIListLayout", screen, {
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Name = "UIListLayout",
        Padding = UDim.new(0, 5),
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
    })
    local inventoryPanel = make("Frame", screen, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Name = "1_Inventory",
        Position = UDim2.new(0.5, 0, 1.04097402, -150),
        Size = UDim2.new(0.551999986, 0, 0.479000002, 0),
        Visible = false,
    })
    local inventoryScroll = make("ScrollingFrame", inventoryPanel, {
        Active = true,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ClipsDescendants = false,
        Name = "ScrollingFrame",
        Position = UDim2.new(0.0191845838, 0, 0.0266823173, 0),
        ScrollBarImageColor3 = Color3.new(0, 0, 0),
        Size = UDim2.new(0.958915055, 0, 0.950767517, 0),
        Visible = true,
    })
    local inventoryGrid = make("UIGridLayout", inventoryScroll, {
        CellSize = UDim2.new(0.111000001, 0, 0.111000001, 0),
        Name = "InventoryGrip",
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
    local panelCorner = make("UICorner", inventoryPanel, {
        Name = "UICorner",
    })
    local panelRatio = make("UIAspectRatioConstraint", inventoryPanel, {
        AspectRatio = 2.319999933242798,
        Name = "Ratio",
    })
    local resizeScript = make("LocalScript", inventoryPanel, {
        Name = "Resize",
    })
    local hotbar = make("Frame", screen, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Name = "2_Hotbar",
        Position = UDim2.new(0.496089488, 0, 0.969945788, -30),
        Size = UDim2.new(0.600000024, 0, 0.104999997, 0),
        Visible = true,
    })
    local hotbarLayout = make("UIListLayout", hotbar, {
        FillDirection = Enum.FillDirection.Horizontal,
        HorizontalAlignment = Enum.HorizontalAlignment.Center,
        Name = "UIListLayout",
        Padding = UDim.new(0, 5),
    })
    local slot1 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "1",
        Position = UDim2.new(0.0300347004, 0, 0, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot1Stroke = make("UIStroke", slot1, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot1Corner = make("UICorner", slot1, {
        Name = "UICorner",
    })
    local slot1Ratio = make("UIAspectRatioConstraint", slot1, {
        Name = "UIAspectRatioConstraint",
    })
    local slot1Label = make("TextLabel", slot1, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[AIMLOCK]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot1Tool = make("ObjectValue", slot1, {
        Name = "Tool",
    })
    local slot6 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "6",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot6Stroke = make("UIStroke", slot6, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot6Corner = make("UICorner", slot6, {
        Name = "UICorner",
    })
    local slot6Ratio = make("UIAspectRatioConstraint", slot6, {
        Name = "UIAspectRatioConstraint",
    })
    local slot6Label = make("TextLabel", slot6, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot6Tool = make("ObjectValue", slot6, {
        Name = "Tool",
    })
    local slot2 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "2",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot2Stroke = make("UIStroke", slot2, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot2Corner = make("UICorner", slot2, {
        Name = "UICorner",
    })
    local slot2Ratio = make("UIAspectRatioConstraint", slot2, {
        Name = "UIAspectRatioConstraint",
    })
    local slot2Label = make("TextLabel", slot2, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot2Tool = make("ObjectValue", slot2, {
        Name = "Tool",
    })
    local slot3 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "3",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot3Stroke = make("UIStroke", slot3, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot3Corner = make("UICorner", slot3, {
        Name = "UICorner",
    })
    local slot3Ratio = make("UIAspectRatioConstraint", slot3, {
        Name = "UIAspectRatioConstraint",
    })
    local slot3Label = make("TextLabel", slot3, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot3Tool = make("ObjectValue", slot3, {
        Name = "Tool",
    })
    local slot5 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "5",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot5Stroke = make("UIStroke", slot5, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot5Corner = make("UICorner", slot5, {
        Name = "UICorner",
    })
    local slot5Ratio = make("UIAspectRatioConstraint", slot5, {
        Name = "UIAspectRatioConstraint",
    })
    local slot5Label = make("TextLabel", slot5, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot5Tool = make("ObjectValue", slot5, {
        Name = "Tool",
    })
    local slot9 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "9",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot9Stroke = make("UIStroke", slot9, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot9Corner = make("UICorner", slot9, {
        Name = "UICorner",
    })
    local slot9Ratio = make("UIAspectRatioConstraint", slot9, {
        Name = "UIAspectRatioConstraint",
    })
    local slot9Label = make("TextLabel", slot9, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot9Tool = make("ObjectValue", slot9, {
        Name = "Tool",
    })
    local slot4 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "4",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot4Stroke = make("UIStroke", slot4, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot4Corner = make("UICorner", slot4, {
        Name = "UICorner",
    })
    local slot4Ratio = make("UIAspectRatioConstraint", slot4, {
        Name = "UIAspectRatioConstraint",
    })
    local slot4Label = make("TextLabel", slot4, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot4Tool = make("ObjectValue", slot4, {
        Name = "Tool",
    })
    local slot8 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "8",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot8Stroke = make("UIStroke", slot8, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot8Corner = make("UICorner", slot8, {
        Name = "UICorner",
    })
    local slot8Ratio = make("UIAspectRatioConstraint", slot8, {
        Name = "UIAspectRatioConstraint",
    })
    local slot8Label = make("TextLabel", slot8, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot8Tool = make("ObjectValue", slot8, {
        Name = "Tool",
    })
    local hotbarRatio = make("UIAspectRatioConstraint", hotbar, {
        AspectRatio = 10,
        Name = "UIAspectRatioConstraint",
    })
    local slot7 = make("ImageButton", hotbar, {
        BackgroundColor3 = Color3.new(0, 0, 0),
        BackgroundTransparency = 0.8999999761581421,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        ImageTransparency = 0.3499999940395355,
        Name = "7",
        Size = UDim2.new(1, 0, 1, 0),
        Visible = true,
    })
    local slot7Stroke = make("UIStroke", slot7, {
        Name = "UIStroke",
        Transparency = 0.7,
    })
    local slot7Corner = make("UICorner", slot7, {
        Name = "UICorner",
    })
    local slot7Ratio = make("UIAspectRatioConstraint", slot7, {
        Name = "UIAspectRatioConstraint",
    })
    local slot7Label = make("TextLabel", slot7, {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Name = "TextLabel",
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "[WOW]",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 10,
        TextWrapped = true,
        Visible = false,
    })
    local slot7Tool = make("ObjectValue", slot7, {
        Name = "Tool",
    })
    local filler = make("Frame", screen, {
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderColor3 = Color3.new(0, 0, 0),
        BorderSizePixel = 0,
        Name = "3_Filler",
        Position = UDim2.new(0.460906953, 0, 0.459852695, 0),
        Size = UDim2.new(0, 100, 0, 1),
        Visible = true,
    })
    local handlerScript = make("LocalScript", screen, {
        Name = "handler",
    })
    return inventoryGui, screen, inventoryPanel, inventoryScroll, inventoryGrid, hotbar
end

end)()
local Players = game:GetService("Players")
local Input = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local player = Players.LocalPlayer
local backpack = __BP:WaitForChild(player, "Backpack", 12)
local gui, screen, panel, scroll, grid, hotbar = makeLayout(game:GetService("CoreGui"))
local slots, records = {}, {}
local dragging, queued, touchButton, suppressActivation
local reconcile, schedule

for index = 1, 9 do slots[index] = hotbar[tostring(index)] end

local function isHeld(tool)
    return tool and ((backpack and tool.Parent == backpack) or (player.Character and tool.Parent == player.Character))
end

local function paint(button, tool)
    local icon = tool and tool.TextureId or ""
    button.Tool.Value = tool
    button.Image = icon
    button.TextLabel.Text = tool and icon == "" and tool.Name or ""
    button.TextLabel.Visible = tool ~= nil and icon == ""
    local equipped = tool ~= nil and player.Character ~= nil and tool.Parent == player.Character
    button.UIStroke.Color = equipped and Color3.fromRGB(255,255,255) or Color3.fromRGB(0,0,0)
    button.UIStroke.Transparency = equipped and 0 or 0.7
    button.UIStroke.Thickness = equipped and 2 or 1
    button.Visible = button.Parent == scroll or panel.Visible or tool ~= nil
end

local function equip(tool)
    if not isHeld(tool) then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return end
    if tool.Parent == character then humanoid:UnequipTools() else humanoid:EquipTool(tool) end
    schedule()
end

local function cancelDrag()
    if dragging then
        if dragging.ghost then dragging.ghost:Destroy() end
        dragging = nil
    end
    if suppressActivation and __BP.alive then
        __BP:Spawn("defer", function() suppressActivation = false end)
    end
end

local function setOpen(open)
    panel.Visible = open
    if not open then cancelDrag() end
    for _, button in ipairs(slots) do paint(button, button.Tool.Value) end
end

local function toggle()
    setOpen(not panel.Visible)
end

-- Preserve the original public integration point for classic topbar buttons.
BackpackApi = {OpenClose=toggle, SetOpen=function(_, open) setOpen(open) end}
ToggleInventory = toggle
__BP:SetCoreGuiEnabled(StarterGui, Enum.CoreGuiType.Backpack, false)

local function bindButton(button, scope)
    scope:Connect(button.Activated, function()
        if not suppressActivation then equip(button.Tool.Value) end
    end)
end
for _, button in ipairs(slots) do bindButton(button, __BP) end

local function emptySlot()
    for _, button in ipairs(slots) do if button.Tool.Value == nil then return button end end
end

local function observe(tool, button)
    local lifetime = __BP:Fork(tool)
    records[tool] = {button=button, lifetime=lifetime}
    lifetime:Connect(tool.AncestryChanged, schedule)
    lifetime:Connect(tool:GetPropertyChangedSignal("Name"), schedule)
    lifetime:Connect(tool:GetPropertyChangedSignal("TextureId"), schedule)
end

local function overflowButton()
    local button = __BP:Clone(slots[1])
    button.Name = "InventoryTool"
    button.Parent = scroll
    -- Its lifetime follows the widget, not the tool currently assigned to it.
    bindButton(button, __BP:Fork(button))
    return button
end

reconcile = function()
    for tool, record in pairs(records) do
        if not isHeld(tool) then
            if dragging and dragging.tool == tool then cancelDrag() end
            local button = record.button
            if button.Parent == scroll then
                __BP:Drop(button)
                button:Destroy()
            else paint(button, nil) end
            __BP:Drop(tool)
            records[tool] = nil
        end
    end
    local tools = backpack and backpack:GetChildren() or {}
    local character = player.Character
    if character then
        for _, tool in ipairs(character:GetChildren()) do table.insert(tools, tool) end
    end
    for _, tool in ipairs(tools) do
        if tool:IsA("Tool") then
            if not records[tool] then
                local button = emptySlot() or overflowButton()
                paint(button, tool)
                observe(tool, button)
            end
            paint(records[tool].button, tool)
        end
    end
    for _, button in ipairs(slots) do paint(button, button.Tool.Value) end
end

schedule = function()
    if queued or not __BP.alive then return end
    queued = true
    __BP:Spawn("defer", function()
        queued = false
        reconcile()
    end)
end

local function resizeGrid()
    local size = slots[1].AbsoluteSize
    grid.CellSize = UDim2.fromOffset(size.X, size.Y)
end
resizeGrid()
__BP:Connect(screen:GetPropertyChangedSignal("AbsoluteSize"), resizeGrid)

local function pointerPosition(input)
    local inset = gui.IgnoreGuiInset and Vector2.new(0,0) or GuiService:GetGuiInset()
    return Vector2.new(input.Position.X-inset.X, input.Position.Y-inset.Y)
end
local function contains(point, object)
    if not object.Visible then return false end
    local position, size = object.AbsolutePosition, object.AbsoluteSize
    return point.X >= position.X and point.X <= position.X+size.X
        and point.Y >= position.Y and point.Y <= position.Y+size.Y
end
local function primary(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end
local function moveGhost(point)
    dragging.ghost.Position = UDim2.fromOffset(point.X, point.Y)
end

__BP:Connect(Input.InputBegan, function(input, processed)
    if not processed then
        if input.KeyCode == Enum.KeyCode.Backquote then toggle(); return end
        local key = tonumber(Input:GetStringForKeyCode(input.KeyCode))
        if key and slots[key] then equip(slots[key].Tool.Value); return end
    end
    if dragging or not panel.Visible or not primary(input) then return end
    local point = pointerPosition(input)
    for tool, record in pairs(records) do
        if contains(point, record.button) then
            -- Delay creating the ghost until the pointer moves. Taps still equip.
            dragging = {tool=tool, source=record.button, input=input, start=point}
            return
        end
    end
end)

__BP:Connect(Input.InputChanged, function(input)
    if not dragging then return end
    local touch = dragging.input.UserInputType == Enum.UserInputType.Touch
    if (touch and input ~= dragging.input) or (not touch and input.UserInputType ~= Enum.UserInputType.MouseMovement) then return end
    local point = pointerPosition(input)
    if not dragging.ghost then
        local dx, dy = point.X-dragging.start.X, point.Y-dragging.start.Y
        if dx*dx+dy*dy < 16 then return end
        suppressActivation = true
        dragging.ghost = __BP:Clone(dragging.source)
        dragging.ghost.Name = "DraggedTool"
        local size = slots[1].AbsoluteSize
        dragging.ghost.Size = UDim2.fromOffset(size.X,size.Y)
        dragging.ghost.Parent = gui
    end
    moveGhost(point)
end)

__BP:Connect(Input.InputEnded, function(input)
    if not dragging or not primary(input) then return end
    if dragging.input.UserInputType == Enum.UserInputType.Touch and input ~= dragging.input then return end
    local current = dragging
    if not current.ghost then
        -- Activated owns taps; clear the pointer state before the event runs.
        dragging = nil
        return
    end
    local point = pointerPosition(input)
    local target
    for _, button in ipairs(slots) do if contains(point,button) then target=button; break end end
    local source = current.source
    if target and target ~= source and isHeld(current.tool) then
        local other = target.Tool.Value
        records[current.tool].button = target
        paint(target,current.tool)
        if other and records[other] then
            records[other].button = source
            paint(source,other)
        elseif source.Parent == scroll then
            __BP:Drop(source);source:Destroy()
        else paint(source,nil) end
    elseif not target and contains(point,panel) and source.Parent == hotbar and isHeld(current.tool) then
        local button = overflowButton()
        records[current.tool].button = button
        paint(button,current.tool)
        paint(source,nil)
    end
    cancelDrag()
    schedule()
end)

local function bindCharacter(character)
    cancelDrag()
    local lifetime = __BP:Fork("character")
    lifetime:Connect(character.ChildAdded, schedule)
    lifetime:Connect(character.ChildRemoved, schedule)
    schedule()
end
__BP:Connect(player.CharacterAdded, bindCharacter)
__BP:Connect(player:GetPropertyChangedSignal("Character"), function()
    if not player.Character then __BP:Drop("character");cancelDrag();schedule() end
end)
local function bindBackpack(container)
    backpack = container
    local lifetime = __BP:Fork("backpack")
    lifetime:Connect(container.ChildAdded, schedule)
    lifetime:Connect(container.ChildRemoved, schedule)
    schedule()
end
__BP:Connect(player.ChildAdded, function(child)
    if child:IsA("Backpack") then bindBackpack(child) end
end)
__BP:Connect(player.ChildRemoved, function(child)
    if child == backpack then backpack=nil;__BP:Drop("backpack");schedule() end
end)
bindBackpack(backpack)
if player.Character then bindCharacter(player.Character) end

if Input.TouchEnabled then
    touchButton = Instance.new("ImageButton")
    touchButton.Name = "ToggleInventoryButton"
    touchButton.Image = "rbxassetid://6870729295"
    touchButton.BackgroundTransparency = 1
    touchButton.Size = UDim2.fromOffset(40,40)
    touchButton.Position = UDim2.new(0.015,0,0.9,0)
    touchButton.ZIndex = 10
    touchButton.Parent = screen
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0,6)
    corner.Parent = touchButton
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255,255,255)
    stroke.Transparency = 0.3
    stroke.Thickness = 1
    stroke.Parent = touchButton
    __BP:Connect(touchButton.MouseButton1Click, toggle)
end
__BP:Add(cancelDrag)
reconcile()
]============],
    ["BetterEmotes"] = [============[loadstring(game:HttpGet("bp://emotes"))()
]============],
    ["Forcefield"] = [============[-- Preserve the original two-shell classic bubble, only while protection exists.
__BP:ForCharacters(function(character, _, generation)
    local present = false
    local function refresh()
        local fields = {}
        for _, child in ipairs(character:GetChildren()) do if child:IsA("ForceField") then table.insert(fields, child) end end
        if #fields == 0 then generation:Drop("bubble"); present = false; return end
        for _, field in ipairs(fields) do generation:Patch(field, "Visible", false) end
        if present then return end
        present = true
        local bubble, shells = generation:Fork("bubble"), {}
        for index, scale in ipairs({7, 7.7}) do
            local shell = bubble:Own(Instance.new("Part"))
            shell.Name, shell.Size = "FF2012", Vector3.new(0.9, 0.9, 0.9)
            shell.Anchored, shell.CanCollide, shell.CanTouch, shell.CanQuery, shell.CastShadow = true, false, false, false, false
            shell.Color, shell.Material, shell.Transparency = Color3.fromRGB(0, 0, 128), Enum.Material.Neon, index == 1 and 0.6 or 0.95
            shell:SetAttribute("BloxyParadoxVisual", true)
            local mesh = bubble:Own(Instance.new("SpecialMesh"))
            mesh.MeshType, mesh.Scale, mesh.Parent = Enum.MeshType.Sphere, Vector3.new(scale, scale, scale), shell
            table.insert(shells, shell)
            local tween = game:GetService("TweenService"):Create(shell, TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {Transparency = index == 1 and 0.95 or 0.6})
            bubble:Add(function() tween:Cancel() end); tween:Play()
        end
        local function follow()
            local root = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
            if root then for _, shell in ipairs(shells) do shell.CFrame = root.CFrame; if not shell.Parent then shell.Parent = workspace end end end
        end
        bubble:Connect(game:GetService("RunService").PreRender, follow); follow()
    end
    generation:Connect(character.ChildAdded, function(child) if child:IsA("ForceField") then refresh() end end)
    generation:Connect(character.ChildRemoved, function(child) if child:IsA("ForceField") then refresh() end end)
    refresh()
end)
]============],
    ["OldSounds"] = [============[-- Original classic audio assets; character generations own their callbacks.
__BP:ForCharacters(function(character, humanoid, generation)
    local root = generation:WaitForChild(character, "HumanoidRootPart")
    local replacements = {Running = true, Jumping = true, Died = true, Climbing = true}
    local function mute(sound)
        if replacements[sound.Name] and (sound:IsA("Sound") or sound:IsA("AudioPlayer")) then generation:Patch(sound, "Volume", 0) end
    end
    for _, sound in ipairs(root:GetChildren()) do mute(sound) end
    generation:Connect(root.ChildAdded, mute)
    local function create(name, id, volume, looped)
        local sound = generation:Own(Instance.new("Sound"))
        sound.Name, sound.SoundId, sound.Volume, sound.Looped = "BP_" .. name, "rbxassetid://" .. id, volume, looped
        sound.Parent = root
        return sound
    end
    local running = create("Running", "174960816", 0.8, true)
    local jumping = create("Jumping", "2428506580", 1, false)
    local died = create("Died", "17755696142", 1, false)
    local climbing = create("Climbing", "7593297942", 0.8, true)
    local speed, climbSpeed = root.AssemblyLinearVelocity.Magnitude, root.AssemblyLinearVelocity.Y
    local function update(sound, enabled)
        if enabled and not sound.IsPlaying then sound:Play() elseif not enabled and sound.IsPlaying then sound:Stop() end
    end
    local function refresh()
        local state = humanoid:GetState()
        update(running, humanoid.Health > 0 and state == Enum.HumanoidStateType.Running and speed > 0.5)
        update(climbing, humanoid.Health > 0 and state == Enum.HumanoidStateType.Climbing and math.abs(climbSpeed) > 0.1)
    end
    generation:Connect(humanoid.Running, function(value) speed = value; refresh() end)
    generation:Connect(humanoid.Climbing, function(value) climbSpeed = value; refresh() end)
    generation:Connect(humanoid.StateChanged, function(_, state) if state == Enum.HumanoidStateType.Jumping then jumping:Play() end; refresh() end)
    generation:Connect(humanoid.Died, function() running:Stop(); climbing:Stop(); died:Play() end)
    refresh()
end)
]============],
    ["SafeChat"] = [============[_G.safeChatVersion="2016"
_G.keyToDestroy=Enum.KeyCode.LeftControl
loadstring(game:HttpGet("bp://safechat"))()
]============],
    ["Textures_2006"] = [============[local style, lighting = getgenv().WorldStyle, game:GetService("Lighting")
local queue, first, last, pending, records = {}, 1, 0, false, {}
local function eligible(part)
    if not part:IsA("BasePart") or part:GetAttribute("BloxyParadoxVisual") then return false end
    local ancestor = part.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Tool") or ancestor:IsA("Accessory") or (ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid")) then return false end
        ancestor = ancestor.Parent
    end
    return part:IsDescendantOf(workspace)
end
local function texture(part, face, id)
    local value = Instance.new("Texture")
    value.Name, value.Texture, value.Face = "BP_Studs", "rbxassetid://" .. id, face
    value.StudsPerTileU, value.StudsPerTileV, value.Parent = 1, 1, part
    return value
end
local function apply(part)
    if records[part] or not eligible(part) then return end
    if style == "2006" then
        __BP:Patch(part, "Material", Enum.Material.Plastic)
        records[part] = {texture(part, Enum.NormalId.Top, "48715260"), texture(part, Enum.NormalId.Bottom, "20299774")}
    elseif part.Material == Enum.Material.Plastic and part.TopSurface == Enum.SurfaceType.Studs and not part:FindFirstChildOfClass("Texture") then
        local value = texture(part, Enum.NormalId.Top, "7027211371")
        value.Color3 = Color3.new(math.min(1, part.Color.R * 2), math.min(1, part.Color.G * 2), math.min(1, part.Color.B * 2))
        records[part] = {value}
    end
end
local function enqueue(part)
    if not part:IsA("BasePart") then return end
    last += 1; queue[last] = part
    if pending then return end
    pending = true
    task.defer(function()
        while first <= last do
            local began, count = os.clock(), 0
            repeat
                local item = queue[first]; queue[first] = nil; first += 1; count += 1
                apply(item)
            until first > last or count >= 64 or os.clock() - began >= 0.0015
            if first <= last then task.wait() end
        end
        first, last, pending = 1, 0, false
    end)
end
workspace.DescendantAdded:Connect(enqueue)
workspace.DescendantRemoving:Connect(function(part)
    local values = records[part]
    if values then records[part] = nil; for _, value in ipairs(values) do value:Destroy() end end
    if __BP.patches[part] then
        for property, record in pairs(__BP.patches[part]) do if part[property] == record.last then part[property] = record.old end end
        __BP.patches[part] = nil
    end
end)
if style == "2006" then
    __BP:Patch(lighting, "ClockTime", 12); __BP:Patch(lighting, "GlobalShadows", false)
    for _, old in ipairs(lighting:GetChildren()) do if old:IsA("Sky") then __BP:Patch(old, "Parent", nil) end end
    local sky = Instance.new("Sky")
    for face, id in pairs({Bk = "161781263", Dn = "161781258", Ft = "161781261", Lf = "161781267", Rt = "161781268", Up = "161781260"}) do sky["Skybox" .. face] = "rbxassetid://" .. id end
    sky.Parent = lighting
else
    __BP:TryHiddenProperty(lighting, "Technology", Enum.Technology.Compatibility)
    __BP:Patch(lighting, "Brightness", 2)
    for _, old in ipairs(lighting:GetChildren()) do if old:IsA("Atmosphere") or old:IsA("DepthOfFieldEffect") then __BP:Patch(old, "Parent", nil) end end
end
for _, part in ipairs(workspace:GetDescendants()) do enqueue(part) end
]============],
    ["Textures_2016"] = [============[local style, lighting = getgenv().WorldStyle, game:GetService("Lighting")
local queue, first, last, pending, records = {}, 1, 0, false, {}
local function eligible(part)
    if not part:IsA("BasePart") or part:GetAttribute("BloxyParadoxVisual") then return false end
    local ancestor = part.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Tool") or ancestor:IsA("Accessory") or (ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid")) then return false end
        ancestor = ancestor.Parent
    end
    return part:IsDescendantOf(workspace)
end
local function texture(part, face, id)
    local value = Instance.new("Texture")
    value.Name, value.Texture, value.Face = "BP_Studs", "rbxassetid://" .. id, face
    value.StudsPerTileU, value.StudsPerTileV, value.Parent = 1, 1, part
    return value
end
local function apply(part)
    if records[part] or not eligible(part) then return end
    if style == "2006" then
        __BP:Patch(part, "Material", Enum.Material.Plastic)
        records[part] = {texture(part, Enum.NormalId.Top, "48715260"), texture(part, Enum.NormalId.Bottom, "20299774")}
    elseif part.Material == Enum.Material.Plastic and part.TopSurface == Enum.SurfaceType.Studs and not part:FindFirstChildOfClass("Texture") then
        local value = texture(part, Enum.NormalId.Top, "7027211371")
        value.Color3 = Color3.new(math.min(1, part.Color.R * 2), math.min(1, part.Color.G * 2), math.min(1, part.Color.B * 2))
        records[part] = {value}
    end
end
local function enqueue(part)
    if not part:IsA("BasePart") then return end
    last += 1; queue[last] = part
    if pending then return end
    pending = true
    task.defer(function()
        while first <= last do
            local began, count = os.clock(), 0
            repeat
                local item = queue[first]; queue[first] = nil; first += 1; count += 1
                apply(item)
            until first > last or count >= 64 or os.clock() - began >= 0.0015
            if first <= last then task.wait() end
        end
        first, last, pending = 1, 0, false
    end)
end
workspace.DescendantAdded:Connect(enqueue)
workspace.DescendantRemoving:Connect(function(part)
    local values = records[part]
    if values then records[part] = nil; for _, value in ipairs(values) do value:Destroy() end end
    if __BP.patches[part] then
        for property, record in pairs(__BP.patches[part]) do if part[property] == record.last then part[property] = record.old end end
        __BP.patches[part] = nil
    end
end)
if style == "2006" then
    __BP:Patch(lighting, "ClockTime", 12); __BP:Patch(lighting, "GlobalShadows", false)
    for _, old in ipairs(lighting:GetChildren()) do if old:IsA("Sky") then __BP:Patch(old, "Parent", nil) end end
    local sky = Instance.new("Sky")
    for face, id in pairs({Bk = "161781263", Dn = "161781258", Ft = "161781261", Lf = "161781267", Rt = "161781268", Up = "161781260"}) do sky["Skybox" .. face] = "rbxassetid://" .. id end
    sky.Parent = lighting
else
    __BP:TryHiddenProperty(lighting, "Technology", Enum.Technology.Compatibility)
    __BP:Patch(lighting, "Brightness", 2)
    for _, old in ipairs(lighting:GetChildren()) do if old:IsA("Atmosphere") or old:IsA("DepthOfFieldEffect") then __BP:Patch(old, "Parent", nil) end end
end
for _, part in ipairs(workspace:GetDescendants()) do enqueue(part) end
]============],
    ["Topbar_2012"] = [============[getgenv().LegacySettings={Year=2012,OldGraphics=true,HideDisplayName=true,SafeChat=false,OldConsole=false,OldBubbleChat=false}
getgenv().SkipClassicChat=false
loadstring(game:HttpGet("bp://legacy"))()
]============],
    ["Topbar_2013"] = [============[getgenv().LegacySettings={Year=2013,OldGraphics=true,HideDisplayName=true,SafeChat=false,OldConsole=false,OldBubbleChat=false}
getgenv().SkipClassicChat=false
loadstring(game:HttpGet("bp://legacy"))()
]============],
    ["Topbar_2014"] = [============[getgenv().LegacySettings={Year=2014,OldGraphics=true,HideDisplayName=true,SafeChat=false,OldConsole=false,OldBubbleChat=false}
getgenv().SkipClassicChat=false
loadstring(game:HttpGet("bp://legacy"))()
]============],
    ["Topbar_2016_A"] = [============[getgenv().LegacySettings={Year=2016,OldGraphics=true,HideDisplayName=true,SafeChat=false,OldConsole=false,OldBubbleChat=false}
getgenv().SkipClassicChat=true
loadstring(game:HttpGet("bp://legacy"))()
]============],
    ["Topbar_2016_S"] = [============[getgenv().LegacySettings={Year=2016,OldGraphics=true,HideDisplayName=true,SafeChat=false,OldConsole=false,OldBubbleChat=false}
getgenv().SkipClassicChat=false
loadstring(game:HttpGet("bp://legacy"))()
]============],
    ["Topbar_2020"] = [============[-- Original Bloxy Paradox 2020 topbar controls and assets.
local Players=game:GetService("Players")
local TweenService=game:GetService("TweenService")
local CoreGui=game:GetService("CoreGui")
local GuiService=game:GetService("GuiService")
local TextChatService=game:GetService("TextChatService")
local LocalPlayer=Players.LocalPlayer
local PlayerGui=LocalPlayer:WaitForChild("PlayerGui",12)
local RobloxGui=CoreGui:WaitForChild("RobloxGui",12)
local settingsApi=loadstring(game:HttpGet("bp://project2016-settings"))()
assert(settingsApi and settingsApi.ToggleVisibility,"Classic settings module did not initialize")
loadstring(game:HttpGet("bp://classic-chat"))()
__BP:HideModernTopbar()
local TopbarGui=Instance.new("ScreenGui")
TopbarGui.Name="BloxyParadox2020"
TopbarGui.IgnoreGuiInset=true
TopbarGui.ResetOnSpawn=false
TopbarGui.DisplayOrder=100
TopbarGui.Parent=CoreGui
local TopBar=Instance.new("Frame")
TopBar.Name="TopBarContainer"
TopBar.Parent=TopbarGui
TopBar.Size=UDim2.new(1,0,0,50)
TopBar.Position=UDim2.fromOffset(0,0)
TopBar.BackgroundTransparency=1
TopBar.ZIndex=10
local SettingsApp=Instance.new("ImageButton")
SettingsApp.Name="Settings"
SettingsApp.Parent=TopBar
SettingsApp.Position=UDim2.new(0,5,0,0)
SettingsApp.Size=UDim2.new(0,38,0,38)
SettingsApp.BackgroundTransparency=0.5
SettingsApp.BackgroundColor3=Color3.new(0,0,0)
SettingsApp.ZIndex=11
local SIcon=Instance.new("ImageLabel")
SIcon.Parent=SettingsApp
SIcon.Size=UDim2.new(1,-7,1,-7)
SIcon.Position=UDim2.new(0,3,0,3)
SIcon.BackgroundTransparency=1
SIcon.Image="rbxassetid://14874733468"
SIcon.ZIndex=12
Instance.new("UICorner",SettingsApp).CornerRadius=UDim.new(0.2,0)
local CloseBtn=Instance.new("TextButton")
CloseBtn.Name="CloseButton"
CloseBtn.Parent=TopBar
CloseBtn.Size=UDim2.new(0,38,0,38)
CloseBtn.Position=UDim2.new(0,5,0,0)
CloseBtn.BackgroundColor3=Color3.new(1,1,1)
CloseBtn.Text="X"
CloseBtn.Visible=false
CloseBtn.TextColor3=Color3.new(0,0,0)
CloseBtn.Font=Enum.Font.SourceSansBold
CloseBtn.TextSize=25
CloseBtn.ZIndex=16
Instance.new("UICorner",CloseBtn).CornerRadius=UDim.new(0.2,0)
local chatOpen=false
local chatContainer=__BP:WaitForChild(PlayerGui,"Chat",12)
local realFrame=chatContainer:WaitForChild("Frame")
realFrame.Visible=false
local ChatApp=Instance.new("ImageButton")
ChatApp.Name="Chat"
ChatApp.Parent=TopBar
ChatApp.Position=UDim2.new(0,55,0,0)
ChatApp.Size=UDim2.new(0,38,0,38)
ChatApp.BackgroundTransparency=0.5
ChatApp.BackgroundColor3=Color3.new(0,0,0)
ChatApp.ZIndex=11
local CIcon=Instance.new("ImageLabel")
CIcon.Parent=ChatApp
CIcon.Size=UDim2.new(1,0,1,0)
CIcon.BackgroundTransparency=1
CIcon.Image="rbxassetid://15839118471"
CIcon.ZIndex=12
Instance.new("UICorner",ChatApp).CornerRadius=UDim.new(0.2,0)
local unread=0
local Badge=Instance.new("Frame")
Badge.Size=UDim2.new(0,20,0,20)
Badge.Position=UDim2.new(1,-13,0,-6)
Badge.BackgroundColor3=Color3.fromRGB(0,0,0)
Badge.Visible=false
Badge.ZIndex=14
Badge.Parent=ChatApp
Instance.new("UICorner",Badge).CornerRadius=UDim.new(1,0)
local BadgeIn=Instance.new("Frame")
BadgeIn.Size=UDim2.new(1,-3,1,-3)
BadgeIn.Position=UDim2.new(0.5,0,0.5,0)
BadgeIn.AnchorPoint=Vector2.new(0.5,0.5)
BadgeIn.BackgroundColor3=Color3.fromRGB(255,255,255)
BadgeIn.ZIndex=15
BadgeIn.Parent=Badge
Instance.new("UICorner",BadgeIn).CornerRadius=UDim.new(1,0)
local BadgeTxt=Instance.new("TextLabel")
BadgeTxt.Size=UDim2.new(1,0,1,0)
BadgeTxt.Position=UDim2.new(0.5,0,0.5,-1)
BadgeTxt.AnchorPoint=Vector2.new(0.5,0.5)
BadgeTxt.BackgroundTransparency=1
BadgeTxt.Text="0"
BadgeTxt.TextColor3=Color3.fromRGB(0,0,0)
BadgeTxt.Font=Enum.Font.SourceSansBold
BadgeTxt.TextSize=15
BadgeTxt.ZIndex=16
BadgeTxt.Parent=BadgeIn
local function updBadge()if chatOpen or unread==0 then Badge.Visible=false else Badge.Visible=true BadgeTxt.Text=unread>=100 and "99+" or tostring(unread)end end

TextChatService.MessageReceived:Connect(function()if not chatOpen then unread=unread+1;updBadge()end end)
ChatApp.MouseButton1Click:Connect(function()chatOpen=not chatOpen;realFrame.Visible=chatOpen;if chatOpen then unread=0;updBadge()end;CIcon.Image=chatOpen and "rbxassetid://15839116089" or "rbxassetid://15839118471"end)
local MoreOpen=false
local MoreApp=Instance.new("ImageButton")
MoreApp.Name="More"
MoreApp.Parent=TopBar
MoreApp.Position=UDim2.new(1,-43,0,0)
MoreApp.Size=UDim2.new(0,38,0,38)
MoreApp.BackgroundTransparency=0.5
MoreApp.BackgroundColor3=Color3.new(0,0,0)
MoreApp.ZIndex=11
local MIcon=Instance.new("ImageLabel")
MIcon.Parent=MoreApp
MIcon.Size=UDim2.new(1,-2,1,-2)
MIcon.Position=UDim2.new(0,1,0,1)
MIcon.BackgroundTransparency=1
MIcon.Image="rbxassetid://136279431647973"
MIcon.ZIndex=12
Instance.new("UICorner",MoreApp).CornerRadius=UDim.new(0.2,0)
local Wip=Instance.new("Frame")
Wip.Size=UDim2.fromScale(1,1)
Wip.Position=UDim2.fromOffset(0,44)
Wip.BackgroundTransparency=1
Wip.ZIndex=40
Wip.Name="Wip"
Wip.Parent=TopbarGui
Wip.Visible=false
local MFrame=Instance.new("ScrollingFrame")
MFrame.Size=UDim2.new(0,300,0,150)
MFrame.Position=UDim2.new(1,-305,0,0)
MFrame.BackgroundColor3=Color3.fromRGB(0,0,0)
MFrame.BackgroundTransparency=0.3
MFrame.CanvasSize=UDim2.new(0,0,0,200)
MFrame.Parent=Wip
Instance.new("UICorner",MFrame).CornerRadius=UDim.new(0.1,0)
local function MakeMore(p,n,i,t,y)local b=Instance.new("ImageButton")b.Name=n b.Size=UDim2.new(1,0,0,50)b.Position=UDim2.new(0,0,0,y)b.BackgroundTransparency=1 b.Parent=p local ic=Instance.new("ImageLabel")ic.Size=UDim2.new(0,45,0,45)ic.Position=UDim2.new(0,10,0,0)ic.BackgroundTransparency=1 ic.Image=i ic.Parent=b local l=Instance.new("TextLabel")l.Parent=b l.Size=UDim2.new(1,-70,0,50)l.Position=UDim2.new(0,70,0,0)l.BackgroundTransparency=1 l.Text=t l.Font=Enum.Font.GothamBold l.TextSize=18 l.TextColor3=Color3.fromRGB(230,230,230)l.TextXAlignment=Enum.TextXAlignment.Left l.TextYAlignment=Enum.TextYAlignment.Center return b end
local LeaderboardBtn=MakeMore(MFrame,"Leaderboard","rbxassetid://81047217774682","Leaderboard",10)
local InventoryBtn=MakeMore(MFrame,"Inventory","rbxassetid://7743874651","Inventory",65)
local EmotesBtn=MakeMore(MFrame,"Emotes","rbxassetid://6031071050","Emotes",120)
MoreApp.MouseButton1Click:Connect(function()MoreOpen=not MoreOpen;Wip.Visible=MoreOpen;MIcon.Image=MoreOpen and "rbxassetid://110209751814466" or "rbxassetid://136279431647973"end)
EmotesBtn.MouseButton1Click:Connect(function()pcall(function()local o=GuiService:GetEmotesMenuOpen();GuiService:SetEmotesMenuOpen(not o)end);MoreOpen=false;Wip.Visible=false;MIcon.Image="rbxassetid://136279431647973"end)

SettingsApp.MouseButton1Click:Connect(function() settingsApi:ToggleVisibility() end)
CloseBtn.MouseButton1Click:Connect(function() settingsApi:SetVisibility(false) end)
LeaderboardBtn.MouseButton1Click:Connect(function() settingsApi:SetVisibility(true); MoreOpen=false; Wip.Visible=false end)
InventoryBtn.MouseButton1Click:Connect(function() __BP:OpenInventory(); MoreOpen=false; Wip.Visible=false end)
local function synchronize()
    local open=settingsApi:GetVisibility()
    SettingsApp.Visible=not open
    CloseBtn.Visible=open
    ChatApp.Visible=not open
    MoreApp.Visible=not open
    realFrame.Visible=chatOpen and not open
    if open then MoreOpen=false; Wip.Visible=false end
end
settingsApi.VisibilityChanged:Connect(synchronize)
synchronize()
]============],
    ["Topbar_OldChat"] = [============[loadstring(game:HttpGet("bp://classic-chat"))()
]============],
}
local URLs = {
    legacy=[============[https://raw.githubusercontent.com/yeku/legacy/5bf6e2dacc743a9cc175ab532e36270f6c07029f/Source.luau]============],
    settings=[============[https://raw.githubusercontent.com/xaviersupreme/Project2016/f7ec68f1671268ec3b52854bf467562ed5661c0a/modules/settings.lua]============],
    safechat=[============[https://raw.githubusercontent.com/mehh0vcki/scripts/6d319e192f7e439f298d369690f47499e88e39e3/safechat.lua]============],
    safechatData=[============[https://raw.githubusercontent.com/mehh0vcki/scripts/6d319e192f7e439f298d369690f47499e88e39e3/static/safechat/2016.lua]============],
    emotes=[============[https://raw.githubusercontent.com/7yd7/Hub/d8cb76797c774b456b0a3c3560e0668ecf2845dd/GUIS/Emotes.lua]============],
    emoteSettings=[============[https://raw.githubusercontent.com/7yd7/Hub/d8cb76797c774b456b0a3c3560e0668ecf2845dd/GUIS/Settings.lua]============],
    openEmote=[============[https://raw.githubusercontent.com/7yd7/Hub/d8cb76797c774b456b0a3c3560e0668ecf2845dd/GUIS/OpenEmote.lua]============],
    notify=[============[https://raw.githubusercontent.com/7yd7/Menu-7yd7/e81a1629d810f5c88a235270c76b97c9c04aecec/GUIS/Off-site/Notify.lua]============],
}
local Embedded = {
suite=[============[--[[
-- RBXM Suite is a tool designed to help run a Roblox model in an executor's environment.
--
-- Author: 0866
-- License: MIT
-- GitHub: https://github.com/richie0866/rbxm-suite/
--]]

---@class Options
---@field runscripts     boolean Run LocalScripts on launch. Defaults to true.
---@field deferred       boolean Whether to defer or spawn scripts on launch. Defaults to true.
---@field nocache        boolean Disable caching Roblox library models. Defaults to false.
---@field nocirculardeps boolean Prevent circular dependency crashes. Defaults to true.
---@field debug          boolean Enable detailed error traceback. Defaults to false.
---@field verbose        boolean Enable verbose mode. Defaults to false.

local PROGRAM_NAME = "rbxm-suite"
local PROGRAM_STORAGE = "_rbxm-suite-v2"
local PROGRAM_TEMP = PROGRAM_STORAGE .. "/temp.dat"

local HttpService = game:GetService("HttpService")

local pathToUrl = getcustomasset or getsynasset or error("Failed to load model! (No custom asset loader found)")

local function useGlobal(key, initialValue)
	local value = getgenv(key)["__rbxm_suite_" .. key]

	if value == nil then
		value = initialValue
		getgenv(key)["__rbxm_suite_" .. key] = value
	end

	return value
end

local function useOption(option, defaultValue)
	if option == nil then
		return defaultValue
	else
		return option
	end
end

local function httpGet(url)
	local response, code = game:HttpGet(url)

	return assert(response, "Error " .. tostring(code) .. ": Failed to GET from " .. url)
end

local function log(message, isVerbose)
	if isVerbose then
		print(message)
	end
end

-- GitHub integration

local github do
	github = {}

	local function init()
		if not isfolder(PROGRAM_STORAGE) then
			makefolder(PROGRAM_STORAGE)
			makefolder(PROGRAM_STORAGE .. "/models")
			writefile(PROGRAM_STORAGE .. "/latest.json", "{}")
		end
	end

	local function updateLatestJson(mutate)
		local data = readfile(PROGRAM_STORAGE .. "/latest.json")
		local versions = HttpService:JSONDecode(data)

		mutate(versions)

		writefile(PROGRAM_STORAGE .. "/latest.json", HttpService:JSONEncode(versions))
	end

	local function getLocalTag(id)
		local data = readfile(PROGRAM_STORAGE .. "/latest.json")
		local versions = HttpService:JSONDecode(data)

		return versions[id]
	end

	local function fetchLatestTag(user, repo)
		local response = httpGet("https://api.github.com/repos/" .. user .. "/" .. repo .. "/releases/latest")

		return HttpService:JSONDecode(response).tag_name
	end

	local function downloadLatest(user, repo, asset, id, path)
		local latestTag = fetchLatestTag(user, repo)

		if isfile(path) and getLocalTag(id) == latestTag then
			return path
		end

		local response = httpGet("https://github.com/" .. user .. "/" .. repo .. "/releases/latest/download/" .. asset)

		writefile(path, response)

		updateLatestJson(function(versions)
			versions[id] = latestTag
		end)
	end

	function github.download(user, repo, tag, asset)
		local id = string.gsub(table.concat({user, repo, tag, asset}, "-"), "[^a-zA-Z0-9_%-]", "_")
		local path = PROGRAM_STORAGE .. "/models/" .. id .. ".rbxm"

		if tag == "latest" then
			if isfile(path) then
				-- Perform a deferred update. This function does not need to yield if a
				-- latest version is already present.
				task.defer(downloadLatest, user, repo, asset, id, path)
			else
				downloadLatest(user, repo, asset, id, path)
			end

			return path
		end

		if isfile(path) then
			return path
		end

		local response = httpGet("https://github.com/" .. user .. "/" .. repo .. "/releases/download/" .. tag .. "/" .. asset)

		writefile(path, response)

		return path
	end

	function github.clearCache()
		delfolder(PROGRAM_STORAGE)
		init()
	end

	init()
end

-- Module resolution

local modules = useGlobal("modules", {})
local currentlyLoading = {}

local idToScript = useGlobal("idToScript", {})
local scriptToId = useGlobal("scriptToId", {})
local globalMap = useGlobal("globalMap", {})

local function loadModule(object, caller, allowRecursion)
	local module = modules[object]

	if module.isLoaded then
		return module.data
	end

	if caller and not allowRecursion then
		currentlyLoading[caller] = object

		local currentObject = object
		local depth = 0

		-- Keep looping until we reach the top of the dependency chain.
		-- Throw an error if we encounter a circular dependency.
		while currentObject do
			depth = depth + 1
			currentObject = currentlyLoading[currentObject]

			if currentObject == object then
				local str = currentObject:GetFullName()

				for _ = 1, depth do
					currentObject = currentlyLoading[currentObject]
					str = str .. "  ⇒ " .. currentObject:GetFullName()
				end

				error("Failed to load '" .. object:GetFullName() .. "'! Detected a circular dependency chain: " .. str, 2)
			end
		end
	end

	local data = module.fn()

	if currentlyLoading[caller] == object then -- Thread-safe cleanup!
		currentlyLoading[caller] = nil
	end

	module.data = data
	module.isLoaded = true

	return data
end

-- Module source bundler

local function createOutputStream()
	local output = {}

	local function push(str)
		table.insert(output, str)
	end

	local function concat()
		return table.concat(output)
	end

	return {
		push = push,
		concat = concat,
	}
end

local function registerModule(object, allowRecursion)
	local id = HttpService:GenerateGUID()

	local function requireImpl(target)
		if typeof(target) == "Instance" and modules[target] then
			return loadModule(target, object, allowRecursion)
		else
			return require(target)
		end
	end

	modules[object] = {
		data = nil,
		fn = nil,
		isLoaded = false,
	}

	idToScript[id] = object
	scriptToId[object] = id

	globalMap[id] = {object, requireImpl}

	return id
end

local function pushHeader(stream)
	stream.push("local modules, globalMap, idToScript = ...")
end

local function pushModule(object, stream, options)
	if not object:IsA("LocalScript") and not object:IsA("ModuleScript") then
		return
	end

	local id = string.format("%q", registerModule(object, not options.nocirculardeps))
	local path = string.format("%q", "@" .. PROGRAM_NAME .. "." .. object:GetFullName())

	if options.debug then
		-- Localize globals to avoid setfenv() optimization issues.
		object.Source = "local script, require = unpack((...)[" .. id .. "]); " .. object.Source

		-- Preserve error traceback and lazy-loading.
		stream.push(
			"modules[idToScript[" .. id .. "]].fn = function ()\n" ..
			"local fn, err = loadstring(idToScript[" .. id .. "].Source, " .. path .. ")\n" ..
			"return assert(fn, err)(globalMap)\n" ..
			"end\n"
		)

		return
	end

	-- Localize globals to avoid setfenv() optimization issues.
	object.Source = "local script, require = unpack(globalMap[" .. id .. "]); " .. object.Source

	-- Error traceback is not preserved, but the source loads immediately.
	stream.push("modules[idToScript[" .. id .. "]].fn = function ()\n" .. object.Source .. "\nend\n")
end

-- Runtime

local function getObjectsNoCache(url, isVerbose)
	local assetId = string.match(url, "^rbxassetid://(%d+)$")

	if not assetId then
		return game:GetObjects(url)
	end

	local data = HttpService:JSONDecode(httpGet("https://assetdelivery.roblox.com/v2/assetId/" .. assetId))
	local rbxmData = httpGet(data.locations[1].location)

	if rbxmData == "" then
		log("⚠️ Model data for asset " .. assetId .. " is blank!", isVerbose)
		return game:GetObjects(url)
	end

	-- Create a temporary file to store the asset.
	writefile(PROGRAM_TEMP, rbxmData)

	local success, result = pcall(function()
		return game:GetObjects(pathToUrl(PROGRAM_TEMP))
	end)

	delfile(PROGRAM_TEMP)

	if not success then
		log("⚠️ Model data for asset " .. assetId .. " failed to load! " .. tostring(result), isVerbose)
		return game:GetObjects(url)
	end

	return result
end

local function getObjects(url, options)
	if string.find(url, "^rbxassetid://") then
		if options.nocache then
			return getObjectsNoCache(url, options.verbose)
		end

		return game:GetObjects(url)
	else
		return game:GetObjects(pathToUrl(url))
	end
end

local function hydrate(stream, model, options)
	pushModule(model, stream, options)

	for _, object in ipairs(model:GetDescendants()) do
		pushModule(object, stream, options)
	end
end

local function initialize(stream)
	assert(loadstring(stream.concat(), "@" .. PROGRAM_NAME))(modules, globalMap, idToScript)
end

local function startScript(object, index, options)
	local spawn = options.deferred and task.defer or task.spawn

	spawn(function()
		log("ℹ️ " .. index .. " Running " .. object:GetFullName(), options.verbose)

		loadModule(object)

		log("✅ " .. index .. " Done!", options.verbose)
	end)
end

local function startScripts(model, options)
	local scripts = 0

	if model:IsA("LocalScript") and not model.Disabled then
		scripts = scripts + 1
		startScript(model, scripts, options)
	end

	for _, object in ipairs(model:GetDescendants()) do
		if object:IsA("LocalScript") and not object.Disabled then
			scripts = scripts + 1
			startScript(object, scripts, options)
		end
	end
end

-- RBXM Suite

---Inserts a model into the game. Loads every module in the model. Returns a
---list of models returned by `game.GetObjects()`.
---@param url string
---@param opt? Options
---@return Instance[]
local function launch(url, opt)
	assert(type(url) == "string", "The first argument 'url' must be a string.")
	assert(type(opt) == "table" or opt == nil, "The second argument 'options' must be a table or nil.")

	opt = opt or {}

	local options = {
		runscripts     = useOption(opt.runscripts, true),
		deferred       = useOption(opt.deferred, true),
		nocache        = useOption(opt.nocache, false),
		nocirculardeps = useOption(opt.nocirculardeps, true),
		debug          = useOption(opt.debug, false),
		verbose        = useOption(opt.verbose, false),
	}

	log("\n\n" .. utf8.char(0x1F680) .. " Launching file '" .. url .. "'\n", options.verbose)

	local clock = os.clock()

	local objects = getObjects(url, options)
	local stream = createOutputStream()

	-- Add the header for localizing globals.
	pushHeader(stream)

	-- Generate module sources.
	for _, model in ipairs(objects) do
		hydrate(stream, model, options)
	end

	-- Registers every module to the 'modules' table.
	initialize(stream)

	-- Run every LocalScript in the models.
	if options.runscripts then
		for _, model in ipairs(objects) do
			startScripts(model, options)
		end
	end

	log("\n\n" .. utf8.char(0x1F389) .. " Done! Took " .. string.format("%.2f", (os.clock() - clock) * 1000) .. " milliseconds.\n", options.verbose)

	return unpack(objects)
end

---Runs the given module or script object and returns the result. The module
---must be registered with `launch()` before calling this function.
---@param object LocalScript | ModuleScript
---@return any
local function require(object)
	assert(typeof(object) == "Instance", "The script must be an Instance.")
	assert(object:IsA("LuaSourceContainer"), "The script must be a Lua module or script.")
	assert(modules[object], "The script must be registered with rbxmSuite.")

	return loadModule(object)
end

---Downloads a model asset from a GitHub Release. Returns a path to the file.
---If a previous version of the asset is already downloaded, the path will be
---returned and updated in the background. Otherwise, this function yields.
---@param repo string `user/repo@tag`, `user/repo@latest`, `user/repo`
---@param asset string
---@return string
local function download(repository, asset)
	local user, repo, tag = string.match(repository, "([^/]+)/([^@]+)@?(.*)")

	assert(user and repo, "Invalid repository format.")
	assert(type(asset) == "string", "The asset must be a string.")

	if tag == "" or tag == nil then
		tag = "latest"
	end

	return github.download(user, repo, tag, asset)
end

---Clears the cache of downloaded assets.
local function clearCache()
	return github.clearCache()
end

return {
	launch = launch,
	require = require,
	download = download,
	clearCache = clearCache,
}
]============],
legacy=[============[--[[
 ___       _______   ________  ________  ________      ___    ___ 
|\  \     |\  ___ \ |\   ____\|\   __  \|\   ____\    |\  \  /  /|
\ \  \    \ \   __/|\ \  \___|\ \  \|\  \ \  \___|    \ \  \/  / /
 \ \  \    \ \  \_|/_\ \  \  __\ \   __  \ \  \        \ \    / / 
  \ \  \____\ \  \_|\ \ \  \|\  \ \  \ \  \ \  \____    \/   / /  
   \ \_______\ \_______\ \_______\ \__\ \__\ \_______\__/   / /   
    \|_______|\|_______|\|_______|\|__|\|__|\|_______|\____/ /    
                                                     \|____|/     
                                                                  
> github.com/yeku/legacy
>> a ROBLOX coregui changer that lets you use older designs
[!] only supports 2012, 2013, 2014, 2015, 2016
]]

if (not game:IsLoaded()) then
	game.Loaded:Wait()
end

-- Settings
local Developer = (isfile and (isfile("yeku.txt") and isfile("Legacy.rbxm")))
local Environment = (getgenv or function() return _G end)
local Settings = Environment().LegacySettings or ({
	Year = 2012,
	OldGraphics = true,
	HideDisplayName = true,
	SafeChat = true,
	OldConsole = true,
	OldBubbleChat = true,
})

-- Services
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")
local TextChatService = game:GetService("TextChatService")

-- Variables
local RobloxGui = CoreGui:WaitForChild("RobloxGui")
local ChatBubbles = CoreGui:WaitForChild("ExperienceChat"):WaitForChild("bubbleChat")

-- Types
export type Properties = { [string]: any }

-- Functions
local Force = function(Object: Instance, Property: string, Value: any)
	if (Object[Property] ~= Value) then
		Object[Property] = Value
	end

	Object:GetPropertyChangedSignal(Property):Connect(function()
		if (Object[Property] ~= Value) then
			Object[Property] = Value
		end
	end)
end

local Set = function(Object: Instance, Properties: Properties, Forced: boolean)
	if (not Object) then
		return
	end

	for Property, Value in next, Properties do
		local Success, Result = pcall(function()
			Object[Property] = Value

			if (Forced) then
				Force(Object, Property, Value)
			end
		end)

		if (not Success) then
			warn(`{Result} | {debug.traceback()}`)
		end
	end
end

local Create = function(ClassName: string, Properties: Properties, Forced: boolean, Parent: Instance?)
	local Object = Instance.new(ClassName)

	if (Parent) then
		Object.Parent = Parent
	end

	Set(Object, Properties, Forced)

	return Object
end

local Run = function(Bool: boolean, Callback: () -> ())
	if (Bool) then
		task.spawn(Callback)
	end
end

-- Module
local Suite = Environment().Suite or loadstring(game:HttpGet("https://raw.githubusercontent.com/yeku/forks/refs/heads/main/Scripts/RBXMSuite.luau"))()
local Legacy = (function()
	local Path do
		if (Developer) then
			StarterGui:SetCore("SendNotification", { Title = "Legacy", Text = "Running the developer build", Duration = 5 })
			Path = "Legacy.rbxm"
		else
			local RBXM = Suite.download("yeku/legacy@latest", "Legacy.rbxm")
			Path = RBXM
		end
	end

	return Suite.launch(Path, { runscripts = true, debug = true })
end)()

-- Setup
local LegacyGui = Suite.require(Legacy):Start(Settings.Year, Settings.SafeChat)

RobloxGui.Enabled = false
RobloxGui.NotificationFrame.Parent = LegacyGui

Run(Settings.OldConsole == true, function()
	loadstring(game:HttpGet("https://raw.githubusercontent.com/yeku/forks/refs/heads/main/Scripts/LegacyConsole.luau"))()
end)

Run(Settings.OldGraphics == true, function()
	if (sethiddenproperty) then
		task.spawn(sethiddenproperty, Lighting, "Technology", Enum.Technology.Compatibility)
	end

	for _, Hidden in next, Lighting:QueryDescendants("> DepthOfFieldEffect, > SunRaysEffect, > BloomEffect, > BlurEffect, > ColorCorrectionEffect, > Atmosphere") do
		if (Hidden:IsA("Atmosphere")) then
			Hidden:Destroy()
		else
			Force(Hidden, "Enabled", false)
		end
	end

	Create("ColorGradingEffect", { TonemapperPreset = Enum.TonemapperPreset.Retro })
	Create("ColorCorrectionEffect", {
		Saturation = 0,
		Contrast = -0.1,
		Parent = Lighting,
	})
end)

Run(Settings.OldBubbleChat == true, function()
	-- Variables
	local BubbleChatConfiguration = TextChatService:WaitForChild("BubbleChatConfiguration")
	local SourceSans = Font.fromEnum(Enum.Font.SourceSans)
	local Size = UDim2.fromOffset(46, 35)
	local PaddingData = ({ 
		PaddingBottom = UDim.new(0, 4),
		PaddingTop = UDim.new(0, 4),
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
	})

	-- Functions
	local ConvertTail = function(Tail)
		if (Tail) then
			Set(Tail, {
				Size = UDim2.fromOffset(25, 10),
				ImageTransparency = 0,
				Image = "rbxassetid://89395716827984"
			})
		end
	end

	local ConvertDistantBubble = function(DistantBubble)
		local RoundedFrame = (DistantBubble and DistantBubble:FindFirstChild("RoundedFrame"))
		local Corner = (RoundedFrame and RoundedFrame:FindFirstChildOfClass("UICorner"))
		local Contents = (RoundedFrame and RoundedFrame:FindFirstChild("Contents"))
		local Padding = (Contents and Contents:FindFirstChildOfClass("UIPadding"))
		local Ellipsis = (Contents and Contents:FindFirstChildOfClass("TextLabel"))

		ConvertTail(DistantBubble:FindFirstChild("Carat"))
		Set(DistantBubble, { Size = Size }, true)
		Set(RoundedFrame, { Size = Size }, true)
		Set(Contents, { Size = Size }, true)
		Set(Corner, { CornerRadius = UDim.new(0, 5) })
		Set(Padding, PaddingData)
		Set(Ellipsis, {
			FontFace = SourceSans,
			TextSize = 22,
			TextColor3 = Color3.fromRGB(60, 68, 75),
			TextTransparency = 0,
		}, true)
	end

	local Convert = function(Object: Instance)
		if (Object.Name == "Caret") then
			ConvertTail(Object)
		elseif (Object.Name == "DistantBubble") then
			ConvertDistantBubble(Object)
		end
	end

	-- Setup
	Set(BubbleChatConfiguration, {
		FontFace = SourceSans,
		TextSize = 22,
		TextColor3 = Color3.fromRGB(60, 68, 75),
		BackgroundTransparency = 0,
		LocalPlayerStudsOffset = Vector3.new(0, 0.4, 0),
	}, true)

	Create("UICorner", { Parent = BubbleChatConfiguration, CornerRadius = UDim.new(0, 5) })
	Create("UIPadding", PaddingData, false, BubbleChatConfiguration)

	for _, Object in next, ChatBubbles:QueryDescendants(`#Caret, #DistantBubble`) do
		Convert(Object)
	end

	ChatBubbles.DescendantAdded:Connect(Convert)
end)

Run(Settings.HideDisplayName, function()
	-- Functions
	local Change = function(Player)
		local Character = (Player.Character or Player.CharacterAdded:Wait())
		local Humanoid = (Character and Character:FindFirstChildOfClass("Humanoid"))

		if (Humanoid and Humanoid.DisplayName == Player.DisplayName) then
			Humanoid.DisplayName = Player.Name
		else
			Character.ChildAdded:Connect(function(Humanoid)
				if (Humanoid:IsA("Humanoid") and Humanoid.DisplayName == Player.DisplayName) then
					Humanoid.DisplayName = Player.Name
				end
			end)
		end
	end

	local Joined = function(Player)
		Change(Player)
		Player.CharacterAdded:Connect(function()
			Change(Player)
		end)
	end

	-- Setup
	for _, Player in next, Players:GetPlayers() do
		task.spawn(Joined, Player)
	end

	Players.PlayerAdded:Connect(Joined)
end)

task.spawn(function()
	local TopBarApp = CoreGui:WaitForChild("TopBarApp", 10):WaitForChild("TopBarApp", 10)
	Force(TopBarApp, "Enabled", false)
end)

task.spawn(function()
	local SettingsShield = RobloxGui:WaitForChild("SettingsClippingShield"):WaitForChild("SettingsShield")
	local Modal = (SettingsShield and SettingsShield:WaitForChild("Modal"))

	if (Modal) then
		Set(Modal, {
			Visible = false,
			Modal = false,
		}, true)
	end
end)

task.spawn(function()
	local ControlFrame = RobloxGui:WaitForChild("ControlFrame", 10)

	if (ControlFrame) then
		ControlFrame:Destroy()
	end
end)
]============],
settings=[============[local CoreGui = game:GetService("CoreGui")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local SoundService = game:GetService("SoundService")
local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")
local VirtualInputManager = nil

pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

local LocalPlayer = Players.LocalPlayer
local GameSettings = UserSettings().GameSettings
local RenderingSettings = settings().Rendering

local Spawn, Wait = task.spawn, task.wait
local Insert = table.insert
local Clamp, Floor = math.clamp, math.floor

local SETTINGS_SHIELD_COLOR = Color3.new(41 / 255, 41 / 255, 41 / 255)
local SETTINGS_SHIELD_TRANSPARENCY = 0.2
local SETTINGS_BASE_ZINDEX = 200
local SETTINGS_INACTIVE_POSITION = UDim2.new(0, 0, -1, -36)
local SETTINGS_ACTIVE_POSITION = UDim2.new(0, 0, 0, 0)

local BUTTON_IMAGE = "rbxasset://textures/ui/Settings/MenuBarAssets/MenuButton.png"
local BUTTON_SELECTED_IMAGE = "rbxasset://textures/ui/Settings/MenuBarAssets/MenuButtonSelected.png"
local TAB_BAR_IMAGE = "rbxasset://textures/ui/Settings/MenuBarAssets/MenuBackground.png"
local TAB_SELECTION_IMAGE = "rbxasset://textures/ui/Settings/MenuBarAssets/MenuSelection.png"
local DROP_DOWN_IMAGE = "rbxasset://textures/ui/Settings/DropDown/DropDown.png"
local SLIDER_SELECTED_LEFT_IMAGE = "rbxasset://textures/ui/Settings/Slider/SelectedBarLeft.png"
local SLIDER_SELECTED_RIGHT_IMAGE = "rbxasset://textures/ui/Settings/Slider/SelectedBarRight.png"
local SLIDER_LEFT_IMAGE = "rbxasset://textures/ui/Settings/Slider/BarLeft.png"
local SLIDER_RIGHT_IMAGE = "rbxasset://textures/ui/Settings/Slider/BarRight.png"
local PLAYER_LIST_OFFSET = 20
local DESCRIPTION_PLACEHOLDER = "Short Description (Optional)"
local REPORT_DESCRIPTION_FALLBACK = "Report Reason"
local PAGE_TOP_PADDING = 12
local KEY_F12 = 0x7B
local KEY_PRINT_SCREEN = 0x2C

local ABUSE_TYPES_PLAYER = {
	"Swearing",
	"Inappropriate Username",
	"Bullying",
	"Scamming",
	"Dating",
	"Cheating/Exploiting",
	"Personal Question",
	"Offsite Links",
}

local ABUSE_TYPES_GAME = {
	"Inappropriate Content",
	"Bad Model or Script",
	"Offsite Link",
}

local GetHeadshot = function(Player)
	return "http://www.roblox.com/Thumbs/Avatar.ashx?x=100&y=100&userId="
		.. tostring(math.max(1, Player.UserId or Player.userId or 1))
end

if getgenv().Settings2016Data then
	for _, Connection in next, (getgenv().Settings2016Data.Connections or {}) do
		pcall(function()
			Connection:Disconnect()
		end)
	end

	for _, Object in next, (getgenv().Settings2016Data.Objects or {}) do
		pcall(function()
			Object:Destroy()
		end)
	end
end

local Data = {
	Connections = {},
	Objects = {},
}
getgenv().Settings2016Data = Data

for _, Object in next, CoreGui:GetChildren() do
	if Object.Name == "Settings2016Gui" or Object.Name == "Core2016SettingsGui" then
		Object:Destroy()
	end
end

local Connect = function(Signal, Callback)
	local Connection = Signal:Connect(Callback)
	Insert(Data.Connections, Connection)
	return Connection
end

local Create = function(Class: string, Properties: { [string]: any })
	local Object = Instance.new(Class)

	for Property, Value in next, (Properties or {}) do
		Object[Property] = Value
	end

	return Object
end

local Protect = function(Callback)
	local Success = pcall(Callback)

	return Success
end

local FadeText = function(Label, Transparency)
	Spawn(function()
		local Start = Label.TextTransparency

		for Index = 1, 6 do
			if not Label.Parent then
				return
			end

			Label.TextTransparency = Start + ((Transparency - Start) * (Index / 6))
			Wait()
		end
	end)
end

local LerpUDim = function(Start, Goal, Alpha)
	return UDim.new(
		Start.Scale + ((Goal.Scale - Start.Scale) * Alpha),
		Start.Offset + ((Goal.Offset - Start.Offset) * Alpha)
	)
end

local LerpUDim2 = function(Start, Goal, Alpha)
	return UDim2.new(LerpUDim(Start.X, Goal.X, Alpha), LerpUDim(Start.Y, Goal.Y, Alpha))
end

local LerpColor = function(Start, Goal, Alpha)
	return Color3.new(
		Start.R + ((Goal.R - Start.R) * Alpha),
		Start.G + ((Goal.G - Start.G) * Alpha),
		Start.B + ((Goal.B - Start.B) * Alpha)
	)
end

local MoveTweens = {}
local MoveTo = function(Object, Position, Callback, Frames)
	MoveTweens[Object] = (MoveTweens[Object] or 0) + 1
	local Id = MoveTweens[Object]

	Spawn(function()
		local Start = Object.Position
		Frames = Frames or 8

		for Index = 1, Frames do
			if not Object.Parent or MoveTweens[Object] ~= Id then
				return
			end

			local Alpha = Index / Frames
			Alpha = 1 - ((1 - Alpha) * (1 - Alpha))
			Object.Position = LerpUDim2(Start, Position, Alpha)
			Wait()
		end

		Object.Position = Position

		if Callback and MoveTweens[Object] == Id then
			Callback()
		end
	end)
end

local TweenTo = function(Object, Position, Direction, Style, Time, Callback)
	MoveTweens[Object] = (MoveTweens[Object] or 0) + 1
	local Id = MoveTweens[Object]

	local Success = Protect(function()
		Object:TweenPosition(Position, Direction, Style, Time, true, function()
			if MoveTweens[Object] ~= Id then
				return
			end

			Object.Position = Position

			if Callback then
				Callback()
			end
		end)
	end)

	if not Success then
		MoveTo(Object, Position, Callback, math.max(1, Floor((Time or 0.1) * 60)))
	end
end

local ColorTweens = {}
local ColorTo = function(Object, Color)
	ColorTweens[Object] = (ColorTweens[Object] or 0) + 1
	local Id = ColorTweens[Object]

	Spawn(function()
		local Start = Object.BackgroundColor3

		for Index = 1, 5 do
			if not Object.Parent or ColorTweens[Object] ~= Id then
				return
			end

			Object.BackgroundColor3 = LerpColor(Start, Color, Index / 5)
			Wait()
		end
	end)
end

local SetMouseSensitivity = function(Value)
	Protect(function()
		UserSettings().GameSettings.MouseSensitivity = Value
	end)

	Protect(function()
		UserInputService.MouseDeltaSensitivity = Value
	end)
end

local SetMasterVolume = function(Value)
	Protect(function()
		UserSettings().GameSettings.MasterVolume = Value
	end)

	Protect(function()
		SoundService.Volume = Value
	end)
end

local ScreenGui = Create("ScreenGui", {
	Name = "Settings2016Gui",
	Parent = CoreGui,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 9000,
	Enabled = true,
})
Insert(Data.Objects, ScreenGui)

local VolumeChangeSound = Create("Sound", {
	Name = "VolumeChangeSound",
	Parent = SoundService,
	SoundId = "rbxasset://sounds/uuhhh.mp3",
	Volume = 1,
})
Insert(Data.Objects, VolumeChangeSound)

local PlayVolumeChangeSound = function()
	Protect(function()
		VolumeChangeSound:Stop()
		VolumeChangeSound:Play()
	end)
end

local MakeText = function(Parent, Text, Size, Position)
	return Create("TextLabel", {
		Parent = Parent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = Size,
		Position = Position or UDim2.new(),
		Font = Enum.Font.SourceSansBold,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		Text = Text,
		TextWrapped = true,
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})
end

local MakeStyledButton = function(Name, Text, Size, Clicked)
	local Button = Create("ImageButton", {
		Name = Name,
		Image = BUTTON_IMAGE,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(8, 6, 46, 44),
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = Size,
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	local Label = Create("TextLabel", {
		Name = Name .. "TextLabel",
		Parent = Button,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -8),
		Position = UDim2.new(0, 0, 0, 0),
		Font = Enum.Font.SourceSansBold,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Text = Text,
		TextWrapped = true,
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Connect(Button.MouseEnter, function()
		Button.Image = BUTTON_SELECTED_IMAGE
	end)

	Connect(Button.MouseLeave, function()
		Button.Image = BUTTON_IMAGE
	end)

	if Clicked then
		Connect(Button.MouseButton1Click, Clicked)
	end

	return Button, Label
end

local MakePage = function(Name)
	local Page = {
		Name = Name,
		Rows = {},
		NextY = 0,
		Frame = Create("Frame", {
			Name = Name .. "Page",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 0),
			Visible = false,
			ZIndex = SETTINGS_BASE_ZINDEX + 1,
		}),
	}

	function Page:AddRow(Row)
		Row.Parent = self.Frame
		Row.Position = UDim2.new(0, 0, 0, self.NextY)
		Insert(self.Rows, Row)
		self.NextY = self.NextY + math.max(1, Row.Size.Y.Offset)
		self.Frame.Size = UDim2.new(1, 0, 0, PAGE_TOP_PADDING + self.NextY)
	end

	return Page
end

local Hub = {
	Visible = false,
	Pages = {},
	MenuStack = {},
	CurrentPage = nil,
	NativeMenuTarget = nil,
	SuppressNativeOpenUntil = 0,
}

local ClippingShield = Create("Frame", {
	Name = "SettingsShield",
	Parent = ScreenGui,
	Size = UDim2.new(1, 0, 1, 0),
	Position = SETTINGS_ACTIVE_POSITION,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	ZIndex = SETTINGS_BASE_ZINDEX,
})

Hub.Shield = Create("Frame", {
	Name = "SettingsShield",
	Parent = ClippingShield,
	Size = UDim2.new(1, 0, 1, 0),
	Position = SETTINGS_INACTIVE_POSITION,
	BackgroundColor3 = SETTINGS_SHIELD_COLOR,
	BackgroundTransparency = SETTINGS_SHIELD_TRANSPARENCY,
	BorderSizePixel = 0,
	Visible = false,
	Active = true,
	ZIndex = SETTINGS_BASE_ZINDEX,
})

Hub.Modal = Create("TextButton", {
	Name = "Modal",
	Parent = Hub.Shield,
	BackgroundTransparency = 1,
	Position = UDim2.new(0, 0, 0, 0),
	Size = UDim2.new(1, 0, 1, 0),
	Text = "",
	Active = true,
	AutoButtonColor = false,
	Modal = true,
	ZIndex = SETTINGS_BASE_ZINDEX,
})

Hub.HubBar = Create("ImageLabel", {
	Name = "HubBar",
	Parent = Hub.Shield,
	Image = TAB_BAR_IMAGE,
	ScaleType = Enum.ScaleType.Slice,
	SliceCenter = Rect.new(4, 4, 6, 6),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.new(0, 800, 0, 60),
	Position = UDim2.new(0.5, -400, 0.1, 0),
	ZIndex = SETTINGS_BASE_ZINDEX + 1,
})

Hub.PageClipper = Create("Frame", {
	Name = "PageViewClipper",
	Parent = Hub.Shield,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Size = UDim2.new(0, 800, 0, 420),
	Position = UDim2.new(0.5, -400, 0.1, 61),
	ZIndex = SETTINGS_BASE_ZINDEX + 1,
})

Hub.PageView = Create("ScrollingFrame", {
	Name = "PageView",
	Parent = Hub.PageClipper,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 1, 0),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	ScrollBarThickness = 6,
	ZIndex = SETTINGS_BASE_ZINDEX + 1,
})

Hub.BottomButtonFrame = Create("Frame", {
	Name = "BottomButtonFrame",
	Parent = Hub.Shield,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.new(0, 800, 0, 60),
	Position = UDim2.new(0.5, -400, 0.9, -60),
	ZIndex = SETTINGS_BASE_ZINDEX + 1,
})

local ResizeHub = function()
	local Viewport = ScreenGui.AbsoluteSize

	if Viewport.X <= 0 or Viewport.Y <= 0 then
		local Camera = workspace.CurrentCamera
		Viewport = (Camera and Camera.ViewportSize) or Vector2.new(1280, 720)
	end

	local Width = (Viewport.X < 820 and Clamp(Viewport.X - 10, 520, 800)) or 800
	local BarHeight = 60
	local LargestPageSize = 600
	local MinimumPageSize = 150
	local BufferSize = 0.05 * Viewport.Y
	local ExtraSpace = (BufferSize * 2) + (BarHeight * 2)
	local UsableScreenHeight = Viewport.Y - ExtraSpace
	local Height = Clamp(UsableScreenHeight, MinimumPageSize, LargestPageSize)

	Hub.HubBar.Size = UDim2.new(0, Width, 0, BarHeight)
	Hub.HubBar.Position = UDim2.new(0.5, -Width / 2, 0.5, -Height / 2 - BarHeight)
	Hub.PageClipper.Size = UDim2.new(0, Width, 0, Height)
	Hub.PageClipper.Position = UDim2.new(0.5, -Width / 2, 0.5, -Height / 2)
	Hub.BottomButtonFrame.Size = UDim2.new(0, Width, 0, BarHeight)
	Hub.BottomButtonFrame.Position = UDim2.new(0.5, -Width / 2, 0.5, Height / 2)
end

ResizeHub()
Connect(ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), ResizeHub)
Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), ResizeHub)
if workspace.CurrentCamera then
	Connect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), ResizeHub)
end

local SwitchToPage
local SetVisibility

local MakeTab = function(Page, Title, Icon, Width)
	local Tab = Create("TextButton", {
		Name = Page.Name .. "Tab",
		Parent = Hub.HubBar,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.new(0, Width or 160, 1, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	local IconLabel = Create("ImageLabel", {
		Name = "Icon",
		Parent = Tab,
		BackgroundTransparency = 1,
		Image = Icon,
		ImageTransparency = 0.5,
		Size = UDim2.new(0, 44, 0, 44),
		Position = UDim2.new(0, 12, 0.5, -22),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("TextLabel", {
		Name = "Title",
		Parent = IconLabel,
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSansBold,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = 0.5,
		Text = Title,
		Size = UDim2.new(1.05, 0, 1, 0),
		Position = UDim2.new(1.2, 0, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	local Selection = Create("ImageLabel", {
		Name = "TabSelection",
		Parent = Tab,
		Image = TAB_SELECTION_IMAGE,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(3, 1, 4, 5),
		Visible = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 1, -6),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Page.Tab = Tab
	Page.Icon = IconLabel
	Page.Selection = Selection

	Connect(Tab.MouseButton1Click, function()
		SwitchToPage(Page)
	end)
end

local LayoutTabs = function()
	local Count = 0

	for _, Page in next, Hub.Pages do
		if Page.Tab then
			Count += 1
		end
	end

	local Index = 0
	for _, Page in next, Hub.Pages do
		if Page.Tab then
			Index += 1
			local Pos = ((Index - 0.5) / Count)
			Page.Tab.Position = UDim2.new(Pos, -Page.Tab.Size.X.Offset / 2, 0, 0)
		end
	end
end

local GetSelectedPage = function()
	return Hub.CurrentPage
end

local GetPageIndex = function(Page)
	for Index, Other in next, Hub.Pages do
		if Other == Page then
			return Index
		end
	end

	return 1
end

SwitchToPage = function(Page, NoStack, NoAnimation)
	if not Page then
		return
	end

	local OldPage = Hub.CurrentPage
	local OldFrame = OldPage and OldPage.Frame
	local Direction = (GetPageIndex(Page) >= GetPageIndex(OldPage) and 1) or -1

	for _, Other in next, Hub.Pages do
		if Other.Frame and Other ~= Page and Other ~= OldPage then
			Other.Frame.Visible = false
		end

		if Other.Selection then
			local Title = Other.Icon and Other.Icon:FindFirstChild("Title")

			Other.Selection.Visible = false
			Other.Icon.ImageTransparency = 0.5

			if Title then
				Title.TextTransparency = 0.5
			end
		end
	end

	Page.Frame.Parent = Hub.PageView
	Page.Frame.Visible = true

	if
		OldFrame
		and OldFrame ~= Page.Frame
		and OldFrame.Parent == Hub.PageView
		and OldFrame.Visible
		and not NoAnimation
	then
		local PageWidth = math.max(Hub.PageClipper.AbsoluteSize.X, 800)
		Page.Frame.Position = UDim2.new(0, Direction * PageWidth, 0, PAGE_TOP_PADDING)
		TweenTo(Page.Frame, UDim2.new(0, 0, 0, PAGE_TOP_PADDING), Enum.EasingDirection.In, Enum.EasingStyle.Quad, 0.1)
		TweenTo(
			OldFrame,
			UDim2.new(0, -Direction * PageWidth, 0, PAGE_TOP_PADDING),
			Enum.EasingDirection.Out,
			Enum.EasingStyle.Quad,
			0.1
		)
		task.delay(0.12, function()
			if Hub.CurrentPage ~= OldPage and OldFrame then
				OldFrame.Visible = false
			end
		end)
	else
		Page.Frame.Position = UDim2.new(0, 0, 0, PAGE_TOP_PADDING)
		if OldFrame and OldFrame ~= Page.Frame then
			OldFrame.Visible = false
		end
	end

	Hub.PageView.CanvasPosition = Vector2.new(0, 0)
	Hub.PageView.CanvasSize =
		UDim2.new(0, 0, 0, math.max(Page.Frame.Size.Y.Offset + PAGE_TOP_PADDING, Hub.PageClipper.AbsoluteSize.Y))
	Hub.CurrentPage = Page

	if Page.Selection then
		local Title = Page.Icon and Page.Icon:FindFirstChild("Title")

		Page.Selection.Visible = true
		Page.Icon.ImageTransparency = 0

		if Title then
			Title.TextTransparency = 0
		end
	end

	if not NoStack and Hub.MenuStack[#Hub.MenuStack] ~= Page then
		Insert(Hub.MenuStack, Page)
	end
end

local AddPage = function(Page, Title, Icon, Width)
	Insert(Hub.Pages, Page)

	if Title then
		MakeTab(Page, Title, Icon, Width)
	end

	LayoutTabs()
end

local MakeRow = function(Page, Name, Height)
	local Row = Create("ImageButton", {
		Name = Name .. "Frame",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Image = "",
		Active = false,
		AutoButtonColor = false,
		Selectable = false,
		Size = UDim2.new(1, 0, 0, Height or 50),
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	Create("TextLabel", {
		Name = Name .. "Label",
		Parent = Row,
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSansBold,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Name,
		Size = UDim2.new(0, 200, 1, 0),
		Position = UDim2.new(0, 10, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Page:AddRow(Row)
	return Row
end

local OpenReportPlayer

local RunAfterMenuCloses = function(Callback)
	SetVisibility(false)

	Spawn(function()
		Wait(0.45)

		if Callback then
			Callback()
		end
	end)
end

local MakePlayerRow = function(Page, Player, Index)
	local Row = Create("ImageLabel", {
		Name = "PlayerLabel" .. Player.Name,
		Parent = Page.Frame,
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/dialog_white.png",
		ImageTransparency = 0.85,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(10, 10, 10, 10),
		Size = UDim2.new(1, 0, 0, 60),
		Position = UDim2.new(0, 0, 0, PLAYER_LIST_OFFSET + ((Index - 1) * 80)),
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	Connect(Row.MouseEnter, function()
		Row.ImageTransparency = 0.65
	end)

	Connect(Row.MouseLeave, function()
		Row.ImageTransparency = 0.85
	end)

	Create("TextLabel", {
		Name = "NameLabel",
		Parent = Row,
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSans,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Player.Name,
		Size = UDim2.new(1, -470, 1, 0),
		Position = UDim2.new(0, 60, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("ImageLabel", {
		Name = "Icon",
		Parent = Row,
		BackgroundTransparency = 1,
		Image = GetHeadshot(Player),
		Size = UDim2.new(0, 36, 0, 36),
		Position = UDim2.new(0, 12, 0.5, -18),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	local CanTargetPlayer = Player ~= LocalPlayer and (Player.UserId or Player.userId or 0) > 1
	local FlagButton, ViewButton = nil, nil

	if CanTargetPlayer then
		FlagButton = MakeStyledButton(Player.Name .. "FlagButton", "", UDim2.new(0, 44, 0, 40), function()
			if OpenReportPlayer then
				OpenReportPlayer(Player)
			end
		end)
		FlagButton.Parent = Row
		FlagButton.Position = UDim2.new(1, -344, 0.5, -20)

		Create("ImageLabel", {
			Parent = FlagButton,
			BackgroundTransparency = 1,
			Image = "rbxasset://textures/ui/Settings/MenuBarIcons/ReportAbuseTab.png",
			Size = UDim2.new(0, 26, 0, 32),
			Position = UDim2.new(0.5, -13, 0.5, -16),
			ZIndex = SETTINGS_BASE_ZINDEX + 4,
		})

		ViewButton = MakeStyledButton(Player.Name .. "ViewButton", "View", UDim2.new(0, 104, 0, 40), function()
			local UserId = Player.UserId or Player.userId
			if not UserId or UserId <= 0 then
				return
			end

			RunAfterMenuCloses(function()
				local Success = Protect(function()
					GuiService:InspectPlayerFromUserId(UserId)
				end)

				if not Success then
					Protect(function()
						StarterGui:SetCore("InspectPlayerFromUserId", UserId)
					end)
				end
			end)
		end)
		ViewButton.Parent = Row
		ViewButton.Position = UDim2.new(1, -284, 0.5, -20)
	end

	local Status = nil
	Protect(function()
		if CanTargetPlayer and (LocalPlayer.UserId or LocalPlayer.userId or 0) > 1 then
			Status = LocalPlayer:GetFriendStatus(Player)
		end
	end)

	local FriendButton, FriendLabel
	if not Status then
		FriendButton = Create("TextButton", {
			Text = "",
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 156, 0, 40),
			Position = UDim2.new(1, -164, 0.5, -20),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
			Parent = Row,
		})
	elseif Status == Enum.FriendStatus.Friend then
		FriendButton = Create("TextButton", {
			Text = "Friend",
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			TextSize = 24,
			TextColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(0, 156, 0, 40),
			Position = UDim2.new(1, -164, 0.5, -20),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
			Parent = Row,
		})
	elseif Status == Enum.FriendStatus.FriendRequestSent then
		FriendButton = Create("TextButton", {
			Text = "Request Sent",
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSans,
			TextSize = 24,
			TextColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(0, 156, 0, 40),
			Position = UDim2.new(1, -164, 0.5, -20),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
			Parent = Row,
		})
	else
		FriendButton, FriendLabel = MakeStyledButton("FriendStatus", "Add Friend", UDim2.new(0, 156, 0, 40), function()
			if FriendLabel and FriendLabel.Text ~= "" then
				FriendButton.ImageTransparency = 1
				FriendLabel.Text = ""
				Protect(function()
					LocalPlayer:RequestFriendship(Player)
				end)
			end
		end)
		FriendButton.Parent = Row
		FriendButton.Position = UDim2.new(1, -164, 0.5, -20)
		if FriendLabel then
			FriendLabel.ZIndex = SETTINGS_BASE_ZINDEX + 3
			FriendLabel.Position = FriendLabel.Position + UDim2.new(0, 0, 0, 1)
		end
	end

	if FriendButton then
		FriendButton.Name = "FriendStatus"
	end

	for _, Button in next, { FlagButton, ViewButton, FriendButton } do
		if Button then
			Connect(Button.MouseEnter, function()
				Row.ImageTransparency = 0.65
			end)
			Connect(Button.MouseLeave, function()
				Row.ImageTransparency = 0.85
			end)
		end
	end

	return Row
end

local MakeSelector = function(Page, Name, Values, Index, Changed)
	local CurrentIndex = Index or 1
	local Row = MakeRow(Page, Name)
	local SelectorFrame = Create("ImageButton", {
		Name = Name .. "Selector",
		Parent = Row,
		BackgroundTransparency = 1,
		Image = "",
		AutoButtonColor = false,
		Size = UDim2.new(0, 502, 0, 50),
		Position = UDim2.new(1, -502, 0.5, -25),
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	local Left = Create("ImageButton", {
		Parent = SelectorFrame,
		Name = "LeftButton",
		BackgroundTransparency = 1,
		Image = "",
		Size = UDim2.new(0, 60, 0, 50),
		Position = UDim2.new(0, -10, 0.5, -25),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("ImageLabel", {
		Parent = Left,
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/Settings/Slider/Left.png",
		Size = UDim2.new(0, 18, 0, 30),
		Position = UDim2.new(1, -24, 0.5, -15),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Right = Create("ImageButton", {
		Parent = SelectorFrame,
		Name = "RightButton",
		BackgroundTransparency = 1,
		Image = "",
		Size = UDim2.new(0, 50, 0, 50),
		Position = UDim2.new(1, -50, 0.5, -25),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("ImageLabel", {
		Parent = Right,
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/Settings/Slider/Right.png",
		Size = UDim2.new(0, 18, 0, 30),
		Position = UDim2.new(0, 6, 0.5, -15),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Label = Create("TextLabel", {
		Parent = SelectorFrame,
		Name = "Selection",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -120, 1, 0),
		Position = UDim2.new(0, 60, 0, 0),
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = 0.2,
		TextYAlignment = Enum.TextYAlignment.Center,
		Font = Enum.Font.SourceSans,
		TextSize = 24,
		Text = Values[CurrentIndex],
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	local SelectorApi = {
		CurrentIndex = CurrentIndex,
		SelectorFrame = SelectorFrame,
		Selection = SelectorFrame,
		RowFrame = Row,
		TextLabel = Label,
		Interactable = true,
	}

	local SetText = function(Text, Direction)
		Label.Text = Text
		Label.Position = UDim2.new(0, 60 + ((Direction or 0) * 16), 0, 0)
		Label.TextTransparency = 0.75
		MoveTo(Label, UDim2.new(0, 60, 0, 0))
		FadeText(Label, 0.2)
	end

	local Apply = function(Delta)
		if not SelectorApi.Interactable then
			return
		end

		CurrentIndex = CurrentIndex + Delta

		if CurrentIndex > #Values then
			CurrentIndex = 1
		elseif CurrentIndex < 1 then
			CurrentIndex = #Values
		end

		SelectorApi.CurrentIndex = CurrentIndex
		SetText(Values[CurrentIndex], Delta)

		if Changed then
			Changed(CurrentIndex, Values[CurrentIndex])
		end
	end

	Connect(Left.MouseButton1Click, function()
		Apply(-1)
	end)

	Connect(Right.MouseButton1Click, function()
		Apply(1)
	end)

	Connect(SelectorFrame.MouseButton1Click, function()
		Apply(1)
	end)

	function SelectorApi:SetSelectionIndex(NewIndex, FireChanged)
		if not NewIndex or #Values == 0 then
			return
		end

		CurrentIndex = Clamp(NewIndex, 1, #Values)
		SelectorApi.CurrentIndex = CurrentIndex
		SetText(Values[CurrentIndex], 0)

		if Changed and FireChanged then
			Changed(CurrentIndex, Values[CurrentIndex])
		end
	end

	function SelectorApi:SetPosition(Position)
		SelectorFrame.Position = Position
	end

	function SelectorApi:SetSize(Size)
		SelectorFrame.Size = Size
	end

	function SelectorApi:SetInteractable(Interactable)
		SelectorApi.Interactable = Interactable
		SelectorFrame.ImageTransparency = Interactable and 0 or 0.65
		Label.TextTransparency = Interactable and 0.2 or 0.65
		Left.Visible = Interactable
		Right.Visible = Interactable
	end

	function SelectorApi:GetSelectedIndex()
		return CurrentIndex
	end

	function SelectorApi:GetSelectedValue()
		return Values[CurrentIndex]
	end

	return SelectorApi
end

local MakeSlider = function(Page, Name, Steps, Index, Changed, MinStep)
	MinStep = MinStep or 0
	local CurrentIndex = Clamp(Index or 1, MinStep, Steps)
	local Row = MakeRow(Page, Name)
	local Holder = Create("Frame", {
		Parent = Row,
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 502, 0, 50),
		Position = UDim2.new(1, -502, 0.5, -25),
		Active = true,
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	local Left = Create("ImageButton", {
		Parent = Holder,
		BackgroundTransparency = 1,
		Image = "",
		Size = UDim2.new(0, 60, 0, 50),
		Position = UDim2.new(0, -10, 0.5, -25),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("ImageLabel", {
		Parent = Left,
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/Settings/Slider/Left.png",
		Size = UDim2.new(0, 18, 0, 30),
		Position = UDim2.new(1, -24, 0.5, -15),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Right = Create("ImageButton", {
		Parent = Holder,
		BackgroundTransparency = 1,
		Image = "",
		Size = UDim2.new(0, 50, 0, 50),
		Position = UDim2.new(1, -50, 0.5, -25),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	Create("ImageLabel", {
		Parent = Right,
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/Settings/Slider/Right.png",
		Size = UDim2.new(0, 18, 0, 30),
		Position = UDim2.new(0, 6, 0.5, -15),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Segments = {}
	local Dragging = false
	local SliderApi = {
		SliderFrame = Holder,
		Selection = Holder,
		RowFrame = Row,
		Interactable = true,
	}

	local Refresh = function(Immediate)
		for Index2, Segment in next, Segments do
			local Selected = SliderApi.Interactable and Index2 <= CurrentIndex
			local Color = (Selected and Color3.fromRGB(0, 162, 255)) or Color3.fromRGB(78, 84, 96)

			if Index2 == 1 or Index2 == Steps then
				Segment.Image = (
					Selected and ((Index2 == 1 and SLIDER_SELECTED_LEFT_IMAGE) or SLIDER_SELECTED_RIGHT_IMAGE)
				) or ((Index2 == 1 and SLIDER_LEFT_IMAGE) or SLIDER_RIGHT_IMAGE)
				Segment.ImageTransparency = 0.36
				Segment.BackgroundTransparency = 1
			else
				if Immediate then
					Segment.BackgroundColor3 = Color
				else
					ColorTo(Segment, Color)
				end
			end
		end

		Left.Visible = SliderApi.Interactable and CurrentIndex > MinStep
		Right.Visible = SliderApi.Interactable and CurrentIndex < Steps
	end

	local SetSliderValue = function(NewIndex)
		NewIndex = Clamp(NewIndex, MinStep, Steps)

		if CurrentIndex == NewIndex then
			return
		end

		CurrentIndex = NewIndex
		Refresh()

		if Changed then
			Changed(CurrentIndex)
		end
	end

	local SetSliderFromX = function(X)
		if not SliderApi.Interactable then
			return
		end

		local FirstSegment = Segments[1]
		local LastSegment = Segments[Steps]

		if not FirstSegment or not LastSegment then
			return
		end

		local StartX = FirstSegment.AbsolutePosition.X
		local EndX = LastSegment.AbsolutePosition.X + LastSegment.AbsoluteSize.X
		local Alpha = Clamp((X - StartX) / (EndX - StartX), 0, 1)

		if MinStep > 0 then
			SetSliderValue(Clamp(Floor((Alpha * Steps) + 1), MinStep, Steps))
		else
			SetSliderValue(Clamp(Floor(Alpha * (Steps + 1)), 0, Steps))
		end
	end

	for Index2 = 1, Steps do
		local Segment = Create("ImageButton", {
			Parent = Holder,
			BackgroundColor3 = Color3.fromRGB(78, 84, 96),
			BackgroundTransparency = 0.36,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Image = "",
			ImageTransparency = 0.36,
			Size = UDim2.new(0, 35, 0, 25),
			Position = UDim2.new(0, 60 + ((Index2 - 1) * 39), 0.5, -12),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
		})

		if Index2 == 1 or Index2 == Steps then
			Segment.BackgroundTransparency = 1
			Segment.ScaleType = Enum.ScaleType.Slice
			Segment.SliceCenter = Rect.new(3, 3, 32, 21)
		end

		Segments[Index2] = Segment
		Connect(Segment.MouseButton1Click, function()
			if SliderApi.Interactable then
				SetSliderValue(Index2)
			end
		end)
	end

	local Capture = Create("TextButton", {
		Parent = Holder,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = false,
		Active = true,
		Size = UDim2.new(0, 400, 1, 0),
		Position = UDim2.new(0, 52, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 5,
	})

	Connect(Capture.InputBegan, function(Input)
		if
			Input.UserInputType == Enum.UserInputType.MouseButton1
			or Input.UserInputType == Enum.UserInputType.Touch
		then
			Dragging = true
			SetSliderFromX(Input.Position.X)
		end
	end)

	Connect(Capture.InputChanged, function(Input)
		if
			Dragging
			and (
				Input.UserInputType == Enum.UserInputType.MouseMovement
				or Input.UserInputType == Enum.UserInputType.Touch
			)
		then
			SetSliderFromX(Input.Position.X)
		end
	end)

	Connect(UserInputService.InputChanged, function(Input)
		if
			Dragging
			and (
				Input.UserInputType == Enum.UserInputType.MouseMovement
				or Input.UserInputType == Enum.UserInputType.Touch
			)
		then
			SetSliderFromX(Input.Position.X)
		end
	end)

	Connect(UserInputService.InputEnded, function(Input)
		if
			Input.UserInputType == Enum.UserInputType.MouseButton1
			or Input.UserInputType == Enum.UserInputType.Touch
		then
			Dragging = false
		end
	end)

	Connect(Left.MouseButton1Click, function()
		if SliderApi.Interactable then
			SetSliderValue(CurrentIndex - 1)
		end
	end)

	Connect(Right.MouseButton1Click, function()
		if SliderApi.Interactable then
			SetSliderValue(CurrentIndex + 1)
		end
	end)

	Refresh(true)

	function SliderApi:SetValue(NewValue)
		CurrentIndex = Clamp(NewValue, MinStep, Steps)
		Refresh(true)
	end

	function SliderApi:GetValue()
		return CurrentIndex
	end

	function SliderApi:SetInteractable(Interactable)
		SliderApi.Interactable = Interactable
		Holder.Active = Interactable
		Holder.ZIndex = SETTINGS_BASE_ZINDEX + (Interactable and 2 or 1)

		for _, Segment in next, Segments do
			Segment.Active = Interactable
			Segment.Selectable = Interactable
			Segment.ZIndex = SETTINGS_BASE_ZINDEX + (Interactable and 3 or 1)
		end

		Refresh(true)
	end

	function SliderApi:SetZIndex(NewZIndex)
		Holder.ZIndex = NewZIndex
		Left.ZIndex = NewZIndex + 1
		Right.ZIndex = NewZIndex + 1

		for _, Segment in next, Segments do
			Segment.ZIndex = NewZIndex + 1
		end
	end

	function SliderApi:SetMinStep(NewMinStep)
		MinStep = Clamp(NewMinStep or 0, 0, Steps)
		CurrentIndex = Clamp(CurrentIndex, MinStep, Steps)
		Refresh(true)
	end

	return SliderApi
end

local MakeDropDown = function(Page, Name, Values, Index, Changed)
	local CurrentIndex = Index
	local Row = MakeRow(Page, Name)
	local Button = MakeStyledButton(Name .. "DropDown", Values[CurrentIndex] or "Choose One", UDim2.new(0, 300, 0, 44))
	Button.Parent = Row
	Button.Position = UDim2.new(1, -350, 0.5, -22)

	local Arrow = Create("ImageLabel", {
		Parent = Button,
		BackgroundTransparency = 1,
		Image = DROP_DOWN_IMAGE,
		Size = UDim2.new(0, 15, 0, 10),
		Position = UDim2.new(1, -40, 0.5, -7),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Label = Button:FindFirstChild(Name .. "DropDownTextLabel")
	local DropDownApi = {
		CurrentIndex = CurrentIndex,
		DropDownFrame = Button,
		Selection = Button,
		Interactable = true,
	}

	local Overlay = Create("TextButton", {
		Parent = ScreenGui,
		Name = Name .. "DropDownFullscreenFrame",
		Visible = false,
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Text = "",
		Size = UDim2.new(1, 0, 1, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 20,
	})

	local Panel = Create("ImageLabel", {
		Parent = Overlay,
		Image = BUTTON_IMAGE,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(8, 6, 46, 44),
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 400, 0.9, 0),
		Position = UDim2.new(0.5, -200, 0.05, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 21,
	})

	local List = Create("ScrollingFrame", {
		Parent = Panel,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -20, 1, -25),
		Position = UDim2.new(0, 10, 0, 10),
		CanvasSize = UDim2.new(0, 0, 0, #Values * 51),
		ScrollBarThickness = 6,
		ZIndex = SETTINGS_BASE_ZINDEX + 21,
	})

	local SetSelection = function(NewIndex, FireChanged)
		CurrentIndex = NewIndex
		DropDownApi.CurrentIndex = CurrentIndex

		local Value = CurrentIndex and Values[CurrentIndex] or nil
		Label.Text = Value or "Choose One"

		if Changed and FireChanged then
			Changed(CurrentIndex, Value)
		end
	end

	local Rebuild = function(NewValues)
		Values = NewValues or Values

		if CurrentIndex and CurrentIndex > #Values then
			CurrentIndex = nil
			DropDownApi.CurrentIndex = nil
		end

		for _, Child in next, List:GetChildren() do
			if Child:IsA("TextButton") then
				Child:Destroy()
			end
		end

		for Index2, Value in next, Values do
			local Option = Create("TextButton", {
				Parent = List,
				Name = "Selection" .. tostring(Index2),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Size = UDim2.new(1, -28, 0, 50),
				Position = UDim2.new(0, 14, 0, (Index2 - 1) * 51),
				TextColor3 = (Index2 == CurrentIndex and Color3.new(1, 1, 1)) or Color3.new(0.7, 0.7, 0.7),
				Font = Enum.Font.SourceSans,
				TextSize = 24,
				Text = Value,
				ZIndex = SETTINGS_BASE_ZINDEX + 22,
			})

			Connect(Option.MouseButton1Click, function()
				SetSelection(Index2, true)
				Overlay.Visible = false
			end)
		end

		List.CanvasSize = UDim2.new(0, 0, 0, #Values * 51)
		SetSelection(CurrentIndex, false)
	end

	Connect(Button.MouseButton1Click, function()
		if DropDownApi.Interactable then
			Overlay.Visible = true
		end
	end)

	Connect(Overlay.MouseButton1Click, function()
		Overlay.Visible = false
	end)

	Rebuild(Values)

	function DropDownApi:UpdateDropDownList(NewValues)
		Rebuild(NewValues)
	end

	function DropDownApi:SetSelectionIndex(NewIndex, FireChanged)
		if not NewIndex or NewIndex < 1 or NewIndex > #Values then
			SetSelection(nil, FireChanged)
			return false
		end

		SetSelection(NewIndex, FireChanged)
		return true
	end

	function DropDownApi:SetSelectionByValue(Value, FireChanged)
		for Index2, Item in next, Values do
			if Item == Value then
				SetSelection(Index2, FireChanged)
				return true
			end
		end

		return false
	end

	function DropDownApi:ResetSelectionIndex(FireChanged)
		SetSelection(nil, FireChanged)
	end

	function DropDownApi:GetSelectedIndex()
		return CurrentIndex
	end

	function DropDownApi:GetSelectedValue()
		return CurrentIndex and Values[CurrentIndex] or nil
	end

	function DropDownApi:SetInteractable(Interactable)
		DropDownApi.Interactable = Interactable
		Button.ImageTransparency = Interactable and 0 or 0.65
		Button.Active = Interactable
		Button.Selectable = Interactable
		if Label then
			Label.TextTransparency = Interactable and 0 or 0.65
		end
		if Arrow then
			Arrow.ImageTransparency = Interactable and 0 or 0.65
		end
	end

	return DropDownApi
end

local ActiveAlert = nil
local ShowAlert = function(AlertMessage, OkButtonText, Cleanup)
	if ActiveAlert then
		ActiveAlert:Destroy()
		ActiveAlert = nil
	end

	Hub.HubBar.Visible = false
	Hub.PageClipper.Visible = false
	Hub.BottomButtonFrame.Visible = false

	local Alert = Create("ImageLabel", {
		Name = "AlertViewBacking",
		Parent = Hub.Shield,
		Image = BUTTON_IMAGE,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(8, 6, 46, 44),
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 400, 0, 350),
		Position = UDim2.new(0.5, -200, 0.5, -175),
		ZIndex = SETTINGS_BASE_ZINDEX + 30,
	})
	ActiveAlert = Alert

	Create("TextLabel", {
		Name = "AlertViewText",
		Parent = Alert,
		BackgroundTransparency = 1,
		Size = UDim2.new(0.95, 0, 0.6, 0),
		Position = UDim2.new(0.025, 0, 0.05, 0),
		Font = Enum.Font.SourceSansBold,
		TextSize = 36,
		Text = AlertMessage,
		TextWrapped = true,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		ZIndex = SETTINGS_BASE_ZINDEX + 31,
	})

	local Button, ButtonText = MakeStyledButton(
		"AlertViewButton",
		OkButtonText or "Ok",
		UDim2.new(0, 200, 0, 50),
		function()
			if ActiveAlert then
				ActiveAlert:Destroy()
				ActiveAlert = nil
			end

			if Cleanup then
				Cleanup()
			else
				Hub.HubBar.Visible = true
				Hub.PageClipper.Visible = true
				Hub.BottomButtonFrame.Visible = true
			end
		end
	)
	Button.Parent = Alert
	Button.Position = UDim2.new(0.5, -100, 0.65, 0)
	Button.ZIndex = SETTINGS_BASE_ZINDEX + 31
	ButtonText.ZIndex = SETTINGS_BASE_ZINDEX + 32
end

local PlayersPage = MakePage("Players")
AddPage(PlayersPage, "Players", "rbxasset://textures/ui/Settings/MenuBarIcons/PlayersTabIcon.png", 150)

if PlayersPage.Icon then
	PlayersPage.Icon.Size = UDim2.new(0, 44, 0, 37)
	PlayersPage.Icon.Position = UDim2.new(0, 15, 0.5, -18)
end

local RebuildPlayersPage = function()
	for _, Child in next, PlayersPage.Frame:GetChildren() do
		if Child.Name:sub(1, 11) == "PlayerLabel" then
			Child:Destroy()
		end
	end

	local SortedPlayers = Players:GetPlayers()
	table.sort(SortedPlayers, function(PlayerA, PlayerB)
		return PlayerA.Name < PlayerB.Name
	end)

	local Count = 0
	for _, Player in next, SortedPlayers do
		Count += 1
		MakePlayerRow(PlayersPage, Player, Count)
	end

	PlayersPage.Frame.Size = UDim2.new(1, 0, 0, PLAYER_LIST_OFFSET + (Count * 80) - 5)
end

RebuildPlayersPage()

Connect(Players.PlayerAdded, function(Player)
	RebuildPlayersPage()
end)

Connect(Players.PlayerRemoving, function(Player)
	task.defer(RebuildPlayersPage)
end)

Protect(function()
	Connect(LocalPlayer.FriendStatusChanged, function()
		RebuildPlayersPage()
	end)
end)

local GamePage = MakePage("GameSettings")
AddPage(GamePage, "Settings", "rbxasset://textures/ui/Settings/MenuBarIcons/GameSettingsTab.png", 170)

local IsTouchClient = UserInputService.TouchEnabled
local CameraDefaultString = IsTouchClient and "Default (Follow)" or "Default (Classic)"
local MovementDefaultString = IsTouchClient and "Default (Thumbstick)" or "Default (Keyboard)"
local ClickToMoveString = IsTouchClient and "Tap to Move" or "Click to Move"

local GetSetting = function(Object, Property, Default)
	local Success, Value = pcall(function()
		return Object[Property]
	end)

	if Success and Value ~= nil then
		return Value
	end

	return Default
end

local SetSetting = function(Object, Property, Value)
	Protect(function()
		Object[Property] = Value
	end)
end

local MakeSectionHeader = function(Page, Title)
	local Row = MakeRow(Page, Title, 64)
	local Label = Row:FindFirstChild(Title .. "Label")
	if Label then
		Label.TextSize = 28
		Label.TextColor3 = Color3.fromRGB(190, 210, 255)
		Label.Size = UDim2.new(1, -20, 1, -10)
		Label.Position = UDim2.new(0, 10, 0, 10)
	end
	return Row
end

local MakeValueRow = function(Page, Name, Value)
	local Row = MakeRow(Page, Name)
	local ValueLabel = Create("TextLabel", {
		Name = Name .. "Value",
		Parent = Row,
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSans,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = tostring(Value or "Unavailable"),
		Size = UDim2.new(0, 360, 1, 0),
		Position = UDim2.new(1, -380, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	return ValueLabel, Row
end

local MakeButtonRow = function(Page, Name, Text, Clicked)
	local Row = MakeRow(Page, Name)
	local Button = MakeStyledButton(Name .. "Action", Text, UDim2.new(0, 300, 0, 44), Clicked)
	Button.Parent = Row
	Button.Position = UDim2.new(1, -400, 0.5, -22)
	return Button, Row
end

local MakeBooleanSelector = function(Page, Name, Object, Property, OnFirst, OffSecond)
	local Current = GetSetting(Object, Property, false)
	local Start = ((Current == true or Current == 1) and 1) or 2
	return MakeSelector(Page, Name, { OnFirst or "On", OffSecond or "Off" }, Start, function(Index)
		SetSetting(Object, Property, Index == 1)
	end)
end

MakeSectionHeader(GamePage, "View & Controls")

local MakeOverrideText = function(Row)
	return Create("TextLabel", {
		Name = "DevOverrideLabel",
		Parent = Row,
		BackgroundTransparency = 1,
		Font = Enum.Font.SourceSans,
		TextSize = 24,
		TextColor3 = Color3.new(1, 1, 1),
		Text = "Set by Developer",
		Visible = false,
		Size = UDim2.new(0, 200, 1, 0),
		Position = UDim2.new(1, -350, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})
end

local SetChangerVisible = function(Changer, OverrideText, Visible)
	if Changer then
		Changer:SetInteractable(Visible)
		Changer.SelectorFrame.Visible = Visible
	end

	if OverrideText then
		OverrideText.Visible = not Visible
	end
end

local ShiftLockMode, ShiftLockOverride = nil, nil
if UserInputService.MouseEnabled and UserInputService.KeyboardEnabled then
	ShiftLockMode = MakeSelector(
		GamePage,
		"Shift Lock Switch",
		{ "On", "Off" },
		(GameSettings.ControlMode == Enum.ControlMode.MouseLockSwitch and 1) or 2,
		function(Index)
			Protect(function()
				GameSettings.ControlMode = (Index == 1 and Enum.ControlMode.MouseLockSwitch) or Enum.ControlMode.Classic
			end)
		end
	)
	ShiftLockOverride = MakeOverrideText(ShiftLockMode.RowFrame)
end

local CameraItems = (IsTouchClient and Enum.TouchCameraMovementMode or Enum.ComputerCameraMovementMode):GetEnumItems()
local CameraNames, CameraMap, CameraStart = {}, {}, 1
for Index, Item in next, CameraItems do
	local Name = (Item.Name == "Default" and CameraDefaultString) or Item.Name
	CameraNames[Index] = Name
	CameraMap[Name] = Item

	if
		(IsTouchClient and GameSettings.TouchCameraMovementMode == Item)
		or ((not IsTouchClient) and GameSettings.ComputerCameraMovementMode == Item)
	then
		CameraStart = Index
	end
end

local CameraMode = MakeSelector(GamePage, "Camera Mode", CameraNames, CameraStart, function(_, Value)
	Protect(function()
		if IsTouchClient then
			GameSettings.TouchCameraMovementMode = CameraMap[Value]
		else
			GameSettings.ComputerCameraMovementMode = CameraMap[Value]
		end
	end)
end)
local CameraOverride = MakeOverrideText(CameraMode.RowFrame)

local MoveItems = (IsTouchClient and Enum.TouchMovementMode or Enum.ComputerMovementMode):GetEnumItems()
local MoveNames, MoveMap, MoveStart = {}, {}, 1
for Index, Item in next, MoveItems do
	local Name = Item.Name
	if Name == "Default" then
		Name = MovementDefaultString
	elseif Name == "KeyboardMouse" then
		Name = "Keyboard + Mouse"
	elseif Name == "ClickToMove" then
		Name = ClickToMoveString
	end

	MoveNames[Index] = Name
	MoveMap[Name] = Item

	if
		(IsTouchClient and GameSettings.TouchMovementMode == Item)
		or ((not IsTouchClient) and GameSettings.ComputerMovementMode == Item)
	then
		MoveStart = Index
	end
end

local MovementMode = MakeSelector(GamePage, "Movement Mode", MoveNames, MoveStart, function(_, Value)
	Protect(function()
		if IsTouchClient then
			GameSettings.TouchMovementMode = MoveMap[Value]
		else
			GameSettings.ComputerMovementMode = MoveMap[Value]
		end
	end)
end)
local MovementOverride = MakeOverrideText(MovementMode.RowFrame)

local UpdateDevChoiceSettings = function(Property)
	if ShiftLockMode and (not Property or Property == "DevEnableMouseLock") then
		local CanUseShiftLock = true
		Protect(function()
			CanUseShiftLock = LocalPlayer.DevEnableMouseLock
		end)
		SetChangerVisible(ShiftLockMode, ShiftLockOverride, CanUseShiftLock)
	end

	if not Property or Property == "DevComputerCameraMode" or Property == "DevTouchCameraMode" then
		local CanUseCamera = true
		Protect(function()
			CanUseCamera = (
				IsTouchClient and LocalPlayer.DevTouchCameraMode == Enum.DevTouchCameraMovementMode.UserChoice
			)
				or (
					not IsTouchClient
					and LocalPlayer.DevComputerCameraMode == Enum.DevComputerCameraMovementMode.UserChoice
				)
		end)
		SetChangerVisible(CameraMode, CameraOverride, CanUseCamera)
	end

	if not Property or Property == "DevComputerMovementMode" or Property == "DevTouchMovementMode" then
		local CanUseMovement = true
		Protect(function()
			CanUseMovement = (
				IsTouchClient and LocalPlayer.DevTouchMovementMode == Enum.DevTouchMovementMode.UserChoice
			)
				or (
					not IsTouchClient
					and LocalPlayer.DevComputerMovementMode == Enum.DevComputerMovementMode.UserChoice
				)
		end)
		SetChangerVisible(MovementMode, MovementOverride, CanUseMovement)
	end
end

UpdateDevChoiceSettings()
Connect(LocalPlayer.Changed, UpdateDevChoiceSettings)

local MouseStart = Clamp(Floor((2 / 3) * (math.sqrt((75 * (GameSettings.MouseSensitivity or 1)) - 11) - 2)), 1, 10)
MakeSlider(GamePage, "Mouse Sensitivity", 10, MouseStart, function(Value)
	Value = Clamp(Value, 1, 10)
	SetMouseSensitivity((0.03 * (Value ^ 2)) + (0.08 * Value) + 0.2)
end, 1)

MakeBooleanSelector(GamePage, "UI Navigation Toggle", GameSettings, "UiNavigationKeyBindEnabled")
MakeBooleanSelector(GamePage, "People's Names", GameSettings, "PlayerNamesEnabled", "Show", "Hide")
MakeBooleanSelector(GamePage, "My Badges", GameSettings, "BadgeVisible", "Show", "Hide")

MakeSectionHeader(GamePage, "Audio")

MakeSlider(GamePage, "Volume", 10, Floor((GameSettings.MasterVolume or 1) * 10), function(Value)
	SetMasterVolume(Value / 10)
	PlayVolumeChangeSound()
end)

MakeSectionHeader(GamePage, "Chat & Language")

MakeButtonRow(GamePage, "Give Translation Feedback", "Give Feedback", function()
	RunAfterMenuCloses(function()
		pcall(function()
			SocialService:PromptFeedbackSubmissionAsync()
		end)
	end)
end)

MakeBooleanSelector(GamePage, "Automatic Chat Translation", GameSettings, "ChatTranslationEnabled")
MakeBooleanSelector(GamePage, "Chat Translation Language", GameSettings, "ChatTranslationToggleEnabled")
MakeBooleanSelector(GamePage, "View Untranslated Messages", GameSettings, "ChatTranslationFTUXShown")

MakeSectionHeader(GamePage, "Display & Graphics")

MakeSelector(GamePage, "Fullscreen", { "On", "Off" }, (GameSettings:InFullScreen() and 1) or 2, function()
	Protect(function()
		local Success = pcall(function()
			GuiService:ToggleFullscreen()
		end)

		if (not Success) and keypress and keyrelease then
			keypress(0x7A)
			keyrelease(0x7A)
		end
	end)
end)

MakeBooleanSelector(GamePage, "Performance Stats", GameSettings, "PerformanceStatsVisible")

MakeButtonRow(GamePage, "MicroProfiler", "Open", function()
	RunAfterMenuCloses(function()
		SetSetting(GameSettings, "OnScreenProfilerEnabled", true)
		if keypress and keyrelease then
			keypress(0x75)
			keyrelease(0x75)
		end
	end)
end)

local QualityLevels = {
	Enum.QualityLevel.Level01,
	Enum.QualityLevel.Level04,
	Enum.QualityLevel.Level06,
	Enum.QualityLevel.Level08,
	Enum.QualityLevel.Level10,
	Enum.QualityLevel.Level12,
	Enum.QualityLevel.Level14,
	Enum.QualityLevel.Level16,
	Enum.QualityLevel.Level18,
	Enum.QualityLevel.Level21,
}

local SavedQualityLevels = {
	Enum.SavedQualitySetting.QualityLevel1,
	Enum.SavedQualitySetting.QualityLevel2,
	Enum.SavedQualitySetting.QualityLevel3,
	Enum.SavedQualitySetting.QualityLevel4,
	Enum.SavedQualitySetting.QualityLevel5,
	Enum.SavedQualitySetting.QualityLevel6,
	Enum.SavedQualitySetting.QualityLevel7,
	Enum.SavedQualitySetting.QualityLevel8,
	Enum.SavedQualitySetting.QualityLevel9,
	Enum.SavedQualitySetting.QualityLevel10,
}

local GetGraphicsSliderStart = function()
	if type(GameSettings.SavedQualityLevel) == "number" then
		if GameSettings.SavedQualityLevel <= 0 then
			return 5
		end

		return Clamp(GameSettings.SavedQualityLevel, 1, 10)
	end

	if type(RenderingSettings.QualityLevel) == "number" and RenderingSettings.QualityLevel <= 0 then
		return 5
	end

	if
		GameSettings.SavedQualityLevel == Enum.SavedQualitySetting.Automatic
		or RenderingSettings.QualityLevel == Enum.QualityLevel.Automatic
	then
		return 5
	end

	for Index, Quality in next, QualityLevels do
		if RenderingSettings.QualityLevel == Quality then
			return Index
		end
	end

	local Saved = tostring(GameSettings.SavedQualityLevel)
	local SavedIndex = tonumber(Saved:match("QualityLevel(%d+)$"))
	return Clamp(SavedIndex or 5, 1, 10)
end

local GraphicsSlider = nil
local GraphicsMode = nil

Protect(function()
	RenderingSettings.EnableFRM = true
end)

local GetEnumItemByValue = function(EnumType, Value)
	local Items = {}
	Protect(function()
		Items = EnumType:GetEnumItems()
	end)

	for _, Item in next, Items do
		if Item.Value == Value then
			return Item
		end
	end

	return nil
end

local SetGraphicsQuality = function(NewValue, AutomaticSettingAllowed)
	NewValue = tonumber(NewValue) or 0

	local MaxQualityLevel = 21
	Protect(function()
		MaxQualityLevel = RenderingSettings:GetMaxQualityLevel()
	end)

	local NewQualityLevel = 0
	if NewValue > 0 or not AutomaticSettingAllowed then
		local Percentage = NewValue / 10
		NewQualityLevel = Floor((MaxQualityLevel - 1) * Percentage)

		if NewQualityLevel == 20 then
			NewQualityLevel = 21
		elseif NewValue == 1 then
			NewQualityLevel = 1
		elseif NewValue < 1 and not AutomaticSettingAllowed then
			NewValue = 1
			NewQualityLevel = 1
		elseif NewQualityLevel > MaxQualityLevel then
			NewQualityLevel = MaxQualityLevel - 1
		end
	end

	local SavedQuality = (NewValue <= 0 and AutomaticSettingAllowed and Enum.SavedQualitySetting.Automatic)
		or GetEnumItemByValue(Enum.SavedQualitySetting, NewValue)
		or SavedQualityLevels[NewValue]
	local RenderQuality = (NewValue <= 0 and AutomaticSettingAllowed and Enum.QualityLevel.Automatic)
		or GetEnumItemByValue(Enum.QualityLevel, NewQualityLevel)
		or QualityLevels[NewValue]

	Protect(function()
		RenderingSettings.EnableFRM = true
	end)
	Protect(function()
		GameSettings.SavedQualityLevel = NewValue
	end)
	Protect(function()
		GameSettings.SavedQualityLevel = SavedQuality
	end)
	Protect(function()
		RenderingSettings.QualityLevel = NewQualityLevel
	end)
	Protect(function()
		RenderingSettings.QualityLevel = RenderQuality
	end)
	Protect(function()
		RenderingSettings.EditQualityLevel = NewQualityLevel
	end)
	Protect(function()
		RenderingSettings.EditQualityLevel = RenderQuality
	end)
	Protect(function()
		RenderingSettings.AutoFRMLevel = NewQualityLevel
	end)
end

local SetGraphicsToAuto = function()
	if GraphicsSlider then
		GraphicsSlider:SetInteractable(false)
	end

	SetGraphicsQuality(0, true)
end

local SetGraphicsToManual = function(Value)
	Value = Clamp(Value or GetGraphicsSliderStart(), 1, 10)

	if GraphicsSlider then
		GraphicsSlider:SetInteractable(true)
		GraphicsSlider:SetValue(Value)
	end

	SetGraphicsQuality(Value, false)
end

GraphicsMode = MakeSelector(GamePage, "Graphics Mode", { "Automatic", "Manual" }, 1, function(Index)
	if Index == 1 then
		SetGraphicsToAuto()
	else
		SetGraphicsToManual((GraphicsSlider and GraphicsSlider:GetValue()) or GetGraphicsSliderStart())
	end
end)

if
	GameSettings.SavedQualityLevel ~= Enum.SavedQualitySetting.Automatic
	and RenderingSettings.QualityLevel ~= Enum.QualityLevel.Automatic
	and GameSettings.SavedQualityLevel ~= 0
	and RenderingSettings.QualityLevel ~= 0
then
	GraphicsMode:SetSelectionIndex(2)
end

GraphicsSlider = MakeSlider(GamePage, "Graphics Quality", 10, GetGraphicsSliderStart(), function(Value)
	Value = Clamp(Value, 1, 10)
	GraphicsMode:SetSelectionIndex(2)
	GraphicsSlider:SetInteractable(true)
	SetGraphicsQuality(Value, false)
end, 1)

Protect(function()
	Connect(game.GraphicsQualityChangeRequest, function(IsIncrease)
		if RenderingSettings.QualityLevel == Enum.QualityLevel.Automatic or RenderingSettings.QualityLevel == 0 then
			return
		end

		local Value = Clamp(GraphicsSlider:GetValue() + (IsIncrease and 1 or -1), 1, 10)
		GraphicsMode:SetSelectionIndex(2)
		GraphicsSlider:SetInteractable(true)
		GraphicsSlider:SetValue(Value)
		SetGraphicsQuality(Value, false)
	end)
end)

if
	GameSettings.SavedQualityLevel == Enum.SavedQualitySetting.Automatic
	or RenderingSettings.QualityLevel == Enum.QualityLevel.Automatic
	or GameSettings.SavedQualityLevel == 0
	or RenderingSettings.QualityLevel == 0
then
	SetGraphicsToAuto()
else
	SetGraphicsToManual(GetGraphicsSliderStart())
end

MakeSelector(
	GamePage,
	"Haptics",
	{ "On", "Off" },
	((GetSetting(GameSettings, "HapticStrength", 1) or 0) > 0 and 1) or 2,
	function(Index)
		SetSetting(GameSettings, "HapticStrength", (Index == 1 and 1) or 0)
	end
)
MakeBooleanSelector(GamePage, "Reduce Motion", GameSettings, "ReducedMotion")

local FpsValues = { "60", "120", "144", "160", "165", "180", "200", "240" }
local FpsStart = 1
local CurrentFps = tostring(GetSetting(GameSettings, "FramerateCap", 60))
for Index, Value in next, FpsValues do
	if Value == CurrentFps then
		FpsStart = Index
	end
end
MakeSelector(GamePage, "Maximum Frame Rate", FpsValues, FpsStart, function(_, Value)
	local Cap = tonumber(Value) or 60
	SetSetting(GameSettings, "FramerateCap", Cap)
	if setfpscap then
		Protect(function()
			setfpscap(Cap)
		end)
	end
end)

MakeBooleanSelector(GamePage, "VR", GameSettings, "VREnabled")

local ReportPage = MakePage("ReportAbuse")
AddPage(ReportPage, "Report", "rbxasset://textures/ui/Settings/MenuBarIcons/ReportAbuseTab.png", 150)

local TypeOfAbuse = nil
local WhichPlayer = nil
local NameToPlayer = {}
local PlayerNames = {}
local Submit = nil
local SubmitLabel = nil
local Description = nil
local ReportMode = nil

local SetSubmitActive = function(Active)
	if not Submit or not SubmitLabel then
		return
	end

	Submit.Selectable = Active
	Submit.ImageTransparency = Active and 0 or 0.65
	Submit.ZIndex = SETTINGS_BASE_ZINDEX + (Active and 3 or 1)
	SubmitLabel.ZIndex = Submit.ZIndex + 1
	SubmitLabel.TextTransparency = Active and 0 or 0.55
end

local GetReportDescription = function()
	local Text = Description and Description.Text or ""

	if Text == "" or Text == DESCRIPTION_PLACEHOLDER then
		return REPORT_DESCRIPTION_FALLBACK
	end

	return Text
end

local CanSubmitReport = function(ReportMode)
	if not TypeOfAbuse or not ReportMode then
		return false
	end

	if not TypeOfAbuse:GetSelectedIndex() then
		return false
	end

	if ReportMode:GetSelectedIndex() == 2 and (not WhichPlayer or not WhichPlayer:GetSelectedValue()) then
		return false
	end

	return true
end

local RefreshSubmitState = function(ReportMode)
	SetSubmitActive(CanSubmitReport(ReportMode))
end

ReportMode = MakeSelector(ReportPage, "Game or Player?", { "Game", "Player" }, 1, function()
	if not TypeOfAbuse or not WhichPlayer then
		return
	end

	WhichPlayer:ResetSelectionIndex()
	TypeOfAbuse:ResetSelectionIndex()

	if ReportMode:GetSelectedIndex() == 1 then
		TypeOfAbuse:UpdateDropDownList(ABUSE_TYPES_GAME)
		WhichPlayer:SetInteractable(false)
	else
		TypeOfAbuse:UpdateDropDownList(ABUSE_TYPES_PLAYER)
		WhichPlayer:SetInteractable(#PlayerNames > 0)
	end

	RefreshSubmitState(ReportMode)
end)
ReportMode:SetSize(UDim2.new(0, 400, 0, 50))
ReportMode:SetPosition(UDim2.new(1, -400, 0.5, -25))

WhichPlayer = MakeDropDown(ReportPage, "Which Player?", PlayerNames, nil, function()
	RefreshSubmitState(ReportMode)
end)
WhichPlayer:SetInteractable(false)

local RefreshReportPlayers = function()
	PlayerNames = {}
	NameToPlayer = {}

	for _, Player in next, Players:GetPlayers() do
		if Player ~= LocalPlayer and (Player.UserId or Player.userId or 0) > 0 then
			Insert(PlayerNames, Player.Name)
			NameToPlayer[Player.Name] = Player
		end
	end

	WhichPlayer:UpdateDropDownList(PlayerNames)
	WhichPlayer:SetInteractable(ReportMode:GetSelectedIndex() == 2 and #PlayerNames > 0)

	if #PlayerNames == 0 and ReportMode:GetSelectedIndex() == 2 then
		ReportMode:SetSelectionIndex(1, true)
	end

	RefreshSubmitState(ReportMode)
end

OpenReportPlayer = function(Player)
	if Player and Player ~= LocalPlayer then
		RefreshReportPlayers()
		ReportMode:SetSelectionIndex(2, true)
		WhichPlayer:SetSelectionByValue(Player.Name, true)

		if Hub.Visible then
			SwitchToPage(ReportPage)
		else
			SetVisibility(true, false, ReportPage)
		end
	end
end

Connect(Players.PlayerAdded, RefreshReportPlayers)
Connect(Players.PlayerRemoving, function()
	task.defer(RefreshReportPlayers)
end)

TypeOfAbuse = MakeDropDown(ReportPage, "Type Of Abuse", ABUSE_TYPES_GAME, nil, function()
	RefreshSubmitState(ReportMode)
end)

local DescriptionRow = MakeRow(ReportPage, "")
Description = Create("TextBox", {
	Parent = DescriptionRow,
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BackgroundTransparency = 0.5,
	BorderSizePixel = 0,
	ClearTextOnFocus = false,
	Font = Enum.Font.SourceSans,
	TextSize = 24,
	TextColor3 = Color3.fromRGB(49, 49, 49),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Text = DESCRIPTION_PLACEHOLDER,
	Size = UDim2.new(1, -20, 0, 100),
	Position = UDim2.new(0, 10, 0, 0),
	ZIndex = SETTINGS_BASE_ZINDEX + 3,
})
Connect(Description.Focused, function()
	if Description.Text == DESCRIPTION_PLACEHOLDER then
		Description.Text = ""
	end
end)
Connect(Description.FocusLost, function()
	if Description.Text == "" then
		Description.Text = DESCRIPTION_PLACEHOLDER
	end
end)
DescriptionRow.Size = UDim2.new(1, 0, 0, 110)
ReportPage.Frame.Size = UDim2.new(1, 0, 0, ReportPage.Frame.Size.Y.Offset + 60)

Submit, SubmitLabel = MakeStyledButton("SubmitButton", "Submit", UDim2.new(0, 198, 0, 50), function()
	if not CanSubmitReport(ReportMode) then
		return
	end

	local IsPlayerReport = ReportMode:GetSelectedIndex() == 2
	local Reason = ((IsPlayerReport and ABUSE_TYPES_PLAYER) or ABUSE_TYPES_GAME)[TypeOfAbuse:GetSelectedIndex()]
	local TargetPlayer = IsPlayerReport and NameToPlayer[WhichPlayer:GetSelectedValue()] or nil
	local DescriptionText = GetReportDescription()

	if IsPlayerReport and not TargetPlayer then
		RefreshSubmitState(ReportMode)
		return
	end

	local Success = Protect(function()
		Players.ReportAbuse(LocalPlayer, TargetPlayer, Reason, DescriptionText)
	end)

	if not Success then
		Success = Protect(function()
			Players:ReportAbuse(TargetPlayer, Reason, DescriptionText)
		end)
	end

	local AlertText = "Thanks for your report! Our moderators will review the chat logs and evaluate what happened."
	if Reason == "Cheating/Exploiting" then
		AlertText = "Thanks for your report! We've recorded your report for evaluation."
	elseif Reason == "Inappropriate Username" then
		AlertText = "Thanks for your report! Our moderators will evaluate the username."
	elseif
		Reason == "Bad Model or Script"
		or Reason == "Inappropriate Content"
		or Reason == "Offsite Link"
		or Reason == "Offsite Links"
	then
		AlertText = "Thanks for your report! Our moderators will review the place and make a determination."
	end

	if not Success then
		AlertText = "Report could not be submitted in this environment."
	end

	ShowAlert(AlertText, "Ok", function()
		ReportMode:SetSelectionIndex(1, true)
		WhichPlayer:ResetSelectionIndex()
		TypeOfAbuse:ResetSelectionIndex()
		Description.Text = DESCRIPTION_PLACEHOLDER
		SetVisibility(false)
	end)
end)

Submit.Parent = ReportPage.Frame
Submit.Position = UDim2.new(0.5, -99, 0, ReportPage.Frame.Size.Y.Offset + 10)
ReportPage.Frame.Size = UDim2.new(1, 0, 0, ReportPage.Frame.Size.Y.Offset + 70)
SetSubmitActive(false)
RefreshReportPlayers()

local HelpPage = MakePage("Help")
AddPage(HelpPage, "Help", "rbxasset://textures/ui/Settings/MenuBarIcons/HelpTab.png", 130)

local CreateHelpGroup = function(Title, Bindings, Position)
	local Group = Create("Frame", {
		Parent = HelpPage.Frame,
		Name = "PCGroupFrame" .. Title,
		BackgroundTransparency = 1,
		Position = Position,
		Size = UDim2.new(1 / 3, -4, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 2,
	})

	Create("TextLabel", {
		Parent = Group,
		BackgroundTransparency = 1,
		Text = Title,
		Font = Enum.Font.SourceSansBold,
		TextSize = 18,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -9, 0, 30),
		Position = UDim2.new(0, 9, 0, 0),
		ZIndex = SETTINGS_BASE_ZINDEX + 3,
	})

	for Index, Binding in ipairs(Bindings) do
		local Row = Create("Frame", {
			Parent = Group,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.65,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 42),
			Position = UDim2.new(0, 0, 0, 30 + ((Index - 1) * 44)),
			ZIndex = SETTINGS_BASE_ZINDEX + 2,
		})

		Create("TextLabel", {
			Parent = Row,
			BackgroundTransparency = 1,
			Text = Binding[1],
			Font = Enum.Font.SourceSansBold,
			TextSize = 18,
			TextColor3 = Color3.new(1, 1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0.45, -9, 1, 0),
			Position = UDim2.new(0, 9, 0, 0),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
		})

		Create("TextLabel", {
			Parent = Row,
			BackgroundTransparency = 1,
			Text = Binding[2],
			Font = Enum.Font.SourceSans,
			TextSize = 18,
			TextColor3 = Color3.new(1, 1, 1),
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(0.55, 0, 1, 0),
			Position = UDim2.new(0.5, -4, 0, 0),
			ZIndex = SETTINGS_BASE_ZINDEX + 3,
		})
	end

	Group.Size = UDim2.new(Group.Size.X.Scale, Group.Size.X.Offset, 0, 30 + (#Bindings * 44))
	return Group
end

local IsOSX = UserInputService:GetPlatform() == Enum.Platform.OSX
local CharMoveFrame = CreateHelpGroup("Character Movement", {
	{ "Move Forward", "W/Up Arrow" },
	{ "Move Backward", "S/Down Arrow" },
	{ "Move Left", "A/Left Arrow" },
	{ "Move Right", "D/Right Arrow" },
	{ "Jump", "Space" },
}, UDim2.new(0, 0, 0, 0))

CreateHelpGroup("Accessories", {
	{ "Equip Tools", "1,2,3..." },
	{ "Unequip Tools", "1,2,3..." },
	{ "Drop Tool", "Backspace" },
	{ "Use Tool", "Left Mouse Button" },
	{ "Drop Hats", "+" },
}, UDim2.new(1 / 3, 4, 0, 0))

CreateHelpGroup("Misc", {
	{ "Screenshot", "Print Screen" },
	{ "Record Video", IsOSX and "F12/fn + F12" or "F12" },
	{ "Dev Console", IsOSX and "F9/fn + F9" or "F9" },
	{ "Mouselock", "Shift" },
	{ "Graphics Level", IsOSX and "F10/fn + F10" or "F10" },
	{ "Fullscreen", IsOSX and "F11/fn + F11" or "F11" },
}, UDim2.new(2 / 3, 8, 0, 0))

CreateHelpGroup("Camera Movement", {
	{ "Rotate", "Right Mouse Button" },
	{ "Zoom In/Out", "Mouse Wheel" },
	{ "Zoom In", "I" },
	{ "Zoom Out", "O" },
}, UDim2.new(0, 0, 0, CharMoveFrame.Size.Y.Offset + 50))

local MenuFrame = CreateHelpGroup("Menu Items", {
	{ "ROBLOX Menu", "ESC" },
	{ "Backpack", "~" },
	{ "Playerlist", "TAB" },
	{ "Chat", "/" },
}, UDim2.new(1 / 3, 4, 0, CharMoveFrame.Size.Y.Offset + 50))

HelpPage.Frame.Size = UDim2.new(1, 0, 0, MenuFrame.Position.Y.Offset + MenuFrame.Size.Y.Offset)

local RecordPage = nil
Protect(function()
	local Platform = UserInputService:GetPlatform()

	if Platform == Enum.Platform.Windows or Platform == Enum.Platform.OSX then
		RecordPage = MakePage("Record")
		AddPage(RecordPage, "Record", "rbxasset://textures/ui/Settings/MenuBarIcons/RecordTab.png", 130)

		local ScreenshotTitle =
			MakeText(RecordPage.Frame, "Screenshot", UDim2.new(1, 0, 0, 36), UDim2.new(0, 10, 0.05, 0))
		ScreenshotTitle.TextSize = 36
		ScreenshotTitle.TextXAlignment = Enum.TextXAlignment.Left

		local ScreenshotBody = MakeText(
			ScreenshotTitle,
			"By clicking the 'Take Screenshot' button, the menu will close and take a screenshot and save it to your computer.",
			UDim2.new(1, -10, 0, 70),
			UDim2.new(0, 0, 1, 0)
		)
		ScreenshotBody.Font = Enum.Font.SourceSans
		ScreenshotBody.TextSize = 24
		ScreenshotBody.TextXAlignment = Enum.TextXAlignment.Left
		ScreenshotBody.TextYAlignment = Enum.TextYAlignment.Top

		local ScreenshotButton = MakeStyledButton(
			"ScreenshotButton",
			"Take Screenshot",
			UDim2.new(0, 300, 0, 44),
			function()
				RunAfterMenuCloses(function()
					pcall(function()
						if keypress and keyrelease then
							keypress(KEY_PRINT_SCREEN)
							keyrelease(KEY_PRINT_SCREEN)
						else
							StarterGui:SetCore("TakeScreenshot")
						end
					end)
				end)
			end
		)
		ScreenshotButton.Parent = ScreenshotBody
		ScreenshotButton.Position = UDim2.new(0, 400, 1, 0)

		local VideoTitle = MakeText(RecordPage.Frame, "Video", UDim2.new(1, 0, 0, 36), UDim2.new(0, 10, 0.5, 0))
		VideoTitle.TextSize = 36
		VideoTitle.TextXAlignment = Enum.TextXAlignment.Left

		local VideoBody = MakeText(
			VideoTitle,
			"By clicking the 'Record Video' button, the menu will close and start recording your screen.",
			UDim2.new(1, -10, 0, 70),
			UDim2.new(0, 0, 1, 0)
		)
		VideoBody.Font = Enum.Font.SourceSans
		VideoBody.TextSize = 24
		VideoBody.TextXAlignment = Enum.TextXAlignment.Left
		VideoBody.TextYAlignment = Enum.TextYAlignment.Top

		local StartSetting = 2
		Protect(function()
			if GameSettings.VideoUploadPromptBehavior == Enum.UploadSetting.Never then
				StartSetting = 1
			end
		end)

		local VideoSettingsMode = MakeSelector(
			RecordPage,
			"Video Settings",
			{ "Save To Disk", "Upload to YouTube" },
			StartSetting,
			function(Index)
				Protect(function()
					GameSettings.VideoUploadPromptBehavior = (Index == 1 and Enum.UploadSetting.Never)
						or Enum.UploadSetting.Always
				end)
			end
		)

		local LastRow = RecordPage.Rows[#RecordPage.Rows]
		if LastRow then
			LastRow.Position = UDim2.new(0, 0, 0, 270)
			VideoSettingsMode:SetPosition(UDim2.new(1, -502, 0.5, -25))
		end

		local RecordButton = MakeStyledButton("RecordButton", "Record Video", UDim2.new(0, 300, 0, 44), function()
			RunAfterMenuCloses(function()
				pcall(function()
					if keypress and keyrelease then
						keypress(KEY_F12)
						keyrelease(KEY_F12)
					else
						StarterGui:SetCore("ToggleRecording")
					end
				end)
			end)
		end)
		RecordButton.Parent = LastRow or RecordPage.Frame
		RecordButton.Position = (LastRow and UDim2.new(0, 410, 1, 10)) or UDim2.new(0, 410, 0, 330)
		RecordPage.Frame.Size = UDim2.new(1, 0, 0, 400)
	end
end)

local ResetPage = MakePage("ResetCharacter")
AddPage(ResetPage)
MakeText(
	ResetPage.Frame,
	"Are you sure you want to reset your character?",
	UDim2.new(1, 0, 0, 200),
	UDim2.new(0, 0, 0, 0)
).TextSize =
	36

local ResetCharacter = function()
	local Character = LocalPlayer.Character
	local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")

	if Humanoid then
		Humanoid.Health = 0
	end

	SetVisibility(false, true)
end

local LeaveGame = function()
	game:Shutdown()
end

local ResetButton = MakeStyledButton("ResetCharacter", "Reset", UDim2.new(0, 200, 0, 50), ResetCharacter)
ResetButton.Parent = ResetPage.Frame
ResetButton.Position = UDim2.new(0.5, -220, 0, 170)
local DontResetButton = MakeStyledButton("DontResetCharacter", "Don't Reset", UDim2.new(0, 200, 0, 50), function()
	Hub.HubBar.Visible = true
	Hub.BottomButtonFrame.Visible = true
	SwitchToPage(Hub.MenuStack[#Hub.MenuStack] or GamePage, true, true)
end)
DontResetButton.Parent = ResetPage.Frame
DontResetButton.Position = UDim2.new(0.5, 20, 0, 170)
ResetPage.Frame.Size = UDim2.new(1, 0, 0, 240)

local LeavePage = MakePage("LeaveGame")
AddPage(LeavePage)
MakeText(LeavePage.Frame, "Are you sure you want to leave the game?", UDim2.new(1, 0, 0, 200), UDim2.new(0, 0, 0, 0)).TextSize =
	36
local LeaveButton = MakeStyledButton("LeaveGame", "Leave", UDim2.new(0, 200, 0, 50), LeaveGame)
LeaveButton.Parent = LeavePage.Frame
LeaveButton.Position = UDim2.new(0.5, -220, 0, 170)
local DontLeaveButton = MakeStyledButton("DontLeaveGame", "Don't Leave", UDim2.new(0, 200, 0, 50), function()
	Hub.HubBar.Visible = true
	Hub.BottomButtonFrame.Visible = true
	SwitchToPage(Hub.MenuStack[#Hub.MenuStack] or GamePage, true, true)
end)
DontLeaveButton.Parent = LeavePage.Frame
DontLeaveButton.Position = UDim2.new(0.5, 20, 0, 170)
LeavePage.Frame.Size = UDim2.new(1, 0, 0, 240)

local PushPage = function(Page)
	Insert(Hub.MenuStack, GetSelectedPage())
	Hub.HubBar.Visible = false
	Hub.BottomButtonFrame.Visible = false
	SwitchToPage(Page, true, true)
end

local MakeBottomButton = function(Name, Text, Icon, Position, Clicked, Size)
	local Button = MakeStyledButton(Name .. "Button", Text, Size or UDim2.new(0, 260, 0, 70), Clicked)
	Button.Parent = Hub.BottomButtonFrame
	Button.Position = Position

	Create("ImageLabel", {
		Parent = Button,
		BackgroundTransparency = 1,
		Image = Icon,
		Size = UDim2.new(0, 48, 0, 48),
		Position = UDim2.new(0, 10, 0, 8),
		ZIndex = SETTINGS_BASE_ZINDEX + 4,
	})

	local Label = Button:FindFirstChild(Name .. "ButtonTextLabel")
	if Label then
		Label.Position = UDim2.new(0, 10, 0, -4)
		Label.Size = UDim2.new(1, 0, 1, 0)
	end

	return Button
end

local BottomButtonSize = UDim2.new(0, 260, 0, 70)

MakeBottomButton(
	"ResetCharacter",
	"    Reset Character",
	"rbxasset://textures/ui/Settings/Help/ResetIcon.png",
	UDim2.new(0.5, -400, 0.5, -25),
	function()
		PushPage(ResetPage)
	end,
	BottomButtonSize
)

MakeBottomButton(
	"LeaveGame",
	"Leave Game",
	"rbxasset://textures/ui/Settings/Help/LeaveIcon.png",
	UDim2.new(0.5, -130, 0.5, -25),
	function()
		PushPage(LeavePage)
	end,
	BottomButtonSize
)

MakeBottomButton(
	"Resume",
	"Resume Game",
	"rbxasset://textures/ui/Settings/Help/EscapeIcon.png",
	UDim2.new(0.5, 140, 0.5, -25),
	function()
		SetVisibility(false)
	end,
	BottomButtonSize
)

local HideNativeSettingsMenu = function()
	local RobloxGui = CoreGui:FindFirstChild("RobloxGui")
	local Shield = RobloxGui and RobloxGui:FindFirstChild("SettingsClippingShield")

	if Shield then
		local HideGuiObject = function(Object)
			if not Object:IsA("GuiObject") then
				return
			end

			pcall(function()
				Object.Visible = false
			end)
			pcall(function()
				Object.Active = false
			end)
			pcall(function()
				Object.Selectable = false
			end)
			pcall(function()
				Object.AutoButtonColor = false
			end)
			pcall(function()
				Object.BackgroundTransparency = 1
			end)
			pcall(function()
				Object.ImageTransparency = 1
			end)
			pcall(function()
				Object.TextTransparency = 1
			end)
		end

		HideGuiObject(Shield)

		for _, Child in next, Shield:GetDescendants() do
			HideGuiObject(Child)
		end
	end
end

local INPUT_LOCK_ACTION = "Settings2016InputLock"
local InputLockBound = false
local InputLockInputs = {}
local InputLockActions = {}
local SavedMouseBehavior = nil
local WasRightMouseDownOnLock = false

local AddInputLock = function(EnumName, Name)
	Protect(function()
		local EnumType = Enum[EnumName]
		local Item = EnumType and EnumType[Name]
		if Item then
			Insert(InputLockInputs, Item)
		end
	end)
end

AddInputLock("PlayerActions", "CharacterForward")
AddInputLock("PlayerActions", "CharacterBackward")
AddInputLock("PlayerActions", "CharacterLeft")
AddInputLock("PlayerActions", "CharacterRight")
AddInputLock("PlayerActions", "CharacterJump")
AddInputLock("KeyCode", "W")
AddInputLock("KeyCode", "A")
AddInputLock("KeyCode", "S")
AddInputLock("KeyCode", "D")
AddInputLock("KeyCode", "Space")
AddInputLock("KeyCode", "LeftShift")
AddInputLock("KeyCode", "RightShift")
AddInputLock("KeyCode", "Thumbstick1")
AddInputLock("KeyCode", "Thumbstick2")
AddInputLock("UserInputType", "MouseButton2")

local IsRightMouseDown = function()
	local IsDown = false

	Protect(function()
		IsDown = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	end)

	return IsDown
end

local ReleaseRightMouseCapture = function()
	Protect(function()
		if mouse2release then
			mouse2release()
		end
	end)

	Protect(function()
		if VirtualInputManager then
			local MouseLocation = UserInputService:GetMouseLocation()
			VirtualInputManager:SendMouseButtonEvent(MouseLocation.X, MouseLocation.Y, 1, false, game, 0)
		end
	end)
end

local SinkGameplayInput = function()
	local FocusedTextBox = nil
	Protect(function()
		FocusedTextBox = UserInputService:GetFocusedTextBox()
	end)

	if FocusedTextBox then
		return Enum.ContextActionResult.Pass
	end

	return Enum.ContextActionResult.Sink
end

local SetGameplayInputLocked = function(Locked)
	if InputLockBound == Locked then
		return
	end

	InputLockBound = Locked

	if Locked then
		Protect(function()
			WasRightMouseDownOnLock = IsRightMouseDown()
			SavedMouseBehavior = UserInputService.MouseBehavior
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end)
		ReleaseRightMouseCapture()

		InputLockActions = {}

		for Index, Input in next, InputLockInputs do
			local ActionName = INPUT_LOCK_ACTION .. tostring(Index)
			local Bound = Protect(function()
				ContextActionService:BindCoreActionAtPriority(ActionName, SinkGameplayInput, false, 10000, Input)
			end)

			if not Bound then
				Bound = Protect(function()
					ContextActionService:BindCoreAction(ActionName, SinkGameplayInput, false, Input)
				end)
			end

			if not Bound then
				Bound = Protect(function()
					ContextActionService:BindActionAtPriority(ActionName, SinkGameplayInput, false, 10000, Input)
				end)
			end

			if Bound then
				Insert(InputLockActions, ActionName)
			end
		end
	else
		for _, ActionName in next, InputLockActions do
			Protect(function()
				ContextActionService:UnbindCoreAction(ActionName)
			end)
			Protect(function()
				ContextActionService:UnbindAction(ActionName)
			end)
		end
		InputLockActions = {}

		Protect(function()
			if SavedMouseBehavior and not (WasRightMouseDownOnLock and SavedMouseBehavior == Enum.MouseBehavior.LockCurrentPosition) then
				UserInputService.MouseBehavior = SavedMouseBehavior
			else
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
			SavedMouseBehavior = nil
			WasRightMouseDownOnLock = false
		end)
	end
end

SetVisibility = function(Visible, NoAnimation, CustomPage)
	if Hub.Visible == Visible and not CustomPage then
		return
	end

	Hub.Visible = Visible
	Hub.Modal.Visible = Visible
	SetGameplayInputLocked(Visible)

	if Visible then
		HideNativeSettingsMenu()
		Hub.Shield.Visible = true
		Hub.HubBar.Visible = true
		Hub.PageClipper.Visible = true
		Hub.BottomButtonFrame.Visible = true

		if NoAnimation then
			Hub.Shield.Position = SETTINGS_ACTIVE_POSITION
		else
			Hub.Shield.Position = SETTINGS_INACTIVE_POSITION
			TweenTo(Hub.Shield, SETTINGS_ACTIVE_POSITION, Enum.EasingDirection.InOut, Enum.EasingStyle.Quart, 0.5)
		end

		SwitchToPage(CustomPage or PlayersPage, true)
	else
		if NoAnimation then
			Hub.Shield.Position = SETTINGS_INACTIVE_POSITION
			Hub.Shield.Visible = false
		else
			TweenTo(
				Hub.Shield,
				SETTINGS_INACTIVE_POSITION,
				Enum.EasingDirection.In,
				Enum.EasingStyle.Quad,
				0.4,
				function()
					if not Hub.Visible then
						Hub.Shield.Visible = false
					end
				end
			)
		end
	end
end

local ToggleVisibility = function()
	SetVisibility(not Hub.Visible)
end

SwitchToPage(GamePage, true)

local LastEscapeAction = 0
local EscapeAction = function(_, State)
	if State ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end

	local Now = tick()
	if (Now - LastEscapeAction) < 0.15 then
		return Enum.ContextActionResult.Sink
	end
	LastEscapeAction = Now

	HideNativeSettingsMenu()
	local WasVisible = Hub.Visible

	if Hub.Visible and (Hub.CurrentPage == ResetPage or Hub.CurrentPage == LeavePage) then
		Hub.HubBar.Visible = true
		Hub.BottomButtonFrame.Visible = true
		SwitchToPage(Hub.MenuStack[#Hub.MenuStack] or GamePage, true, true)
	else
		if WasVisible then
			Hub.SuppressNativeOpenUntil = Now + 0.8
		end

		ToggleVisibility()
	end

	Spawn(function()
		Wait()
		HideNativeSettingsMenu()
	end)

	return Enum.ContextActionResult.Sink
end

Protect(function()
	local BoundAtPriority = pcall(function()
		ContextActionService:BindCoreActionAtPriority(
			"RBXEscapeMainMenu",
			EscapeAction,
			false,
			10000,
			Enum.KeyCode.Escape,
			Enum.KeyCode.ButtonStart
		)
	end)

	if not BoundAtPriority then
		ContextActionService:BindCoreAction(
			"RBXEscapeMainMenu",
			EscapeAction,
			false,
			Enum.KeyCode.Escape,
			Enum.KeyCode.ButtonStart
		)
	end
end)

Connect(UserInputService.InputBegan, function(Input, Processed)
	if Processed and Input.KeyCode ~= Enum.KeyCode.Escape then
		return
	end

	if Input.KeyCode == Enum.KeyCode.Escape then
		EscapeAction(nil, Enum.UserInputState.Begin)
	elseif
		Hub.Visible
		and Input.KeyCode == Enum.KeyCode.R
		and Hub.CurrentPage ~= ResetPage
		and Hub.CurrentPage ~= LeavePage
	then
		PushPage(ResetPage)
	elseif
		Hub.Visible
		and Input.KeyCode == Enum.KeyCode.L
		and Hub.CurrentPage ~= ResetPage
		and Hub.CurrentPage ~= LeavePage
	then
		PushPage(LeavePage)
	elseif Hub.Visible and (Input.KeyCode == Enum.KeyCode.Return or Input.KeyCode == Enum.KeyCode.KeypadEnter) then
		if Hub.CurrentPage == ResetPage then
			ResetCharacter()
		elseif Hub.CurrentPage == LeavePage then
			LeaveGame()
		end
	end
end)

local HookNativeMenu = function()
	local HookedNative = {}

	local GetNativeMenuTarget = function()
		if Hub.NativeMenuTarget == nil then
			return true
		end

		return Hub.NativeMenuTarget
	end

	local NativeMenuOpened = function()
		HideNativeSettingsMenu()

		if tick() < Hub.SuppressNativeOpenUntil then
			return
		end

		SetVisibility(GetNativeMenuTarget())
		Hub.NativeMenuTarget = nil
	end

	local HookNativeObject = function(Object)
		if not Object or HookedNative[Object] or not Object:IsA("GuiObject") then
			return
		end

		HookedNative[Object] = true
		Connect(Object:GetPropertyChangedSignal("Visible"), function()
			if Object.Visible then
				NativeMenuOpened()
			end
		end)

		if Object.Visible then
			NativeMenuOpened()
		end
	end

	local RobloxGui = CoreGui:FindFirstChild("RobloxGui")
	local Shield = RobloxGui and RobloxGui:FindFirstChild("SettingsClippingShield")

	local HookNativeContainer = function(NewShield)
		if not NewShield then
			return
		end

		Shield = NewShield
		HideNativeSettingsMenu()

		for _, Object in next, NewShield:GetDescendants() do
			HookNativeObject(Object)
		end
	end

	HookNativeContainer(Shield)

	if RobloxGui then
		Connect(RobloxGui.DescendantAdded, function(Descendant)
			if Descendant.Name == "SettingsClippingShield" and Descendant.Parent == RobloxGui then
				HookNativeContainer(Descendant)
			elseif Shield and Descendant:IsDescendantOf(Shield) then
				HookNativeObject(Descendant)
				if Descendant:IsA("GuiObject") and Descendant.Visible then
					NativeMenuOpened()
				end
			end
		end)
	end

	local TopBarApp = CoreGui:FindFirstChild("TopBarApp")
	TopBarApp = TopBarApp and TopBarApp:FindFirstChild("TopBarApp")
	local Holder = TopBarApp and TopBarApp:FindFirstChild("MenuIconHolder")
	local Hit = Holder and Holder:FindFirstChild("TriggerPoint") and Holder.TriggerPoint:FindFirstChild("IconHitArea")

	if Hit and Hit:IsA("GuiButton") then
		Connect(Hit.MouseButton1Click, function()
			local Target = not Hub.Visible
			Hub.NativeMenuTarget = Target
			Spawn(function()
				Wait()
				SetVisibility(Target)
				if Hub.NativeMenuTarget == Target then
					Hub.NativeMenuTarget = nil
				end
			end)
		end)
	end
end

Spawn(HookNativeMenu)

local Api = {}
function Api:SetVisibility(Visible, NoAnimation, CustomPage)
	SetVisibility(Visible, NoAnimation, CustomPage)
end

function Api:ToggleVisibility()
	ToggleVisibility()
end

function Api:GetVisibility()
	return Hub.Visible
end

function Api:ReportPlayer(Player)
	if OpenReportPlayer then
		OpenReportPlayer(Player)
	end
end

Api.Instance = Hub
getgenv().Settings2016 = Api

return Api
]============],
safechat=[============[local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local safeChatData = loadstring(game:HttpGet("https://raw.githubusercontent.com/mehh0vcki/scripts/refs/heads/main/static/safechat/".. _G.safeChatVersion ..".lua"))()

-- [FUNCTIONS]
local function instanceNewData(datatype: string, properties: table)
	local Item = Instance.new(datatype)
	if Item then
		for property, value in pairs(properties) do
			Item[property] = value
		end
	end
	return Item
end

local function resetElement(element)
    if element:IsA("Frame") then
        element.Visible = false
    elseif element:IsA("TextButton") then
        element.BackgroundColor3 = Color3.new(1, 1, 1)
    end
    for _, child in pairs(element:GetChildren()) do
        resetElement(child)
    end
end

-- [ELEMENTS]
local SafeChatGUI = instanceNewData("ScreenGui", { -- [SCREENGUI]
    Name="SafeChatGUI", 
    Parent=game.CoreGui
})

local SafeChatFrame = instanceNewData("Frame", {
    Name = "SafeChatFrame",
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.fromScale(0, 1),
    Size = UDim2.fromScale(1, 1),
    Parent = SafeChatGUI
})

local UIAspectRatio = instanceNewData("UIAspectRatioConstraint", {
    Name = "UIAspectRatio",
    AspectRatio = 1.333,
    Parent = SafeChatFrame
})

local Templates = instanceNewData("Folder", { -- [TEMPLATES]
    Name = "Templates",
    Parent = SafeChatFrame
})

local TempBranch = instanceNewData("Frame", {
    Name = "TempBranch",
    AnchorPoint = Vector2.new(0, 0.5),
    BackgroundTransparency = 1,
    BackgroundColor3 = Color3.fromRGB(255,255,255),
    BorderColor3 = Color3.fromRGB(27, 42, 53),
    BorderSizePixel = 1,
    Position = UDim2.new(1, 5, 0.5, 0),
    Size = UDim2.fromOffset(140, 24),
    ZIndex = 2,
    Parent = Templates,
    Visible = false
})

local UIListLayout = instanceNewData("UIListLayout", {
	Padding = UDim.new(0, 5),
    SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Center,
    Parent = TempBranch
})

local TempButton = instanceNewData("TextButton", {
    Name = "TempButton",
    BackgroundColor3 = Color3.fromRGB(255, 255, 255),
    BorderColor3 = Color3.fromRGB(62, 62, 62),
    BorderSizePixel = 1,
    Position = UDim2.fromScale(0,0),
    Size = UDim2.fromOffset(140, 24),
    ZIndex = 2,
	Font = Enum.Font.Cartoon,
    TextSize = 12,
    TextStrokeTransparency = 0.95,
    TextTransparency = 0.25,
    Parent = Templates,
    Visible = false
})

local ChatButton = instanceNewData("ImageButton", { -- [CHATBUTTON]
    Name = "ChatButton",
    BackgroundTransparency = 1,
    Position = UDim2.fromScale(0.02, 0.535),
    Size = UDim2.fromOffset(32, 32),
    Image = "rbxassetid://991182833",
    Parent = SafeChatFrame
})

local Click = instanceNewData("Sound", {
    Name = "Click",
    SoundId = "rbxasset://sounds/switch.mp3",
    Volume = 0.5,
    Parent = ChatButton
})

local Hint = instanceNewData("ImageLabel", {
    Name = "Hint",
    AnchorPoint = Vector2.new(0.5, 0.75),
    BackgroundTransparency = 1,
    Position = UDim2.new(1, 5, 0, 0),
    Size = UDim2.fromScale(0.75, 0.75),
    Image = "rbxasset://textures/ui/Settings/Help/XButtonDark@2x.png",
    Parent = ChatButton
}) -- it was pain to type it all out

-- [SETUP]
local chatNavigation
local isChatHovered = false

local function buildChatTree(chatNode)
		local branchFrame = TempBranch:Clone()
		branchFrame.Name = "Branches"
		local selectedButton = nil

		for index, branch in ipairs(chatNode.Branches) do
			local label = branch.Label
			local button = TempButton:Clone()
			button.Name = label
			button.Text = label
			button.LayoutOrder = index
			button.Visible = true

			local subBranchFrame = buildChatTree(branch)
			subBranchFrame.Parent = button
			button.Parent = branchFrame

			local function highlightButton()
				if selectedButton then
					resetElement(selectedButton)
				end
				selectedButton = button
				button.BackgroundColor3 = Color3.new(0.7, 0.7, 0.7)
				subBranchFrame.Visible = true
			end

			local function onButtonClick()
				local shouldSendMessage = true
				if UserInputService.TouchEnabled and not subBranchFrame.Visible and #subBranchFrame:GetChildren() > 1 then
					subBranchFrame.Visible = true
					shouldSendMessage = false
				end
				if shouldSendMessage then
					local textChannel = TextChatService:FindFirstChild("RBXGeneral", true)
					if textChannel and textChannel:IsA("TextChannel") then
						textChannel:SendAsync(label)
					end
					Click:Play()
					ChatButton.Image = "rbxassetid://991182833"
					resetElement(chatNavigation)
				end
			end

			button.MouseEnter:Connect(highlightButton)
			button.SelectionGained:Connect(highlightButton)
			button.MouseButton1Down:Connect(onButtonClick)
		end
		return branchFrame
	end

chatNavigation = buildChatTree(safeChatData)
chatNavigation.Parent = ChatButton

ChatButton.MouseEnter:Connect(function()
    ChatButton.Image = "rbxassetid://991182834"
    isChatHovered = true
end)

ChatButton.MouseLeave:Connect(function()
    ChatButton.Image = "rbxassetid://991182833"
    isChatHovered = false
end)

ChatButton.MouseButton1Down:Connect(function()
    ChatButton.Image = "rbxassetid://991182832"
    if isChatHovered then
        chatNavigation.Visible = not chatNavigation.Visible
        ChatButton.Image = "rbxassetid://991182832"
    end
end)

-- [CLEAN UP]
UserInputService.InputBegan:Connect(function(input, proceeded)
    if proceeded then return end
    if input.KeyCode == _G.keyToDestroy then
        SafeChatGUI:Destroy()
        script.Enabled = false
    end
end)
]============],
safechatData=[============[local safeChatData = {
    Label = "ROOT",
    Branches = {
        {
            Label = "Use the Chat menu to talk to me.",
            Branches = {}
        },
        {
            Label = "I can only see menu chats.",
            Branches = {}
        },
        {
            Label = "Hello",
            Branches = {
                {
                    Label = "Hi",
                    Branches = {
                        {
                            Label = "Hi there!",
                            Branches = {}
                        },
                        {
                            Label = "Hi everyone",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Howdy",
                    Branches = {
                        {
                            Label = "Howdy partner!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Greetings",
                    Branches = {
                        {
                            Label = "Greetings everyone",
                            Branches = {}
                        },
                        {
                            Label = "Greetings Robloxians!",
                            Branches = {}
                        },
                        {
                            Label = "Seasons greetings!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Welcome",
                    Branches = {
                        {
                            Label = "Welcome to my place",
                            Branches = {}
                        },
                        {
                            Label = "Welcome to our base",
                            Branches = {}
                        },
                        {
                            Label = "Welcome to my barbeque",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Hey there!",
                    Branches = {}
                },
                {
                    Label = "What's up?",
                    Branches = {
                        {
                            Label = "How are you doing?",
                            Branches = {}
                        },
                        {
                            Label = "How's it going?",
                            Branches = {}
                        },
                        {
                            Label = "What's new?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Good day",
                    Branches = {
                        {
                            Label = "Good morning",
                            Branches = {}
                        },
                        {
                            Label = "Good afternoon",
                            Branches = {}
                        },
                        {
                            Label = "Good evening",
                            Branches = {}
                        },
                        {
                            Label = "Good night",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Silly",
                    Branches = {
                        {
                            Label = "Waaaaaaaz up?!",
                            Branches = {}
                        },
                        {
                            Label = "Hullo!",
                            Branches = {}
                        },
                        {
                            Label = "Behold greatness, mortals!",
                            Branches = {}
                        },
                        {
                            Label = "Pardon me, is this Sparta?",
                            Branches = {}
                        },
                        {
                            Label = "THIS IS SPARTAAAA!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Happy Holidays!",
                    Branches = {
                        {
                            Label = "Happy New Year!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Valentine's Day!",
                            Branches = {}
                        },
                        {
                            Label = "Beware the Ides of March!",
                            Branches = {}
                        },
                        {
                            Label = "Happy St. Patrick's Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Easter!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Earth Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy 4th of July!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Thanksgiving!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Halloween!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Hanukkah!",
                            Branches = {}
                        },
                        {
                            Label = "Merry Christmas!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Halloween!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Earth Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy May Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy Towel Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy ROBLOX Day!",
                            Branches = {}
                        },
                        {
                            Label = "Happy LOL Day!",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Goodbye",
            Branches = {
                {
                    Label = "Good Night",
                    Branches = {
                        {
                            Label = "Sweet dreams",
                            Branches = {}
                        },
                        {
                            Label = "Go to sleep!",
                            Branches = {}
                        },
                        {
                            Label = "Lights out!",
                            Branches = {}
                        },
                        {
                            Label = "Bedtime",
                            Branches = {}
                        },
                        {
                            Label = "Going to bed now",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Later",
                    Branches = {
                        {
                            Label = "See ya later",
                            Branches = {}
                        },
                        {
                            Label = "Later gator!",
                            Branches = {}
                        },
                        {
                            Label = "See you tomorrow",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Bye",
                    Branches = {
                        {
                            Label = "Hasta la bye bye!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "I'll be right back",
                    Branches = {}
                },
                {
                    Label = "I have to go",
                    Branches = {}
                },
                {
                    Label = "Farewell",
                    Branches = {
                        {
                            Label = "Take care",
                            Branches = {}
                        },
                        {
                            Label = "Have a nice day",
                            Branches = {}
                        },
                        {
                            Label = "Goodluck!",
                            Branches = {}
                        },
                        {
                            Label = "Ta-ta for now!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Peace",
                    Branches = {
                        {
                            Label = "Peace out!",
                            Branches = {}
                        },
                        {
                            Label = "Peace dudes!",
                            Branches = {}
                        },
                        {
                            Label = "Rest in pieces!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Silly",
                    Branches = {
                        {
                            Label = "To the batcave!",
                            Branches = {}
                        },
                        {
                            Label = "Over and out!",
                            Branches = {}
                        },
                        {
                            Label = "Happy trails!",
                            Branches = {}
                        },
                        {
                            Label = "I've got to book it!",
                            Branches = {}
                        },
                        {
                            Label = "Tootles!",
                            Branches = {}
                        },
                        {
                            Label = "Smell you later!",
                            Branches = {}
                        },
                        {
                            Label = "GG!",
                            Branches = {}
                        },
                        {
                            Label = "My house is on fire! gtg.",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Friend",
            Branches = {
                {
                    Label = "Wanna be friends?",
                    Branches = {}
                },
                {
                    Label = "Follow me",
                    Branches = {
                        {
                            Label = "Come to my place!",
                            Branches = {}
                        },
                        {
                            Label = "Come to my base!",
                            Branches = {}
                        },
                        {
                            Label = "Follow me, team!",
                            Branches = {}
                        },
                        {
                            Label = "Follow me",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Your place is cool",
                    Branches = {
                        {
                            Label = "Your place is fun",
                            Branches = {}
                        },
                        {
                            Label = "Your place is awesome",
                            Branches = {}
                        },
                        {
                            Label = "Your place looks good",
                            Branches = {}
                        },
                        {
                            Label = "This place is awesome!",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Thank you",
                    Branches = {
                        {
                            Label = "Thanks for playing",
                            Branches = {}
                        },
                        {
                            Label = "Thanks for visiting",
                            Branches = {}
                        },
                        {
                            Label = "Thanks for everything",
                            Branches = {}
                        },
                        {
                            Label = "No, thank you",
                            Branches = {}
                        },
                        {
                            Label = "Thanx",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "No problem",
                    Branches = {
                        {
                            Label = "Don't worry",
                            Branches = {}
                        },
                        {
                            Label = "That's ok",
                            Branches = {}
                        },
                        {
                            Label = "np",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "You are ...",
                    Branches = {
                        {
                            Label = "You are great!",
                            Branches = {}
                        },
                        {
                            Label = "You are good!",
                            Branches = {}
                        },
                        {
                            Label = "You are cool!",
                            Branches = {}
                        },
                        {
                            Label = "You are funny!",
                            Branches = {}
                        },
                        {
                            Label = "You are silly!",
                            Branches = {}
                        },
                        {
                            Label = "You are awesome!",
                            Branches = {}
                        },
                        {
                            Label = "You are doing something I don't like, please stop",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "I like ...",
                    Branches = {
                        {
                            Label = "I like your name",
                            Branches = {}
                        },
                        {
                            Label = "I like your shirt",
                            Branches = {}
                        },
                        {
                            Label = "I like your place",
                            Branches = {}
                        },
                        {
                            Label = "I like your style",
                            Branches = {}
                        },
                        {
                            Label = "I like you",
                            Branches = {}
                        },
                        {
                            Label = "I like items",
                            Branches = {}
                        },
                        {
                            Label = "I like money",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Sorry",
                    Branches = {
                        {
                            Label = "My bad!",
                            Branches = {}
                        },
                        {
                            Label = "I'm sorry",
                            Branches = {}
                        },
                        {
                            Label = "Whoops!",
                            Branches = {}
                        },
                        {
                            Label = "Please forgive me.",
                            Branches = {}
                        },
                        {
                            Label = "I forgive you.",
                            Branches = {}
                        },
                        {
                            Label = "I didn't mean to do that.",
                            Branches = {}
                        },
                        {
                            Label = "Sorry, I'll stop now.",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Questions",
            Branches = {
                {
                    Label = "Who?",
                    Branches = {
                        {
                            Label = "Who wants to be my friend?",
                            Branches = {}
                        },
                        {
                            Label = "Who wants to be on my team?",
                            Branches = {}
                        },
                        {
                            Label = "Who made this brilliant game?",
                            Branches = {}
                        },
                        {
                            Label = "LOLWHO?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "What?",
                    Branches = {
                        {
                            Label = "What is your favorite animal?",
                            Branches = {}
                        },
                        {
                            Label = "What is your favorite game?",
                            Branches = {}
                        },
                        {
                            Label = "What is your favorite movie?",
                            Branches = {}
                        },
                        {
                            Label = "What is your favorite TV show?",
                            Branches = {}
                        },
                        {
                            Label = "What is your favorite music?",
                            Branches = {}
                        },
                        {
                            Label = "What are your hobbies?",
                            Branches = {}
                        },
                        {
                            Label = "LOLWUT?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "When?",
                    Branches = {
                        {
                            Label = "When are you online?",
                            Branches = {}
                        },
                        {
                            Label = "When is the new version coming out?",
                            Branches = {}
                        },
                        {
                            Label = "When can we play again?",
                            Branches = {}
                        },
                        {
                            Label = "When will your place be done?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Where?",
                    Branches = {
                        {
                            Label = "Where do you want to go?",
                            Branches = {}
                        },
                        {
                            Label = "Where are you going?",
                            Branches = {}
                        },
                        {
                            Label = "Where am I?!",
                            Branches = {}
                        },
                        {
                            Label = "Where did you go?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "How?",
                    Branches = {
                        {
                            Label = "How are you today?",
                            Branches = {}
                        },
                        {
                            Label = "How did you make this cool place?",
                            Branches = {}
                        },
                        {
                            Label = "LOLHOW?",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Can I...",
                    Branches = {
                        {
                            Label = "Can I have a tour?",
                            Branches = {}
                        },
                        {
                            Label = "Can I be on your team?",
                            Branches = {}
                        },
                        {
                            Label = "Can I be your friend?",
                            Branches = {}
                        },
                        {
                            Label = "Can I try something?",
                            Branches = {}
                        },
                        {
                            Label = "Can I have that please?",
                            Branches = {}
                        },
                        {
                            Label = "Can I have that back please?",
                            Branches = {}
                        },
                        {
                            Label = "Can I have borrow your hat?",
                            Branches = {}
                        },
                        {
                            Label = "Can I have borrow your gear?",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Answers",
            Branches = {
                {
                    Label = "You need help?",
                    Branches = {
                        {
                            Label = "Check out the news section",
                            Branches = {}
                        },
                        {
                            Label = "Check out the help section",
                            Branches = {}
                        },
                        {
                            Label = "Read the wiki!",
                            Branches = {}
                        },
                        {
                            Label = "All the answers are in the wiki!",
                            Branches = {}
                        },
                        {
                            Label = "I will help you with this.",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Some people ...",
                    Branches = {
                        {
                            Label = "Me",
                            Branches = {}
                        },
                        {
                            Label = "Not me",
                            Branches = {}
                        },
                        {
                            Label = "You",
                            Branches = {}
                        },
                        {
                            Label = "All of us",
                            Branches = {}
                        },
                        {
                            Label = "Everyone but you",
                            Branches = {}
                        },
                        {
                            Label = "Builderman!",
                            Branches = {}
                        },
                        {
                            Label = "Telamon!",
                            Branches = {}
                        },
                        {
                            Label = "My team",
                            Branches = {}
                        },
                        {
                            Label = "My group",
                            Branches = {}
                        },
                        {
                            Label = "Mom",
                            Branches = {}
                        },
                        {
                            Label = "Dad",
                            Branches = {}
                        },
                        {
                            Label = "Sister",
                            Branches = {}
                        },
                        {
                            Label = "Brother",
                            Branches = {}
                        },
                        {
                            Label = "Cousin",
                            Branches = {}
                        },
                        {
                            Label = "Grandparent",
                            Branches = {}
                        },
                        {
                            Label = "Friend",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Time ...",
                    Branches = {
                        {
                            Label = "In the morning",
                            Branches = {}
                        },
                        {
                            Label = "In the afternoon",
                            Branches = {}
                        },
                        {
                            Label = "At night",
                            Branches = {}
                        },
                        {
                            Label = "Tomorrow",
                            Branches = {}
                        },
                        {
                            Label = "This week",
                            Branches = {}
                        },
                        {
                            Label = "This month",
                            Branches = {}
                        },
                        {
                            Label = "Sometime",
                            Branches = {}
                        },
                        {
                            Label = "Sometimes",
                            Branches = {}
                        },
                        {
                            Label = "Whenever you want",
                            Branches = {}
                        },
                        {
                            Label = "Never",
                            Branches = {}
                        },
                        {
                            Label = "After this",
                            Branches = {}
                        },
                        {
                            Label = "In 10 minutes",
                            Branches = {}
                        },
                        {
                            Label = "In a couple hours",
                            Branches = {}
                        },
                        {
                            Label = "In a couple days",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Animals",
                    Branches = {
                        {
                            Label = "Cats",
                            Branches = {
                                {
                                    Label = "Lion",
                                    Branches = {}
                                },
                                {
                                    Label = "Tiger",
                                    Branches = {}
                                },
                                {
                                    Label = "Leopard",
                                    Branches = {}
                                },
                                {
                                    Label = "Cheetah",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Dogs",
                            Branches = {
                                {
                                    Label = "Wolves",
                                    Branches = {}
                                },
                                {
                                    Label = "Beagle",
                                    Branches = {}
                                },
                                {
                                    Label = "Collie",
                                    Branches = {}
                                },
                                {
                                    Label = "Dalmatian",
                                    Branches = {}
                                },
                                {
                                    Label = "Poodle",
                                    Branches = {}
                                },
                                {
                                    Label = "Spaniel",
                                    Branches = {}
                                },
                                {
                                    Label = "Shepherd",
                                    Branches = {}
                                },
                                {
                                    Label = "Terrier",
                                    Branches = {}
                                },
                                {
                                    Label = "Retriever",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Horses",
                            Branches = {
                                {
                                    Label = "Ponies",
                                    Branches = {}
                                },
                                {
                                    Label = "Stallions",
                                    Branches = {}
                                },
                                {
                                    Label = "Pwnyz",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Reptiles",
                            Branches = {
                                {
                                    Label = "Dinosaurs",
                                    Branches = {}
                                },
                                {
                                    Label = "Lizards",
                                    Branches = {}
                                },
                                {
                                    Label = "Snakes",
                                    Branches = {}
                                },
                                {
                                    Label = "Turtles!",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Hamster",
                            Branches = {}
                        },
                        {
                            Label = "Monkey",
                            Branches = {}
                        },
                        {
                            Label = "Bears",
                            Branches = {}
                        },
                        {
                            Label = "Fish",
                            Branches = {
                                {
                                    Label = "Goldfish",
                                    Branches = {}
                                },
                                {
                                    Label = "Sharks",
                                    Branches = {}
                                },
                                {
                                    Label = "Sea Bass",
                                    Branches = {}
                                },
                                {
                                    Label = "Halibut",
                                    Branches = {}
                                },
                                {
                                    Label = "Tropical Fish",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Birds",
                            Branches = {
                                {
                                    Label = "Eagles",
                                    Branches = {}
                                },
                                {
                                    Label = "Penguins",
                                    Branches = {}
                                },
                                {
                                    Label = "Parakeets",
                                    Branches = {}
                                },
                                {
                                    Label = "Owls",
                                    Branches = {}
                                },
                                {
                                    Label = "Hawks",
                                    Branches = {}
                                },
                                {
                                    Label = "Pidgeons",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Elephants",
                            Branches = {}
                        },
                        {
                            Label = "Mythical Beasts",
                            Branches = {
                                {
                                    Label = "Dragons",
                                    Branches = {}
                                },
                                {
                                    Label = "Unicorns",
                                    Branches = {}
                                },
                                {
                                    Label = "Sea Serpents",
                                    Branches = {}
                                },
                                {
                                    Label = "Sphinx",
                                    Branches = {}
                                },
                                {
                                    Label = "Cyclops",
                                    Branches = {}
                                },
                                {
                                    Label = "Minotaurs",
                                    Branches = {}
                                },
                                {
                                    Label = "Goblins",
                                    Branches = {}
                                },
                                {
                                    Label = "Honest Politicians",
                                    Branches = {}
                                },
                                {
                                    Label = "Ghosts",
                                    Branches = {}
                                },
                                {
                                    Label = "Scylla and Charybdis",
                                    Branches = {}
                                }
                            }
                        }
                    }
                },
                {
                    Label = "Games",
                    Branches = {
                        {
                            Label = "Roblox",
                            Branches = {
                                {
                                    Label = "BrickBattle",
                                    Branches = {}
                                },
                                {
                                    Label = "Community Building",
                                    Branches = {}
                                },
                                {
                                    Label = "Roblox Minigames",
                                    Branches = {}
                                },
                                {
                                    Label = "Contest Place",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Action",
                            Branches = {}
                        },
                        {
                            Label = "Puzzle",
                            Branches = {}
                        },
                        {
                            Label = "Strategy",
                            Branches = {}
                        },
                        {
                            Label = "Racing",
                            Branches = {}
                        },
                        {
                            Label = "RPG",
                            Branches = {}
                        },
                        {
                            Label = "Obstacle Course",
                            Branches = {}
                        },
                        {
                            Label = "Tycoon",
                            Branches = {}
                        },
                        {
                            Label = "Board games",
                            Branches = {
                                {
                                    Label = "Chess",
                                    Branches = {}
                                },
                                {
                                    Label = "Checkers",
                                    Branches = {}
                                },
                                {
                                    Label = "Settlers of Catan",
                                    Branches = {}
                                },
                                {
                                    Label = "Tigris and Euphrates",
                                    Branches = {}
                                },
                                {
                                    Label = "El Grande",
                                    Branches = {}
                                },
                                {
                                    Label = "Stratego",
                                    Branches = {}
                                },
                                {
                                    Label = "Carcassonne",
                                    Branches = {}
                                }
                            }
                        }
                    }
                },
                {
                    Label = "Sports",
                    Branches = {
                        {
                            Label = "Hockey",
                            Branches = {}
                        },
                        {
                            Label = "Soccer",
                            Branches = {}
                        },
                        {
                            Label = "Football",
                            Branches = {}
                        },
                        {
                            Label = "Baseball",
                            Branches = {}
                        },
                        {
                            Label = "Basketball",
                            Branches = {}
                        },
                        {
                            Label = "Volleyball",
                            Branches = {}
                        },
                        {
                            Label = "Tennis",
                            Branches = {}
                        },
                        {
                            Label = "Sports team practice",
                            Branches = {}
                        },
                        {
                            Label = "Watersports",
                            Branches = {
                                {
                                    Label = "Surfing",
                                    Branches = {}
                                },
                                {
                                    Label = "Swimming",
                                    Branches = {}
                                },
                                {
                                    Label = "Water Polo",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Winter sports",
                            Branches = {
                                {
                                    Label = "Skiing",
                                    Branches = {}
                                },
                                {
                                    Label = "Snowboarding",
                                    Branches = {}
                                },
                                {
                                    Label = "Sledding",
                                    Branches = {}
                                },
                                {
                                    Label = "Skating",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Adventure",
                            Branches = {
                                {
                                    Label = "Rock climbing",
                                    Branches = {}
                                },
                                {
                                    Label = "Hiking",
                                    Branches = {}
                                },
                                {
                                    Label = "Fishing",
                                    Branches = {}
                                },
                                {
                                    Label = "Horseback riding",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Wacky",
                            Branches = {
                                {
                                    Label = "Foosball",
                                    Branches = {}
                                },
                                {
                                    Label = "Calvinball",
                                    Branches = {}
                                },
                                {
                                    Label = "Croquet",
                                    Branches = {}
                                },
                                {
                                    Label = "Cricket",
                                    Branches = {}
                                },
                                {
                                    Label = "Dodgeball",
                                    Branches = {}
                                },
                                {
                                    Label = "Squash",
                                    Branches = {}
                                },
                                {
                                    Label = "Trampoline",
                                    Branches = {}
                                }
                            }
                        }
                    }
                },
                {
                    Label = "Movies/TV",
                    Branches = {
                        {
                            Label = "Science Fiction",
                            Branches = {}
                        },
                        {
                            Label = "Animated",
                            Branches = {
                                {
                                    Label = "Anime",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Comedy",
                            Branches = {}
                        },
                        {
                            Label = "Romantic",
                            Branches = {}
                        },
                        {
                            Label = "Action",
                            Branches = {}
                        },
                        {
                            Label = "Fantasy",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Music",
                    Branches = {
                        {
                            Label = "Country",
                            Branches = {}
                        },
                        {
                            Label = "Jazz",
                            Branches = {}
                        },
                        {
                            Label = "Rap",
                            Branches = {}
                        },
                        {
                            Label = "Hip-hop",
                            Branches = {}
                        },
                        {
                            Label = "Techno",
                            Branches = {}
                        },
                        {
                            Label = "Classical",
                            Branches = {}
                        },
                        {
                            Label = "Pop",
                            Branches = {}
                        },
                        {
                            Label = "Rock",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Hobbies",
                    Branches = {
                        {
                            Label = "Computers",
                            Branches = {
                                {
                                    Label = "Building computers",
                                    Branches = {}
                                },
                                {
                                    Label = "Videogames",
                                    Branches = {}
                                },
                                {
                                    Label = "Coding",
                                    Branches = {}
                                },
                                {
                                    Label = "Hacking",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "The Internet",
                            Branches = {
                                {
                                    Label = "lol. teh internets!",
                                    Branches = {}
                                },
                                {
                                    Label = "Watching vids",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Dance",
                            Branches = {}
                        },
                        {
                            Label = "Gymnastics",
                            Branches = {}
                        },
                        {
                            Label = "Martial Arts",
                            Branches = {
                                {
                                    Label = "Karate",
                                    Branches = {}
                                },
                                {
                                    Label = "Judo",
                                    Branches = {}
                                },
                                {
                                    Label = "Taikwon Do",
                                    Branches = {}
                                },
                                {
                                    Label = "Wushu",
                                    Branches = {}
                                },
                                {
                                    Label = "Street fighting",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Listening to music",
                            Branches = {}
                        },
                        {
                            Label = "Music lessons",
                            Branches = {
                                {
                                    Label = "Playing in my band",
                                    Branches = {}
                                },
                                {
                                    Label = "Playing piano",
                                    Branches = {}
                                },
                                {
                                    Label = "Playing guitar",
                                    Branches = {}
                                },
                                {
                                    Label = "Playing violin",
                                    Branches = {}
                                },
                                {
                                    Label = "Playing drums",
                                    Branches = {}
                                },
                                {
                                    Label = "Playing a weird instrument",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Arts and crafts",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Location",
                    Branches = {
                        {
                            Label = "USA",
                            Branches = {
                                {
                                    Label = "West",
                                    Branches = {
                                        {
                                            Label = "Alaska",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Arizona",
                                            Branches = {}
                                        },
                                        {
                                            Label = "California",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Colorado",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Hawaii",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Idaho",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Montana",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Nevada",
                                            Branches = {}
                                        },
                                        {
                                            Label = "New Mexico",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Oregon",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Utah",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Washington",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Wyoming",
                                            Branches = {}
                                        }
                                    }
                                },
                                {
                                    Label = "Midwest",
                                    Branches = {
                                        {
                                            Label = "Illinois",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Indiana",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Iowa",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Kansas",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Michigan",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Minnesota",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Missouri",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Nebraska",
                                            Branches = {}
                                        },
                                        {
                                            Label = "North Dakota",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Ohio",
                                            Branches = {}
                                        },
                                        {
                                            Label = "South Dakota",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Wisconsin",
                                            Branches = {}
                                        }
                                    }
                                },
                                {
                                    Label = "Northeast",
                                    Branches = {
                                        {
                                            Label = "Connecticut",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Delaware",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Maine",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Maryland",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Massachusetts",
                                            Branches = {}
                                        },
                                        {
                                            Label = "New Hampshire",
                                            Branches = {}
                                        },
                                        {
                                            Label = "New Jersey",
                                            Branches = {}
                                        },
                                        {
                                            Label = "New York",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Pennsylvania",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Rhode Island",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Vermont",
                                            Branches = {}
                                        }
                                    }
                                },
                                {
                                    Label = "South",
                                    Branches = {
                                        {
                                            Label = "Alabama",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Arkansas",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Florida",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Georgia",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Kentucky",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Louisiana",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Mississippi",
                                            Branches = {}
                                        },
                                        {
                                            Label = "North Carolina",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Oklahoma",
                                            Branches = {}
                                        },
                                        {
                                            Label = "South Carolina",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Tennessee",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Texas",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Virginia",
                                            Branches = {}
                                        },
                                        {
                                            Label = "West Virginia",
                                            Branches = {}
                                        }
                                    }
                                }
                            }
                        },
                        {
                            Label = "Canada",
                            Branches = {
                                {
                                    Label = "Alberta",
                                    Branches = {}
                                },
                                {
                                    Label = "British Columbia",
                                    Branches = {}
                                },
                                {
                                    Label = "Manitoba",
                                    Branches = {}
                                },
                                {
                                    Label = "New Brunswick",
                                    Branches = {}
                                },
                                {
                                    Label = "Newfoundland",
                                    Branches = {}
                                },
                                {
                                    Label = "Northwest Territories",
                                    Branches = {}
                                },
                                {
                                    Label = "Nova Scotia",
                                    Branches = {}
                                },
                                {
                                    Label = "Nunavut",
                                    Branches = {}
                                },
                                {
                                    Label = "Ontario",
                                    Branches = {}
                                },
                                {
                                    Label = "Prince Edward Island",
                                    Branches = {}
                                },
                                {
                                    Label = "Quebec",
                                    Branches = {}
                                },
                                {
                                    Label = "Saskatchewan",
                                    Branches = {}
                                },
                                {
                                    Label = "Yukon",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Mexico",
                            Branches = {}
                        },
                        {
                            Label = "Central America",
                            Branches = {}
                        },
                        {
                            Label = "Europe",
                            Branches = {
                                {
                                    Label = "Great Britain",
                                    Branches = {
                                        {
                                            Label = "England",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Scotland",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Wales",
                                            Branches = {}
                                        },
                                        {
                                            Label = "Northern Ireland",
                                            Branches = {}
                                        }
                                    }
                                },
                                {
                                    Label = "France",
                                    Branches = {}
                                },
                                {
                                    Label = "Germany",
                                    Branches = {}
                                },
                                {
                                    Label = "Spain",
                                    Branches = {}
                                },
                                {
                                    Label = "Italy",
                                    Branches = {}
                                },
                                {
                                    Label = "Poland",
                                    Branches = {}
                                },
                                {
                                    Label = "Switzerland",
                                    Branches = {}
                                },
                                {
                                    Label = "Greece",
                                    Branches = {}
                                },
                                {
                                    Label = "Romania",
                                    Branches = {}
                                },
                                {
                                    Label = "Netherlands",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Asia",
                            Branches = {
                                {
                                    Label = "China",
                                    Branches = {}
                                },
                                {
                                    Label = "India",
                                    Branches = {}
                                },
                                {
                                    Label = "Japan",
                                    Branches = {}
                                },
                                {
                                    Label = "Korea",
                                    Branches = {}
                                },
                                {
                                    Label = "Russia",
                                    Branches = {}
                                },
                                {
                                    Label = "Vietnam",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "South America",
                            Branches = {
                                {
                                    Label = "Argentina",
                                    Branches = {}
                                },
                                {
                                    Label = "Brazil",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Africa",
                            Branches = {
                                {
                                    Label = "Eygpt",
                                    Branches = {}
                                },
                                {
                                    Label = "Swaziland",
                                    Branches = {}
                                }
                            }
                        },
                        {
                            Label = "Australia",
                            Branches = {}
                        },
                        {
                            Label = "Middle East",
                            Branches = {}
                        },
                        {
                            Label = "Antarctica",
                            Branches = {}
                        },
                        {
                            Label = "New Zealand",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Age",
                    Branches = {
                        {
                            Label = "Rugrat",
                            Branches = {}
                        },
                        {
                            Label = "Kid",
                            Branches = {}
                        },
                        {
                            Label = "Tween",
                            Branches = {}
                        },
                        {
                            Label = "Teen",
                            Branches = {}
                        },
                        {
                            Label = "Twenties",
                            Branches = {}
                        },
                        {
                            Label = "Old",
                            Branches = {}
                        },
                        {
                            Label = "Ancient",
                            Branches = {}
                        },
                        {
                            Label = "Mesozoic",
                            Branches = {}
                        },
                        {
                            Label = "I don't want to say my age. Don't ask.",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Mood",
                    Branches = {
                        {
                            Label = "Good",
                            Branches = {}
                        },
                        {
                            Label = "Great!",
                            Branches = {}
                        },
                        {
                            Label = "Not bad",
                            Branches = {}
                        },
                        {
                            Label = "Sad",
                            Branches = {}
                        },
                        {
                            Label = "Hyper",
                            Branches = {}
                        },
                        {
                            Label = "Chill",
                            Branches = {}
                        },
                        {
                            Label = "Happy",
                            Branches = {}
                        },
                        {
                            Label = "Kind of mad",
                            Branches = {}
                        }
                    }
                },
                {
                    Label = "Boy",
                    Branches = {}
                },
                {
                    Label = "Girl",
                    Branches = {}
                },
                {
                    Label = "I don't want to say boy or girl. Don't ask.",
                    Branches = {}
                }
            }
        },
        {
            Label = "Game",
            Branches = {
                {
                    Label = "Let's build",
                    Branches = {}
                },
                {
                    Label = "Let's battle",
                    Branches = {}
                },
                {
                    Label = "Nice one!",
                    Branches = {}
                },
                {
                    Label = "So far so good!",
                    Branches = {}
                },
                {
                    Label = "Lucky shot!",
                    Branches = {}
                },
                {
                    Label = "Oh man!",
                    Branches = {}
                },
                {
                    Label = "I challenge you to a fight!",
                    Branches = {}
                },
                {
                    Label = "Help me with this",
                    Branches = {}
                },
                {
                    Label = "Let's go to your game",
                    Branches = {}
                },
                {
                    Label = "Can you show me how do to that?",
                    Branches = {}
                },
                {
                    Label = "Backflip!",
                    Branches = {}
                },
                {
                    Label = "Frontflip!",
                    Branches = {}
                },
                {
                    Label = "Dance!",
                    Branches = {}
                },
                {
                    Label = "I'm on your side!",
                    Branches = {}
                },
                {
                    Label = "Game Commands",
                    Branches = {
                        {
                            Label = "regen",
                            Branches = {}
                        },
                        {
                            Label = "reset",
                            Branches = {}
                        },
                        {
                            Label = "go",
                            Branches = {}
                        },
                        {
                            Label = "fix",
                            Branches = {}
                        },
                        {
                            Label = "respawn",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Silly",
            Branches = {
                {
                    Label = "Muahahahaha!",
                    Branches = {}
                },
                {
                    Label = "all your base are belong to me!",
                    Branches = {}
                },
                {
                    Label = "GET OFF MAH LAWN",
                    Branches = {}
                },
                {
                    Label = "TEH EPIK DUCK IS COMING!!!",
                    Branches = {}
                },
                {
                    Label = "ROFL",
                    Branches = {}
                },
                {
                    Label = "1337",
                    Branches = {
                        {
                            Label = "i r teh pwnz0r!",
                            Branches = {}
                        },
                        {
                            Label = "w00t!",
                            Branches = {}
                        },
                        {
                            Label = "z0mg h4x!",
                            Branches = {}
                        },
                        {
                            Label = "ub3rR0xXorzage!",
                            Branches = {}
                        }
                    }
                }
            }
        },
        {
            Label = "Yes",
            Branches = {
                {
                    Label = "Absolutely!",
                    Branches = {}
                },
                {
                    Label = "Rock on!",
                    Branches = {}
                },
                {
                    Label = "Totally!",
                    Branches = {}
                },
                {
                    Label = "Juice!",
                    Branches = {}
                },
                {
                    Label = "Yay!",
                    Branches = {}
                },
                {
                    Label = "Yesh",
                    Branches = {}
                }
            }
        },
        {
            Label = "No",
            Branches = {
                {
                    Label = "Ummm. No.",
                    Branches = {}
                },
                {
                    Label = "...",
                    Branches = {}
                },
                {
                    Label = "Stop!",
                    Branches = {}
                },
                {
                    Label = "Go away!",
                    Branches = {}
                },
                {
                    Label = "Don't do that",
                    Branches = {}
                },
                {
                    Label = "Stop breaking the rules",
                    Branches = {}
                },
                {
                    Label = "I don't want to",
                    Branches = {}
                }
            }
        },
        {
            Label = "Ok",
            Branches = {
                {
                    Label = "Well... ok",
                    Branches = {}
                },
                {
                    Label = "Sure",
                    Branches = {}
                }
            }
        },
        {
            Label = "Uncertain",
            Branches = {
                {
                    Label = "Maybe",
                    Branches = {}
                },
                {
                    Label = "I don't know",
                    Branches = {}
                },
                {
                    Label = "idk",
                    Branches = {}
                },
                {
                    Label = "I can't decide",
                    Branches = {}
                },
                {
                    Label = "Hmm...",
                    Branches = {}
                }
            }
        },
        {
            Label = ":-)",
            Branches = {
                {
                    Label = ":-(",
                    Branches = {}
                },
                {
                    Label = ":D",
                    Branches = {}
                },
                {
                    Label = ":-O",
                    Branches = {}
                },
                {
                    Label = "lol",
                    Branches = {}
                },
                {
                    Label = "=D",
                    Branches = {}
                },
                {
                    Label = "D=",
                    Branches = {}
                },
                {
                    Label = "XD",
                    Branches = {}
                },
                {
                    Label = ";D",
                    Branches = {}
                },
                {
                    Label = ";)",
                    Branches = {}
                },
                {
                    Label = "O_O",
                    Branches = {}
                },
                {
                    Label = "=)",
                    Branches = {}
                },
                {
                    Label = "@_@",
                    Branches = {}
                },
                {
                    Label = ">_<",
                    Branches = {}
                },
                {
                    Label = "T_T",
                    Branches = {}
                },
                {
                    Label = "^_^",
                    Branches = {}
                },
                {
                    Label = "<(0_0<) <(0_0)> (>0_0)> KIRBY DANCE",
                    Branches = {}
                },
                {
                    Label = ")';",
                    Branches = {}
                },
                {
                    Label = ":3",
                    Branches = {}
                }
            }
        },
        {
            Label = "Ratings",
            Branches = {
                {
                    Label = "Rate it!",
                    Branches = {}
                },
                {
                    Label = "I give it a 1 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 2 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 3 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 4 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 5 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 6 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 7 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 8 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 9 out of 10",
                    Branches = {}
                },
                {
                    Label = "I give it a 10 out of 10!",
                    Branches = {}
                }
            }
        }
    }
}
return safeChatData
]============],
emotes=[============[--[[ 
    Source script taken from: https://github.com/Roblox/creator-docs/blob/main/content/en-us/characters/emotes.md

    scriptblox: https://scriptblox.com/script/Universal-Script-7yd7-I-Emote-Script-48024
]]


if _G.EmotesGUIRunning then
    getgenv().Notify({
        Title = '7yd7 | Emote',
        Content = '⚠️ It works It actually works',
        Duration = 5
    })
    return
end
_G.EmotesGUIRunning = true
local offsaleAnimationJson = true

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")
local ContentProvider = game:GetService("ContentProvider")
local StarterGui = game:GetService("StarterGui")
local request = http_request or (syn and syn.request) or request

local State = {
    currentMode = "emote",
    savedAnimPage = 1,
    savedEmotePage = 1,
    emotesWalkEnabled = false,
    favoriteEnabled = false,
    hudEditorActive = false,
    speedEmoteEnabled = false,
    isLoading = false,
    favoriteSetVersion = 0,
    favoriteSetBuiltVersion = -1,
    emoteCacheVersion = 0,
    animationCacheVersion = 0,
    isGUICreated = false,
    isMonitoringClicks = false,
    lastRadialActionTime = 0,
    lastWheelVisibleTime = 0,
    lastActionTick = 0,
    lastRandomEmoteId = nil,
    lastRandomAnimationId = nil,
    lastRandomVisualSpam = 0,
    randomSpamConn = nil,
    animImageSpamConn = nil,
    animImageSpamMap = nil,
    animImageSpamTicks = nil,
    animImageSpamToken = 0,
    animImageRetry = 0,
    randomSlotBlockerConn = nil,
    totalEmotesLoaded = 0,
    currentPage = 1,
    totalPages = 1,
    itemsPerPage = 8,
    emoteSearchTerm = "",
    animationSearchTerm = "",
    currentEmoteTrack = nil,
    currentCharacter = nil,
    emoteClickConnections = {},
    guiConnections = {},
    animationsData = {},
    originalAnimationsData = {},
    filteredAnimations = {},
    favoriteAnimations = {},
    favoriteAnimationsFileName = "FavoriteAnimations.json",
    emotesData = {},
    originalEmotesData = {},
    filteredEmotes = {},
    scannedEmotes = {},
    favoriteEmotes = {},
    favoriteFileName = "FavoriteEmotes.json",
    speedEmoteConfigFile = "SpeedEmoteConfig.json",
    favoriteEmoteSet = {},
    favoriteAnimationSet = {},
    emotePageCache = { version = nil, normal = {}, favorites = {} },
    animationPageCache = { version = nil, normal = {}, favorites = {} },
    suppressSearch = false,
    emoteMonitorToken = 0,
    animationMonitorToken = 0,
    imageUpdateToken = 0,
    defaultButtonImage = "rbxassetid://71408678974152",
    enabledButtonImage = "rbxassetid://106798555684020",
    favoriteIconId = "rbxassetid://97307461910825",
    notFavoriteIconId = "rbxassetid://124025954365505",
    toolEquipped = false,
    EmoteTheme = nil,
    isApplyingTheme = false,
    targetImages = {},
    AnimationCachePath = "7yd7/AnimationCache.json",
    AnimationCache = {},
    AnimationListCachePath = "7yd7/AnimationListCache.json",
    EmoteListCachePath = "7yd7/EmoteListCache.json",
    CustomAnimationPath = "7yd7/CustomAnimations.json",
    CustomAnimations = {},
    currentCustomAnimationName = "Default",
    customAnimationEditorActive = false,
    customAnimationEditingKey = nil,
    customAnimationEditingName = nil,
    EmotePagePath = "7yd7/EmotePages.json",
    EmotePages = {},
    currentEmotePageName = "Default",
    EmoteDataCachePath = "7yd7/EmoteDataCache.json"
}

Config = {
    NotifyEnabled = true,
    SearchVisible = true,
    FavVisible = true,
    ModeVisible = true,
    FreezeVisible = true,
    SpeedVisible = true,
    NavVisible = true,
    EmoteSpeed = 1,
    EmoteSpeedEnabled = false,
    SelectedTheme = "Default",
    EmotePage = 1,
    AnimationPage = 1,
    RandomEnabled = true,
    RandomMode = "All",
    AuthenticFirstPage = false,
    HUDPositions = {},
    HUDSizes = {},
    HUDProperties = {},
    CustomFrames = {},
    AutoReloadEnabled = false,
    LastPlayedAnimationData = nil,
    DiscordVisible = true
}

HUD = {
    Connections = {},
    IsUnlocked = false,
    DefaultPositions = {},
    DefaultSizes = {},
    DefaultTexts = {},
    DefaultPlaceholders = {},
    Layouts = {},
    LayoutsRemoved = {},
    SelectionGui = nil,
    SelectedElement = nil,
    ResizeHandles = {},
    ResizeConnections = {},
    FriendlyNames = {
        ["Under.1left"] = "PrevPage",
        ["Under.9right"] = "NextPage",
        ["Under.4pages"] = "TotalPages",
        ["Under.3TextLabel"] = "Divider",
        ["Under.2Route-number"] = "CurrentPage",
        ["Top.Search"] = "Search",
        ["EmoteWalkButton"] = "Freeze",
        ["Favorite"] = "Favorite",
        ["SpeedEmote"] = "SpeedEmote",
        ["SpeedBox"] = "SpeedBox",
        ["Changepage"] = "ChangePage",
        ["Reload"] = "AutoReload",
        ["Top"] = "Top",
        ["Under"] = "Under"
    }
}

local DEFAULT_IDLE_ICON_ID = "rbxassetid://106798555684020"
local DEFAULT_IDLE_ICON_COLOR = Color3.fromRGB(0, 255, 150)

function DeepCopy(original)
    if type(original) ~= "table" then return original end
    local copy = {}
    for k, v in pairs(original) do
        if type(v) == "table" then
            v = DeepCopy(v)
        end
        copy[k] = v
    end
    return copy
end

function ColorToTable(color)
    return {color.R, color.G, color.B}
end

function TableToColor(tbl)
    if not tbl or type(tbl) ~= "table" or #tbl < 3 then return Color3.new(1,1,1) end
    return Color3.new(tbl[1], tbl[2], tbl[3])
end

function loadAnimationCache()
    if isfile and isfile(State.AnimationCachePath) then
        local success, decoded = pcall(function()
            return HttpService:JSONDecode(readfile(State.AnimationCachePath))
        end)
        if success and type(decoded) == "table" then
            State.AnimationCache = decoded
        end
    end
end

function saveAnimationCache()
    if writefile then
        pcall(function()
            if not isfolder("7yd7") then makefolder("7yd7") end
            writefile(State.AnimationCachePath, HttpService:JSONEncode(State.AnimationCache))
        end)
    end
end

function resolveAnimationMappings(bundledItems)
    local mappings = {}
    for _, assetIds in pairs(bundledItems) do
        for _, assetId in pairs(assetIds) do
            local success, objects = pcall(function()
                return game:GetObjects("rbxassetid://" .. assetId)
            end)
            if success and objects then
                local function searchTree(parent, parentPath)
                    for _, child in pairs(parent:GetChildren()) do
                        if child:IsA("Animation") then
                            local animationPath = parentPath .. "." .. child.Name
                            local pathParts = animationPath:split(".")
                            local weightVals = {}
                            for _, wChild in ipairs(child:GetChildren()) do
                                if wChild:IsA("NumberValue") and wChild.Name == "Weight" then
                                    table.insert(weightVals, wChild.Value)
                                end
                            end
                            table.insert(mappings, {
                                category = pathParts[#pathParts - 1],
                                name = pathParts[#pathParts],
                                animationId = child.AnimationId,
                                weights = weightVals
                            })
                        elseif #child:GetChildren() > 0 then
                            searchTree(child, parentPath .. "." .. child.Name)
                        end
                    end
                end
                for _, obj in pairs(objects) do
                    searchTree(obj, obj.Name)
                    obj.Parent = workspace
                    task.delay(1, function()
                        if obj then obj:Destroy() end
                    end)
                end
            end
        end
    end
    return mappings
end

function buildCustomSetMappings(setName)
    if type(setName) == "string" then
        setName = setName:gsub("%s*%-.*$", "")
    end
    local set = State.CustomAnimations and State.CustomAnimations.Sets and State.CustomAnimations.Sets[setName]
    if not set then return {} end
    local mappings = {}
    for cat, anims in pairs(set) do
        if cat ~= "__meta" then
            for name, id in pairs(anims) do
                if tostring(id) ~= "0" then
                    table.insert(mappings, {category = cat, name = name, animationId = "rbxassetid://" .. id})
                end
            end
        end
    end
    return mappings
end



loadAnimationCache()


local UI = {
    CustomFrames = {},
    Under = nil, 
    _1left = nil, 
    _9right = nil, 
    _4pages = nil, 
    _3TextLabel = nil, 
    _2Routenumber = nil, 
    Top = nil, 
    EmoteWalkButton = nil,
    Search = nil, 
    Favorite = nil, 
    SpeedEmote = nil, 
    SpeedBox = nil, 
    Changepage = nil,
    Reload = nil,
    Background = nil
}

local HUD = { 
    Connections = {},
    Strokes = {},
    ResizeHandles = {},
    ResizeConnections = {},
    UndoStack = {},
    SelectedElement = nil,
    Overlay = nil,
    IsUnlocked = false,
    ForceVisibleConn = nil,
    Layouts = {},
    LayoutsRemoved = {},
    FriendlyNames = {
        ["Under.1left"] = "Left Arrow",
        ["Under.9right"] = "Right Arrow",
        ["Under.4pages"] = "Total Pages",
        ["Under.3TextLabel"] = "Separator Label",
        ["Under.2Route-number"] = "Page Number Box",
        ["Top.Search"] = "Search/ID Box",
    },
    DefaultPositions = {
        Top = UDim2.new(0.127499998, 0, -0.109999999, 0),
        Under = UDim2.new(0.129999995, 0, 1, 0),
        EmoteWalkButton = UDim2.new(0.889999986, 0, -0.107500002, 0),
        Favorite = UDim2.new(0.0189999994, 0, -0.108000003, 0),
        SpeedEmote = UDim2.new(0.888999999, 0, 0, 0),
        SpeedBox = UDim2.new(0.0189999398, 0, -0.000499992399, 0),
        Changepage = UDim2.new(0.019, 0, 1.021, 0),
        Reload = UDim2.new(0.888999999, 0, 1.02100003, 0),
        ["Left Arrow"] = UDim2.new(0, 0, 0.028, 0),
        ["Right Arrow"] = UDim2.new(0.169, 0, 0.028, 0),
        ["Total Pages"] = UDim2.new(0.339, 0, 0.094, 0), 
        ["Separator Label"] = UDim2.new(0.498, 0, 0.028, 0),
        ["Page Number Box"] = UDim2.new(0.837, 0, 0.094, 0),
        ["Search/ID Box"] = UDim2.new(0.01, 0, 0.092, 0),
    },
    DefaultSizes = {
        Top = UDim2.new(0.737500012, 0, 0.0949999914, 0),
        Under = UDim2.new(0.737500012, 0, 0.132499993, 0),
        EmoteWalkButton = UDim2.new(0.0874999985, 0, 0.0874999985, 0),
        Favorite = UDim2.new(0.0874999985, 0, 0.0874999985, 0),
        SpeedEmote = UDim2.new(0.0874999985, 0, 0.0874999985, 0),
        SpeedBox = UDim2.new(0.0874999985, 0, 0.0874999985, 0),
        Changepage = UDim2.new(0.087, 0, 0.087, 0),
        Reload = UDim2.new(0.0869999975, 0, 0.0869999975, 0),
        ["Left Arrow"] = UDim2.new(0.169491529, 0, 0.94339627, 0),
        ["Right Arrow"] = UDim2.new(0.169491529, 0, 0.94339627, 0),
        ["Total Pages"] = UDim2.new(0.159322038, 0, 0.811320841, 0),
        ["Separator Label"] = UDim2.new(0.338983059, 0, 0.94339627, 0),
        ["Page Number Box"] = UDim2.new(0.159322038, 0, 0.811320841, 0),
        ["Search/ID Box"] = UDim2.new(0.864406765, 0, 0.81578958, 0),
    },
    DefaultTexts = {
        ["Left Arrow"] = "",
        ["Right Arrow"] = "",
        ["Total Pages"] = "1",
        ["Separator Label"] = " ------ ",
        ["Page Number Box"] = "1",
        ["Search/ID Box"] = "",
        ["SpeedBox"] = "1",
    },
    DefaultPlaceholders = {
        ["Search/ID Box"] = "Search/ID",
    }
}

function getAllHUDObjects()
    local elems = {}
    if UI.Top then elems["Top"] = UI.Top end
    if UI.Under then elems["Under"] = UI.Under end
    if UI.EmoteWalkButton then elems["EmoteWalkButton"] = UI.EmoteWalkButton end
    if UI.Favorite then elems["Favorite"] = UI.Favorite end
    if UI.SpeedEmote then elems["SpeedEmote"] = UI.SpeedEmote end
    if UI.SpeedBox then elems["SpeedBox"] = UI.SpeedBox end
    if UI.Changepage then elems["Changepage"] = UI.Changepage end
    if UI.Reload then elems["Reload"] = UI.Reload end
    if UI.CustomFrames then
        for n, f in pairs(UI.CustomFrames) do
            elems[n] = f
        end
    end

    if UI.Top then
        for _, child in pairs(UI.Top:GetChildren()) do
            if child:IsA("GuiObject") and not child:IsA("UIListLayout") and not child:IsA("UICorner") then
                local internalName = "Top." .. child.Name
                elems[HUD.FriendlyNames[internalName] or internalName] = child
            end
        end
    end
    if UI.Under then
        for _, child in pairs(UI.Under:GetChildren()) do
            if child:IsA("GuiObject") and not child:IsA("UIListLayout") and not child:IsA("UICorner") then
                local internalName = "Under." .. child.Name
                elems[HUD.FriendlyNames[internalName] or internalName] = child
            end
        end
    end
    return elems
end

function getMovableElements()
    local all = getAllHUDObjects()
    local movable = {}
    
    for name, el in pairs(all) do
        local isChild = false
        for _, friendly in pairs(HUD.FriendlyNames) do 
            if name == friendly then isChild = true; break end 
        end
        
        if not isChild or HUD.IsUnlocked then
            movable[name] = el
        end
    end
    return movable
end

function ColorToTable(c) return {math.round(c.R*255), math.round(c.G*255), math.round(c.B*255)} end
function TableToColor(t)
    if type(t) ~= "table" then
        return Color3.fromRGB(255, 255, 255)
    end
    local r = tonumber(t[1]) or 255
    local g = tonumber(t[2]) or 255
    local b = tonumber(t[3]) or 255
    return Color3.fromRGB(r, g, b)
end

local function isThemeDefaultRGB(r, g, b)
    return r == 28 and g == 30 and b == 32
end

local AnimationSystem = {
    Cache = {},
    currentThemeName = "Default"
}   

AnimationSystem.LooksLikeGif = function(url)
    if not url then return false end
    url = string.lower(tostring(url))
    return url:find(".gif") or url:find("gif") or url:find("format=gif") or url:find("image/gif")
end

AnimationSystem.NormalizeUrl = function(url)
    if not url or url == "" then return url end
    local targetUrl = tostring(url)
    
    targetUrl = targetUrl:gsub("%?raw=true", "")
    
    if targetUrl:find("github%.com/") and not targetUrl:find("raw.githubusercontent%.com") then
        targetUrl = targetUrl:gsub("github%.com/", "raw.githubusercontent.com/")
        targetUrl = targetUrl:gsub("/blob/", "/")
        targetUrl = targetUrl:gsub("/raw/", "/")
    end
    
    if targetUrl:find(" ") and not targetUrl:find("%%20") then
        targetUrl = targetUrl:gsub(" ", "%%20")
    end
    
    if not targetUrl:find("://") then
        local id = targetUrl:match("id=(%d+)") or targetUrl:match("^(%d+)$")
        if id then return "rbxassetid://" .. id end
    end
    return targetUrl
end

AnimationSystem.ParseGifInfo = function(bytes)
    if not bytes or #bytes < 13 then return nil end
    if bytes:sub(1, 3) ~= "GIF" then return nil end
    local function u16le(pos)
        local b1 = bytes:byte(pos) or 0
        local b2 = bytes:byte(pos + 1) or 0
        return b1 + b2 * 256
    end
    local width = u16le(7)
    local height = u16le(9)
    local packed = bytes:byte(11) or 0
    local gctFlag = bit32.band(packed, 0x80) ~= 0
    local gctSize = bit32.band(packed, 0x07)
    local offset = 13
    if gctFlag then
        offset = offset + (3 * (2 ^ (gctSize + 1)))
    end

    local frames = 0
    local delays = {}
    local pendingDelay = nil

    local function skipSubBlocks(pos)
        while pos <= #bytes do
            local size = bytes:byte(pos) or 0
            pos = pos + 1
            if size == 0 then break end
            pos = pos + size
        end
        return pos
    end

    while offset <= #bytes do
        local b = bytes:byte(offset)
        if not b then break end
        if b == 0x3B then
            break
        elseif b == 0x21 then
            local label = bytes:byte(offset + 1) or 0
            if label == 0xF9 then
                local delay = u16le(offset + 4)
                pendingDelay = delay
                offset = offset + 8
            else
                offset = skipSubBlocks(offset + 2)
            end
        elseif b == 0x2C then
            frames = frames + 1
            if pendingDelay then
                table.insert(delays, pendingDelay)
                pendingDelay = nil
            end
            local packedImg = bytes:byte(offset + 9) or 0
            local lctFlag = bit32.band(packedImg, 0x80) ~= 0
            local lctSize = bit32.band(packedImg, 0x07)
            offset = offset + 10
            if lctFlag then
                offset = offset + (3 * (2 ^ (lctSize + 1)))
            end
            offset = offset + 1
            offset = skipSubBlocks(offset)
        else
            offset = offset + 1
        end
    end

    local totalDelay = 0
    for _, d in ipairs(delays) do totalDelay = totalDelay + d end
    local avgDelay = (#delays > 0) and (totalDelay / #delays) or 10

    return {
        width = width,
        height = height,
        frames = frames > 0 and frames or #delays,
        totalDelayCs = totalDelay,
        avgDelayCs = avgDelay
    }
end

AnimationSystem.ParsePngInfo = function(bytes)
    if not bytes or #bytes < 24 then return nil end
    if bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local function u32be(pos)
        local b1 = bytes:byte(pos) or 0
        local b2 = bytes:byte(pos + 1) or 0
        local b3 = bytes:byte(pos + 2) or 0
        local b4 = bytes:byte(pos + 3) or 0
        return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    local width = u32be(17)
    local height = u32be(21)
    if width <= 0 or height <= 0 then return nil end
    return { width = width, height = height }
end

AnimationSystem.StopGif = function()
    if State.currentWheelAnimToken then
        State.currentWheelAnimToken = State.currentWheelAnimToken + 1
    end
end

AnimationSystem.SetImageMode = function(img, custom)
    if not img then return end
    if custom then
        img.ScaleType = Enum.ScaleType.Stretch
        img.SliceCenter = Rect.new(0, 0, 0, 0)
        img.SliceScale = 1
    else
        img.ScaleType = Enum.ScaleType.Fit
    end
end

AnimationSystem.StartGif = function(img, data)
    AnimationSystem.StopGif()
    if not img or not data or not data.sprite then return end
    
    State.currentWheelAnimToken = (State.currentWheelAnimToken or 0) + 1
    local token = State.currentWheelAnimToken
    
    local frames = data.frames or 1
    local frameW = data.frameW or 0
    local frameH = data.frameH or 0
    local cols = data.cols or 1
    local rows = data.rows or 1
    local delay = data.delay or 0.1
    if delay <= 0 then delay = 0.1 end
    local sheetW = data.sheetW or (cols * frameW)
    local sheetH = data.sheetH or (rows * frameH)
    
    img.Image = data.sprite
    img.ImageRectSize = Vector2.new(frameW, frameH)
    img.ImageRectOffset = Vector2.new(0, 0)
    task.spawn(function()
        pcall(function() ContentProvider:PreloadAsync({img}) end)
    end)
    
    local current = 0
    local acc = 0
    local connection
    connection = RunService.Heartbeat:Connect(function(dt)
        if token ~= State.currentWheelAnimToken then
            connection:Disconnect()
            return
        end
        if not img or not img.Parent then
            connection:Disconnect()
            return
        end
        acc = acc + dt
        if acc < delay then return end
        while acc >= delay do
            acc = acc - delay
            current = (current + 1) % frames
        end
        local col = current % cols
        local row = math.floor(current / cols)
        local offsetX = math.min(col * frameW, math.max(0, sheetW - frameW))
        local offsetY = math.min(row * frameH, math.max(0, sheetH - frameH))
        img.ImageRectOffset = Vector2.new(offsetX, offsetY)
    end)
end

AnimationSystem.AreMetaEqual = function(a, b)
    if not a or not b then return a == b end
    return a.GifUrl == b.GifUrl and a.SheetUrl == b.SheetUrl and a.Enabled == b.Enabled
end

AnimationSystem.MakeKey = function(gif, sheet)
    return tostring(gif) .. "|" .. tostring(sheet)
end

function ApplyFreezeButtonVisual()
    if not UI.EmoteWalkButton then return end
    UI.EmoteWalkButton.Image = State.emotesWalkEnabled and State.enabledButtonImage or State.defaultButtonImage
end

AnimationSystem.GetIconColor = function(key)
    if themes and themes[AnimationSystem.currentThemeName] then
        local theme = themes[AnimationSystem.currentThemeName]
        if theme.IconColors and theme.IconColors[key] then
            return TableToColor(theme.IconColors[key])
        end
        return TableToColor(theme.ImageColor or {255, 255, 255})
    elseif State.EmoteTheme then
        local theme = State.EmoteTheme
        if theme.IconColors and theme.IconColors[key] then
            return TableToColor(theme.IconColors[key])
        end
        return theme.ImageColor or Color3.new(1, 1, 1)
    end
    return Color3.fromRGB(255, 255, 255)
end

AnimationSystem.ResetRandomSlot = function(frontFrame)
    if not frontFrame then return end
    local slot = frontFrame:FindFirstChild("1")
    if slot and slot:IsA("ImageLabel") then
        slot.ImageColor3 = Color3.fromRGB(255, 255, 255)
        slot.Image = ""
        local idValue = slot:FindFirstChild("AnimationID")
        if idValue then idValue:Destroy() end
    end
end

function SafeLoad(url, name)
    local success, content
    for i = 1, 3 do
        success, content = pcall(function() return game:HttpGet(url) end)
        if success and content and content ~= "" then break end
        task.wait(0.5)
    end
    
    if not success or not content or content == "" then
        getgenv().Notify({
            Title = '7yd7 | Error',
            Content = 'Failed to download ' .. (name or "script") .. ' after 3 attempts.',
            Duration = 5
        })
        return function() end
    end

    local func, err = loadstring(content)
    if not func then
        warn("7yd7 | SafeLoad: Failed to parse " .. (name or "script") .. ": " .. tostring(err))
        return function() end
    end

    local ok, res = pcall(func)
    if not ok then
        warn("7yd7 | SafeLoad: Error executing " .. (name or "script") .. ": " .. tostring(res))
        return function() end
    end
    return res
end

SafeLoad("https://raw.githubusercontent.com/7yd7/Menu-7yd7/refs/heads/Script/GUIS/Off-site/Notify.lua", "Notify System")

local function getAssetCustom(filePath)
    if not filePath or filePath == "" then return nil end
    local customFn = getcustomasset or getsynasset
    if customFn then
        local ok, res = pcall(customFn, filePath)
        if ok and res and res ~= "" then
            return res
        end
    end
    return nil
end

local function fetchBinary(url)
    if not url or url == "" then return nil end
    local targetUrl = AnimationSystem.NormalizeUrl(url)
    
    if request then
        local ok, res = pcall(function()
            return request({
                Url = targetUrl,
                Method = "GET",
                Headers = {
                    ["User-Agent"] = "Roblox/WinInet"
                }
            })
        end)
        if ok and res and (res.StatusCode == 200 or res.Status == 200) and res.Body and #res.Body > 0 then
            local low = res.Body:sub(1, 100):lower()
            if not (low:find("<!doctype") or low:find("<html") or low:find("<head")) then
                return res.Body
            end
        end
    end

    local ok, body = pcall(function()
        return game:HttpGet(targetUrl)
    end)
    if ok and body and #body > 0 then
        local low = body:sub(1, 100):lower()
        if not (low:find("<!doctype") or low:find("<html") or low:find("<head")) then
            return body
        end
    end
    return nil
end

function GetAsset(asset, preloadedBytes)
    if not asset or asset == "" then return "" end
    local assetStr = tostring(asset)
    
    _G.AssetCache = _G.AssetCache or {}
    if _G.AssetCache[assetStr] then return _G.AssetCache[assetStr] end

    if not assetStr:find("://") and tonumber(assetStr) then
        local id = "rbxassetid://" .. assetStr
        _G.AssetCache[assetStr] = id
        return id
    end
    
    if assetStr:find("rbxassetid://") or assetStr:find("rbxasset://") or assetStr:find("rbxthumb://") then
        return assetStr
    end
    
    if assetStr:find("http") then
        local targetUrl = AnimationSystem.NormalizeUrl(assetStr)

        local filename = targetUrl:match("([^/]+)$") or "asset.png"
        filename = filename:match("([^%?]+)") or filename
        
        filename = filename:gsub("[%c%*%?%\"%<%>%|]", "_")
        
        if filename:lower():find("%.gif$") then
            filename = filename:gsub("%.[gG][iI][fF]$", ".png")
        end
        if not filename:find("%.") then filename = filename .. ".png" end
        
        local path = "7yd7/Assets/" .. filename
        
        if isfile and isfile(path) then
            local res = getAssetCustom(path)
            if res and res ~= "" then
                _G.AssetCache[assetStr] = res
                return res
            end
        end

        if not isfolder("7yd7/Assets") then 
            pcall(function()
                if not isfolder("7yd7") then makefolder("7yd7") end
                makefolder("7yd7/Assets") 
            end)
        end
        
        local content = preloadedBytes or fetchBinary(targetUrl)
        if content and #content > 0 then
            pcall(function() writefile(path, content) end)
            
            for attempt = 1, 4 do
                local res = getAssetCustom(path)
                if res and res ~= "" then
                    _G.AssetCache[assetStr] = res
                    return res
                end
                task.wait(0.08)
            end
        end
    end
    
    return assetStr
end

local function estimateRobloxResizedSize(origW, origH)
    if origW <= 0 or origH <= 0 then return origW, origH end
    local longest = math.max(origW, origH)
    local scale = 1
    if longest > 1024 then
        scale = 1024 / longest
    end
    return origW * scale, origH * scale
end

local function getExactImageSize(asset)
    local AssetService = game:GetService("AssetService")
    local ok, editImage = pcall(function()
        return AssetService:CreateEditableImageAsync(asset)
    end)
    if ok and editImage then
        local w = editImage.Size.X
        local h = editImage.Size.Y
        editImage:Destroy()
        if w > 0 and h > 0 then
            return w, h
        end
    end
    return nil
end

local DEFAULT_WHEEL_BG = "rbxasset://textures/ui/Emotes/Large/SegmentedCircle.png"
local RANDOM_SLOT_ICON = "rbxassetid://109283577128136"
local RANDOM_SLOT_COLOR = Color3.fromRGB(188, 188, 188)
local DEFAULT_IDLE_ICON_ID = "98513150727403"
local DEFAULT_IDLE_ICON_COLOR = Color3.fromRGB(188, 188, 188)
local wheelImgState = setmetatable({}, { __mode = "k" })
local checkEmotesMenuExists
local playEmote
local playRandomEmote
local handleSectorAction
local calculateTotalPages
local updatePageDisplay
local updateEmotes
local isInFavorites
local toggleFavorite
local toggleFavoriteAnimation
local refreshCustomAnimationState
local findCustomAnimationDataByName
local applyAnimation

local ConfigPath = "7yd7/EmoteSettings.json"

function updateHUDLayouts()
    if not Config then return end
    local function toggleLayout(parent, unlocked)
        if not parent then return end
        local key = parent.Name
        local l = parent:FindFirstChildOfClass("UIListLayout") or HUD.Layouts[key]
        
        if l then
            HUD.Layouts[key] = l
            
            local hasCustomP = false
            for _, child in pairs(parent:GetChildren()) do
                if child:IsA("GuiObject") then
                    local internalName = key .. "." .. child.Name
                    local friendly = HUD.FriendlyNames[internalName] or internalName
                    if Config.HUDPositions and Config.HUDPositions[friendly] then
                        hasCustomP = true
                        break
                    end
                end
            end

            if HUD.IsUnlocked then
                l.Parent = nil
            elseif hasCustomP or (HUD.LayoutsRemoved and HUD.LayoutsRemoved[key]) then
                l.Parent = nil 
            else
                l.Parent = parent
            end
        end
    end
    
    toggleLayout(UI.Top, HUD.IsUnlocked)
    toggleLayout(UI.Under, HUD.IsUnlocked)
end

function applySavedPositions() end 
local enterHUDEditor, exitHUDEditor

local function updateSpeedBoxVisibility()
    if not UI.SpeedBox then return end
    if State.hudEditorActive then
        UI.SpeedBox.Visible = Config.SpeedVisible
    else
        UI.SpeedBox.Visible = (Config.SpeedVisible and State.speedEmoteEnabled)
    end
end

function ApplyUIVisibility()
    pcall(function()
        if UI.Search and UI.Top then UI.Top.Visible = Config.SearchVisible end
        if UI.Favorite then UI.Favorite.Visible = Config.FavVisible end
        if UI.Changepage then UI.Changepage.Visible = Config.ModeVisible end
        if UI.EmoteWalkButton then UI.EmoteWalkButton.Visible = Config.FreezeVisible end
        if UI.SpeedEmote then UI.SpeedEmote.Visible = Config.SpeedVisible end
        updateSpeedBoxVisibility()
        if UI.Under then UI.Under.Visible = Config.NavVisible end
        if UI.Reload then 
            if State.hudEditorActive then
                UI.Reload.Visible = true
            else
                UI.Reload.Visible = (State.currentMode == "animation" and Config.NavVisible) 
            end
        end
    end)
end

function SaveConfig()
    if not isfolder("7yd7") then makefolder("7yd7") end
    writefile(ConfigPath, HttpService:JSONEncode(Config))
end

function LoadConfig()
    if isfile(ConfigPath) then
        local success, decoded = pcall(function() return HttpService:JSONDecode(readfile(ConfigPath)) end)
        if success and type(decoded) == "table" then
            for k, v in pairs(decoded) do Config[k] = v end
        end
    end
    getgenv().autoReloadEnabled = Config.AutoReloadEnabled or false
    getgenv().lastPlayedAnimation = Config.LastPlayedAnimationData
end
LoadConfig()

local rawNotify = getgenv().Notify
getgenv().Notify = function(data)
    if Config.NotifyEnabled then
        rawNotify(data)
    end
end

local SettingsLib = SafeLoad("https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/Settings.lua", "Settings Library")

local ToggleContainer = Instance.new("Frame")
ToggleContainer.Name = "open/Close"
ToggleContainer.Parent = SettingsLib.UI
ToggleContainer.BackgroundTransparency = 1
ToggleContainer.Size = UDim2.fromScale(1, 1)
ToggleContainer.ZIndex = 5000
ToggleContainer.Visible = false
ToggleContainer.Active = false
ToggleContainer.Selectable = false

local ToggleBtn = Instance.new("ImageButton")
ToggleBtn.Name = "ToggleSettings"
ToggleBtn.Parent = ToggleContainer
ToggleBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
ToggleBtn.BackgroundTransparency = 0.4
ToggleBtn.Position = UDim2.new(0, 10, 1, -52)
ToggleBtn.Size = UDim2.fromOffset(42, 42)
ToggleBtn.Image = "rbxassetid://79568054778195"

local DiscordBtn = Instance.new("ImageButton")
DiscordBtn.Name = "DiscordButton"
DiscordBtn.Parent = ToggleContainer
DiscordBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
DiscordBtn.BackgroundTransparency = 0.4
DiscordBtn.Position = UDim2.new(0, 57, 1, -52)
DiscordBtn.Size = UDim2.fromOffset(42, 42)
DiscordBtn.Image = "rbxassetid://98681818461563"

local DiscordCorner = Instance.new("UICorner")
DiscordCorner.CornerRadius = UDim.new(0, 10)
DiscordCorner.Parent = DiscordBtn

local ToggleCorner = Instance.new("UICorner")
ToggleCorner.CornerRadius = UDim.new(0, 10)
ToggleCorner.Parent = ToggleBtn

function getSettingsMainFrame()
    if SettingsLib and SettingsLib.UI then
        return SettingsLib.UI:FindFirstChild("MainFrame")
    end
    return nil
end

function applySettingsToggleStyle()
    local main = getSettingsMainFrame()
    local bgColor
    if main then
        bgColor = main.BackgroundColor3
    elseif State.EmoteTheme and State.EmoteTheme.Background then
        bgColor = State.EmoteTheme.Background
    end

    if bgColor then
        ToggleBtn.BackgroundColor3 = bgColor
        DiscordBtn.BackgroundColor3 = bgColor
    end
end

function syncToggleVisibility()
    local main = getSettingsMainFrame()
    if main then
        ToggleContainer.Visible = not main.Visible
    else
        ToggleContainer.Visible = true
    end
end

function syncDiscordVisibility()
    DiscordBtn.Visible = Config.DiscordVisible
end

DiscordBtn.MouseButton1Click:Connect(function()
    setclipboard("https://discord.gg/kRfzv2kV7X")
    getgenv().Notify({Title = "Discord", Content = "The Discord invite has been copied", Duration = 3})
end)

ToggleBtn.MouseButton1Click:Connect(function()
    local main = getSettingsMainFrame()
    if main then
        main.Visible = not main.Visible
        syncToggleVisibility()
    else
        SettingsLib.UI.Enabled = not SettingsLib.UI.Enabled
    end
end)

applySettingsToggleStyle()
syncToggleVisibility()
syncDiscordVisibility()

do
    local main = getSettingsMainFrame()
    if main then
        main:GetPropertyChangedSignal("Visible"):Connect(syncToggleVisibility)
    end
end

local TogglesUI = {}
local GeneralTab = SettingsLib.CreateTab("General", 1)
TogglesUI.NotifyEnabled = SettingsLib.AddToggle(GeneralTab, "Show Notifications", "Receive alerts and feedback", Config.NotifyEnabled, function(v)
    Config.NotifyEnabled = v
    SaveConfig()
end)

TogglesUI.AuthenticFirstPage = SettingsLib.AddToggle(GeneralTab, "Authentic Emotes Page", "Show owned emotes on page 1", Config.AuthenticFirstPage, function(v)
    Config.AuthenticFirstPage = v
    State.totalPages = calculateTotalPages()
    if State.currentPage > State.totalPages then
        State.currentPage = State.totalPages
    end
    updatePageDisplay()
    updateEmotes()
    SaveConfig()
end)

local randomModes = { "All", "Favorites" }
local randomDropdown = SettingsLib.AddDropdown(GeneralTab, "Random Source", randomModes, Config.RandomMode or "All", function(v)
    Config.RandomMode = v
    SaveConfig()
end)
if randomDropdown and randomDropdown.Button then
    randomDropdown.Button.Text = (Config.RandomMode or "All") .. "  ▼"
end

TogglesUI.RandomEnabled = SettingsLib.AddToggle(GeneralTab, "Random Enabled", "Enable/disable random", Config.RandomEnabled, function(v)
    Config.RandomEnabled = v
    if not v then
        pcall(function()
            local frontFrame = game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
            local slot1 = frontFrame and frontFrame:FindFirstChild("1")
            local slot2 = frontFrame and frontFrame:FindFirstChild("2")
            if slot1 and slot1:IsA("ImageLabel") and slot2 and slot2:IsA("ImageLabel") then
                local img2 = slot2.Image
                if img2 and img2 ~= "" then
                    slot1.Image = img2
                end
            end
        end)
    end
    State.totalPages = calculateTotalPages()
    if State.currentPage > State.totalPages then
        State.currentPage = State.totalPages
    end
    updatePageDisplay()
    updateEmotes()
    SaveConfig()
end)

local CleanFavItem = SettingsLib.AddItem(GeneralTab, "Clean Deleted Favorites", "Scan all favorites (emotes + animations) and remove any that were deleted (click twice)")
CleanFavItem.LayoutOrder = 10
local CleanFavBtn = SettingsLib:Create("TextButton", {
    Parent = CleanFavItem,
    BackgroundColor3 = Color3.fromRGB(220, 60, 60),
    Position = UDim2.new(1, -90, 0.5, -12),
    Size = UDim2.new(0, 80, 0, 24),
    Font = Enum.Font.GothamBold,
    Text = "CLEAN",
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 11
}, { SettingsLib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

local cleanFavConfirm = false
local cleanFavConfirmConn = nil
local cleanFavCleaning = false

local function resetCleanButton()
    cleanFavConfirm = false
    if cleanFavConfirmConn then
        pcall(function() cleanFavConfirmConn:Cancel() end)
        cleanFavConfirmConn = nil
    end
    if CleanFavBtn and CleanFavBtn.Parent then
        CleanFavBtn.Text = "CLEAN"
        CleanFavBtn.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
    end
end

local cleanDeletedFavorites

cleanDeletedFavorites = function()
    if cleanFavCleaning then return end
    cleanFavCleaning = true

    local emoteIds = {}
    local animIds = {}

    local emotePages = (State.EmotePages and State.EmotePages.Sets) or {}
    for _, favList in pairs(emotePages) do
        if type(favList) == "table" then
            for _, fav in ipairs(favList) do
                if fav and fav.id and tonumber(fav.id) and tonumber(fav.id) > 0 then
                    emoteIds[tostring(fav.id)] = true
                end
            end
        end
    end

    for _, fav in ipairs(State.favoriteAnimations or {}) do
        if fav and fav.id and not fav.isCustomSet and tonumber(fav.id) and tonumber(fav.id) > 0 then
            animIds[tostring(fav.id)] = true
        end
    end

    local emoteIdList = {}
    for id in pairs(emoteIds) do table.insert(emoteIdList, id) end
    local animIdList = {}
    for id in pairs(animIds) do table.insert(animIdList, id) end

    local totalChecks = #emoteIdList + #animIdList
    if totalChecks == 0 then
        getgenv().Notify({ Title = "7yd7 | Clean", Content = "No favorites to check!", Duration = 3 })
        cleanFavCleaning = false
        resetCleanButton()
        return
    end

    getgenv().Notify({ Title = "7yd7 | Clean", Content = "Checking " .. totalChecks .. " favorites...", Duration = 3 })

    local deletedEmotes = {}
    local deletedAnims = {}
    local checked = 0

    local function updateProgress()
        if CleanFavBtn and CleanFavBtn.Parent then
            CleanFavBtn.Text = math.floor((checked / totalChecks) * 100) .. "%"
        end
    end

    local function checkBatch(ids, isBundle, deletedOut)
        local url
        if isBundle then
            url = "https://thumbnails.roblox.com/v1/bundles/thumbnails?bundleIds=" .. table.concat(ids, ",") .. "&size=420x420&format=Png"
        else
            url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. table.concat(ids, ",") .. "&size=420x420&format=Png"
        end
        local body = fetchBinary(url)
        local parsed = nil
        if body and #body > 0 then
            pcall(function()
                parsed = HttpService:JSONDecode(body)
            end)
        end
        if parsed and parsed.data and type(parsed.data) == "table" then
            for _, entry in ipairs(parsed.data) do
                local targetId = tostring(entry.targetId)
                if entry.state == "Blocked" or entry.state == "Error" or not entry.imageUrl or entry.imageUrl == "" then
                    deletedOut[targetId] = true
                end
            end
        end
        task.wait(0.05)
    end

    local BATCH = 50
    for i = 1, #emoteIdList, BATCH do
        local chunk = {}
        for j = i, math.min(i + BATCH - 1, #emoteIdList) do table.insert(chunk, emoteIdList[j]) end
        checkBatch(chunk, false, deletedEmotes)
        checked = checked + #chunk
        updateProgress()
    end
    for i = 1, #animIdList, BATCH do
        local chunk = {}
        for j = i, math.min(i + BATCH - 1, #animIdList) do table.insert(chunk, animIdList[j]) end
        checkBatch(chunk, true, deletedAnims)
        checked = checked + #chunk
        updateProgress()
    end

    local removedEmotes = 0
    for pageName, favList in pairs(emotePages) do
        if type(favList) == "table" then
            local newList = {}
            for _, fav in ipairs(favList) do
                if fav and fav.id and deletedEmotes[tostring(fav.id)] then
                    removedEmotes = removedEmotes + 1
                else
                    table.insert(newList, fav)
                end
            end
            State.EmotePages.Sets[pageName] = newList
        end
    end

    local removedAnims = 0
    local newAnims = {}
    for _, fav in ipairs(State.favoriteAnimations or {}) do
        if fav and fav.id and not fav.isCustomSet and deletedAnims[tostring(fav.id)] then
            removedAnims = removedAnims + 1
        else
            table.insert(newAnims, fav)
        end
    end
    State.favoriteAnimations = newAnims

    State.favoriteEmotes = DeepCopy(State.EmotePages.Sets[State.currentEmotePageName] or {}) or {}
    State.favoriteEmoteSet = {}
    for _, fav in pairs(State.favoriteEmotes) do
        State.favoriteEmoteSet[tostring(fav.id)] = true
    end
    State.favoriteAnimationSet = {}
    for _, fav in pairs(State.favoriteAnimations) do
        State.favoriteAnimationSet[tostring(fav.id)] = true
    end
    State.favoriteSetVersion = State.favoriteSetVersion + 1

    State.SaveEmotePages(State.EmotePages)
    pcall(function()
        if not isfolder("7yd7") then makefolder("7yd7") end
        writefile(State.favoriteAnimationsFileName, HttpService:JSONEncode(State.favoriteAnimations))
    end)

    _G.filteredFavoritesForDisplay = nil
    _G.filteredFavoritesAnimationsForDisplay = nil

    State.totalPages = calculateTotalPages()
    if State.currentPage > State.totalPages then
        State.currentPage = State.totalPages
    end
    updatePageDisplay()
    if State.currentMode == "animation" then
        updateAnimations()
    else
        updateEmotes()
    end
    updateAllFavoriteIcons()

    for _, fav in pairs(State.favoriteEmotes) do
        if fav and fav.id then
            preloadThumbnail("rbxthumb://type=Asset&id=" .. tostring(fav.id) .. "&w=420&h=420")
        end
    end
    for _, fav in pairs(State.favoriteAnimations) do
        if fav and fav.id and not fav.isCustomSet then
            preloadThumbnail("rbxthumb://type=BundleThumbnail&id=" .. tostring(fav.id) .. "&w=420&h=420")
        end
    end

    local cleanUpToken = State.imageUpdateToken
    task.delay(0.35, function()
        if State.imageUpdateToken ~= cleanUpToken then return end
        updatePageDisplay()
        if State.currentMode == "animation" then
            updateAnimations()
        else
            updateEmotes()
        end
        updateAllFavoriteIcons()
    end)

    getgenv().Notify({
        Title = "7yd7 | Cleaned",
        Content = "Removed " .. removedEmotes .. " deleted emote" .. (removedEmotes == 1 and "" or "s") .. " & " .. removedAnims .. " deleted animation" .. (removedAnims == 1 and "" or "s"),
        Duration = 5
    })
    cleanFavCleaning = false
    resetCleanButton()
end

CleanFavBtn.MouseButton1Click:Connect(function()
    if cleanFavCleaning then return end
    if not cleanFavConfirm then
        cleanFavConfirm = true
        CleanFavBtn.Text = "CONFIRM?"
        CleanFavBtn.BackgroundColor3 = Color3.fromRGB(255, 140, 30)
        if cleanFavConfirmConn then
            pcall(function() cleanFavConfirmConn:Cancel() end)
        end
        cleanFavConfirmConn = task.delay(3, resetCleanButton)
        return
    end
    resetCleanButton()
    CleanFavBtn.Text = "0%"
    CleanFavBtn.BackgroundColor3 = Color3.fromRGB(0, 180, 90)
    task.spawn(cleanDeletedFavorites)
end)

local ButtonsTab = SettingsLib.CreateTab("Buttons", 2)

TogglesUI.SearchVisible = SettingsLib.AddToggle(ButtonsTab, "Search Bar", "Show/Hide the search input", Config.SearchVisible, function(v)
    Config.SearchVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.FavVisible = SettingsLib.AddToggle(ButtonsTab, "Favorites Button", "Show/Hide the star button", Config.FavVisible, function(v)
    Config.FavVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.ModeVisible = SettingsLib.AddToggle(ButtonsTab, "Mode Switcher", "Show/Hide animation mode button", Config.ModeVisible, function(v)
    Config.ModeVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.FreezeVisible = SettingsLib.AddToggle(ButtonsTab, "Freeze Button", "Show/Hide emote freeze button", Config.FreezeVisible, function(v)
    Config.FreezeVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.SpeedVisible = SettingsLib.AddToggle(ButtonsTab, "Speed Button", "Show/Hide the speed controller", Config.SpeedVisible, function(v)
    Config.SpeedVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.NavVisible = SettingsLib.AddToggle(ButtonsTab, "Page Controls", "Show/Hide navigation buttons", Config.NavVisible, function(v)
    Config.NavVisible = v
    ApplyUIVisibility()
    SaveConfig()
end)

TogglesUI.DiscordVisible = SettingsLib.AddToggle(ButtonsTab, "Discord Button", "Show/Hide the discord link button", Config.DiscordVisible, function(v)
    Config.DiscordVisible = v
    syncDiscordVisibility()
    SaveConfig()
end)

local cachedOverlay = nil
local hudEditorItem = SettingsLib.AddItem(ButtonsTab, "HUD Editor", "Reposition buttons & UI elements")
hudEditorItem.LayoutOrder = -10
local hudEditorBtn = SettingsLib:Create("TextButton", {
    Parent = hudEditorItem,
    BackgroundColor3 = Color3.fromRGB(0, 255, 150),
    Position = UDim2.new(1, -80, 0.5, -12),
    Size = UDim2.new(0, 70, 0, 24),
    Font = Enum.Font.GothamBold,
    Text = "EDIT",
    TextColor3 = Color3.fromRGB(24, 25, 28),
    TextSize = 11
}, { SettingsLib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

hudEditorBtn.MouseButton1Click:Connect(function()
    if enterHUDEditor then enterHUDEditor() end
end)
function getBackgroundOverlay()
    if cachedOverlay and cachedOverlay.Parent then return cachedOverlay end
    
    local success, result = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Back.Background
                   .BackgroundCircleOverlay
    end)
    if success and result then
        cachedOverlay = result
        return result
    end
    return nil
end

function DeepCopy(t)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            copy[k] = DeepCopy(v)
        else
            copy[k] = v
        end
    end
    return copy
end

local ApplyFavoriteButtonVisual
function updateGUIColors()
    local backgroundOverlay = getBackgroundOverlay()
    if not backgroundOverlay then
        return
    end

    local theme = State.EmoteTheme
    if not theme then return end
    
    local bgColor = theme.Background
    local accentColor = theme.Accent
    local imgColor = theme.ImageColor
    local bgTransparency = backgroundOverlay.BackgroundTransparency

    local function getIconColor(key)
        if theme.IconColors and theme.IconColors[key] then
            return TableToColor(theme.IconColors[key])
        end
        return imgColor
    end

    if UI._1left then
        UI._1left.ImageColor3 = getIconColor("Left")
        UI._1left.ImageTransparency = bgTransparency
        UI._1left.BackgroundTransparency = 1 
    end

    if UI._9right then
        UI._9right.ImageColor3 = getIconColor("Right")
        UI._9right.ImageTransparency = bgTransparency
        UI._9right.BackgroundTransparency = 1
    end

    if UI._4pages then
        UI._4pages.TextColor3 = bgColor 
        UI._4pages.TextTransparency = bgTransparency
    end

    if UI._3TextLabel then
        UI._3TextLabel.TextColor3 = bgColor
        UI._3TextLabel.TextTransparency = bgTransparency
    end

    if UI._2Routenumber then
        UI._2Routenumber.TextColor3 = bgColor
        UI._2Routenumber.PlaceholderColor3 = bgColor
        UI._2Routenumber.TextTransparency = bgTransparency
    end

    if UI.Under then
        UI.Under.BackgroundTransparency = 1
    end

    if UI.Top then
        UI.Top.BackgroundColor3 = bgColor
        UI.Top.BackgroundTransparency = bgTransparency
    end

    if UI.EmoteWalkButton then
        UI.EmoteWalkButton.BackgroundColor3 = bgColor
        UI.EmoteWalkButton.BackgroundTransparency = bgTransparency
    end

    if UI.CustomFrames then
        for _, frame in pairs(UI.CustomFrames) do
            frame.BackgroundColor3 = bgColor
            frame.BackgroundTransparency = bgTransparency
        end
    end

    if UI.SpeedEmote then
        UI.SpeedEmote.BackgroundColor3 = bgColor
        UI.SpeedEmote.BackgroundTransparency = bgTransparency
    end

     if UI.Changepage then
        UI.Changepage.BackgroundColor3 = bgColor
        UI.Changepage.BackgroundTransparency = bgTransparency
    end

    if UI.SpeedBox then
        UI.SpeedBox.BackgroundColor3 = bgColor
        UI.SpeedBox.BackgroundTransparency = bgTransparency
    end

    if UI.Favorite then
        UI.Favorite.BackgroundColor3 = bgColor
        UI.Favorite.BackgroundTransparency = bgTransparency
    end

    if UI.Reload then
        UI.Reload.BackgroundColor3 = bgColor
        UI.Reload.BackgroundTransparency = bgTransparency
    end
    
    if ApplyFavoriteButtonVisual then
        ApplyFavoriteButtonVisual()
    end

    local function applyHUDProperties()
        if not Config.HUDProperties then return end
        local allMovable = getAllHUDObjects()
        for name, uiExt in pairs(allMovable) do
            local props = Config.HUDProperties[name]
            if props then
                if props.ZIndex ~= nil then pcall(function() uiExt.ZIndex = props.ZIndex end) end
                if props.BgTrans ~= nil then pcall(function() uiExt.BackgroundTransparency = props.BgTrans end) end
                if props.ImgTrans ~= nil and (uiExt:IsA("ImageLabel") or uiExt:IsA("ImageButton")) then pcall(function() uiExt.ImageTransparency = props.ImgTrans end) end
                if props.BgColor and type(props.BgColor) == "table" then
                    local r, g, b = props.BgColor[1], props.BgColor[2], props.BgColor[3]
                    if r and g and b and not isThemeDefaultRGB(r, g, b) then
                        pcall(function() uiExt.BackgroundColor3 = Color3.fromRGB(r, g, b) end)
                    end
                end
                if props.ImgColor and type(props.ImgColor) == "table" and (uiExt:IsA("ImageLabel") or uiExt:IsA("ImageButton")) then
                    local r, g, b = props.ImgColor[1], props.ImgColor[2], props.ImgColor[3]
                    if r and g and b and not isThemeDefaultRGB(r, g, b) then
                        pcall(function() uiExt.ImageColor3 = Color3.fromRGB(r, g, b) end)
                    end
                end
                if props.TxtColor and type(props.TxtColor) == "table" and (uiExt:IsA("TextLabel") or uiExt:IsA("TextBox")) then
                    local r, g, b = props.TxtColor[1], props.TxtColor[2], props.TxtColor[3]
                    if r and g and b and not isThemeDefaultRGB(r, g, b) then
                        pcall(function() uiExt.TextColor3 = Color3.fromRGB(r, g, b) end)
                    end
                end
                if props.Radius and uiExt:FindFirstChildWhichIsA("UICorner") then
                    local s1, o1 = props.Radius:match("{%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*}")
                    if s1 then pcall(function() uiExt:FindFirstChildWhichIsA("UICorner").CornerRadius = UDim.new(tonumber(s1), tonumber(o1)) end) end
                end
            end
        end
    end
    
    applyHUDProperties()
    ApplyUIVisibility()
    applySettingsToggleStyle()
end

ApplyFavoriteButtonVisual = function()
    if not UI.Favorite then return end
    local isOn = State.favoriteEnabled
    local image = isOn and State.favoriteIconId or State.notFavoriteIconId
    if image and image ~= "" then
        UI.Favorite.Image = image
    end
    local colorKey = isOn and "Favorite" or "NotFavorite"
    UI.Favorite.ImageColor3 = AnimationSystem.GetIconColor(colorKey)
end

-- Optimizing performance: Removed RenderStepped loop
-- game:GetService("RunService").RenderStepped:Connect(function()
--     updateGUIColors()
-- end)

local ThemeTab = SettingsLib.CreateTab("Theme", 3)

local DiscordPromo = SettingsLib.AddItem(ThemeTab, "WANT THEMES?", "Join our Discord for themes!")
DiscordPromo.LayoutOrder = -1

local CopyBtn = SettingsLib:Create("TextButton", {
    Parent = DiscordPromo,
    BackgroundColor3 = Color3.fromRGB(0, 255, 150),
    Position = UDim2.new(1, -95, 0.5, -12),
    Size = UDim2.new(0, 85, 0, 24),
    Font = Enum.Font.GothamBold,
    Text = "COPY LINK",
    TextColor3 = Color3.fromRGB(24, 25, 28),
    TextSize = 11
}, { SettingsLib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

CopyBtn.MouseButton1Click:Connect(function()
    setclipboard("https://discord.gg/kRfzv2kV7X")
    getgenv().Notify({Title = "Discord", Content = "Link copied to clipboard!", Duration = 3})
end)

local ThemeConfigPath = "7yd7/EmoteThemes.json"

local lastSaveTime = 0
local saveDebounce = 1
local pendingSave = false

function SaveThemesImplementation(themes)
    if not isfolder("7yd7") then makefolder("7yd7") end
    local toSave = { Themes = {}, Order = {}, Selected = themes.Selected or AnimationSystem.currentThemeName }
    
    toSave.Order = themes.Order or {}
    
    for name, data in pairs(themes) do
        if name ~= "Default" and name ~= "Order" and name ~= "Selected" then
            toSave.Themes[name] = data
        end
    end
    writefile(ThemeConfigPath, HttpService:JSONEncode(toSave))
end

function SaveThemes(themes)
    if pendingSave then 
        pendingSave = "queued"
        return 
    end
    pendingSave = true
    task.delay(0.5, function()
        SaveThemesImplementation(themes)
        local wasQueued = pendingSave == "queued"
        pendingSave = false
        if wasQueued then
            SaveThemes(themes)
        end
    end)
end

function LoadThemes()
    local defaultTheme = {
        Background = {28, 30, 32},
        Accent = {0, 255, 150},
        ImageColor = {255, 255, 255},
        IconColors = {
            Left = {0, 0, 0},
            Right = {0, 0, 0}
        },
        Icons = {
            Left = "93111945058621",
            Right = "107938916240738",
            Walk = "71408678974152",
            Favorite = "97307461910825",
            NotFavorite = "124025954365505",
            Speed = "116056570415896",
            Page = "13285615740",
            Reload = "127493377027615"
        },
        Wheel = {
            BackgroundImage = "rbxasset://textures/ui/Emotes/Large/SegmentedCircle.png",
            BackgroundImageColor = {255, 255, 255},
            SelectionGradient = "rbxasset://textures/ui/Emotes/Large/SelectedGradient.png",
            SelectionGradientColor = {255, 255, 255},
            SelectionLine = "rbxasset://textures/ui/Emotes/Large/SelectedLine.png",
            SelectionLineColor = {255, 255, 255}
        }
    }
    
    local loaded = { Default = defaultTheme, Order = {"Default"} }
    
    if isfile(ThemeConfigPath) then
        local success, decoded = pcall(function() return HttpService:JSONDecode(readfile(ThemeConfigPath)) end)
        if success and type(decoded) == "table" then
            local themesTable = decoded.Themes or decoded 
            local orderTable = decoded.Order or {}
            
            for name, data in pairs(themesTable) do
                if not data.Icons then data.Icons = DeepCopy(defaultTheme.Icons) end
                if not data.Wheel then data.Wheel = DeepCopy(defaultTheme.Wheel) end
                loaded[name] = data
                
                if name == "Default" then
                    if not data.IconColors then data.IconColors = {} end
                    data.IconColors.Left = {0, 0, 0}
                    data.IconColors.Right = {0, 0, 0}
                end

                if not decoded.Order and name ~= "Default" then
                    table.insert(loaded.Order, name)
                end
            end
            
            if decoded.Order then
                loaded.Order = {"Default"}
                for _, name in ipairs(decoded.Order) do
                    if name ~= "Default" and loaded[name] then
                        table.insert(loaded.Order, name)
                    end
                end
            end
            
            if decoded.Selected and loaded[decoded.Selected] then
                loaded.Selected = decoded.Selected
            end
            
            return loaded
        end
    end
    return loaded
end

State.pendingCustomAnimSave = false
State.SaveCustomAnimationsImplementation = function(animData)
    if not isfolder("7yd7") then makefolder("7yd7") end
    local toSave = { Sets = {}, Order = animData.Order or {"Default"}, Selected = animData.Selected or "Default" }
    for name, data in pairs(animData.Sets) do
        if name ~= "Default" then
            toSave.Sets[name] = data
        end
    end
    writefile(State.CustomAnimationPath, HttpService:JSONEncode(toSave))
end

State.SaveCustomAnimations = function(animData)
    if State.pendingCustomAnimSave then
        State.pendingCustomAnimSave = "queued"
        return
    end
    State.pendingCustomAnimSave = true
    task.delay(0.5, function()
        State.SaveCustomAnimationsImplementation(animData)
        local wasQueued = State.pendingCustomAnimSave == "queued"
        State.pendingCustomAnimSave = false
        if wasQueued then State.SaveCustomAnimations(animData) end
    end)
end

State.LoadCustomAnimations = function()
    local defaultAnim = {
        idle = { Animation1 = 0, Animation2 = 0 },
        walk = { WalkAnim = 0 },
        run = { RunAnim = 0 },
        jump = { JumpAnim = 0 },
        fall = { FallAnim = 0 },
        climb = { ClimbAnim = 0 },
        swimidle = { SwimIdle = 0 },
        swim = { Swim = 0 },
        __meta = { IconImage = DEFAULT_IDLE_ICON_ID, IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) }
    }
    local loaded = { Sets = { Default = defaultAnim }, Order = {"Default"}, Selected = "Default" }
    
    if isfile(State.CustomAnimationPath) then
        local success, decoded = pcall(function() return HttpService:JSONDecode(readfile(State.CustomAnimationPath)) end)
        if success and type(decoded) == "table" then
            local setsTable = decoded.Sets or {}
            for name, data in pairs(setsTable) do
                loaded.Sets[name] = data
            end
            
            if decoded.Order then
                loaded.Order = {"Default"}
                for _, name in ipairs(decoded.Order) do
                    if name ~= "Default" and loaded.Sets[name] then
                        table.insert(loaded.Order, name)
                    end
                end
            end
            
            if decoded.Selected and loaded.Sets[decoded.Selected] then
                loaded.Selected = decoded.Selected
            end
        end
    end
    
    return loaded
end

State.SaveEmotePages = function(pageData)
    if not isfolder("7yd7") then makefolder("7yd7") end
    local toSave = { 
        Sets = {}, 
        Order = pageData.Order or {"Default"}, 
        Selected = pageData.Selected or "Default" 
    }
    for name, data in pairs(pageData.Sets) do
        if name ~= "Default" then
            toSave.Sets[name] = data
        end
    end
    writefile(State.EmotePagePath, HttpService:JSONEncode(toSave))
    
    if pageData.Sets["Default"] then
        writefile(State.favoriteFileName, HttpService:JSONEncode(pageData.Sets["Default"]))
    end
end

function SwitchEmotePage(pageName)
    if not State.EmotePages.Sets[pageName] then return end
    
    State.currentEmotePageName = pageName
    State.EmotePages.Selected = pageName
    
    local pageData = State.EmotePages.Sets[pageName]
    State.favoriteEmotes = DeepCopy(pageData) or {}
    
    State.favoriteEmoteSet = {}
    for _, fav in pairs(State.favoriteEmotes) do
        State.favoriteEmoteSet[tostring(fav.id)] = true
    end
    
    State.favoriteSetVersion = State.favoriteSetVersion + 1
    State.totalPages = calculateTotalPages()
    if State.currentPage > State.totalPages then
        State.currentPage = State.totalPages
    end
    
    updatePageDisplay()
    if State.currentMode == "emote" then
        updateEmotes()
    end
    updateAllFavoriteIcons()
end

State.LoadEmotePages = function()
    local defaultFavorites = {}
    
    if isfile(State.favoriteFileName) then
        local ok, decoded = pcall(function() return HttpService:JSONDecode(readfile(State.favoriteFileName)) end)
        if ok and type(decoded) == "table" then
            defaultFavorites = decoded
        end
    end

    local loaded = { Sets = { Default = defaultFavorites }, Order = {"Default"}, Selected = "Default" }
    
    if isfile(State.EmotePagePath) then
        local success, decoded = pcall(function() return HttpService:JSONDecode(readfile(State.EmotePagePath)) end)
        if success and type(decoded) == "table" then
            local setsTable = decoded.Sets or {}
            for name, data in pairs(setsTable) do
                if name ~= "Default" then
                    loaded.Sets[name] = data
                end
            end
            
            if decoded.Order then
                loaded.Order = {"Default"}
                for _, name in ipairs(decoded.Order) do
                    if name ~= "Default" and loaded.Sets[name] then
                        table.insert(loaded.Order, name)
                    end
                end
            end
            
            if decoded.Selected and (loaded.Sets[decoded.Selected] or decoded.Selected == "Default") then
                loaded.Selected = decoded.Selected
            end
        end
    end
    
    return loaded
end

State.EmotePages = State.LoadEmotePages()
State.currentEmotePageName = State.EmotePages.Selected or "Default"
if not State.EmotePages.Sets[State.currentEmotePageName] then 
    State.currentEmotePageName = "Default" 
end

State.favoriteEmotes = DeepCopy(State.EmotePages.Sets[State.currentEmotePageName]) or {}
State.favoriteEmoteSet = {}
for _, fav in pairs(State.favoriteEmotes) do
    State.favoriteEmoteSet[tostring(fav.id)] = true
end

State.favoriteAnimations = {}
pcall(function()
    if isfile and isfile(State.favoriteAnimationsFileName) then
        local json = readfile(State.favoriteAnimationsFileName)
        local decoded = HttpService:JSONDecode(json)
        if type(decoded) == "table" then
            State.favoriteAnimations = decoded
        end
    end
end)
State.favoriteAnimationSet = {}
for _, fav in pairs(State.favoriteAnimations) do
    State.favoriteAnimationSet[tostring(fav.id)] = true
end


State.CustomAnimations = State.LoadCustomAnimations()
State.currentCustomAnimationName = State.CustomAnimations.Selected or "Default"
if not State.CustomAnimations.Sets[State.currentCustomAnimationName] then 
    State.currentCustomAnimationName = "Default" 
end

local themes = LoadThemes()
local currentThemeName = Config.SelectedTheme or themes.Selected or "Default"
if not themes[currentThemeName] then currentThemeName = "Default" end

local themeDropdown

function GetNames()
    local n = {}
    if themes.Order then
        for _, name in ipairs(themes.Order) do
            if name ~= "Order" and name ~= "Selected" and themes[name] then 
                table.insert(n, name) 
            end
        end
    end
    for name, _ in pairs(themes) do
        if name ~= "Order" and name ~= "Selected" and not table.find(n, name) then
            table.insert(n, name)
        end
    end
    return n
end

local UIElements = {
    Background = {},
    Accent = {},
    ImageColor = {},
    Icons = {},
    Wheel = {}
}

function ApplyWheelBackgroundImage(bgImg, wheel)
    if not bgImg or not wheel then return end
    local bgSrc = wheel.BackgroundImage or ""
    local isCustomBg = tostring(bgSrc) ~= DEFAULT_WHEEL_BG

    local gifUrl, sheetUrl = nil, nil
    if bgSrc and tostring(bgSrc):find("\n") then
        local lines = {}
        for line in tostring(bgSrc):gmatch("[^\r\n]+") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then table.insert(lines, line) end
        end
        gifUrl = lines[1]
        sheetUrl = lines[2]
    elseif tostring(bgSrc):find("|") then
        local parts = {}
        for part in tostring(bgSrc):gmatch("[^|]+") do
            part = part:match("^%s*(.-)%s*$")
            if part ~= "" then table.insert(parts, part) end
        end
        gifUrl = parts[1]
        sheetUrl = parts[2]
    elseif AnimationSystem.LooksLikeGif(bgSrc) then
        gifUrl = bgSrc
    end
 
    local targetUrl = AnimationSystem.NormalizeUrl(bgSrc)
    if gifUrl then gifUrl = AnimationSystem.NormalizeUrl(gifUrl) end
    if sheetUrl then sheetUrl = AnimationSystem.NormalizeUrl(sheetUrl) end
 
    if gifUrl and sheetUrl and sheetUrl ~= "" then
        if gifUrl:lower():find("%.png") and (sheetUrl:lower():find("%.gif") or sheetUrl:lower():find("format=gif")) then
            local temp = gifUrl
            gifUrl = sheetUrl
            sheetUrl = temp
        end

        local cacheKey = AnimationSystem.MakeKey(gifUrl, sheetUrl)
        local meta = wheel.Animation
        if meta and meta.GifUrl == gifUrl and meta.SheetUrl == sheetUrl then
            AnimationSystem.Cache[cacheKey] = meta
        else
            meta = AnimationSystem.Cache[cacheKey]
        end
 
        if meta and meta.Enabled == true then
            if (meta.FrameWidth or 0) > 0 and (meta.FrameHeight or 0) > 0 then
                local frames = tonumber(meta.Frames) or 0
                local cols = tonumber(meta.Cols) or 0
                local rows = tonumber(meta.Rows) or 0
                local frameW = tonumber(meta.FrameWidth) or 0
                local frameH = tonumber(meta.FrameHeight) or 0
                local fps = tonumber(meta.FPS) or 10
                local delay = fps > 0 and (1 / fps) or 0.1
                local rawSheetW = tonumber(meta.SheetWidth) or (cols * frameW)
                local rawSheetH = tonumber(meta.SheetHeight) or (rows * frameH)
                local sheetAsset = GetAsset(sheetUrl)
                if sheetAsset and sheetAsset ~= "" and not sheetAsset:find("^https?://") then
                    local resizedW, resizedH = estimateRobloxResizedSize(rawSheetW, rawSheetH)
                    local adjFrameW = frameW * (resizedW / rawSheetW)
                    local adjFrameH = frameH * (resizedH / rawSheetH)

                    local spriteData = {
                        sprite = sheetAsset,
                        frames = frames,
                        frameW = adjFrameW,
                        frameH = adjFrameH,
                        cols = cols,
                        rows = rows,
                        sheetW = resizedW,
                        sheetH = resizedH,
                        delay = delay
                    }
                    AnimationSystem.SetImageMode(bgImg, true)
                    AnimationSystem.StartGif(bgImg, spriteData)
                    return
                end
            end
        end

        task.spawn(function()
            local gifBytes = fetchBinary(gifUrl)
            local gifInfo = gifBytes and AnimationSystem.ParseGifInfo(gifBytes) or nil

            local sheetBytes = fetchBinary(sheetUrl)
            local sheetInfo = sheetBytes and AnimationSystem.ParsePngInfo(sheetBytes) or nil
            local sheetAsset = GetAsset(sheetUrl, sheetBytes)

            if gifInfo and sheetInfo and sheetAsset and sheetAsset ~= "" and not sheetAsset:find("^https?://") then
                local frameW = gifInfo.width
                local frameH = gifInfo.height
                local cols = math.max(1, math.floor(sheetInfo.width / frameW + 0.0001))
                local rows = math.max(1, math.floor(sheetInfo.height / frameH + 0.0001))
                local maxFrames = cols * rows
                local frames = math.min(gifInfo.frames or maxFrames, maxFrames)
                local fps = (gifInfo.avgDelayCs and gifInfo.avgDelayCs > 0) and (100 / gifInfo.avgDelayCs) or 10

                local resizedW, resizedH = estimateRobloxResizedSize(sheetInfo.width, sheetInfo.height)
                local scaleX = resizedW / sheetInfo.width
                local scaleY = resizedH / sheetInfo.height
                local adjFrameW = frameW * scaleX
                local adjFrameH = frameH * scaleY

                local spriteData = {
                    sprite = sheetAsset,
                    frames = frames,
                    frameW = adjFrameW,
                    frameH = adjFrameH,
                    cols = cols,
                    rows = rows,
                    sheetW = resizedW,
                    sheetH = resizedH,
                    gifInfo = gifInfo
                }

                local newMeta = {
                    Enabled = true,
                    FrameWidth = frameW,
                    FrameHeight = frameH,
                    FPS = math.floor(fps + 0.5),
                    Frames = frames,
                    Cols = cols,
                    Rows = rows,
                    SheetWidth = sheetInfo.width,
                    SheetHeight = sheetInfo.height,
                    GifUrl = gifUrl,
                    SheetUrl = sheetUrl
                }
                wheel.Animation = newMeta
                AnimationSystem.Cache[cacheKey] = newMeta
                if AnimationSystem.currentThemeName and AnimationSystem.currentThemeName ~= "Default" then
                    SaveThemes(themes)
                end

                AnimationSystem.SetImageMode(bgImg, true)
                AnimationSystem.StartGif(bgImg, spriteData)
                return
            else
                AnimationSystem.StopGif()
                AnimationSystem.SetImageMode(bgImg, isCustomBg)
                local fallback = GetAsset(sheetUrl, sheetBytes)
                if fallback and fallback ~= "" and not fallback:find("^https?://") then
                    bgImg.Image = fallback
                else
                    bgImg.Image = DEFAULT_WHEEL_BG
                end
                bgImg.ImageRectSize = Vector2.new(0, 0)
                bgImg.ImageRectOffset = Vector2.new(0, 0)
            end
        end)
        return
    end
 
    AnimationSystem.StopGif()
    AnimationSystem.SetImageMode(bgImg, isCustomBg)
    bgImg.Image = GetAsset(targetUrl)
    bgImg.ImageRectSize = Vector2.new(0, 0)
    bgImg.ImageRectOffset = Vector2.new(0, 0)
end

function ApplyTheme(themeData)
    if State.isApplyingTheme then return end
    if not themeData then
        warn("7yd7 | ApplyTheme: themeData is nil. Falling back to Default.")
        themeData = themes and themes["Default"] or nil
        if not themeData then return end
    end
    
    State.isApplyingTheme = true
    
    local ok, err = pcall(function()
        if themeData.Background then
            State.EmoteTheme = {
                Background = TableToColor(themeData.Background),
                Accent = TableToColor(themeData.Accent or {0, 255, 150}),
                ImageColor = TableToColor(themeData.ImageColor or {255, 255, 255}),
                Icons = themeData.Icons or {},
                IconColors = themeData.IconColors or {},
                Wheel = themeData.Wheel or {}
            }
            
            local function getIconColor(key)
                if State.EmoteTheme.IconColors and State.EmoteTheme.IconColors[key] then
                    return TableToColor(State.EmoteTheme.IconColors[key])
                end
                return State.EmoteTheme.ImageColor 
            end
            
            State.favoriteIconId = GetAsset(State.EmoteTheme.Icons.Favorite)
            State.notFavoriteIconId = GetAsset(State.EmoteTheme.Icons.NotFavorite)
            
            updateGUIColors()
            
            if UI._1left then UI._1left.Image = GetAsset(State.EmoteTheme.Icons.Left); UI._1left.ImageColor3 = getIconColor("Left") end
            if UI._9right then UI._9right.Image = GetAsset(State.EmoteTheme.Icons.Right); UI._9right.ImageColor3 = getIconColor("Right") end
            if UI.EmoteWalkButton then 
                UI.EmoteWalkButton.ImageColor3 = getIconColor("Walk") 
                ApplyFreezeButtonVisual()
            end
            if UI.SpeedEmote then UI.SpeedEmote.Image = GetAsset(State.EmoteTheme.Icons.Speed); UI.SpeedEmote.ImageColor3 = getIconColor("Speed") end
            if UI.Changepage then UI.Changepage.Image = GetAsset(State.EmoteTheme.Icons.Page); UI.Changepage.ImageColor3 = getIconColor("Page") end
            if UI.Reload then UI.Reload.Image = GetAsset(State.EmoteTheme.Icons.Reload); UI.Reload.ImageColor3 = getIconColor("Reload") end
            
            if UI.Favorite then ApplyFavoriteButtonVisual() end 

            
            if UI.Background and UI.Background.Main then UI.Background.Main.SetValue(State.EmoteTheme.Background) end
            
            for key, comp in pairs(UIElements.Icons) do
                local iconVal = State.EmoteTheme.Icons[key] or ""
                local specificColor = State.EmoteTheme.IconColors and State.EmoteTheme.IconColors[key]
                local colorVal
                
                if specificColor then
                    colorVal = TableToColor(specificColor)
                else
                    colorVal = State.EmoteTheme.ImageColor 
                end
                
                if comp then comp.SetValue(iconVal, colorVal) end
            end

            for name, data in pairs(themes) do
                if data == themeData then
                    AnimationSystem.currentThemeName = name
                    break
                end
            end

            local function applyWheel()
                pcall(function()
                    local coreGui = game:GetService("CoreGui")
                    local robloxGui = coreGui:FindFirstChild("RobloxGui")
                    if not robloxGui then return end
                    local emotesMenu = robloxGui:FindFirstChild("EmotesMenu")
                    if not emotesMenu then return end
                    local children = emotesMenu:FindFirstChild("Children")
                    local main = children and children:FindFirstChild("Main")
                    local emotesWheel = main and main:FindFirstChild("EmotesWheel")
                    local back = emotesWheel and emotesWheel:FindFirstChild("Back")
                    local root = back and back:FindFirstChild("Background")
                    if not root then return end
                    
                    local wheel = State.EmoteTheme.Wheel
                    if not wheel then return end

                    local function getAsset(id)
                        return GetAsset(id)
                    end

                    local bgImg = root:FindFirstChild("BackgroundImage")
                    if bgImg then
                        ApplyWheelBackgroundImage(bgImg, wheel)
                        bgImg.ImageColor3 = TableToColor(wheel.BackgroundImageColor or {255,255,255})
                    end

                    local gradContainer = root:FindFirstChild("BackgroundGradient")
                    local selectionGrad = gradContainer and gradContainer:FindFirstChild("SelectionGradient")
                    local grad = selectionGrad and selectionGrad:FindFirstChild("SelectedGradient")
                    if grad then
                        grad.Image = getAsset(wheel.SelectionGradient)
                        grad.ImageColor3 = TableToColor(wheel.SelectionGradientColor or {255,255,255})
                    end

                    local selection = root:FindFirstChild("Selection")
                    local selectionEffect = selection and selection:FindFirstChild("SelectionEffect")
                    local line = selectionEffect and selectionEffect:FindFirstChild("SelectedLine")
                    if line then
                        line.Image = getAsset(wheel.SelectionLine)
                        line.ImageColor3 = TableToColor(wheel.SelectionLineColor or {255,255,255})
                    end
                end)
            end
            applyWheel()

            for key, comp in pairs(UIElements.Wheel) do
                local imgVal = State.EmoteTheme.Wheel[key] or ""
                local colorVal = TableToColor(State.EmoteTheme.Wheel[key.."Color"] or {255, 255, 255})
                if comp then comp.SetValue(imgVal, colorVal) end
            end
        end
    end)
    
    State.isApplyingTheme = false
    
    if not ok then
        warn("7yd7 | ApplyTheme error: " .. tostring(err))
    end
end

checkEmotesMenuExists = function()
    local coreGui = game:GetService("CoreGui")
    local robloxGui = coreGui:FindFirstChild("RobloxGui")
    if not robloxGui then
        return false
    end

    local emotesMenu = robloxGui:FindFirstChild("EmotesMenu")
    if not emotesMenu then
        return false
    end

    local children = emotesMenu:FindFirstChild("Children")
    if not children then
        return false
    end

    local main = children:FindFirstChild("Main")
    if not main then
        return false
    end

    local emotesWheel = main:FindFirstChild("EmotesWheel")
    if not emotesWheel then
        return false
    end

    return true, emotesWheel
end

task.spawn(function()
    local attempts = 0
    while attempts < 30 do
        local exists, emotesWheel = checkEmotesMenuExists()
        if exists and emotesWheel then
            ApplyTheme(themes[currentThemeName])
            
            emotesWheel:GetPropertyChangedSignal("Visible"):Connect(function()
                if emotesWheel.Visible then
                    task.wait(0.05)
                    ApplyTheme(themes[currentThemeName])
                end
            end)
            break
        end
        attempts = attempts + 1
        task.wait(1)
    end
end)

themeDropdown = SettingsLib.AddDropdown(ThemeTab, "Select Theme", GetNames(), currentThemeName, function(v)
    currentThemeName = v
    Config.SelectedTheme = v
    SaveConfig()
    if themes[v] then
        SaveThemes(themes) 
        task.wait(0.1)
        ApplyTheme(themes[v])
    end
end)
if themeDropdown and themeDropdown.Button and themeDropdown.Button.Parent and themeDropdown.Button.Parent.Parent then
   themeDropdown.Button.Parent.Parent.LayoutOrder = 0
end

local BtnItem = SettingsLib.AddItem(ThemeTab, "Theme Management", "Manage your themes")
BtnItem.LayoutOrder = 1 
BtnItem.BackgroundColor3 = Color3.fromRGB(35, 38, 42)
BtnItem.Size = UDim2.new(0.95, 0, 0, 70) 

for _, v in pairs(BtnItem:GetChildren()) do if v.Name == "Title" or v.Name == "Desc" then v:Destroy() end end

local ManagementContainer = Instance.new("Frame")
ManagementContainer.Parent = BtnItem
ManagementContainer.BackgroundTransparency = 1
ManagementContainer.Size = UDim2.new(1, 0, 1, 0)

local Layout = Instance.new("UIListLayout")
Layout.FillDirection = Enum.FillDirection.Horizontal
Layout.Padding = UDim.new(0, 15)
Layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
Layout.VerticalAlignment = Enum.VerticalAlignment.Center
Layout.Parent = ManagementContainer

local BtnRow = ManagementContainer 

function CreatePopup(title, size)
    local panel = Instance.new("Frame")
    panel.Size = size or UDim2.fromOffset(280, 140)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.BackgroundColor3 = Color3.fromHex("18191c")
    panel.ZIndex = 2000
    panel.Parent = SettingsLib.UI

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Parent = panel
    stroke.Color = (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150)
    stroke.Thickness = 1.5
    stroke.Transparency = 0.5

    local lbl = Instance.new("TextLabel")
    lbl.Parent = panel
    lbl.Size = UDim2.new(1, 0, 0, 35)
    lbl.BackgroundTransparency = 1
    lbl.Text = title:upper()
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 13
    lbl.TextColor3 = Color3.new(1,1,1)
    
    local content = Instance.new("Frame")
    content.Name = "Content"
    content.Parent = panel
    content.BackgroundTransparency = 1
    content.Position = UDim2.new(0, 0, 0, 35)
    content.Size = UDim2.new(1, 0, 1, -35)
    
    return panel, content
end

function CreateInput(parent, placeholder, text, isMulti)
    local box = Instance.new("TextBox")
    box.Size = isMulti and UDim2.new(0.9, 0, 0, 100) or UDim2.new(0.9, 0, 0, 35)
    box.Position = UDim2.new(0.05, 0, 0, 5)
    box.BackgroundColor3 = Color3.fromRGB(35, 38, 41)
    box.TextColor3 = Color3.new(1,1,1)
    box.PlaceholderText = placeholder or ""
    box.Text = text or ""
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.MultiLine = isMulti
    box.TextWrapped = isMulti
    box.Parent = parent
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = box
    
    return box
end

function CreateButton(parent, text, color, pos, size)
    local btn = Instance.new("TextButton")
    btn.Size = size or UDim2.new(0.4, 0, 0, 32)
    btn.Position = pos
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.Font = Enum.Font.GothamBold
    btn.TextColor3 = (color.R + color.G + color.B < 1.5) and Color3.new(1,1,1) or Color3.new(0,0,0)
    btn.TextSize = 12
    btn.Parent = parent
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = btn
    
    return btn
end

SettingsLib.AddIconButton(BtnRow, "108445456753346", function()
    local popup, content = CreatePopup("Create Theme")
    local In = CreateInput(content, "Theme Name...")
    
    local Save = CreateButton(content, "SAVE", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Cancel.TextColor3 = Color3.new(1,1,1)

    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not themes[In.Text] then
            themes[In.Text] = DeepCopy(themes[currentThemeName])
            if not themes[In.Text].IconColors then themes[In.Text].IconColors = {} end
            table.insert(themes.Order, In.Text)
            
            table.sort(themes.Order, function(a, b)
                if a == "Default" then return true end
                if b == "Default" then return false end
                return a:lower() < b:lower()
            end)
            
            SaveThemes(themes)
            currentThemeName = In.Text
            themeDropdown.Refresh(GetNames())
            themeDropdown.Button.Text = currentThemeName .. "  ▼"
            ApplyTheme(themes[currentThemeName])
            popup:Destroy()
        end
    end)
    
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(BtnRow, "71829270056766", function()
    if currentThemeName ~= "Default" then
        local idx = table.find(themes.Order, currentThemeName)
        if idx then table.remove(themes.Order, idx) end
        
        themes[currentThemeName] = nil
        SaveThemes(themes)
        currentThemeName = "Default"
        themeDropdown.Refresh(GetNames())
        themeDropdown.Button.Text = "Default  ▼"
        ApplyTheme(themes["Default"])
    end
end)

SettingsLib.AddIconButton(BtnRow, "117761881427472", function()
    if currentThemeName == "Default" then return end
    
    local popup, content = CreatePopup("Rename Theme")
    local In = CreateInput(content, "New Name...", currentThemeName)
    
    local Save = CreateButton(content, "RENAME", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Cancel.TextColor3 = Color3.new(1,1,1)

    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not themes[In.Text] then
            local idx = table.find(themes.Order, currentThemeName)
            if idx then themes.Order[idx] = In.Text end
            
            themes[In.Text] = themes[currentThemeName]
            themes[currentThemeName] = nil
            currentThemeName = In.Text
            SaveThemes(themes)
            themeDropdown.Refresh(GetNames())
            themeDropdown.Button.Text = currentThemeName .. "  ▼"
            popup:Destroy()
        end
    end)
    
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(BtnRow, "78317476576895", function()
    local popup, content = CreatePopup("Import Theme", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "Paste Theme JSON here...", "", true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    
    local imp = CreateButton(content, "IMPORT THEME", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))

    imp.MouseButton1Click:Connect(function()
        local s, d = pcall(function() return HttpService:JSONDecode(box.Text) end)
        if s and type(d) == "table" and d.name then
            if d.name == "Default" then
                getgenv().Notify({Title = "Error", Content = "Cannot overwrite 'Default' theme.", Duration = 3})
                return
            end
            if not themes[d.name] then
                table.insert(themes.Order, d.name)
            end
            themes[d.name] = d.data
            SaveThemes(themes)
            themeDropdown.Refresh(GetNames())
            popup:Destroy()
        else
            getgenv().Notify({Title = "Error", Content = "Invalid JSON Format!", Duration = 3})
        end
    end)
    
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "×"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(BtnRow, "107588515524752", function()
    local exportData = { name = currentThemeName, data = themes[currentThemeName] }
    local json = HttpService:JSONEncode(exportData)
    
    local popup, content = CreatePopup("Export Theme", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "", json, true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    box.TextEditable = false
    
    local copy = CreateButton(content, "COPY TO CLIPBOARD", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))

    copy.MouseButton1Click:Connect(function()
        setclipboard(json)
        copy.Text = "COPIED!"
        task.delay(1, function() copy.Text = "COPY TO CLIPBOARD" end)
    end)
    
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "×"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)


function SmartUpdate(key, subkey, val)
    if currentThemeName == "Default" then
        getgenv().Notify({Title = "Theme", Content = "Cannot modify Default theme. Create a new one!", Duration = 2})
        return
    end

    if themes[currentThemeName] then
        if not themes[currentThemeName][key] then themes[currentThemeName][key] = {} end
        
        if subkey then
            themes[currentThemeName][key][subkey] = val
        else
            themes[currentThemeName][key] = val
        end
        SaveThemes(themes)
        ApplyTheme(themes[currentThemeName])
    end
end

local WheelFolder = SettingsLib.AddFolder(ThemeTab, "Wheel Settings")
WheelFolder.Parent.LayoutOrder = 1.1

function AddWheelInput(title, wheelKey)
    local initialData = themes["Default"].Wheel[wheelKey]
    local initialColor = TableToColor(themes["Default"].Wheel[wheelKey.."Color"])
    
    local current = (themes[currentThemeName].Wheel and themes[currentThemeName].Wheel[wheelKey]) or initialData
    local currentColor = TableToColor((themes[currentThemeName].Wheel and themes[currentThemeName].Wheel[wheelKey.."Color"]) or themes["Default"].Wheel[wheelKey.."Color"])
    
    local comp = SettingsLib.AddAssetColor(WheelFolder, title, "Asset ID...", current, currentColor, function(text, color)
        if currentThemeName == "Default" then
            getgenv().Notify({Title = "Theme", Content = "Cannot modify Default theme!", Duration = 2})
            return
        end
        
        if themes[currentThemeName] then
            if not themes[currentThemeName].Wheel then themes[currentThemeName].Wheel = {} end
            themes[currentThemeName].Wheel[wheelKey] = text
            themes[currentThemeName].Wheel[wheelKey.."Color"] = ColorToTable(color)
            
            SaveThemes(themes)
            ApplyTheme(themes[currentThemeName])
        end
    end)
    UIElements.Wheel[wheelKey] = comp

    local resetBtn = SettingsLib:Create("ImageButton", {
        Parent = comp.Item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -120, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 10
    })
    
    resetBtn.MouseButton1Click:Connect(function()
        if currentThemeName == "Default" then return end
        comp.SetValue(initialData, initialColor)
        if themes[currentThemeName] then
            if not themes[currentThemeName].Wheel then themes[currentThemeName].Wheel = {} end
            themes[currentThemeName].Wheel[wheelKey] = initialData
            themes[currentThemeName].Wheel[wheelKey.."Color"] = ColorToTable(initialColor)
            SaveThemes(themes)
            ApplyTheme(themes[currentThemeName])
        end
    end)
end

AddWheelInput("Wheel Background", "BackgroundImage")
AddWheelInput("Selection Gradient", "SelectionGradient")
AddWheelInput("Selection Line", "SelectionLine")

local BackgroundFolder = SettingsLib.AddFolder(ThemeTab, "Background Settings")
BackgroundFolder.Parent.LayoutOrder = 2
UIElements.Background.Main = SettingsLib.AddColorPicker(BackgroundFolder, "Main Background", TableToColor(themes[currentThemeName].Background), function(c)
    SmartUpdate("Background", nil, ColorToTable(c))
end)

local IconSettingsFolder = SettingsLib.AddFolder(ThemeTab, "Icon Settings")
IconSettingsFolder.Parent.LayoutOrder = 3

function AddAssetInput(title, iconKey)
    local current = (themes[currentThemeName].Icons and themes[currentThemeName].Icons[iconKey]) or ""
    local defaultText = (themes["Default"].Icons and themes["Default"].Icons[iconKey]) or ""
    
    local currentColor = Color3.new(1,1,1)
    if themes[currentThemeName].IconColors and themes[currentThemeName].IconColors[iconKey] then
        currentColor = TableToColor(themes[currentThemeName].IconColors[iconKey])
    elseif themes[currentThemeName].ImageColor then
        currentColor = TableToColor(themes[currentThemeName].ImageColor)
    end
    
    local defaultColor = Color3.new(1,1,1)
    if themes["Default"].IconColors and themes["Default"].IconColors[iconKey] then
        defaultColor = TableToColor(themes["Default"].IconColors[iconKey])
    elseif themes["Default"].ImageColor then
        defaultColor = TableToColor(themes["Default"].ImageColor)
    end
    
    local comp = SettingsLib.AddInputWithColor(IconSettingsFolder, title, "Asset ID...", defaultText, defaultColor, function(text, color)
        local s, err = pcall(function()
            if currentThemeName == "Default" then
                getgenv().Notify({Title = "Theme", Content = "Cannot modify Default theme!", Duration = 2})
                return
            end
            
            if themes[currentThemeName] then
                if not themes[currentThemeName].Icons then themes[currentThemeName].Icons = {} end
                if not themes[currentThemeName].IconColors then themes[currentThemeName].IconColors = {} end
                
                local cTable = ColorToTable(color)
                themes[currentThemeName].Icons[iconKey] = text
                themes[currentThemeName].IconColors[iconKey] = cTable
                
                SaveThemes(themes)
                ApplyTheme(themes[currentThemeName])
            end
        end)
        if not s then
            warn("Theme Save Error: " .. tostring(err))
            getgenv().Notify({Title = "Error", Content = "Failed to save color!", Duration = 3})
        end
    end)
    comp.SetValue(current, currentColor)
    UIElements.Icons[iconKey] = comp
end

AddAssetInput("Left Arrow", "Left")
AddAssetInput("Right Arrow", "Right")
AddAssetInput("Walk Icon", "Walk")
AddAssetInput("Speed Icon", "Speed")
AddAssetInput("Page Icon", "Page")
AddAssetInput("Reload Icon", "Reload")
AddAssetInput("Favorite (Star)", "Favorite")
AddAssetInput("Not Favorite", "NotFavorite")

State.exitCustomAnimationEditor = function()
    if not State.customAnimationEditorActive then return end
    State.customAnimationEditorActive = false
    State.customAnimationEditingKey = nil
    State.customAnimationEditingName = nil

    for _, conn in pairs(State.CustomAnimEditorConnections or {}) do
        pcall(function() conn:Disconnect() end)
    end
    State.CustomAnimEditorConnections = {}

    if State.CustomAnimOverlay and State.CustomAnimOverlay.Parent then 
        State.CustomAnimOverlay:Destroy() 
    end
    State.CustomAnimOverlay = nil

    if State.CustomAnimForceVisibleConn then 
        State.CustomAnimForceVisibleConn:Disconnect()
        State.CustomAnimForceVisibleConn = nil 
    end

    if UI.Search then UI.Search.TextEditable = true; UI.Search.Active = true end
    if UI.SpeedBox then UI.SpeedBox.TextEditable = true; UI.SpeedBox.Active = true end
    if UI._2Routenumber then UI._2Routenumber.TextEditable = true; UI._2Routenumber.Active = true end
    
    pcall(function() game:GetService("GuiService"):SetEmotesMenuOpen(false) end)
    pcall(function() game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false end)

    local main = getSettingsMainFrame()
    if main then main.Visible = true end
    if syncToggleVisibility then syncToggleVisibility() end

    if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end

    if State.currentMode ~= "animation" then
        State.currentMode = "animation"
        State.suppressSearch = true
        if UI.Search then UI.Search.Text = State.animationSearchTerm end
        State.suppressSearch = false
        if State.animationSearchTerm ~= "" and searchAnimations then
            searchAnimations(State.animationSearchTerm)
        end
        State.currentPage = State.savedAnimPage
        State.totalPages = calculateTotalPages()
        updatePageDisplay()
        updateEmotes()
        if updateScriptPriorityOverlay then updateScriptPriorityOverlay() end
        State.animationMonitorToken = State.animationMonitorToken + 1
        local token = State.animationMonitorToken
        State.isMonitoringClicks = true
        if monitorAnimations then
            task.spawn(function() monitorAnimations(token) end)
        end
    end
end

State.enterCustomAnimationEditor = function(category, animName)
    if State.customAnimationEditorActive then return end
    if State.currentCustomAnimationName == "Default" then
        getgenv().Notify({ Title = "7yd7 | Error", Content = "Cannot edit Default Animation set. Create a new one!", Duration = 3 })
        return
    end

    State.customAnimationEditorActive = true
    State.customAnimationEditingKey = category
    State.customAnimationEditingName = animName
    
    if State.currentMode ~= "animation" then
        State.currentMode = "animation"
        State.suppressSearch = true
        if UI.Search then UI.Search.Text = State.animationSearchTerm end
        State.suppressSearch = false
        State.currentPage = State.savedAnimPage
        State.totalPages = calculateTotalPages()
        updatePageDisplay()
        updateEmotes()
        if updateScriptPriorityOverlay then updateScriptPriorityOverlay() end
        State.animationMonitorToken = State.animationMonitorToken + 1
        local token = State.animationMonitorToken
        State.isMonitoringClicks = true
        if monitorAnimations then
            task.spawn(function()
                monitorAnimations(token)
            end)
        end
        
        local beforeVersion = State.animationCacheVersion
        task.spawn(function()
            if fetchAllAnimations then
                fetchAllAnimations()
            else
                return
            end
            if State.currentMode ~= "animation" then return end
            if State.animationCacheVersion ~= beforeVersion then
                State.suppressSearch = true
                if UI.Search then UI.Search.Text = State.animationSearchTerm end
                State.suppressSearch = false
                if State.animationSearchTerm ~= "" and searchAnimations then
                    searchAnimations(State.animationSearchTerm)
                end
                State.currentPage = State.savedAnimPage
                State.totalPages = calculateTotalPages()
                updatePageDisplay()
                updateEmotes()
                if updateScriptPriorityOverlay then updateScriptPriorityOverlay() end
            end
        end)
    end

    GuiService:SetEmotesMenuOpen(false)
    task.wait(0.15)

    local exists, emotesWheel = checkEmotesMenuExists()
    if not exists then State.customAnimationEditorActive = false; return end
    emotesWheel.Visible = true

    State.CustomAnimForceVisibleConn = RunService.Heartbeat:Connect(function()
        if not State.customAnimationEditorActive then return end
        pcall(function()
            local _, ew = checkEmotesMenuExists()
            if ew then ew.Visible = true end
        end)
    end)

    local main = getSettingsMainFrame()
    if main then main.Visible = false end
    if syncToggleVisibility then syncToggleVisibility() end

    local overlay = Instance.new("Frame")
    overlay.Name = "CustomAnimOverlay"
    overlay.Parent = SettingsLib.UI
    overlay.BackgroundTransparency = 1
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.ZIndex = 6000
    overlay.Active = false
    State.CustomAnimOverlay = overlay

    local bc = Instance.new("Frame")
    bc.Parent = overlay
    bc.BackgroundTransparency = 1
    bc.AnchorPoint = Vector2.new(1, 0)
    bc.Position = UDim2.new(1, -10, 0, 10)
    bc.Size = UDim2.fromOffset(42, 42)
    bc.ZIndex = 6000

    local backBtn = Instance.new("ImageButton")
    backBtn.Name = "CustomAnimBackBtn"
    backBtn.Size = UDim2.fromOffset(42, 42)
    backBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    backBtn.BackgroundTransparency = 0.4
    backBtn.Image = "rbxassetid://79024388644722"
    backBtn.ZIndex = 6001
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = backBtn
    
    backBtn.Parent = bc
    
    State.CustomAnimEditorConnections = State.CustomAnimEditorConnections or {}
    table.insert(State.CustomAnimEditorConnections, backBtn.MouseButton1Click:Connect(function()
        State.exitCustomAnimationEditor()
    end))

    if UI._2Routenumber then UI._2Routenumber.TextEditable = false; UI._2Routenumber.Active = false; pcall(function() UI._2Routenumber:ReleaseFocus() end) end

    getgenv().Notify({ Title = "7yd7 | Animation Editor", Content = "🖱️ Select an animation from the wheel to set for " .. animName, Duration = 5 })
end

State.CustomAnimTab = SettingsLib.CreateTab("Animation", 4)
State.CustomAnimDropdown = SettingsLib.AddDropdown(State.CustomAnimTab, "Select Animation", State.CustomAnimations.Order, State.currentCustomAnimationName, function(v)
    State.currentCustomAnimationName = v
    State.CustomAnimations.Selected = v
    State.SaveCustomAnimations(State.CustomAnimations)
    if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
    if State.ApplyCustomAnimIconUI then State.ApplyCustomAnimIconUI() end
    if refreshCustomAnimationState then refreshCustomAnimationState(false) end
end)
if State.CustomAnimDropdown and State.CustomAnimDropdown.Button and State.CustomAnimDropdown.Button.Parent and State.CustomAnimDropdown.Button.Parent.Parent then
   State.CustomAnimDropdown.Button.Parent.Parent.LayoutOrder = 0
end

local CustomAnimBtnItem = SettingsLib.AddItem(State.CustomAnimTab, "Animation Management", "Manage your animations")
CustomAnimBtnItem.LayoutOrder = 1 
CustomAnimBtnItem.BackgroundColor3 = Color3.fromRGB(35, 38, 42)
CustomAnimBtnItem.Size = UDim2.new(0.95, 0, 0, 70) 
for _, v in pairs(CustomAnimBtnItem:GetChildren()) do if v.Name == "Title" or v.Name == "Desc" then v:Destroy() end end

local CustomAnimMgtContainer = Instance.new("Frame")
CustomAnimMgtContainer.Parent = CustomAnimBtnItem
CustomAnimMgtContainer.BackgroundTransparency = 1
CustomAnimMgtContainer.Size = UDim2.new(1, 0, 1, 0)

local CustomAnimLayout = Instance.new("UIListLayout")
CustomAnimLayout.FillDirection = Enum.FillDirection.Horizontal
CustomAnimLayout.Padding = UDim.new(0, 15)
CustomAnimLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
CustomAnimLayout.VerticalAlignment = Enum.VerticalAlignment.Center
CustomAnimLayout.Parent = CustomAnimMgtContainer

function NormalizeCustomAnimationData(animData)
    local defaultAnim = {
        idle = { Animation1 = 0, Animation2 = 0 },
        walk = { WalkAnim = 0 },
        run = { RunAnim = 0 },
        jump = { JumpAnim = 0 },
        fall = { FallAnim = 0 },
        swimidle = { SwimIdle = 0 },
        swim = { Swim = 0 },
        __meta = { IconImage = DEFAULT_IDLE_ICON_ID, IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) }
    }
    
    local result = { Sets = { Default = DeepCopy(defaultAnim) }, Order = {"Default"}, Selected = "Default" }
    if type(animData) ~= "table" then return result end
    
    local setsTable = animData.Sets or animData
    if type(setsTable) == "table" then
        for name, data in pairs(setsTable) do
            if type(data) == "table" then
                if name == "Default" then
                    result.Sets.Default = data
                else
                    result.Sets[name] = data
                end
                data.__meta = data.__meta or {}
                if data.__meta.IconImage == nil then data.__meta.IconImage = DEFAULT_IDLE_ICON_ID end
                if data.__meta.IconColor == nil then data.__meta.IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) end
            end
        end
    end
    
    local order = animData.Order
    if type(order) == "table" then
        for _, name in ipairs(order) do
            if name ~= "Default" and result.Sets[name] then
                table.insert(result.Order, name)
            end
        end
    else
        for name, _ in pairs(result.Sets) do
            if name ~= "Default" then table.insert(result.Order, name) end
        end
    end
    
    local selected = animData.Selected
    if type(selected) == "string" and result.Sets[selected] then
        result.Selected = selected
    end
    
    return result
end

function MakeUniqueSetName(baseSets, desiredName)
    if not baseSets[desiredName] then return desiredName end
    local i = 2
    local candidate = desiredName .. " (Imported)"
    if not baseSets[candidate] then return candidate end
    while true do
        candidate = desiredName .. " (Imported " .. i .. ")"
        if not baseSets[candidate] then return candidate end
        i = i + 1
    end
end

SettingsLib.AddIconButton(CustomAnimMgtContainer, "108445456753346", function()
    local popup, content = CreatePopup("Create Animation")
    local In = CreateInput(content, "Animation Name...")
    
    local Save = CreateButton(content, "SAVE", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Cancel.TextColor3 = Color3.new(1,1,1)

    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not State.CustomAnimations.Sets[In.Text] then
            local defaultAnim = {
                idle = { Animation1 = 0, Animation2 = 0 },
                walk = { WalkAnim = 0 },
                run = { RunAnim = 0 },
                jump = { JumpAnim = 0 },
                fall = { FallAnim = 0 },
                swimidle = { SwimIdle = 0 },
                swim = { Swim = 0 },
                __meta = { IconImage = DEFAULT_IDLE_ICON_ID, IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) }
            }
            State.CustomAnimations.Sets[In.Text] = defaultAnim
            table.insert(State.CustomAnimations.Order, In.Text)
            
            table.sort(State.CustomAnimations.Order, function(a, b)
                if a == "Default" then return true end
                if b == "Default" then return false end
                return a:lower() < b:lower()
            end)
            
            State.currentCustomAnimationName = In.Text
            State.CustomAnimations.Selected = In.Text
            State.SaveCustomAnimations(State.CustomAnimations)
            if State.CustomAnimDropdown then
                State.CustomAnimDropdown.Refresh(State.CustomAnimations.Order)
                State.CustomAnimDropdown.Button.Text = State.currentCustomAnimationName .. "  ▼"
            end
            if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
            if State.ApplyCustomAnimIconUI then State.ApplyCustomAnimIconUI() end
            if refreshCustomAnimationState then refreshCustomAnimationState(false) end
            popup:Destroy()
        end
    end)
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(CustomAnimMgtContainer, "71829270056766", function()
    if State.currentCustomAnimationName ~= "Default" then
        local idx = table.find(State.CustomAnimations.Order, State.currentCustomAnimationName)
        if idx then table.remove(State.CustomAnimations.Order, idx) end
        
        State.CustomAnimations.Sets[State.currentCustomAnimationName] = nil
        State.currentCustomAnimationName = "Default"
        State.CustomAnimations.Selected = "Default"
        State.SaveCustomAnimations(State.CustomAnimations)
        if State.CustomAnimDropdown then
            State.CustomAnimDropdown.Refresh(State.CustomAnimations.Order)
            State.CustomAnimDropdown.Button.Text = "Default  ▼"
        end
        if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
        if State.ApplyCustomAnimIconUI then State.ApplyCustomAnimIconUI() end
        if refreshCustomAnimationState then refreshCustomAnimationState(false) end
    end
end)

SettingsLib.AddIconButton(CustomAnimMgtContainer, "117761881427472", function()
    if State.currentCustomAnimationName == "Default" then return end
    
    local popup, content = CreatePopup("Rename Animation")
    local In = CreateInput(content, "New Name...", State.currentCustomAnimationName)
    
    local Save = CreateButton(content, "RENAME", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Cancel.TextColor3 = Color3.new(1,1,1)

    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not State.CustomAnimations.Sets[In.Text] then
            local idx = table.find(State.CustomAnimations.Order, State.currentCustomAnimationName)
            if idx then State.CustomAnimations.Order[idx] = In.Text end
            
            State.CustomAnimations.Sets[In.Text] = State.CustomAnimations.Sets[State.currentCustomAnimationName]
            State.CustomAnimations.Sets[State.currentCustomAnimationName] = nil
            State.currentCustomAnimationName = In.Text
            State.CustomAnimations.Selected = In.Text
            State.SaveCustomAnimations(State.CustomAnimations)
            if State.CustomAnimDropdown then
                State.CustomAnimDropdown.Refresh(State.CustomAnimations.Order)
                State.CustomAnimDropdown.Button.Text = State.currentCustomAnimationName .. "  ▼"
            end
            if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
            if State.ApplyCustomAnimIconUI then State.ApplyCustomAnimIconUI() end
            if refreshCustomAnimationState then refreshCustomAnimationState(false) end
            popup:Destroy()
        end
    end)
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(CustomAnimMgtContainer, "107588515524752", function()
    local currentSet = State.CustomAnimations.Sets[State.currentCustomAnimationName]
    local data = {
        Type = "CustomAnimationSet",
        Name = State.currentCustomAnimationName,
        Data = currentSet
    }
    local json = HttpService:JSONEncode(data)
    
    local popup, content = CreatePopup("Export Animations", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "", json, true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    box.TextEditable = false
    
    local copy = CreateButton(content, "COPY TO CLIPBOARD", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))
    copy.MouseButton1Click:Connect(function()
        setclipboard(json)
        copy.Text = "COPIED!"
        task.delay(1, function() copy.Text = "COPY TO CLIPBOARD" end)
    end)
    
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "X"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(CustomAnimMgtContainer, "78317476576895", function()
    local popup, content = CreatePopup("Import Animations", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "Paste Animation JSON here...", "", true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    
    local imp = CreateButton(content, "IMPORT DATA", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))
    imp.MouseButton1Click:Connect(function()
        local s, d = pcall(function() return HttpService:JSONDecode(box.Text) end)
        if s and type(d) == "table" then
            if d.Type and d.Type ~= "CustomAnimationSet" then
                getgenv().Notify({ Title = "Error", Content = "Backup type mismatch!", Duration = 3 })
                return
            end
            if type(d.Data) ~= "table" then
                getgenv().Notify({ Title = "Error", Content = "Invalid JSON", Duration = 3 })
                return
            end
            State.CustomAnimations = NormalizeCustomAnimationData(State.CustomAnimations)
            local sourceName = d.Name or "Imported"
            local targetName = MakeUniqueSetName(State.CustomAnimations.Sets, sourceName)
            local imported = d.Data
            imported.__meta = imported.__meta or {}
            if imported.__meta.IconImage == nil then imported.__meta.IconImage = DEFAULT_IDLE_ICON_ID end
            if imported.__meta.IconColor == nil then imported.__meta.IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) end
            State.CustomAnimations.Sets[targetName] = imported
            table.insert(State.CustomAnimations.Order, targetName)
            State.currentCustomAnimationName = targetName
            State.CustomAnimations.Selected = targetName
            
            State.SaveCustomAnimations(State.CustomAnimations)
            if State.CustomAnimDropdown then
                State.CustomAnimDropdown.Refresh(State.CustomAnimations.Order)
                State.CustomAnimDropdown.Button.Text = State.currentCustomAnimationName .. "  ▼"
            end
            if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
            if State.ApplyCustomAnimIconUI then State.ApplyCustomAnimIconUI() end
            if refreshCustomAnimationState then refreshCustomAnimationState(false) end
            popup:Destroy()
            getgenv().Notify({ Title = "7yd7 | Animation", Content = "✅ Imported custom animations", Duration = 3 })
        else
            getgenv().Notify({ Title = "Error", Content = "Invalid JSON", Duration = 3 })
        end
    end)
    
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "x"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

function GetCurrentCustomAnimMeta()
    local set = State.CustomAnimations.Sets[State.currentCustomAnimationName]
    if not set then return nil end
    set.__meta = set.__meta or {}
    if set.__meta.IconImage == nil then set.__meta.IconImage = DEFAULT_IDLE_ICON_ID end
    if set.__meta.IconColor == nil then set.__meta.IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR) end
    return set.__meta
end

State.ApplyCustomAnimIconUI = function()
    if not State.CustomAnimIconControl or not State.CustomAnimIconControl.SetValue then return end
    local meta = GetCurrentCustomAnimMeta()
    if not meta then return end
    State.CustomAnimIconControl.SetValue(meta.IconImage or DEFAULT_IDLE_ICON_ID, TableToColor(meta.IconColor or ColorToTable(DEFAULT_IDLE_ICON_COLOR)))
end

do
    local meta = GetCurrentCustomAnimMeta() or {}
    local currentImage = meta.IconImage or DEFAULT_IDLE_ICON_ID
    local currentColor = TableToColor(meta.IconColor or ColorToTable(DEFAULT_IDLE_ICON_COLOR))
    State.CustomAnimIconControl = SettingsLib.AddAssetColor(State.CustomAnimTab, "Icon", "Asset ID or URL...", currentImage, currentColor, function(text, color)
        local set = State.CustomAnimations.Sets[State.currentCustomAnimationName]
        if not set then return end
        set.__meta = set.__meta or {}
        set.__meta.IconImage = text
        set.__meta.IconColor = ColorToTable(color)
        State.SaveCustomAnimations(State.CustomAnimations)
        if refreshCustomAnimationState then refreshCustomAnimationState(false) end
    end)
    if State.CustomAnimIconControl and State.CustomAnimIconControl.Item then
        State.CustomAnimIconControl.Item.LayoutOrder = 1.5
    end
    
    local resetBtn = SettingsLib:Create("ImageButton", {
        Parent = State.CustomAnimIconControl.Item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -120, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 10
    })
    resetBtn.MouseButton1Click:Connect(function()
        local set = State.CustomAnimations.Sets[State.currentCustomAnimationName]
        if not set then return end
        set.__meta = set.__meta or {}
        set.__meta.IconImage = DEFAULT_IDLE_ICON_ID
        set.__meta.IconColor = ColorToTable(DEFAULT_IDLE_ICON_COLOR)
        State.SaveCustomAnimations(State.CustomAnimations)
        if State.CustomAnimIconControl and State.CustomAnimIconControl.SetValue then
            State.CustomAnimIconControl.SetValue(DEFAULT_IDLE_ICON_ID, DEFAULT_IDLE_ICON_COLOR)
        end
        if refreshCustomAnimationState then refreshCustomAnimationState(false) end
    end)
end

State.CustomAnimUIElems = {}
function CreateAnimSetUI(folder, cat, name)
    local item = SettingsLib.AddItem(folder, cat .. " - " .. name, "Current ID: 0")
    
    local resetBtn = SettingsLib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -70, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 10
    })
    
    local editBtn = SettingsLib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -40, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://117761881427472",
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 10
    })
    
    resetBtn.MouseButton1Click:Connect(function()
        if State.currentCustomAnimationName == "Default" then return end
        if State.CustomAnimations.Sets[State.currentCustomAnimationName] then
            if not State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] then
                State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] = {}
            end
            State.CustomAnimations.Sets[State.currentCustomAnimationName][cat][name] = 0
            State.SaveCustomAnimations(State.CustomAnimations)
            if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
            if refreshCustomAnimationState then refreshCustomAnimationState(true) end
        end
    end)
    
    editBtn.MouseButton1Click:Connect(function()
        State.enterCustomAnimationEditor(cat, name)
    end)
    
    table.insert(State.CustomAnimUIElems, { item = item, cat = cat, name = name })
end

State.CustomAnimFolders = {}
State.CustomAnimFolders.Idle = SettingsLib.AddFolder(State.CustomAnimTab, "Idle Animations")
State.CustomAnimFolders.Idle.Parent.LayoutOrder = 2
CreateAnimSetUI(State.CustomAnimFolders.Idle, "idle", "Animation1")
CreateAnimSetUI(State.CustomAnimFolders.Idle, "idle", "Animation2")

State.CustomAnimFolders.Movement = SettingsLib.AddFolder(State.CustomAnimTab, "Movement Animations")
State.CustomAnimFolders.Movement.Parent.LayoutOrder = 3
CreateAnimSetUI(State.CustomAnimFolders.Movement, "walk", "WalkAnim")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "run", "RunAnim")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "jump", "JumpAnim")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "fall", "FallAnim")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "climb", "ClimbAnim")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "swimidle", "SwimIdle")
CreateAnimSetUI(State.CustomAnimFolders.Movement, "swim", "Swim")

State.RefreshCustomAnimUI = function()
    local set = State.CustomAnimations.Sets[State.currentCustomAnimationName]
    if not set then return end
    
    for _, elem in pairs(State.CustomAnimUIElems) do
        local desc = elem.item:FindFirstChild("Desc")
        if desc then
            local val = set[elem.cat] and set[elem.cat][elem.name] or 0
            desc.Text = "Current ID: " .. tostring(val)
        end
    end
end
State.RefreshCustomAnimUI()

State.PageTab = SettingsLib.CreateTab("Page", 5)

function GetEmotePageNames()
    return State.EmotePages.Order
end

SettingsLib.AddItem(State.PageTab, "Page Profiles", "Pages allow you to save different favorite sets. Switch pages to quickly change your favorite wheel loadout.")

SettingsLib.AddItem(State.PageTab, "Emote Profiles", "Manage your favorite emote profiles")

State.PageDropdown = SettingsLib.AddDropdown(State.PageTab, "Select Emote Page", GetEmotePageNames(), State.currentEmotePageName, function(v)
    SwitchEmotePage(v)
    State.SaveEmotePages(State.EmotePages)
end)

local EmotePageMgtItem = SettingsLib.AddItem(State.PageTab, "Emote Page Management", " ")
EmotePageMgtItem.BackgroundColor3 = Color3.fromRGB(35, 38, 42)
EmotePageMgtItem.Size = UDim2.new(0.95, 0, 0, 70)
for _, v in pairs(EmotePageMgtItem:GetChildren()) do if v.Name == "Title" or v.Name == "Desc" then v:Destroy() end end

local EmotePageMgtContainer = Instance.new("Frame")
EmotePageMgtContainer.Parent = EmotePageMgtItem
EmotePageMgtContainer.BackgroundTransparency = 1
EmotePageMgtContainer.Size = UDim2.new(1, 0, 1, 0)

local EmotePageLayout = Instance.new("UIListLayout")
EmotePageLayout.FillDirection = Enum.FillDirection.Horizontal
EmotePageLayout.Padding = UDim.new(0, 15)
EmotePageLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
EmotePageLayout.VerticalAlignment = Enum.VerticalAlignment.Center
EmotePageLayout.Parent = EmotePageMgtContainer

SettingsLib.AddIconButton(EmotePageMgtContainer, "108445456753346", function()
    local popup, content = CreatePopup("Create Emote Page")
    local In = CreateInput(content, "Page Name...")
    local Save = CreateButton(content, "SAVE", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not State.EmotePages.Sets[In.Text] then
            State.EmotePages.Sets[In.Text] = {}
            table.insert(State.EmotePages.Order, In.Text)
            table.sort(State.EmotePages.Order, function(a, b)
                if a == "Default" then return true end
                if b == "Default" then return false end
                return a:lower() < b:lower()
            end)
            State.SaveEmotePages(State.EmotePages)
            if State.PageDropdown then State.PageDropdown.Refresh(GetEmotePageNames()) end
            SwitchEmotePage(In.Text)
            if State.PageDropdown then State.PageDropdown.Button.Text = State.currentEmotePageName .. "  ▼" end
            popup:Destroy()
        end
    end)
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(EmotePageMgtContainer, "71829270056766", function()
    if State.currentEmotePageName ~= "Default" then
        local idx = table.find(State.EmotePages.Order, State.currentEmotePageName)
        if idx then table.remove(State.EmotePages.Order, idx) end
        State.EmotePages.Sets[State.currentEmotePageName] = nil
        State.currentEmotePageName = "Default"
        State.EmotePages.Selected = "Default"
        State.SaveEmotePages(State.EmotePages)
        if State.PageDropdown then
            State.PageDropdown.Refresh(GetEmotePageNames())
            State.PageDropdown.Button.Text = "Default  ▼"
        end
        SwitchEmotePage("Default")
    end
end)

SettingsLib.AddIconButton(EmotePageMgtContainer, "117761881427472", function()
    if State.currentEmotePageName == "Default" then return end
    local popup, content = CreatePopup("Rename Emote Page")
    local In = CreateInput(content, "New Name...", State.currentEmotePageName)
    local Save = CreateButton(content, "RENAME", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.6, 0))
    local Cancel = CreateButton(content, "CANCEL", Color3.fromRGB(50, 50, 50), UDim2.new(0.55, 0, 0.6, 0))
    Save.MouseButton1Click:Connect(function()
        if In.Text ~= "" and not State.EmotePages.Sets[In.Text] then
            local idx = table.find(State.EmotePages.Order, State.currentEmotePageName)
            if idx then State.EmotePages.Order[idx] = In.Text end
            State.EmotePages.Sets[In.Text] = State.EmotePages.Sets[State.currentEmotePageName]
            State.EmotePages.Sets[State.currentEmotePageName] = nil
            State.currentEmotePageName = In.Text
            State.EmotePages.Selected = In.Text
            State.SaveEmotePages(State.EmotePages)
            if State.PageDropdown then
                State.PageDropdown.Refresh(GetEmotePageNames())
                State.PageDropdown.Button.Text = State.currentEmotePageName .. "  ▼"
            end
            popup:Destroy()
        end
    end)
    Cancel.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(EmotePageMgtContainer, "107588515524752", function() 
    local currentSet = State.EmotePages.Sets[State.currentEmotePageName]
    local data = { Type = "EmotePageSet", Name = State.currentEmotePageName, Data = currentSet }
    local json = HttpService:JSONEncode(data)
    local popup, content = CreatePopup("Export Emote Page", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "", json, true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    box.TextEditable = false
    local copy = CreateButton(content, "COPY TO CLIPBOARD", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))
    copy.MouseButton1Click:Connect(function()
        setclipboard(json)
        copy.Text = "COPIED!"
        task.delay(1, function() copy.Text = "COPY TO CLIPBOARD" end)
    end)
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "×"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddIconButton(EmotePageMgtContainer, "78317476576895", function() 
    local popup, content = CreatePopup("Import Emote Page", UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "Paste Page JSON here...", "", true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    local imp = CreateButton(content, "IMPORT DATA", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))
    imp.MouseButton1Click:Connect(function()
        local s, d = pcall(function() return HttpService:JSONDecode(box.Text) end)
        if s and type(d) == "table" and d.Type == "EmotePageSet" and type(d.Data) == "table" then
            local targetName = MakeUniqueSetName(State.EmotePages.Sets, d.Name or "Imported")
            State.EmotePages.Sets[targetName] = d.Data
            table.insert(State.EmotePages.Order, targetName)
            State.currentEmotePageName = targetName
            State.EmotePages.Selected = targetName
            State.SaveEmotePages(State.EmotePages)
            if State.PageDropdown then
                State.PageDropdown.Refresh(GetEmotePageNames())
                State.PageDropdown.Button.Text = State.currentEmotePageName .. "  ▼"
            end
            SwitchEmotePage(targetName)
            popup:Destroy()
            getgenv().Notify({ Title = "7yd7 | Page", Content = "✅ Imported Emote page", Duration = 3 })
        else
            getgenv().Notify({ Title = "Error", Content = "Invalid Emote Page JSON", Duration = 3 })
        end
    end)
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "×"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end)

SettingsLib.AddItem(State.PageTab, "Animation Profiles", "Manage your favorite animation profiles")


local BackupTab = SettingsLib.CreateTab("Backup", 6)

local BackupDesc = SettingsLib.AddItem(BackupTab, "What's included in a backup?", " ")
BackupDesc.LayoutOrder = 1
BackupDesc.Size = UDim2.new(0.95, 0, 0, 110)
for _, v in pairs(BackupDesc:GetChildren()) do if v.Name == "Title" or v.Name == "Desc" then v:Destroy() end end
BackupDesc.BackgroundTransparency = 0
BackupDesc.BackgroundColor3 = Color3.fromRGB(35, 38, 42)

local BackupTitle = Instance.new("TextLabel")
BackupTitle.Parent = BackupDesc
BackupTitle.BackgroundTransparency = 1
BackupTitle.Position = UDim2.new(0, 12, 0, 6)
BackupTitle.Size = UDim2.new(1, -24, 0, 18)
BackupTitle.Font = Enum.Font.GothamBold
BackupTitle.Text = "What's included in a backup?"
BackupTitle.TextColor3 = Color3.fromRGB(200, 200, 200)
BackupTitle.TextSize = 12
BackupTitle.TextXAlignment = Enum.TextXAlignment.Left

local DescList = Instance.new("Frame")
DescList.Parent = BackupDesc
DescList.BackgroundTransparency = 1
DescList.Position = UDim2.new(0, 12, 0, 28)
DescList.Size = UDim2.new(1, -24, 1, -28)

local LayoutDesc = Instance.new("UIListLayout")
LayoutDesc.Parent = DescList
LayoutDesc.Padding = UDim.new(0, 4)

function MakeDescLine(text)
    local lbl = Instance.new("TextLabel")
    lbl.Parent = DescList
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, 0, 0, 15)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.TextWrapped = true
    lbl.Font = Enum.Font.Gotham
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(150, 150, 150)
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.RichText = true
end

MakeDescLine("<b>• Theme:</b> Saves custom themes")
MakeDescLine("<b>• Settings:</b> Saves HUD layout & values")
MakeDescLine("<b>• Favorite:</b> Saves favorite emotes/anims")
MakeDescLine("<b>• All:</b> Includes everything above")

local ExportItem = SettingsLib.AddItem(BackupTab, "Export Settings", "Save current settings to a file for sharing or later import.")
ExportItem.LayoutOrder = 2

local ExportBtnContainer = Instance.new("Frame")
ExportBtnContainer.Parent = ExportItem
ExportBtnContainer.BackgroundTransparency = 1
ExportBtnContainer.Size = UDim2.new(1, -24, 0, 60)

local expDesc = ExportItem:FindFirstChild("Desc")
if expDesc then
    expDesc.Size = UDim2.new(1, -24, 0, 0)
    local function updateExpPos()
        ExportBtnContainer.Position = UDim2.new(0, 12, 0, expDesc.Position.Y.Offset + expDesc.AbsoluteSize.Y + 12)
    end
    expDesc:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateExpPos)
    updateExpPos()
else
    ExportBtnContainer.Position = UDim2.new(0, 12, 0, 32)
end

local ExportLayout = Instance.new("UIGridLayout")
ExportLayout.CellSize = UDim2.new(0.48, 0, 0, 26)
ExportLayout.CellPadding = UDim2.new(0.04, 0, 0, 8)
ExportLayout.SortOrder = Enum.SortOrder.LayoutOrder
ExportLayout.Parent = ExportBtnContainer

function CreateExportBtn(text, color, order)
    local btn = Instance.new("TextButton")
    btn.LayoutOrder = order
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.Font = Enum.Font.GothamBold
    btn.TextColor3 = Color3.new(1,1,1)
    btn.TextSize = 11
    btn.Parent = ExportBtnContainer
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn
    
    return btn
end

local btnColors = {
    dark = Color3.fromRGB(45, 48, 52),
    blue = Color3.fromRGB(88, 101, 242)
}

local BtnExportAll = CreateExportBtn("Export All Settings", btnColors.dark, 1)
local BtnExportThemes = CreateExportBtn("Export Themes", btnColors.blue, 2)
local BtnExportSettings = CreateExportBtn("Export Settings", btnColors.blue, 3)
local BtnExportFavorites = CreateExportBtn("Export Favorites", btnColors.blue, 4)

function GetFavoritesData()
    local favAnimsStr = "{}"
    if isfile and isfile(State.favoriteAnimationsFileName) then
        favAnimsStr = readfile(State.favoriteAnimationsFileName)
    end
    return {
        EmotePages = State.EmotePages,
        Animations = HttpService:JSONDecode(favAnimsStr) or {}
    }
end

BtnExportAll.MouseButton1Click:Connect(function()
    local data = {
        Type = "All",
        Themes = LoadThemes(),
        Settings = Config,
        Favorites = GetFavoritesData()
    }
    setclipboard(HttpService:JSONEncode(data))
    BtnExportAll.Text = "Copied!"
    task.delay(1, function() BtnExportAll.Text = "Export All Settings" end)
end)

BtnExportThemes.MouseButton1Click:Connect(function()
    local data = {
        Type = "Themes",
        Themes = LoadThemes()
    }
    setclipboard(HttpService:JSONEncode(data))
    BtnExportThemes.Text = "Copied!"
    task.delay(1, function() BtnExportThemes.Text = "Export Themes" end)
end)

BtnExportSettings.MouseButton1Click:Connect(function()
    local data = {
        Type = "Settings",
        Settings = Config
    }
    setclipboard(HttpService:JSONEncode(data))
    BtnExportSettings.Text = "Copied!"
    task.delay(1, function() BtnExportSettings.Text = "Export Settings" end)
end)

BtnExportFavorites.MouseButton1Click:Connect(function()
    local data = {
        Type = "Favorites",
        Favorites = GetFavoritesData()
    }
    setclipboard(HttpService:JSONEncode(data))
    BtnExportFavorites.Text = "Copied!"
    task.delay(1, function() BtnExportFavorites.Text = "Export Favorites" end)
end)


local ImportItem = SettingsLib.AddItem(BackupTab, "Import Settings", "Select a backup file to restore your configuration and overwrite current settings.")
ImportItem.LayoutOrder = 3

local ImportBtnContainer = Instance.new("Frame")
ImportBtnContainer.Parent = ImportItem
ImportBtnContainer.BackgroundTransparency = 1
ImportBtnContainer.Size = UDim2.new(1, -24, 0, 60)

local impDesc = ImportItem:FindFirstChild("Desc")
if impDesc then
    impDesc.Size = UDim2.new(1, -24, 0, 0)
    local function updateImpPos()
        ImportBtnContainer.Position = UDim2.new(0, 12, 0, impDesc.Position.Y.Offset + impDesc.AbsoluteSize.Y + 12)
    end
    impDesc:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateImpPos)
    updateImpPos()
else
    ImportBtnContainer.Position = UDim2.new(0, 12, 0, 32)
end

local ImportLayout = Instance.new("UIGridLayout")
ImportLayout.CellSize = UDim2.new(0.48, 0, 0, 26)
ImportLayout.CellPadding = UDim2.new(0.04, 0, 0, 8)
ImportLayout.SortOrder = Enum.SortOrder.LayoutOrder
ImportLayout.Parent = ImportBtnContainer

function CreateImportBtn(text, color, order)
    local btn = Instance.new("TextButton")
    btn.LayoutOrder = order
    btn.BackgroundColor3 = color
    btn.Text = text
    btn.Font = Enum.Font.GothamBold
    btn.TextColor3 = Color3.new(1,1,1)
    btn.TextSize = 11
    btn.Parent = ImportBtnContainer
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn
    
    return btn
end

local BtnImportAll = CreateImportBtn("Import All Settings", btnColors.dark, 1)
local BtnImportThemes = CreateImportBtn("Import Themes", btnColors.blue, 2)
local BtnImportSettings = CreateImportBtn("Import Settings", btnColors.blue, 3)
local BtnImportFavorites = CreateImportBtn("Import Favorites", btnColors.blue, 4)

function HandleImportPrompt(typeStr)
    local popup, content = CreatePopup("Import " .. typeStr, UDim2.fromOffset(320, 240))
    local box = CreateInput(content, "Paste Backup JSON here...", "", true)
    box.Size = UDim2.new(0.9, 0, 0, 130)
    
    local imp = CreateButton(content, "IMPORT DATA", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))

    imp.MouseButton1Click:Connect(function()
        local s, d = pcall(function() return HttpService:JSONDecode(box.Text) end)
        if s and type(d) == "table" and d.Type then
            if typeStr ~= "All" and d.Type ~= "All" and typeStr ~= d.Type then
                 getgenv().Notify({Title = "Error", Content = "Backup type mismatch!", Duration = 3})
                 return
            end
            
            if d.Themes and (typeStr == "All" or typeStr == "Themes") then
                themes = d.Themes
                currentThemeName = themes.Selected or Config.SelectedTheme or "Default"
                SaveThemesImplementation(themes)
                themeDropdown.Refresh(GetNames())
                if themeDropdown and themeDropdown.Button then
                    themeDropdown.Button.Text = currentThemeName .. "  ▼"
                end
                local themeToApply = themes[currentThemeName] or themes["Default"]
                if themeToApply then
                    State.isApplyingTheme = false
                    ApplyTheme(themeToApply)
                else
                    warn("7yd7 | Missing Default theme during import fallback")
                end
            end
            if d.Settings and (typeStr == "All" or typeStr == "Settings") then
                for k, v in pairs(d.Settings) do Config[k] = v end
                SaveConfig()
                ApplyUIVisibility()
                if applySavedPositions then applySavedPositions() end
                if State.RefreshSettingsUI then State.RefreshSettingsUI() end
            end
            if (d.Favorites or d.EmotePages) and (typeStr == "All" or typeStr == "Favorites") then
                local emotesData = d.EmotePages
                if not emotesData and type(d.Favorites) == "table" then
                    emotesData = d.Favorites.EmotePages or d.Favorites.Emotes
                end
                if emotesData then
                    if emotesData.Sets then
                        State.EmotePages = emotesData
                    else
                        State.EmotePages.Sets.Default = emotesData
                    end
                    State.SaveEmotePages(State.EmotePages)
                    local targetPage = State.EmotePages.Selected
                    if not State.EmotePages.Sets[targetPage] then targetPage = "Default" end
                    SwitchEmotePage(targetPage)
                end
                
                if d.Favorites and d.Favorites.Animations then
                     State.favoriteAnimations = d.Favorites.Animations
                     writefile(State.favoriteAnimationsFileName, HttpService:JSONEncode(d.Favorites.Animations))
                     State.favoriteSetVersion = State.favoriteSetVersion + 1
                end
                if State.RefreshUI then State.RefreshUI() end
            end
            
            getgenv().Notify({Title = "Success", Content = "Data imported successfully!", Duration = 3})
            popup:Destroy()
        else
            getgenv().Notify({Title = "Error", Content = "Invalid Backup JSON Format!", Duration = 3})
        end
    end)
    
    local close = Instance.new("TextButton")
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -30, 0, 5)
    close.Text = "×"
    close.Font = Enum.Font.GothamBold
    close.TextSize = 20
    close.BackgroundTransparency = 1
    close.TextColor3 = Color3.new(1,1,1)
    close.Parent = popup
    close.MouseButton1Click:Connect(function() popup:Destroy() end)
end

BtnImportAll.MouseButton1Click:Connect(function() HandleImportPrompt("All") end)
BtnImportThemes.MouseButton1Click:Connect(function() HandleImportPrompt("Themes") end)
BtnImportSettings.MouseButton1Click:Connect(function() HandleImportPrompt("Settings") end)
BtnImportFavorites.MouseButton1Click:Connect(function() HandleImportPrompt("Favorites") end)

getgenv().Notify({
    Title = '7yd7 | Emote',
    Content = '⚠️ Script loading...',
    Duration = 5
})

local Players = game:GetService("Players")
local player = Players.LocalPlayer
if not player then
    player = Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
end
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")

getgenv().OwnedAuthenticEmotes = getgenv().OwnedAuthenticEmotes or {}
function gatherAuthenticEmotes(char)
    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    local desc = hum:WaitForChild("HumanoidDescription", 5)
    if not desc then return end
    local allEmotes = desc:GetEmotes()
    local owned = {}
    
    for _, e in ipairs(desc:GetEquippedEmotes()) do
        local id = allEmotes[e.Name] and allEmotes[e.Name][1]
        if id then
            local idNum = tonumber((tostring(id):gsub("rbxassetid://", "")))
            if idNum then
                table.insert(owned, {
                    name = e.Name,
                    id = idNum
                })
            end
        end
    end
    if #owned > 0 then
        getgenv().OwnedAuthenticEmotes = owned
    end
end

task.spawn(function() gatherAuthenticEmotes(character) end)
player.CharacterAdded:Connect(gatherAuthenticEmotes)

local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

RunService.Heartbeat:Connect(function()
    local success, menu = pcall(function() return CoreGui.RobloxGui.EmotesMenu.Children end)
    if not (success and menu) then return end
    
    pcall(function()
        local wheelVisible = menu.Main.EmotesWheel.Visible
        if wheelVisible then
            State.lastWheelVisibleTime = tick()
        end
        ToggleContainer.Visible = wheelVisible
    end)

    local errorMsg = menu:FindFirstChild("ErrorMessage")

    if errorMsg and errorMsg.Visible then
        if player.Character and player.Character:FindFirstChild("Humanoid") and player.Character.Humanoid.RigType == Enum.HumanoidRigType.R6 then
            errorMsg.ErrorText.Text = "Only r15 does not work r6"
        elseif tick() - State.lastRadialActionTime < 2 then
            errorMsg.Visible = false
        end
    end
end)


function ErrorMessage(text, duration)

    if State.currentTimer then
        task.cancel(State.currentTimer)
        State.currentTimer = nil
    end
    
    local errorMessage = CoreGui.RobloxGui.EmotesMenu.Children.ErrorMessage
    local errorText = errorMessage.ErrorText
    
    errorText.Text = text
    
    errorMessage.Visible = true
    
    State.currentTimer = task.delay(duration, function()
        errorMessage.Visible = false
        State.currentTimer = nil
    end)
end

function stopEmotes()
    for _, track in ipairs(humanoid:GetPlayingAnimationTracks()) do
        track:Stop()
    end
end

function getCharacterAndHumanoid()
    local character = player.Character
    if not character then
        return nil, nil
    end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then
        return nil, nil
    end
    return character, humanoid
end

function urlToId(animationId)
    animationId = string.gsub(animationId, "http://www%.roblox%.com/asset/%?id=", "")
    animationId = string.gsub(animationId, "rbxassetid://", "")
    return animationId
end

function resolveEmoteToAnimationId(emoteId)
    local fallbackId = tonumber(emoteId)
    if not emoteId or emoteId == "" then return fallbackId end

    local objects
    local ok = false
    local idStr = tostring(emoteId)
    for _, url in ipairs({
        "rbxassetid://" .. idStr,
        "http://www.roblox.com/asset/?id=" .. idStr
    }) do
        ok, objects = pcall(function()
            return game:GetObjects(url)
        end)
        if ok and type(objects) == "table" and #objects > 0 then
            break
        end
    end
    if ok and type(objects) == "table" then
        local function findAnimId(obj)
            if obj:IsA("Animation") then
                local animId = tonumber(urlToId(obj.AnimationId))
                if animId and animId > 0 then
                    return animId
                end
            end
            for _, child in ipairs(obj:GetChildren()) do
                local found = findAnimId(child)
                if found then return found end
            end
            return nil
        end

        local rootObj = objects[1]
        if rootObj and rootObj.Parent == nil then
            pcall(function() rootObj.Parent = workspace end)
        end
        if rootObj then
            local foundRoot = findAnimId(rootObj)
            if foundRoot then
                pcall(function() rootObj:Destroy() end)
                return foundRoot
            end
        end
        for _, obj in ipairs(objects) do
            local found = findAnimId(obj)
            pcall(function() obj:Destroy() end)
            if found then
                return found
            end
        end
    end
    return fallbackId
end

function saveFavoritesAnimations()
    if writefile then
        local jsonData = HttpService:JSONEncode(State.favoriteAnimations)
        writefile(State.favoriteAnimationsFileName, jsonData)
    end
end

function loadFavoritesAnimations()
    if readfile and isfile and isfile(State.favoriteAnimationsFileName) then
        local success, result = pcall(function()
            local fileContent = readfile(State.favoriteAnimationsFileName)
            return HttpService:JSONDecode(fileContent)
        end)
        if success and type(result) == "table" then
            local filtered = {}
            for _, fav in pairs(result) do
                local idNum = fav and tonumber(fav.id)
                if fav and idNum and (idNum > 0 or idNum < -1000) then
                    if fav.isCustomSet == nil and idNum < 0 then
                        fav.isCustomSet = true
                    end
                    if IsCustomSetData(fav) and not fav.customSetName and type(fav.name) == "string" then
                        local baseName = fav.name:gsub("%s*%-.*$", "")
                        fav.customSetName = baseName
                    end
                    table.insert(filtered, fav)
                end
            end
            State.favoriteAnimations = filtered
            State.favoriteSetVersion = State.favoriteSetVersion + 1
        end
    end
end

function disconnectAllConnections()
    for _, connection in pairs(State.guiConnections) do
        if connection then
            connection:Disconnect()
        end
    end
    State.guiConnections = {}
    if ContextActionService then
        ContextActionService:UnbindAction("7yd7_EmoteWheelHotkeys")
    end
end

function loadSpeedEmoteConfig()
    State.speedEmoteEnabled = Config.EmoteSpeedEnabled
    if UI.SpeedBox then
        UI.SpeedBox.Text = tostring(Config.EmoteSpeed)
        updateSpeedBoxVisibility()
    end
end

function extractAssetId(imageUrl)
    local assetId = string.match(imageUrl, "Asset&id=(%d+)")
    return assetId
end

local isRandomSlotEnabled
local isRandomSlotActive

function isEmoteSearchActive()
    return State.currentMode == "emote" and State.emoteSearchTerm and State.emoteSearchTerm ~= ""
end

function isAnimationSearchActive()
    return State.currentMode == "animation" and State.animationSearchTerm and State.animationSearchTerm ~= ""
end

function isSearchActive()
    return isEmoteSearchActive() or isAnimationSearchActive()
end

function shouldRandomSlotBeShown()
    if Config.RandomEnabled ~= true then return false end
    if State.currentMode == "emote" then
        return not isEmoteSearchActive()
    elseif State.currentMode == "animation" then
        return not isAnimationSearchActive()
    end
    return false
end

function getFirstPageSize()
    if shouldRandomSlotBeShown() then
        return math.max(State.itemsPerPage - 1, 1)
    end
    return State.itemsPerPage
end

isRandomSlotEnabled = function()
    return Config.RandomEnabled == true
end

function calcPagesForList(count, isFirstList)
    if count <= 0 then return 0 end
    if isFirstList then
        local first = getFirstPageSize()
        if count <= first then return 1 end
        return 1 + math.ceil((count - first) / State.itemsPerPage)
    end
    return math.ceil(count / State.itemsPerPage)
end

function getCategoryStats()
    local stats = {}
    local randomCaptured = false
    local shouldShowRandom = shouldRandomSlotBeShown()

    local authenticEmotes = (Config.AuthenticFirstPage and State.currentMode == "emote") and (getgenv().OwnedAuthenticEmotes or {}) or {}
    if #authenticEmotes > 0 then
        local pages = calcPagesForList(#authenticEmotes, false)
        table.insert(stats, { name = "Authentic", list = authenticEmotes, pages = pages, hasRandom = false })
    end

    local favoritesToUse = (State.currentMode == "animation") and (_G.filteredFavoritesAnimationsForDisplay or State.favoriteAnimations) or (_G.filteredFavoritesForDisplay or State.favoriteEmotes)
    if #favoritesToUse > 0 then
        local hasRandom = not randomCaptured and shouldShowRandom
        if hasRandom then randomCaptured = true end
        local pages = calcPagesForList(#favoritesToUse, hasRandom)
        table.insert(stats, { name = "Favorites", list = favoritesToUse, pages = pages, hasRandom = hasRandom })
    end

    local normalList = {}
    if State.currentMode == "animation" then
        normalList = State.animationPageCache.normal or {}
    else
        normalList = State.emotePageCache.normal or {}
    end

    if #normalList > 0 then
        local hasRandom = not randomCaptured and shouldShowRandom
        if hasRandom then randomCaptured = true end
        local pages = calcPagesForList(#normalList, hasRandom)
        table.insert(stats, { name = "Normal", list = normalList, pages = pages, hasRandom = hasRandom })
    end

    return stats
end

isRandomSlotActive = function()
    if not shouldRandomSlotBeShown() then return false end
    local categories = getCategoryStats()
    local totalPages = 0
    for _, cat in ipairs(categories) do
        if cat.hasRandom then
            return State.currentPage == totalPages + 1
        end
        totalPages = totalPages + cat.pages
    end
    return false
end

function getPageSize(pageNumber, isFirstList)
    if isFirstList and pageNumber == 1 then
        return getFirstPageSize()
    end
    return State.itemsPerPage
end

function getListSlice(list, pageNumber, isFirstList)
    local pageSize = getPageSize(pageNumber, isFirstList)
    local startIndex
    if isFirstList and pageNumber == 1 then
        startIndex = 1
    elseif isFirstList then
        startIndex = getFirstPageSize() + (pageNumber - 2) * State.itemsPerPage + 1
    else
        startIndex = (pageNumber - 1) * State.itemsPerPage + 1
    end
    local endIndex = math.min(startIndex + pageSize - 1, #list)
    local items = {}
    for i = startIndex, endIndex do
        if list[i] then table.insert(items, list[i]) end
    end
    return items
end

function getRandomSourceList()
    if Config.RandomEnabled == false then
        return {}
    end
    if State.favoriteEnabled then
        if State.currentMode == "animation" then
            return State.filteredAnimations
        end
        return State.filteredEmotes
    end
    if Config.RandomMode == "Favorites" then
        if State.currentMode == "animation" then
            return _G.filteredFavoritesAnimationsForDisplay or State.favoriteAnimations
        end
        return _G.filteredFavoritesForDisplay or State.favoriteEmotes
    end
    if State.currentMode == "animation" then
        return State.filteredAnimations
    end
    return State.filteredEmotes
end

function pickRandomItem()
    local list = getRandomSourceList() or {}
    if #list == 0 then return nil end
    return list[math.random(1, #list)]
end

function pickRandomItemForMode()
    local list = getRandomSourceList() or {}
    if #list == 0 then return nil end
    if State.currentMode == "animation" then
        local filtered = {}
        for _, item in ipairs(list) do
            if item.bundledItems then
                table.insert(filtered, item)
            end
        end
        if #filtered == 0 then return nil end
        return filtered[math.random(1, #filtered)]
    end
    return list[math.random(1, #list)]
end
function updateRandomSlotBlocker(frontFrame, enable)
    if not frontFrame then return end
    local slot = frontFrame:FindFirstChild("1")
    if not slot or not slot:IsA("ImageLabel") then return end

    local blocker = slot:FindFirstChild("RandomBlocker")
    if enable then
        if not blocker then
            blocker = Instance.new("ImageButton")
            blocker.Name = "RandomBlocker"
            blocker.BackgroundTransparency = 1
            blocker.Size = UDim2.new(1, 0, 1, 0)
            blocker.Position = UDim2.new(0, 0, 0, 0)
            blocker.AutoButtonColor = false
            blocker.ZIndex = slot.ZIndex + 10
            blocker.Parent = slot
        else
            blocker.ZIndex = slot.ZIndex + 10
        end
        blocker.Active = true
    else
        if blocker then blocker:Destroy() end
        if State.randomSlotBlockerConn then
            State.randomSlotBlockerConn:Disconnect()
            State.randomSlotBlockerConn = nil
        end
    end
end

function clearCustomHitboxes()
    if State.randomSlotBlockerConn then
        State.randomSlotBlockerConn:Disconnect()
        State.randomSlotBlockerConn = nil
    end
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    if not success or not frontFrame then return end
    local slot1 = frontFrame:FindFirstChild("1")
    if slot1 then
        local blocker = slot1:FindFirstChild("RandomBlocker")
        if blocker then blocker:Destroy() end
    end
    for _, child in pairs(frontFrame:GetChildren()) do
        if child:IsA("ImageLabel") then
            child.Active = false
        end
    end
    frontFrame.Active = true   
end

function applyEmotesButtonsActiveState()
end

function setEmotesButtonsActiveForFavorites()
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    if not success or not frontFrame then return end
    for _, child in pairs(frontFrame:GetChildren()) do
        if child:IsA("ImageLabel") then
            child.Active = true
        end
    end
    frontFrame.Active = true
end

function updateScriptPriorityOverlay()
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    if not success or not frontFrame then return end

    local enable = (State.favoriteEnabled or State.currentMode == "animation" or State.customAnimationEditorActive)
    local blocker = frontFrame:FindFirstChild("ScriptPriorityBlocker")
    if enable then
        if not blocker then
            blocker = Instance.new("ImageButton")
            blocker.Name = "ScriptPriorityBlocker"
            blocker.BackgroundTransparency = 1
            blocker.Size = UDim2.new(1, 0, 1, 0)
            blocker.Position = UDim2.new(0, 0, 0, 0)
            blocker.AutoButtonColor = false
            blocker.ZIndex = 9999
            blocker.Parent = frontFrame
            
            blocker.InputBegan:Connect(function(input)
                if State.hudEditorActive then return end
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
                
                local okWheel, emotesWheel = pcall(function()
                    return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel
                end)
                if not (okWheel and emotesWheel) then return end
                if not emotesWheel.Visible then return end

                local actualPos = Vector2.new(input.Position.X, input.Position.Y)
                local absPos = emotesWheel.AbsolutePosition
                local absSize = emotesWheel.AbsoluteSize

                local inXBounds = (actualPos.X >= absPos.X) and (actualPos.X <= absPos.X + absSize.X)
                local inYBounds = (actualPos.Y >= absPos.Y) and (actualPos.Y <= absPos.Y + absSize.Y)
                if not (inXBounds and inYBounds) then return end

                local center = absPos + (absSize / 2)
                local dx = actualPos.X - center.X
                local dy = actualPos.Y - center.Y

                local distance = math.sqrt(dx*dx + dy*dy)
                local radius = math.min(absSize.X, absSize.Y) * 0.5
                if distance > radius then return end
                local dynamicDeadzone = radius * 0.2
                if distance < dynamicDeadzone then return end

                local sectorAngle = 360 / 8
                local angle = math.deg(math.atan2(dy, dx))
                local correctedAngle = (angle + 90 + (sectorAngle / 2)) % 360
                local index = math.floor(correctedAngle / sectorAngle) + 1
                if not (State.customAnimationEditorActive or State.favoriteEnabled or State.currentMode == "animation" or (index == 1 and isRandomSlotActive())) then return end

                handleSectorAction(index)
            end)
        end
        blocker.Active = true
    else
        if blocker then blocker:Destroy() end
    end
end

function applyRandomSlotVisual(frontFrame)
    if not frontFrame then return end
    local slot = frontFrame:FindFirstChild("1")
    if slot and slot:IsA("ImageLabel") then
        if not isRandomSlotEnabled() then
            AnimationSystem.ResetRandomSlot(frontFrame)
            return
        end
        if slot.Image ~= RANDOM_SLOT_ICON then
            slot.Image = RANDOM_SLOT_ICON
        end
        if slot.ImageColor3 ~= RANDOM_SLOT_COLOR then
            slot.ImageColor3 = RANDOM_SLOT_COLOR
        end
        if State.currentMode == "emote" then
            updateRandomSlotBlocker(frontFrame, true)
        else
            updateRandomSlotBlocker(frontFrame, false)
        end
        local idValue = slot:FindFirstChild("AnimationID")
        if idValue then idValue:Destroy() end
        local favoriteIcon = slot:FindFirstChild("FavoriteIcon")
        if favoriteIcon then favoriteIcon:Destroy() end
    end
end

function resetRandomSlotColor(frontFrame)
    if not frontFrame then return end
    local slot = frontFrame:FindFirstChild("1")
    if slot and slot:IsA("ImageLabel") then
        if slot.ImageColor3 == RANDOM_SLOT_COLOR then
            slot.ImageColor3 = Color3.new(1, 1, 1)
        end
        if slot.Image == RANDOM_SLOT_ICON then
            slot.Image = ""
        end
    end
    updateRandomSlotBlocker(frontFrame, false)
    if State.randomSpamConn then
        State.randomSpamConn:Disconnect()
        State.randomSpamConn = nil
    end
end

function applySearchSlot1Image()
    pcall(function()
        local frontFrame = game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
        local slot1 = frontFrame and frontFrame:FindFirstChild("1")
        local slot2 = frontFrame and frontFrame:FindFirstChild("2")
        if slot1 and slot1:IsA("ImageLabel") and slot2 and slot2:IsA("ImageLabel") then
            local img2 = slot2.Image
            if img2 and img2 ~= "" then
                slot1.Image = img2
            end
        end
    end)
end

function bumpImageUpdateToken()
    State.imageUpdateToken = State.imageUpdateToken + 1
end

local ContentProvider = game:GetService("ContentProvider")
function preloadThumbnail(url)
    if not url or url == "" then return end
    task.spawn(function()
        pcall(function()
            ContentProvider:PreloadAsync({Instance.new("ImageLabel", {Image = url})})
        end)
    end)
end

function enforceImages()
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    if not success or not frontFrame then return end
    
    local token = State.imageUpdateToken
    for slotName, targetImg in pairs(State.targetImages) do
        local slot = frontFrame:FindFirstChild(slotName)
        if slot and slot:IsA("ImageLabel") then
            if slot.Image ~= targetImg then
                slot.Image = targetImg
            end
            if slotName == "1" and isRandomSlotActive() then
                if slot.ImageColor3 ~= RANDOM_SLOT_COLOR then
                    slot.ImageColor3 = RANDOM_SLOT_COLOR
                end
            end
        end
    end
end

function spamRandomSlotVisual(frontFrame, token)
    if not frontFrame then return end
    State.targetImages["1"] = RANDOM_SLOT_ICON
    enforceImages()
end

function spamAnimationImages(frontFrame, imageMap, token)
    if not frontFrame then return end
    for k, v in pairs(imageMap or {}) do
        State.targetImages[k] = v
    end
    enforceImages()
end


function getEmoteName(assetId)
    local success, productInfo = pcall(function()
        return game:GetService("MarketplaceService"):GetProductInfo(tonumber(assetId))
    end)
    
    if success and productInfo then
        return productInfo.Name
    else
        return "Emote_" .. tostring(assetId)
    end
end

isInFavorites = function(assetId)
    if not assetId then return false end
    if State.favoriteSetBuiltVersion ~= State.favoriteSetVersion then
        State.favoriteEmoteSet = {}
        for _, favorite in pairs(State.favoriteEmotes) do
            if favorite.id then
                State.favoriteEmoteSet[tostring(favorite.id)] = true
            end
        end
        State.favoriteAnimationSet = {}
        for _, favorite in pairs(State.favoriteAnimations) do
            if favorite.id then
                State.favoriteAnimationSet[tostring(favorite.id)] = true
            end
        end
        State.favoriteSetBuiltVersion = State.favoriteSetVersion
    end
    if State.currentMode == "animation" then
        return State.favoriteAnimationSet[tostring(assetId)] == true
    end
    return State.favoriteEmoteSet[tostring(assetId)] == true
end

function rebuildEmoteNormalCache()
    if State.emotePageCache.version == State.emoteCacheVersion and State.emotePageCache.favVersion == State.favoriteSetVersion then
        return
    end
    if State.favoriteSetBuiltVersion ~= State.favoriteSetVersion then
        State.favoriteEmoteSet = {}
        for _, favorite in pairs(State.favoriteEmotes) do
            State.favoriteEmoteSet[tostring(favorite.id)] = true
        end
        State.favoriteAnimationSet = {}
        for _, favorite in pairs(State.favoriteAnimations) do
            State.favoriteAnimationSet[tostring(favorite.id)] = true
        end
        State.favoriteSetBuiltVersion = State.favoriteSetVersion
    end
    local normal = {}
    for _, emote in ipairs(State.filteredEmotes) do
        if not State.favoriteEmoteSet[tostring(emote.id)] then
            table.insert(normal, emote)
        end
    end
    State.emotePageCache.normal = normal
    State.emotePageCache.version = State.emoteCacheVersion
    State.emotePageCache.favVersion = State.favoriteSetVersion
end

function rebuildAnimationNormalCache()
    if State.animationPageCache.version == State.animationCacheVersion and State.animationPageCache.favVersion == State.favoriteSetVersion then
        return
    end
    if State.favoriteSetBuiltVersion ~= State.favoriteSetVersion then
        State.favoriteEmoteSet = {}
        for _, favorite in pairs(State.favoriteEmotes) do
            State.favoriteEmoteSet[tostring(favorite.id)] = true
        end
        State.favoriteAnimationSet = {}
        for _, favorite in pairs(State.favoriteAnimations) do
            State.favoriteAnimationSet[tostring(favorite.id)] = true
        end
        State.favoriteSetBuiltVersion = State.favoriteSetVersion
    end
    local normal = {}
    for _, animation in ipairs(State.filteredAnimations) do
        if not State.favoriteAnimationSet[tostring(animation.id)] then
            table.insert(normal, animation)
        end
    end
    State.animationPageCache.normal = normal
    State.animationPageCache.version = State.animationCacheVersion
    State.animationPageCache.favVersion = State.favoriteSetVersion
end

function getCustomSetIcon(setName)
    local set = State.CustomAnimations and State.CustomAnimations.Sets and State.CustomAnimations.Sets[setName]
    local meta = set and set.__meta or {}
    local iconImage = meta.IconImage or DEFAULT_IDLE_ICON_ID
    local iconColor = TableToColor(meta.IconColor or ColorToTable(DEFAULT_IDLE_ICON_COLOR))
    return iconImage, iconColor
end

function IsCustomSetData(data)
    if not data then return false end
    if data.isCustomSet then return true end
    local idNum = tonumber(data.id)
    return idNum and idNum < 0 or false
end

function GetCustomSetName(data)
    if not data then return nil end
    local name = data.customSetName or data.name
    if type(name) == "string" then
        name = name:gsub("%s*%-.*$", "")
    end
    return name
end

function updateAnimationImages(currentPageAnimations, randomActive)
    local token = State.imageUpdateToken
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    
    if not success or not frontFrame then
        return
    end

    if randomActive then
        applyRandomSlotVisual(frontFrame)
        State.targetImages = {["1"] = RANDOM_SLOT_ICON}
        spamRandomSlotVisual(frontFrame, token)
    else
        State.targetImages = {}
        resetRandomSlotColor(frontFrame)
    end

    local startSlot = randomActive and 2 or 1
    local imageMap = {}
    local newTargetImages = {}
    if randomActive then
        newTargetImages["1"] = RANDOM_SLOT_ICON
    end

    for i = 1, 12 do
        if i >= startSlot then
            local listIndex = randomActive and (i - 1) or i
            local animationData = currentPageAnimations[listIndex]
            if animationData and animationData.id then
                local idStr = tostring(animationData.id)
                local image
                if IsCustomSetData(animationData) then
                    local customImage = getCustomSetIcon(GetCustomSetName(animationData) or animationData.name)
                    image = GetAsset(customImage)
                else
                    image = "rbxthumb://type=BundleThumbnail&id=" .. idStr .. "&w=420&h=420"
                end
                newTargetImages[tostring(i)] = image
                imageMap[tostring(i)] = image
            else
                newTargetImages[tostring(i)] = ""
                imageMap[tostring(i)] = ""
            end
        end
    end
    
    State.targetImages = newTargetImages

    for slotName, image in pairs(imageMap) do
        local child = frontFrame:FindFirstChild(slotName)
        if child and child:IsA("ImageLabel") then
            preloadThumbnail(image)
            child.Image = image
            
            local listIndex = randomActive and (tonumber(slotName) - 1) or tonumber(slotName)
            local animationData = currentPageAnimations[listIndex]
            if animationData and animationData.id then
                local idValue = child:FindFirstChild("AnimationID") or Instance.new("IntValue")
                idValue.Name = "AnimationID"
                idValue.Value = tonumber(animationData.id) or 0
                idValue.Parent = child
                
                if IsCustomSetData(animationData) then
                    local _, customColor = getCustomSetIcon(GetCustomSetName(animationData) or animationData.name)
                    child.ImageColor3 = customColor
                else
                    child.ImageColor3 = Color3.new(1, 1, 1)
                end
            elseif not randomActive and child.ImageColor3 == RANDOM_SLOT_COLOR then
                child.ImageColor3 = Color3.new(1, 1, 1)
            end
        end
    end
    
    applyEmotesButtonsActiveState()
end


function updateFavoriteIcon(imageLabel, assetId, isFavorite)
    local favoriteIcon = imageLabel:FindFirstChild("FavoriteIcon")
    
    if not favoriteIcon then
        favoriteIcon = Instance.new("ImageLabel")
        favoriteIcon.Name = "FavoriteIcon"
        favoriteIcon.Size = UDim2.new(0.3, 0, 0.3, 0) 
        favoriteIcon.Position = UDim2.new(0.7, 0, 0, 0)
        favoriteIcon.AnchorPoint = Vector2.new(0, 0)
        favoriteIcon.BackgroundTransparency = 1
        favoriteIcon.ZIndex = imageLabel.ZIndex + 5
        favoriteIcon.ScaleType = Enum.ScaleType.Fit
        favoriteIcon.Parent = imageLabel
    end
    
    if isFavorite then
        favoriteIcon.Image = State.favoriteIconId
    else
        favoriteIcon.Image = State.notFavoriteIconId 
    end
end

function updateAllFavoriteIcons()
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    
    if success and frontFrame then
        if not State.favoriteEnabled then
            for _, child in pairs(frontFrame:GetChildren()) do
                if child:IsA("ImageLabel") then
                    local favoriteIcon = child:FindFirstChild("FavoriteIcon")
                    if favoriteIcon then favoriteIcon:Destroy() end
                end
            end
            return
        end
        local randomActive = isRandomSlotActive()
        for _, child in pairs(frontFrame:GetChildren()) do
            if child:IsA("ImageLabel") and child.Image ~= "" and (not randomActive or child.Name ~= "1") then
                local assetId
                if State.currentMode == "animation" then
                    local idValue = child:FindFirstChild("AnimationID")
                    if idValue then
                        assetId = idValue.Value
                    end
                else
                    assetId = extractAssetId(child.Image)
                end
                
                if assetId then
                    local isFavorite = isInFavorites(assetId)
                    updateFavoriteIcon(child, assetId, isFavorite)
                end
            end
        end
        applyEmotesButtonsActiveState()
    end
end

function updateAnimations()
    local character, humanoid = getCharacterAndHumanoid()
    if not character or not humanoid then
        return
    end

    local humanoidDescription = humanoid.HumanoidDescription
    if not humanoidDescription then
        if not State.pendingAnimRetry then
            State.pendingAnimRetry = true
            task.delay(0.2, function()
                State.pendingAnimRetry = false
                if State.currentMode == "animation" then
                    updateAnimations()
                end
            end)
        end
        return
    end

    bumpImageUpdateToken()
    rebuildAnimationNormalCache()

    local currentPageAnimations = {}
    local animationTable = {}
    local equippedAnimations = {}

    local categories = getCategoryStats()
    local accumulatedPages = 0
    local currentCat = nil
    
    for _, cat in ipairs(categories) do
        if State.currentPage <= accumulatedPages + cat.pages then
            local adjustedPage = State.currentPage - accumulatedPages
            currentPageAnimations = getListSlice(cat.list, adjustedPage, cat.hasRandom)
            currentCat = cat
            break
        end
        accumulatedPages = accumulatedPages + cat.pages
    end

    local randomActive = isRandomSlotActive()
    if randomActive then
        local randomFallback = currentPageAnimations[1] or (State.filteredAnimations and State.filteredAnimations[1])
        if randomFallback then
            animationTable["Random Animation"] = {randomFallback.id}
            table.insert(equippedAnimations, "Random Animation")
        end
    end

    State.animImageRetry = 0
    for _, animation in pairs(currentPageAnimations) do
        local animationName = animation.name
        local animationId = animation.id
        animationTable[animationName] = {animationId}
        table.insert(equippedAnimations, animationName)
    end

    humanoidDescription:SetEmotes(animationTable)
    humanoidDescription:SetEquippedEmotes(equippedAnimations)
    
    updateAnimationImages(currentPageAnimations, randomActive)
    if State.favoriteEnabled then
        setEmotesButtonsActiveForFavorites()
    end

    task.delay(0.2, function()
        if State.favoriteEnabled then
            setEmotesButtonsActiveForFavorites()
        end
        if State.favoriteEnabled then
            updateAllFavoriteIcons()
        end
    end)
end

updateEmotes = function()
    local character, humanoid = getCharacterAndHumanoid()
    if not character or not humanoid then
        return
    end

    if State.currentMode == "animation" then
        updateAnimations()
        return
    end
    
    bumpImageUpdateToken()
    local token = State.imageUpdateToken
    
    if State.animImageSpamConn then
        State.animImageSpamConn:Disconnect()
        State.animImageSpamConn = nil
        State.animImageSpamMap = nil
        State.animImageSpamTicks = nil
        State.animImageSpamToken = State.animImageSpamToken + 1
    end

    local humanoidDescription = humanoid.HumanoidDescription
    if not humanoidDescription then
        return
    end

    local currentPageEmotes = {}
    local emoteTable = {}
    local equippedEmotes = {}

    rebuildEmoteNormalCache()
    local categories = getCategoryStats()
    local accumulatedPages = 0
    local currentCat = nil
    
    for _, cat in ipairs(categories) do
        if State.currentPage <= accumulatedPages + cat.pages then
            local adjustedPage = State.currentPage - accumulatedPages
            currentPageEmotes = getListSlice(cat.list, adjustedPage, cat.hasRandom)
            currentCat = cat
            break
        end
        accumulatedPages = accumulatedPages + cat.pages
    end

    local randomActive = isRandomSlotActive()
    if randomActive then
        local randomFallback = currentPageEmotes[1] or (State.filteredEmotes and State.filteredEmotes[1])
        if randomFallback then
            emoteTable["Random Emote"] = {randomFallback.id}
            table.insert(equippedEmotes, "Random Emote")
        end
    end

    for _, emote in pairs(currentPageEmotes) do
        local emoteName = emote.name
        local emoteId = emote.id
        emoteTable[emoteName] = {emoteId}
        table.insert(equippedEmotes, emoteName)
    end

    humanoidDescription:SetEmotes(emoteTable)
    humanoidDescription:SetEquippedEmotes(equippedEmotes)
    
    local newTargetImages = {}
    if randomActive then
        newTargetImages["1"] = RANDOM_SLOT_ICON
    end

    local startSlot = randomActive and 2 or 1
    for i = 1, 12 do
        if i >= startSlot then
            local listIndex = randomActive and (i - 1) or i
            local emoteData = currentPageEmotes[listIndex]
            if emoteData and emoteData.id then
                local idStr = tostring(emoteData.id)
                newTargetImages[tostring(i)] = "rbxthumb://type=Asset&id=" .. idStr .. "&w=420&h=420"
            else
                newTargetImages[tostring(i)] = ""
            end
        end
    end
    
    State.targetImages = newTargetImages

    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    
    if success and frontFrame then
        for slotName, image in pairs(newTargetImages) do
            local child = frontFrame:FindFirstChild(slotName)
            if child and child:IsA("ImageLabel") then
                child.Image = image
                if slotName == "1" and randomActive then
                    child.ImageColor3 = RANDOM_SLOT_COLOR
                else
                    child.ImageColor3 = Color3.new(1, 1, 1)
                end
            end
        end
        
        if State.favoriteEnabled then
            setEmotesButtonsActiveForFavorites()
        end
        if randomActive then
            applyRandomSlotVisual(frontFrame)
            spamRandomSlotVisual(frontFrame, token)
        else
            resetRandomSlotColor(frontFrame)
        end
    end

    task.delay(0.2, function()
        if State.favoriteEnabled then
            setEmotesButtonsActiveForFavorites()
        end
        if State.favoriteEnabled then
            updateAllFavoriteIcons()
        end
    end)
end

calculateTotalPages = function()
    rebuildEmoteNormalCache()
    rebuildAnimationNormalCache()

    local categories = getCategoryStats()
    local total = 0
    for _, cat in ipairs(categories) do
        total = total + cat.pages
    end
    return math.max(total, 1)
end

function isGivenAnimation(animationHolder, animationId)
    for _, animation in animationHolder:GetChildren() do
        if animation:IsA("Animation") and urlToId(animation.AnimationId) == animationId then
            return true
        end
    end
    return false
end

local function isToolAnimation(animationTrack)
    local animation = animationTrack and animationTrack.Animation
    if not animation then return false end
    local current = animation.Parent
    while current do
        if current:IsA("Tool") then
            return true
        end
        current = current.Parent
    end
    return false
end

local function findAnimationInDescendants(folder, animationId)
    if not folder then return false end
    for _, obj in ipairs(folder:GetDescendants()) do
        if obj:IsA("Animation") and urlToId(obj.AnimationId) == animationId then
            return true
        end
    end
    return false
end

local toolAnimationIds = {}

local function refreshToolAnimationIds()
    local newSet = {}
    local function addFrom(container)
        if not container then return end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") then
                for _, obj in ipairs(tool:GetDescendants()) do
                    if obj:IsA("Animation") then
                        local animId = urlToId(obj.AnimationId)
                        if animId ~= "" and animId ~= "0" then
                            newSet[animId] = true
                        end
                    end
                end
            end
        end
    end
    addFrom(player.Character)
    addFrom(player.Backpack)
    toolAnimationIds = newSet
end

function isDancing(character, animationTrack)
    if not character or not character.Animate or not animationTrack or not animationTrack.Animation then
        return false
    end
    if isToolAnimation(animationTrack) then
        return false
    end
    local animationId = urlToId(animationTrack.Animation.AnimationId)
    if toolAnimationIds[animationId] then
        return false
    end
    if findAnimationInDescendants(character.Animate:FindFirstChild("Tools"), animationId) then
        return false
    end
    for _, animationHolder in character.Animate:GetChildren() do
        if animationHolder:IsA("StringValue") then
            local sharesAnimationId = isGivenAnimation(animationHolder, animationId)
            if sharesAnimationId then
                return false
            end
        end
    end
    return true
end

function createGUIElements()
    local exists, emotesWheel = checkEmotesMenuExists()
    if not exists then
        return false
    end

    if UI.CustomFrames then
        for _, frame in pairs(UI.CustomFrames) do
            if frame and frame.Parent then frame:Destroy() end
        end
    end
    UI.CustomFrames = {}

    if emotesWheel:FindFirstChild("Under") then
        emotesWheel.Under:Destroy()
    end
    if emotesWheel:FindFirstChild("Top") then
        emotesWheel.Top:Destroy()
    end
    if emotesWheel:FindFirstChild("EmoteWalkButton") then
        emotesWheel.EmoteWalkButton:Destroy()
    end
    if emotesWheel:FindFirstChild("Favorite") then
        emotesWheel.Favorite:Destroy()
    end
    if emotesWheel:FindFirstChild("SpeedEmote") then
        emotesWheel.SpeedEmote:Destroy()
    end
    if emotesWheel:FindFirstChild("Changepage") then
        emotesWheel.Changepage:Destroy()
    end
    if emotesWheel:FindFirstChild("SpeedBox") then
        emotesWheel.SpeedBox:Destroy()
    end
    if emotesWheel:FindFirstChild("Reload") then
        emotesWheel.Reload:Destroy()
    end

    UI.Under = Instance.new("Frame")
    local UIListLayout = Instance.new("UIListLayout")
    UI._1left = Instance.new("ImageButton")
    UI._9right = Instance.new("ImageButton")
    UI._4pages = Instance.new("TextLabel")
    UI._3TextLabel = Instance.new("TextLabel")
    UI._2Routenumber = Instance.new("TextBox")
    UI.EmoteWalkButton = Instance.new("ImageButton")
    local UICorner_Left = Instance.new("UICorner")
    UICorner_Left.CornerRadius = UDim.new(0, 10)
    UICorner_Left.Parent = UI._1left
    
    local UICorner_Right = Instance.new("UICorner")
    UICorner_Right.CornerRadius = UDim.new(0, 10)
    UICorner_Right.Parent = UI._9right

    local UICorner1 = Instance.new("UICorner")
    UI.Top = Instance.new("Frame")
    local UIListLayout_2 = Instance.new("UIListLayout")
    local UICorner = Instance.new("UICorner")
    UI.Search = Instance.new("TextBox")
    UI.Favorite = Instance.new("ImageButton")
    local UICorner2 = Instance.new("UICorner")
    UI.SpeedBox = Instance.new("TextBox")
    local UICorner_4 = Instance.new("UICorner")
    UI.SpeedEmote = Instance.new("ImageButton")
    local UICorner_2 = Instance.new("UICorner")
    UI.Changepage = Instance.new("ImageButton")
    local UICorner_5 = Instance.new("UICorner")
    UI.Reload = Instance.new("ImageButton")
    local UICorner_6 = Instance.new("UICorner")

    UI.Under.Name = "Under"
    UI.Under.Parent = emotesWheel
    UI.Under.BackgroundTransparency = 1.000
    UI.Under.BorderSizePixel = 0
    UI.Under.Position = UDim2.new(0.129999995, 0, 1, 0)
    UI.Under.Size = UDim2.new(0.737500012, 0, 0.132499993, 0)

    UIListLayout.Parent = UI.Under
    UIListLayout.FillDirection = Enum.FillDirection.Horizontal
    UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Center

    UI._1left.Name = "1left"
    UI._1left.Parent = UI.Under
    UI._1left.BackgroundTransparency = 1.000
    UI._1left.BorderSizePixel = 0
    UI._1left.Size = UDim2.new(0.169491529, 0, 0.94339627, 0)
    UI._1left.Image = "rbxassetid://93111945058621"
    UI._1left.ImageColor3 = Color3.fromRGB(0, 0, 0)
    UI._1left.ImageTransparency = 0.400

    UI._9right.Name = "9right"
    UI._9right.Parent = UI.Under
    UI._9right.BackgroundTransparency = 1.000
    UI._9right.BorderSizePixel = 0
    UI._9right.Size = UDim2.new(0.169491529, 0, 0.94339627, 0)
    UI._9right.Image = "rbxassetid://107938916240738"
    UI._9right.ImageColor3 = Color3.fromRGB(0, 0, 0)
    UI._9right.ImageTransparency = 0.400

    UI._4pages.Name = "4pages"
    UI._4pages.Parent = UI.Under
    UI._4pages.BackgroundTransparency = 1.000
    UI._4pages.BorderSizePixel = 0
    UI._4pages.Size = UDim2.new(0.159322038, 0, 0.811320841, 0)
    UI._4pages.Font = Enum.Font.SourceSansBold
    UI._4pages.Text = "1"
    UI._4pages.TextColor3 = Color3.fromRGB(0, 0, 0)
    UI._4pages.TextScaled = true
    UI._4pages.TextSize = 14.000
    UI._4pages.TextTransparency = 0.400
    UI._4pages.TextWrapped = true

    UI._3TextLabel.Name = "3TextLabel"
    UI._3TextLabel.Parent = UI.Under
    UI._3TextLabel.BackgroundTransparency = 1.000
    UI._3TextLabel.BorderSizePixel = 0
    UI._3TextLabel.Size = UDim2.new(0.338983059, 0, 0.94339627, 0)
    UI._3TextLabel.Font = Enum.Font.SourceSansBold
    UI._3TextLabel.Text = " ------ "
    UI._3TextLabel.TextColor3 = Color3.fromRGB(0, 0, 0)
    UI._3TextLabel.TextScaled = true
    UI._3TextLabel.TextSize = 14.000
    UI._3TextLabel.TextTransparency = 0.400
    UI._3TextLabel.TextWrapped = true

    UI._2Routenumber.Name = "2Route-number"
    UI._2Routenumber.Parent = UI.Under
    UI._2Routenumber.Active = true
    UI._2Routenumber.BackgroundTransparency = 1.000
    UI._2Routenumber.BorderSizePixel = 0
    UI._2Routenumber.Size = UDim2.new(0.159322038, 0, 0.811320841, 0)
    UI._2Routenumber.Font = Enum.Font.SourceSansBold
    UI._2Routenumber.PlaceholderColor3 = Color3.fromRGB(0, 0, 0)
    UI._2Routenumber.Text = "1"
    UI._2Routenumber.TextColor3 = Color3.fromRGB(0, 0, 0)
    UI._2Routenumber.TextScaled = true
    UI._2Routenumber.TextSize = 14.000
    UI._2Routenumber.TextTransparency = 0.400
    UI._2Routenumber.TextWrapped = true

    UI.Top.Name = "Top"
    UI.Top.Parent = emotesWheel
    UI.Top.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.Top.BackgroundTransparency = 0.400
    UI.Top.BorderSizePixel = 0
    UI.Top.Position = UDim2.new(0.127499998, 0, -0.109999999, 0)
    UI.Top.Size = UDim2.new(0.737500012, 0, 0.0949999914, 0)

    UIListLayout_2.Parent = UI.Top
    UIListLayout_2.FillDirection = Enum.FillDirection.Horizontal
    UIListLayout_2.HorizontalAlignment = Enum.HorizontalAlignment.Center
    UIListLayout_2.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout_2.VerticalAlignment = Enum.VerticalAlignment.Center

    UICorner.CornerRadius = UDim.new(0, 20)
    UICorner.Parent = UI.Top

    UI.Search.Name = "Search"
    UI.Search.Parent = UI.Top
    UI.Search.BackgroundTransparency = 1.000
    UI.Search.Size = UDim2.new(0.864406765, 0, 0.81578958, 0)
    UI.Search.Font = Enum.Font.SourceSansBold
    UI.Search.PlaceholderText = "Search/ID"
    UI.Search.Text = ""
    UI.Search.TextColor3 = Color3.fromRGB(255, 255, 255)
    UI.Search.TextScaled = true
    UI.Search.TextSize = 14.000
    UI.Search.TextWrapped = true

    UI.EmoteWalkButton.Name = "EmoteWalkButton"
    UI.EmoteWalkButton.Parent = emotesWheel
    UI.EmoteWalkButton.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.EmoteWalkButton.BackgroundTransparency = 0.400
    UI.EmoteWalkButton.BorderSizePixel = 0
    UI.EmoteWalkButton.Position = UDim2.new(0.889999986, 0, -0.107500002, 0)
    UI.EmoteWalkButton.Size = UDim2.new(0.0874999985, 0, 0.0874999985, 0)
    UI.EmoteWalkButton.Image = State.defaultButtonImage

    UICorner1.CornerRadius = UDim.new(0, 10)
    UICorner1.Parent = UI.EmoteWalkButton

    UI.Favorite.Name = "Favorite"
    UI.Favorite.Parent = emotesWheel
    UI.Favorite.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.Favorite.BackgroundTransparency = 0.400
    UI.Favorite.BorderSizePixel = 0
    UI.Favorite.Position = UDim2.new(0.0189999994, 0, -0.108000003, 0)
    UI.Favorite.Size = UDim2.new(0.0874999985, 0, 0.0874999985, 0)
    UI.Favorite.Image = "rbxassetid://124025954365505"

    UICorner2.CornerRadius = UDim.new(0, 10)
    UICorner2.Parent = UI.Favorite

    UI.SpeedBox.Name = "SpeedBox"
    UI.SpeedBox.Parent = emotesWheel
    UI.SpeedBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.SpeedBox.BackgroundTransparency = 0.400
    UI.SpeedBox.BorderSizePixel = 0
    UI.SpeedBox.Position = UDim2.new(0.0189999398, 0, -0.000499992399, 0)
    UI.SpeedBox.Size = UDim2.new(0.0874999985, 0, 0.0874999985, 0)
    UI.SpeedBox.Visible = false
    UI.SpeedBox.Font = Enum.Font.SourceSansBold
    UI.SpeedBox.PlaceholderColor3 = Color3.fromRGB(178, 178, 178)
    UI.SpeedBox.Text = "1"
    UI.SpeedBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    UI.SpeedBox.TextScaled = true
    UI.SpeedBox.TextWrapped = true
    UI.SpeedBox:GetPropertyChangedSignal("Text"):Connect(function()
       UI.SpeedBox.Text = UI.SpeedBox.Text:gsub("[^%d.]", "")
    end)
    UI.SpeedBox.ZIndex = 2

    UICorner_4.CornerRadius = UDim.new(0, 10)
    UICorner_4.Parent = UI.SpeedBox

    UI.SpeedEmote.Name = "SpeedEmote"
    UI.SpeedEmote.Parent = emotesWheel
    UI.SpeedEmote.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.SpeedEmote.BackgroundTransparency = 0.400
    UI.SpeedEmote.BorderSizePixel = 0
    UI.SpeedEmote.Position = UDim2.new(0.888999999, 0, -0, 0)
    UI.SpeedEmote.Size = UDim2.new(0.0874999985, 0, 0.0874999985, 0)
    UI.SpeedEmote.Image = "rbxassetid://116056570415896"
    UI.SpeedEmote.ZIndex = 2

    UICorner_2.CornerRadius = UDim.new(0, 10)
    UICorner_2.Parent = UI.SpeedEmote

UI.Changepage.Name = "Changepage"
UI.Changepage.Parent = emotesWheel
UI.Changepage.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
UI.Changepage.BackgroundTransparency = 0.400
UI.Changepage.BorderColor3 = Color3.fromRGB(0, 0, 0)
UI.Changepage.BorderSizePixel = 0
UI.Changepage.Position = UDim2.new(0.019, 0,1.021, 0)
UI.Changepage.Size = UDim2.new(0.087, 0,0.087, 0)
UI.Changepage.ZIndex = 3
UI.Changepage.Image = "rbxassetid://13285615740"

UICorner_5.CornerRadius = UDim.new(0, 10)
UICorner_5.Parent = UI.Changepage

    UI.Reload.Name = "Reload"
    UI.Reload.Parent = emotesWheel
    UI.Reload.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    UI.Reload.BackgroundTransparency = 0.400
    UI.Reload.BorderSizePixel = 0
    UI.Reload.Position = UDim2.new(0.888999999, 0, 1.02100003, 0)
    UI.Reload.Size = UDim2.new(0.0869999975, 0, 0.0869999975, 0)
    UI.Reload.ZIndex = 3
    UI.Reload.Image = "rbxassetid://127493377027615"

    UICorner_6.CornerRadius = UDim.new(0, 10)
    UICorner_6.Parent = UI.Reload

    local function spawnCustomFrame(name, zIndex)
        local cf = Instance.new("Frame")
        cf.Name = name
        cf.Parent = emotesWheel
        cf.BackgroundColor3 = Color3.fromRGB(0,0,0)
        cf.BackgroundTransparency = 0.4
        cf.ZIndex = zIndex or 3
        cf.BorderSizePixel = 0
        cf.Active = true
        
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = cf

        if not UI.CustomFrames then UI.CustomFrames = {} end
        UI.CustomFrames[name] = cf

        return cf
    end

    local function recordDefaults()
        local allMovable = getMovableElements()
        for name, el in pairs(allMovable) do
             HUD.DefaultPositions[name] = el.Position
             HUD.DefaultSizes[name] = el.Size
             if el:IsA("TextLabel") or el:IsA("TextBox") then
                 HUD.DefaultTexts[name] = el.Text
                 if el:IsA("TextBox") then
                     HUD.DefaultPlaceholders[name] = el.PlaceholderText
                 end
             end
        end
    end
    
    if Config.CustomFrames then
        for name, data in pairs(Config.CustomFrames) do
            spawnCustomFrame(name, data.ZIndex or 3)
        end
    end
    
    recordDefaults()
    loadSpeedEmoteConfig()

    connectEvents()
    State.isGUICreated = true
    
    ApplyTheme(themes[currentThemeName] or themes.Default)
    
    updateGUIColors()
    
    ApplyUIVisibility()
    
    if ApplyFreezeButtonVisual then ApplyFreezeButtonVisual() end
    if applySavedPositions then applySavedPositions() end
    if updateHUDLayouts then updateHUDLayouts() end
    
    return true
end

updatePageDisplay = function()
    if UI._4pages and UI._2Routenumber then
        UI._4pages.Text = tostring(State.totalPages)
        UI._2Routenumber.Text = tostring(State.currentPage)
    end
end


toggleFavorite = function(emoteId, emoteName)
    local found = false
    local index = 0

    for i, fav in pairs(State.favoriteEmotes) do
        if tostring(fav.id) == tostring(emoteId) then
            found = true
            index = i
            break
        end
    end

    if found then
        table.remove(State.favoriteEmotes, index)
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = '🗑️ Removed "' .. emoteName .. '" from favorites',
            Duration = 3
        })
    else
        table.insert(State.favoriteEmotes, {
            id = emoteId,
            name = emoteName .. " - ⭐"
        })
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = '✅ Added "' .. emoteName .. '" to favorites',
            Duration = 3
        })
    end

    State.EmotePages.Sets[State.currentEmotePageName] = DeepCopy(State.favoriteEmotes)
    State.SaveEmotePages(State.EmotePages)

    State.favoriteSetVersion = State.favoriteSetVersion + 1
    State.totalPages = calculateTotalPages()
    updatePageDisplay()
    updateEmotes()
    updateAllFavoriteIcons()
end


toggleFavoriteAnimation = function(animationData)
    local found = false
    local index = 0

    for i, fav in pairs(State.favoriteAnimations) do
        if fav.id == animationData.id then
            found = true
            index = i
            break
        end
    end

    if found then
        table.remove(State.favoriteAnimations, index)
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = '🗑️ Removed "' .. animationData.name .. '" from favorites',
            Duration = 3
        })
    else
        table.insert(State.favoriteAnimations, {
            id = animationData.id,
            name = animationData.name .. " - ⭐",
            bundledItems = animationData.bundledItems,
            isCustomSet = IsCustomSetData(animationData),
            customSetName = IsCustomSetData(animationData) and (type(animationData.name) == "string" and animationData.name:gsub("%s*%-.*$", "") or animationData.name) or nil
        })
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = '✅ Added "' .. animationData.name .. '" to favorites',
            Duration = 3
        })
    end

    State.favoriteSetVersion = State.favoriteSetVersion + 1
    
    pcall(function()
        if not isfolder("7yd7") then makefolder("7yd7") end
        writefile(State.favoriteAnimationsFileName, HttpService:JSONEncode(State.favoriteAnimations))
    end)

    State.totalPages = calculateTotalPages()
    updatePageDisplay()
    updateAnimations()
    updateAllFavoriteIcons()
end



function setupEmoteClickDetection()
    if State.isMonitoringClicks then
        return
    end
    
    State.emoteMonitorToken = State.emoteMonitorToken + 1
    local token = State.emoteMonitorToken

    local function monitorEmotes()
        while State.favoriteEnabled and State.currentMode == "emote" and State.emoteMonitorToken == token do
            local success, frontFrame = pcall(function()
                return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
            end)

            if success and frontFrame then
                for _, connection in pairs(State.emoteClickConnections) do
                    if connection then
                        connection:Disconnect()
                    end
                end
                State.emoteClickConnections = {}

                local randomActive = isRandomSlotActive()
                for _, child in pairs(frontFrame:GetChildren()) do
                    if child:IsA("ImageLabel") and child.Image ~= "" and (not randomActive or child.Name ~= "1") then
                        local imageUrl = child.Image
                        local assetId = extractAssetId(imageUrl)
                        if assetId then
                            local isFavorite = isInFavorites(assetId)
                            updateFavoriteIcon(child, assetId, isFavorite)
                        end
                    end
                end

                applyEmotesButtonsActiveState()
            end

            task.wait(0.1)
        end
    end

    if State.favoriteEnabled then
        State.isMonitoringClicks = true
        task.spawn(monitorEmotes)
    end
end

applyAnimation = function(animationData)
    local player = game.Players.LocalPlayer
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoid = character:FindFirstChild("Humanoid")
    local animate = character:FindFirstChild("Animate")
    
    if not animate or not humanoid then
        getgenv().Notify({
            Title = '7yd7 | Animation Error',
            Content = '❌ Animate or Humanoid not found',
            Duration = 3
        })
        return
    end
    
    local bundleId = animationData.id
    local bundledItems = animationData.bundledItems

    getgenv().lastPlayedAnimation = animationData
    Config.LastPlayedAnimationData = animationData
    task.spawn(SaveConfig)
    
        if not bundledItems and not animationData.isCustomSet then
        getgenv().Notify({
            Title = '7yd7 | Animation Error', 
            Content = '??? No bundled items found',
            Duration = 3
        })
        return
    end
    
    if animationData.isCustomSet and not bundledItems then
        bundledItems = {"Custom-Animation"}
    end
    
    for _, track in pairs(humanoid:GetPlayingAnimationTracks()) do
        track:Stop()
    end
    
    local cacheKey = tostring(bundleId)
    local mappings = State.AnimationCache[cacheKey]
    
    if mappings and #mappings > 0 and mappings._version ~= 2 then
        mappings = nil
    end
    
        if animationData.isCustomSet then
            mappings = buildCustomSetMappings(GetCustomSetName(animationData) or animationData.name)
            if #mappings > 0 then
                mappings._version = 2
                State.AnimationCache[cacheKey] = mappings
                task.spawn(saveAnimationCache)
            end
    elseif not mappings then
        mappings = resolveAnimationMappings(bundledItems)
        if #mappings > 0 then
            mappings._version = 2
            State.AnimationCache[cacheKey] = mappings
            task.spawn(saveAnimationCache)
        end
    end
    
    if #mappings == 0 then return end
    
    local sorted = {}
    for _, m in ipairs(mappings) do
        if m.category:lower() == "idle" then
            table.insert(sorted, 1, m)
        else
            table.insert(sorted, m)
        end
    end
    
    local function applyAnimationToObject(animObj, animId, weights)
        if not animObj or not animObj:IsA("Animation") then return end

        animObj.AnimationId = animId

        if weights ~= nil then
            for _, child in ipairs(animObj:GetChildren()) do
                if child:IsA("NumberValue") and child.Name == "Weight" then
                    child:Destroy()
                end
            end
            for _, wVal in ipairs(weights) do
                local w = Instance.new("NumberValue")
                w.Name = "Weight"
                w.Value = wVal
                w.Parent = animObj
            end
        end
    end

    local mappingMap = {}
    for _, m in ipairs(sorted) do
        local cat = m.category:lower()
        if not mappingMap[cat] then
            mappingMap[cat] = { folderName = m.category, items = {} }
        end
        mappingMap[cat].items[m.name:lower()] = m
    end

    for cat, data in pairs(mappingMap) do
        local categoryFolder = animate:FindFirstChild(data.folderName)
        if not categoryFolder then
            continue
        end

        local items = data.items

        local sourceByName = {}
        for name, m in pairs(items) do
            sourceByName[name] = m
        end

        for _, animObj in ipairs(categoryFolder:GetChildren()) do
            if animObj:IsA("Animation") then
                local lowerName = animObj.Name:lower()
                local m = sourceByName[lowerName]
                if m then
                    sourceByName[lowerName] = nil
                    applyAnimationToObject(animObj, m.animationId, m.weights)
                    if animObj.Name ~= m.name then
                        animObj.Name = m.name
                    end
                else
                    animObj:Destroy()
                end
            end
        end

        for name, m in pairs(sourceByName) do
            local animObj = Instance.new("Animation")
            animObj.Name = m.name
            applyAnimationToObject(animObj, m.animationId, m.weights)
            animObj.Parent = categoryFolder
        end
    end
    
    if humanoid.MoveDirection.Magnitude == 0 then
        animate.Disabled = true
        animate.Disabled = false
    end
end

function playAnimationPreview(animationData)
    local _, humanoid = getCharacterAndHumanoid()
    if not humanoid then return false end
    local animator = humanoid:FindFirstChild("Animator")
    if not animator then return false end

    local bundledItems = animationData and animationData.bundledItems
    if not bundledItems then return false end
    
    local bundleId = animationData.id
    local cacheKey = tostring(bundleId)
    local mappings = State.AnimationCache[cacheKey]
    
    if not mappings then
        mappings = resolveAnimationMappings(bundledItems)
        if #mappings > 0 then
            State.AnimationCache[cacheKey] = mappings
            task.spawn(saveAnimationCache)
        end
    end
    
    if #mappings == 0 then return false end
    
    local m = mappings[1]
    local animation = Instance.new("Animation")
    animation.AnimationId = m.animationId
    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    if ok and track then
        track.Priority = Enum.AnimationPriority.Action
        track.Looped = true
        if State.speedEmoteEnabled or State.emotesWalkEnabled then
            track:Play()
        end
        State.currentEmoteTrack = track
        if State.speedEmoteEnabled then
            local speedVal = tonumber(UI.SpeedBox.Text) or Config.EmoteSpeed or 1
            track:AdjustSpeed(speedVal)
        end
        return true
    end

    return false
end

handleSectorAction = function(index)
    if tick() - State.lastActionTick < 0.25 then return end
    State.lastActionTick = tick()

    if State.customAnimationEditorActive and (not State.customAnimationEditingKey or not State.customAnimationEditingName or not (State.CustomAnimOverlay and State.CustomAnimOverlay.Parent)) then
        if State.exitCustomAnimationEditor then
            State.exitCustomAnimationEditor()
        else
            State.customAnimationEditorActive = false
        end
    end

    local randomActive = isRandomSlotActive()
    if index == 1 and randomActive then
        local itemData = pickRandomItemForMode()
        if not itemData then
            getgenv().Notify({
                Title = '7yd7 | Random',
                Content = '? No valid random item found',
                Duration = 3
            })
            return
        end
        State.lastRadialActionTime = tick()

        if State.customAnimationEditorActive then
            local animIdToSave = itemData.id
            local cat = State.customAnimationEditingKey
            local name = State.customAnimationEditingName
            if State.CustomAnimations.Sets[State.currentCustomAnimationName] and cat and name then
                if State.currentMode == "emote" or (State.currentMode == "animation" and not itemData.bundledItems) then
                    local resolved = resolveEmoteToAnimationId(itemData.id)
                    if resolved then animIdToSave = resolved end
                end
                if not State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] then
                    State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] = {}
                end
                State.CustomAnimations.Sets[State.currentCustomAnimationName][cat][name] = animIdToSave
                State.SaveCustomAnimations(State.CustomAnimations)
                getgenv().Notify({ Title = "7yd7 | Saved", Content = "✅ Saved " .. name, Duration = 3 })
                if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
                if refreshCustomAnimationState then refreshCustomAnimationState(true) end
                State.exitCustomAnimationEditor()
            end
            return
        end

        if State.favoriteEnabled then
            if State.currentMode == "animation" then
                if not isInFavorites(itemData.id) then
                    toggleFavoriteAnimation(itemData)
                end
            else
                if not isInFavorites(itemData.id) then
                    toggleFavorite(itemData.id, itemData.name)
                end
            end
            return
        end

        if State.currentMode == "animation" then
            if stopCurrentEmote then stopCurrentEmote() end
            applyAnimation(itemData)
            State.lastRandomAnimationId = itemData.id
            if not State.favoriteEnabled then
                pcall(function()
                    game:GetService("GuiService"):SetEmotesMenuOpen(false)
                end)
                pcall(function()
                    game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false
                end)
            end
        else
            local _, hum = getCharacterAndHumanoid()
            if hum then
                pcall(function()
                    game:GetService("GuiService"):SetEmotesMenuOpen(false)
                end)
                pcall(function()
                    game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false
                end)
                playRandomEmote(hum, itemData.id)
                State.lastRandomEmoteId = itemData.id
            end
        end
        return
    end

    if State.currentMode == "animation" then
        rebuildAnimationNormalCache()
    else
        rebuildEmoteNormalCache()
    end

    local function getEmoteAtIndex(idx)
        local categories = getCategoryStats()
        local accumulatedPages = 0
        
        for _, cat in ipairs(categories) do
            if State.currentPage <= accumulatedPages + cat.pages then
                local adjustedPage = State.currentPage - accumulatedPages
                local pageItems = getListSlice(cat.list, adjustedPage, cat.hasRandom)
                return pageItems[idx]
            end
            accumulatedPages = accumulatedPages + cat.pages
        end
        return nil
    end

    local slotOffset = randomActive and 1 or 0
    local itemData = getEmoteAtIndex(index - slotOffset)
    if not itemData then return end

    State.lastRadialActionTime = tick()

    if State.customAnimationEditorActive then
        local animIdToSave = itemData.id
        local cat = State.customAnimationEditingKey
        local name = State.customAnimationEditingName

        if State.currentMode == "emote" or (State.currentMode == "animation" and not itemData.bundledItems) then
            local resolved = resolveEmoteToAnimationId(itemData.id)
            if resolved then animIdToSave = resolved end
        end

        if State.currentMode == "animation" and itemData.bundledItems then
            local resolved = resolveAnimationMappings(itemData.bundledItems)
            if resolved and #resolved > 0 then
                local match
                for _, m in ipairs(resolved) do
                    if m.category:lower() == cat:lower() and m.name:lower() == name:lower() then
                        match = m
                        break
                    end
                end
                if not match then
                    for _, m in ipairs(resolved) do
                        if m.category:lower() == cat:lower() then
                            match = m
                            break
                        end
                    end
                end
                if match then
                    local extractedId = tonumber(urlToId(match.animationId))
                    if extractedId then
                        animIdToSave = extractedId
                    end
                end
                
                if animIdToSave == itemData.id and resolved[1] then
                    animIdToSave = tonumber(urlToId(resolved[1].animationId)) or itemData.id
                end
            end
        end

        if State.CustomAnimations.Sets[State.currentCustomAnimationName] and cat and name then
            if not State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] then
                State.CustomAnimations.Sets[State.currentCustomAnimationName][cat] = {}
            end
            State.CustomAnimations.Sets[State.currentCustomAnimationName][cat][name] = animIdToSave
            State.SaveCustomAnimations(State.CustomAnimations)
            getgenv().Notify({ Title = "7yd7 | Saved", Content = "✅ Saved " .. name, Duration = 3 })
            
            if State.RefreshCustomAnimUI then State.RefreshCustomAnimUI() end
            if refreshCustomAnimationState then refreshCustomAnimationState(true) end
            State.exitCustomAnimationEditor()
        end
        return
    end

    if State.favoriteEnabled then
        if State.currentMode == "animation" then
            toggleFavoriteAnimation(itemData)
        else
            toggleFavorite(itemData.id, itemData.name)
        end
    else
        if State.currentMode == "animation" then
            applyAnimation(itemData)
            pcall(function()
                game:GetService("GuiService"):SetEmotesMenuOpen(false)
            end)
            pcall(function()
                game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false
            end)
        else
            local _, hum = getCharacterAndHumanoid()
            if hum then
                if playRandomEmote then
                    playRandomEmote(hum, itemData.id)
                elseif playEmote then
                    playEmote(hum, itemData.id)
                end
            end
        end
    end

end

function clearAnimationSlotImages()
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    if not success or not frontFrame then
        return
    end

    for i = 1, State.itemsPerPage do
        local child = frontFrame:FindFirstChild(tostring(i))
        if child and child:IsA("ImageLabel") then
            local idValue = child:FindFirstChild("AnimationID")
            if idValue then
                idValue:Destroy()
            end
            if child.Image and child.Image:find("rbxthumb://type=BundleThumbnail") then
                child.Image = ""
            end
        end
    end
end


function monitorAnimations(token)
    while State.currentMode == "animation" and State.animationMonitorToken == token do
        local success, frontFrame = pcall(function()
            return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
        end)
        
        if success and frontFrame then
            for _, connection in pairs(State.emoteClickConnections) do
                if connection then
                    connection:Disconnect()
                end
            end
            State.emoteClickConnections = {}
            
            local favoritesToUse = _G.filteredFavoritesAnimationsForDisplay or State.favoriteAnimations
            local hasFavorites = #favoritesToUse > 0
            local favoritePagesCount = hasFavorites and calcPagesForList(#favoritesToUse, true) or 0
            local isInFavoritesPages = State.currentPage <= favoritePagesCount
            
            local currentPageAnimations = {}
            
            if isInFavoritesPages and hasFavorites then
                currentPageAnimations = getListSlice(favoritesToUse, State.currentPage, true)
            else
                local normalAnimations = {}
                for _, animation in pairs(State.filteredAnimations) do
                    if not isInFavorites(animation.id) then
                        table.insert(normalAnimations, animation)
                    end
                end
                
                local adjustedPage = State.currentPage - favoritePagesCount
                local isFirstNormalList = (favoritePagesCount == 0)
                currentPageAnimations = getListSlice(normalAnimations, adjustedPage, isFirstNormalList)
            end
            
            local randomActive = isRandomSlotActive()
            local buttonIndex = 1
            for _, child in pairs(frontFrame:GetChildren()) do
                if child:IsA("ImageLabel") and (not randomActive or child.Name ~= "1") then
                    if buttonIndex <= #currentPageAnimations then
                        local animationData = currentPageAnimations[buttonIndex]
                        
                        if State.favoriteEnabled then
                            local isFavorite = isInFavorites(animationData.id)
                            updateFavoriteIcon(child, animationData.id, isFavorite)
                        else
                            local favoriteIcon = child:FindFirstChild("FavoriteIcon")
                            if favoriteIcon then
                                favoriteIcon:Destroy()
                            end
                        end
                        buttonIndex = buttonIndex + 1
                    else
                        local favoriteIcon = child:FindFirstChild("FavoriteIcon")
                        if favoriteIcon then
                            favoriteIcon:Destroy()
                        end
                    end
                end
            end

        end
        
        task.wait(0.1)
    end
end

function stopEmoteClickDetection()
    State.isMonitoringClicks = false
    State.emoteMonitorToken = State.emoteMonitorToken + 1
    State.animationMonitorToken = State.animationMonitorToken + 1
    
    for _, connection in pairs(State.emoteClickConnections) do
        if connection then
            connection:Disconnect()
        end
    end
    State.emoteClickConnections = {}
    
    local success, frontFrame = pcall(function()
        return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
    end)
    
    if success and frontFrame then
        for _, child in pairs(frontFrame:GetChildren()) do
            if child:IsA("ImageLabel") then
                local clickDetector = child:FindFirstChild("ClickDetector")
                if clickDetector then
                    clickDetector:Destroy()
                end
                
                local favoriteIcon = child:FindFirstChild("FavoriteIcon")
                if favoriteIcon then
                    favoriteIcon:Destroy()
                end
            end
        end
        applyEmotesButtonsActiveState()
    end
end


function fetchAllEmotes()
    if State.isLoading then
        return
    end
    State.isLoading = true

    local function applyData(data, total)
        State.emotesData = data
        State.totalEmotesLoaded = total
        State.originalEmotesData = State.emotesData
        State.filteredEmotes = State.emotesData
        State.emoteCacheVersion = State.emoteCacheVersion + 1
        State.totalPages = calculateTotalPages()
        State.currentPage = 1
        updatePageDisplay()
        updateEmotes()
        State.isLoading = false
    end

    local function fetchFromUrl()
        local success, result = pcall(function()
            local jsonContent = game:HttpGet("https://raw.githubusercontent.com/7yd7/sniper-Emote/refs/heads/test/EmoteSniper.json")
            if jsonContent and jsonContent ~= "" then
                local data = HttpService:JSONDecode(jsonContent)
                return data.data or {}
            else
                return nil
            end
        end)

        if success and result then
            local emoteData = {}
            local total = 0
            for _, item in pairs(result) do
                local id = tonumber(item.id)
                if id and id > 0 then
                    table.insert(emoteData, {id = id, name = item.name or ("Emote_" .. id)})
                    total = total + 1
                end
            end
            if #emoteData > 0 then
                pcall(function()
                    if not isfolder("7yd7") then makefolder("7yd7") end
                    writefile(State.EmoteDataCachePath, HttpService:JSONEncode(emoteData))
                end)
                return emoteData, total
            end
        end
        return nil, nil
    end

    local cacheData = nil
    pcall(function()
        if isfile and isfile(State.EmoteDataCachePath) then
            local json = readfile(State.EmoteDataCachePath)
            local decoded = HttpService:JSONDecode(json)
            if type(decoded) == "table" and #decoded > 0 then
                cacheData = decoded
            end
        end
    end)

    if cacheData then
        applyData(cacheData, #cacheData)
    else
        State.emotesData = {{id = 3360686498, name = "Stadium"},{id = 3360692915, name = "Tilt"},{id = 3576968026, name = "Shrug"},{id = 3360689775, name = "Salute"}}
        State.totalEmotesLoaded = #State.emotesData
        State.originalEmotesData = State.emotesData
        State.filteredEmotes = State.emotesData
        State.emoteCacheVersion = State.emoteCacheVersion + 1
        State.totalPages = calculateTotalPages()
        State.currentPage = 1
        updatePageDisplay()
        updateEmotes()
        State.isLoading = false
    end

    task.spawn(function()
        while true do
            local emoteData, total = fetchFromUrl()
            if emoteData then
                applyData(emoteData, total)
                getgenv().Notify({Title = '7yd7 | Emote', Content = "📦 Emotes loaded", Duration = 3})
                return
            end
            task.wait(3)
        end
    end)
end

function fetchAllAnimations()
    if State.isLoading then
        return
    end
    State.isLoading = true
    State.animationsData = {}

    local function processCustomSets()
        if State.CustomAnimations and State.CustomAnimations.Order then
            for idx, customSetName in ipairs(State.CustomAnimations.Order) do
                if customSetName ~= "Default" and State.CustomAnimations.Sets[customSetName] then
                    local fakeId = -1000 - idx
                    local customSetData = State.CustomAnimations.Sets[customSetName]
                    local mappings = {}
                    for cat, anims in pairs(customSetData) do
                        if cat ~= "__meta" then
                            for name, id in pairs(anims) do
                                if tostring(id) ~= "0" then
                                    table.insert(mappings, {category = cat, name = name, animationId = "rbxassetid://" .. id})
                                end
                            end
                        end
                    end
                    mappings._version = 2
                    State.AnimationCache[tostring(fakeId)] = mappings

                    local customAnimationData = {
                        id = fakeId,
                        name = customSetName,
                        bundledItems = {"Custom-Animation"},
                        isCustomSet = true
                    }
                    table.insert(State.animationsData, 1, customAnimationData)
                end
            end
        end
    end

    local function finalize()
        State.originalAnimationsData = State.animationsData
        State.filteredAnimations = State.animationsData
        State.animationCacheVersion = State.animationCacheVersion + 1
        State.isLoading = false
    end

    processCustomSets()
    finalize()

    task.spawn(function()
        local success, result = pcall(function()
            local jsonContent = game:HttpGet("https://raw.githubusercontent.com/7yd7/sniper-Emote/refs/heads/test/AnimationSniper.json")
            if jsonContent and jsonContent ~= "" then
                local data = HttpService:JSONDecode(jsonContent)
                return data.data or {}
            end
            return nil
        end)

        local offsaleSuccess, offsaleResult
        if offsaleAnimationJson then
            offsaleSuccess, offsaleResult = pcall(function()
                local jsonContent = game:HttpGet("https://raw.githubusercontent.com/7yd7/sniper-Emote/refs/heads/test/AnimationSniperoffsale.json")
                if jsonContent and jsonContent ~= "" then
                    local data = HttpService:JSONDecode(jsonContent)
                    return data.data or {}
                end
                return nil
            end)
        end

        if success or offsaleSuccess then
            local animationsData = {}
            local seenIds = {}

            if success and result then
                for _, item in pairs(result) do
                    local id = tonumber(item.id)
                    if id and id > 0 then
                        seenIds[id] = true
                        table.insert(animationsData, {
                            id = id,
                            name = item.name or ("Animation_" .. id),
                            bundledItems = item.bundledItems
                        })
                    end
                end
            end

            if offsaleSuccess and offsaleResult then
                for _, item in pairs(offsaleResult) do
                    local id = tonumber(item.id)
                    if id and id > 0 and not seenIds[id] then
                        seenIds[id] = true
                        table.insert(animationsData, {
                            id = id,
                            name = item.name or ("Animation_Offsale_" .. id),
                            bundledItems = item.bundledItems
                        })
                    end
                end
            end

            local prevMode = State.currentMode
            State.animationsData = animationsData
            processCustomSets()
            finalize()
            State.totalPages = calculateTotalPages()
            if State.currentPage > State.totalPages then
                State.currentPage = State.totalPages
            end
            if prevMode == "animation" then
                if State.animationSearchTerm ~= "" and searchAnimations then
                    searchAnimations(State.animationSearchTerm)
                else
                    updatePageDisplay()
                    updateAnimations()
                end
            end
        end
    end)
end

local function smartSearchMatch(name, searchTerm)
    if not searchTerm or searchTerm == "" then return true end
    name = name:lower()
    searchTerm = searchTerm:lower()
    
    for word in searchTerm:gmatch("%S+") do
        if not name:find(word, 1, true) then
            return false
        end
    end
    return true
end

function searchEmotes(searchTerm)
    if State.isLoading then
        getgenv().Notify({
            Title = '7yd7 | Emote',
            Content = '⚠️ Loading please wait...',
            Duration = 5
        })
        return
    end

    searchTerm = searchTerm:lower()

    if searchTerm == "" then
        State.filteredEmotes = State.originalEmotesData
        State.emoteCacheVersion = State.emoteCacheVersion + 1
        if _G.originalFavoritesBackup then
            _G.originalFavoritesBackup = nil
        end
        _G.filteredFavoritesForDisplay = nil
    else
        local isIdSearch = searchTerm:match("^%d+$")
        
        local newFilteredList = {}
        
        if isIdSearch then
            for _, emote in pairs(State.originalEmotesData) do
                if tostring(emote.id) == searchTerm then
                    table.insert(newFilteredList, emote)
                end
            end
        else
            for _, emote in pairs(State.originalEmotesData) do
                if smartSearchMatch(emote.name, searchTerm) then
                    table.insert(newFilteredList, emote)
                end
            end
        end
        
        State.filteredEmotes = newFilteredList
        State.emoteCacheVersion = State.emoteCacheVersion + 1

        if not isIdSearch then
            if not _G.originalFavoritesBackup then
                _G.originalFavoritesBackup = {}
                for i, favorite in pairs(State.favoriteEmotes) do
                    _G.originalFavoritesBackup[i] = {
                        id = favorite.id,
                        name = favorite.name
                    }
                end
            end

            _G.filteredFavoritesForDisplay = {}
            for _, favorite in pairs(State.favoriteEmotes) do
                if smartSearchMatch(favorite.name, searchTerm) then
                    table.insert(_G.filteredFavoritesForDisplay, favorite)
                end
            end
        end
        applySearchSlot1Image()
    end

    State.totalPages = calculateTotalPages()
    State.currentPage = 1
    updatePageDisplay()
    updateEmotes()
end

function searchAnimations(searchTerm)
    if State.isLoading then
        getgenv().Notify({
            Title = '7yd7 | Animation',
            Content = '⚠️ Loading please wait...',
            Duration = 5
        })
        return
    end

    searchTerm = searchTerm:lower()

    if searchTerm == "" then
        State.filteredAnimations = State.originalAnimationsData
        State.animationCacheVersion = State.animationCacheVersion + 1
        if _G.originalAnimationFavoritesBackup then
            _G.originalAnimationFavoritesBackup = nil
        end
        _G.filteredFavoritesAnimationsForDisplay = nil
    else
        local isIdSearch = searchTerm:match("^%d+$")
        
        local newFilteredList = {}
        
        if isIdSearch then
            for _, animation in pairs(State.originalAnimationsData) do
                if tostring(animation.id) == searchTerm then
                    table.insert(newFilteredList, animation)
                end
            end
        else
            for _, animation in pairs(State.originalAnimationsData) do
                if smartSearchMatch(animation.name, searchTerm) then
                    table.insert(newFilteredList, animation)
                end
            end
        end
        
        State.filteredAnimations = newFilteredList
        State.animationCacheVersion = State.animationCacheVersion + 1

        if not isIdSearch then
            if not _G.originalAnimationFavoritesBackup then
                _G.originalAnimationFavoritesBackup = {}
                for i, favorite in pairs(State.favoriteAnimations) do
                    _G.originalAnimationFavoritesBackup[i] = {
                        id = favorite.id,
                        name = favorite.name,
                        bundledItems = favorite.bundledItems
                    }
                end
            end

            _G.filteredFavoritesAnimationsForDisplay = {}
            for _, favorite in pairs(State.favoriteAnimations) do
                if smartSearchMatch(favorite.name, searchTerm) then
                    table.insert(_G.filteredFavoritesAnimationsForDisplay, favorite)
                end
            end
        end
        applySearchSlot1Image()
    end

    State.totalPages = calculateTotalPages()
    State.currentPage = 1
    updatePageDisplay()
    updateAnimations()
end

findCustomAnimationDataByName = function(setName)
    if not setName or setName == "Default" then
        return nil
    end

    for _, animationData in ipairs(State.originalAnimationsData or {}) do
        if animationData.isCustomSet and animationData.name == setName then
            return animationData
        end
    end

    for _, animationData in ipairs(State.animationsData or {}) do
        if animationData.isCustomSet and animationData.name == setName then
            return animationData
        end
    end

    return nil
end

refreshCustomAnimationState = function(applySelectedSet)
    local activeSearch = State.animationSearchTerm or ""
    local previousPage = State.currentPage

    fetchAllAnimations()

    if activeSearch ~= "" then
        searchAnimations(activeSearch)
    else
        State.filteredAnimations = State.originalAnimationsData
        State.animationCacheVersion = State.animationCacheVersion + 1
        State.totalPages = calculateTotalPages()
        local maxPage = math.max(State.totalPages, 1)
        if previousPage < 1 then
            State.currentPage = 1
        elseif previousPage > maxPage then
            State.currentPage = maxPage
        else
            State.currentPage = previousPage
        end
        updatePageDisplay()
        if State.currentMode == "animation" then
            updateAnimations()
        end
    end

    if applySelectedSet and State.currentCustomAnimationName ~= "Default" then
        local selectedAnimationData = findCustomAnimationDataByName(State.currentCustomAnimationName)
        if selectedAnimationData then
            pcall(function()
                applyAnimation(selectedAnimationData)
            end)
        end
    end
end

function goToPage(pageNumber)
    bumpImageUpdateToken()
    if pageNumber < 1 then
        State.currentPage = 1
    elseif pageNumber > State.totalPages then
        State.currentPage = State.totalPages
    else
        State.currentPage = pageNumber
    end
    updatePageDisplay()
    updateEmotes()
end

function previousPage()
    bumpImageUpdateToken()
    if State.currentPage <= 1 then
        State.currentPage = State.totalPages
    else
        State.currentPage = State.currentPage - 1
    end
    updatePageDisplay()
    updateEmotes()
end

function nextPage()
    bumpImageUpdateToken()
    if State.currentPage >= State.totalPages then
        State.currentPage = 1
    else
        State.currentPage = State.currentPage + 1
    end
    updatePageDisplay()
    updateEmotes()
end

function stopCurrentEmote()
    if State.currentEmoteTrack then
        State.currentEmoteTrack:Stop()
        State.currentEmoteTrack = nil
    end
end

playEmote = function(humanoid, emoteId)
    stopCurrentEmote()
    stopEmotes()

    local animation = Instance.new("Animation")
    animation.AnimationId = "rbxassetid://" .. emoteId

    local success, animTrack = pcall(function()
        return humanoid.Animator:LoadAnimation(animation)
    end)

    if success and animTrack then
        State.currentEmoteTrack = animTrack
        State.currentEmoteTrack.Priority = Enum.AnimationPriority.Action
        State.currentEmoteTrack.Looped = true
        task.wait(0.1)
        if State.speedEmoteEnabled or State.emotesWalkEnabled then
            State.currentEmoteTrack:Play()

            if State.speedEmoteEnabled then
                local speedValue = tonumber(UI.SpeedBox.Text) or 1
                State.currentEmoteTrack:AdjustSpeed(speedValue)
            end
        end
    end
end

playRandomEmote = function(humanoid, emoteId)
    stopCurrentEmote()
    stopEmotes()

    local ok, track = pcall(function()
        return humanoid:PlayEmoteAndGetAnimTrackById(emoteId)
    end)
    if ok and track and typeof(track) == "Instance" and track:IsA("AnimationTrack") then
        State.currentEmoteTrack = track
        if State.speedEmoteEnabled then
            local speedVal = tonumber(UI.SpeedBox.Text) or Config.EmoteSpeed or 1
            track:AdjustSpeed(speedVal)
        end
    end
end

function onCharacterAdded(character)
    State.currentCharacter = character
    stopCurrentEmote()

    local humanoid = character:WaitForChild("Humanoid")
    local animator = humanoid:WaitForChild("Animator")

    if getgenv().autoReloadEnabled and getgenv().lastPlayedAnimation then
        task.spawn(function()
            local player = game.Players.LocalPlayer
            if not player:HasAppearanceLoaded() then
                player.CharacterAppearanceLoaded:Wait()
            end
            local animate = character:WaitForChild("Animate")
            character:WaitForChild("HumanoidRootPart")
            applyAnimation(getgenv().lastPlayedAnimation)
            getgenv().Notify({
                Title = '7yd7 | Auto Reload Animation',
                Content = '🔄 The last animation was automatically \n reapplied',
                Duration = 3
            })
            
            local lastAnim = getgenv().lastPlayedAnimation
            local cacheKey = tostring(lastAnim.id)
            local changed = false
            for i = 1, 7 do
                task.wait(0.01)
                if not character or not character.Parent or not humanoid then break end
                local mappings = State.AnimationCache[cacheKey]
                if not mappings and lastAnim.isCustomSet then
                    mappings = buildCustomSetMappings(GetCustomSetName and GetCustomSetName(lastAnim) or lastAnim.name)
                end
                if mappings and animate and animate.Parent then
                    for _, m in ipairs(mappings) do
                        local categoryFolder = animate:FindFirstChild(m.category)
                        if categoryFolder then
                            for _, animObj in ipairs(categoryFolder:GetChildren()) do
                                if animObj:IsA("Animation") and animObj.Name:lower() == m.name:lower() then
                                    if animObj.AnimationId ~= m.animationId then
                                        animObj.AnimationId = m.animationId
                                        if m.weights ~= nil then
                                            for _, child in ipairs(animObj:GetChildren()) do
                                                if child:IsA("NumberValue") and child.Name == "Weight" then
                                                    child:Destroy()
                                                end
                                            end
                                            for _, wVal in ipairs(m.weights) do
                                                local w = Instance.new("NumberValue")
                                                w.Name = "Weight"
                                                w.Value = wVal
                                                w.Parent = animObj
                                            end
                                        end
                                        changed = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if changed and humanoid.MoveDirection.Magnitude == 0 then
                animate.Disabled = true
                animate.Disabled = false
            end
        end)
    end

    local function isAnyEmoteEnhanceActive()
        return State.emotesWalkEnabled or State.speedEmoteEnabled
    end

    local function handleFrozenToolEquip()
        State.toolEquipped = true
        refreshToolAnimationIds()
    end

    local function handleFrozenToolUnequip()
        State.toolEquipped = false
        refreshToolAnimationIds()
    end

    if character:FindFirstChildOfClass("Tool") then
        State.toolEquipped = true
    end
    refreshToolAnimationIds()

    character.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            handleFrozenToolEquip()
        end
    end)

    character.ChildRemoved:Connect(function(child)
        if child:IsA("Tool") and not character:FindFirstChildOfClass("Tool") then
            handleFrozenToolUnequip()
        end
    end)

    animator.AnimationPlayed:Connect(function(animationTrack)
        if isDancing(character, animationTrack) then
            local playedEmoteId = urlToId(animationTrack.Animation.AnimationId)
            if playedEmoteId == "" or playedEmoteId == "0" then return end

            if State.toolEquipped then
                return
            end

            if State.emotesWalkEnabled then
                if State.currentEmoteTrack then
                    local currentEmoteId = urlToId(State.currentEmoteTrack.Animation.AnimationId)
                    if currentEmoteId == playedEmoteId then
                        return
                    else
                        stopCurrentEmote()
                    end
                end

                playEmote(humanoid, playedEmoteId)

                if currentEmoteTrack then
                    currentEmoteTrack.Ended:Connect(function()
                        if currentEmoteTrack == animationTrack then
                            currentEmoteTrack = nil
                        end
                    end)
                end
            end

            if State.speedEmoteEnabled and not State.emotesWalkEnabled then
                if State.currentEmoteTrack then
                    local currentEmoteId = urlToId(State.currentEmoteTrack.Animation.AnimationId)
                    if currentEmoteId == playedEmoteId then
                        return
                    else
                        stopCurrentEmote()
                    end
                end

                playEmote(humanoid, playedEmoteId)

                if currentEmoteTrack then
                    currentEmoteTrack.Ended:Connect(function()
                        if currentEmoteTrack == animationTrack then
                            currentEmoteTrack = nil
                        end
                    end)
                end
            end
        end
    end)

    humanoid.Died:Connect(function()
    if State.hudEditorActive and exitHUDEditor then exitHUDEditor() end
    State.emotesWalkEnabled = false
    State.speedEmoteEnabled = false
    State.favoriteEnabled = false
    State.toolEquipped = false
    State.currentEmoteTrack = nil

    stopEmotes()
        stopCurrentEmote()
    end)
end

function toggleEmoteWalk()
    State.emotesWalkEnabled = not State.emotesWalkEnabled
    ApplyFreezeButtonVisual()

    if State.emotesWalkEnabled then
        getgenv().Notify({
            Title = '7yd7 | Emote Freeze',
            Content = "🔒 Emote freeze ON",
            Duration = 5
        })

        task.wait(0.1)
        stopCurrentEmote()
        if State.currentEmoteTrack and State.currentEmoteTrack.IsPlaying then
            State.currentEmoteTrack:AdjustSpeed(1)
        end
    else
        getgenv().Notify({
            Title = '7yd7 | Emote Freeze',
            Content = '🔓 Emote freeze OFF',
            Duration = 5
        })
        task.wait(0.1)
        stopCurrentEmote()

        if State.currentEmoteTrack and State.currentEmoteTrack.IsPlaying and State.speedEmoteEnabled then
            local speedValue = tonumber(UI.SpeedBox.Text) or 1
            State.currentEmoteTrack:AdjustSpeed(speedValue)
        elseif State.currentEmoteTrack and State.currentEmoteTrack.IsPlaying then
            State.currentEmoteTrack:AdjustSpeed(1)
        end
    end
end

function toggleSpeedEmote()
    State.speedEmoteEnabled = not State.speedEmoteEnabled
    updateSpeedBoxVisibility()

    if State.speedEmoteEnabled then
        getgenv().Notify({
            Title = '7yd7 | Speed Emote',
            Content = "⚡ Speed Emote ON",
            Duration = 5
        })
        task.wait(0.1)
        stopCurrentEmote()
    else
        getgenv().Notify({
            Title = '7yd7 | Speed Emote',
            Content = '⚡ Speed Emote OFF',
            Duration = 5
        })
        task.wait(0.1)
        stopCurrentEmote()
    end

    Config.EmoteSpeedEnabled = State.speedEmoteEnabled
    Config.EmoteSpeed = tonumber(UI.SpeedBox.Text) or 1
    SaveConfig()
end

function toggleFavoriteMode()
    State.favoriteEnabled = not State.favoriteEnabled

    if State.favoriteEnabled then
        ApplyFavoriteButtonVisual()
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = "🔒 Favorite ON",
            Duration = 5
        })

        updateScriptPriorityOverlay()
        setEmotesButtonsActiveForFavorites()

        if State.currentMode == "emote" then
            setupEmoteClickDetection()
        else 
            updateAllFavoriteIcons()
        end
    else
        ApplyFavoriteButtonVisual()
        getgenv().Notify({
            Title = '7yd7 | Favorite System',
            Content = '🔓 Favorite OFF',
            Duration = 3
        })
        
        if State.currentMode == "emote" then
            stopEmoteClickDetection()
        else
            updateAllFavoriteIcons()
        end
        clearCustomHitboxes()
        updateScriptPriorityOverlay()
    end

    pcall(function()
        local frontFrame = CoreGui.RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
        applyEmotesButtonsActiveState()
    end)
end

local clickCooldown = {}
local CLICK_COOLDOWN_TIME = 0.1

function safeButtonClick(buttonName, callback)
    if State.hudEditorActive then return end
    local currentTime = tick()
    if not clickCooldown[buttonName] or (currentTime - clickCooldown[buttonName]) > CLICK_COOLDOWN_TIME then
        clickCooldown[buttonName] = currentTime
        callback()
    end
end

function setupAnimationClickDetection()
    if State.isMonitoringClicks then
        return
    end
    
    if State.currentMode == "animation" then
        State.animationMonitorToken = State.animationMonitorToken + 1
        local token = State.animationMonitorToken
        State.isMonitoringClicks = true
        task.spawn(function()
            monitorAnimations(token)
        end)
    end
end

function toggleAutoReload()
    getgenv().autoReloadEnabled = not getgenv().autoReloadEnabled
    Config.AutoReloadEnabled = getgenv().autoReloadEnabled
    task.spawn(SaveConfig)
    
    if getgenv().autoReloadEnabled then
        getgenv().Notify({
            Title = '7yd7 | Auto Reload Animation',
            Content = "🔄 Auto Reload ON",
            Duration = 5
        })
    else
        getgenv().Notify({
            Title = '7yd7 | Auto Reload Animation',
            Content = '🔄 Auto Reload OFF',
            Duration = 3
        })
    end
end

function connectEvents()
    disconnectAllConnections()

    if UI._1left then
        table.insert(State.guiConnections, UI._1left.MouseButton1Click:Connect(function()
            safeButtonClick("PrevPage", previousPage)
        end))
    end

    if UI._9right then
        table.insert(State.guiConnections, UI._9right.MouseButton1Click:Connect(function()
            safeButtonClick("NextPage", nextPage)
        end))
    end

    if UI._2Routenumber then
        table.insert(State.guiConnections, UI._2Routenumber.FocusLost:Connect(function(enterPressed)
            if State.hudEditorActive then return end
            local pageNum = tonumber(UI._2Routenumber.Text)
            if pageNum then
                goToPage(pageNum)
            else
                UI._2Routenumber.Text = tostring(State.currentPage)
            end
        end))
    end

    if UI.Search then
        table.insert(State.guiConnections, UI.Search.Changed:Connect(function(property)
            if State.hudEditorActive then return end
            if property == "Text" then
                if State.suppressSearch then
                    return
                end
                if State.currentMode == "emote" then
                    State.emoteSearchTerm = UI.Search.Text
                    searchEmotes(State.emoteSearchTerm)
                else
                    State.animationSearchTerm = UI.Search.Text
                    searchAnimations(State.animationSearchTerm)
                end
            end
        end))
    end

    local SECTOR_COUNT = 8
    local SECTOR_ANGLE = 360 / SECTOR_COUNT
    
    local function isAuthenticPageActive()
        if not (Config.AuthenticFirstPage and State.currentMode == "emote") then
            return false
        end
        local authenticEmotes = getgenv().OwnedAuthenticEmotes or {}
        local authenticPagesCount = calcPagesForList(#authenticEmotes, false)
        return #authenticEmotes > 0 and State.currentPage <= authenticPagesCount
    end

    table.insert(State.guiConnections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if State.hudEditorActive then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
        
        local exists, emotesWheel = checkEmotesMenuExists()
        local isRecentlyVisible = (tick() - State.lastWheelVisibleTime < 0.15)
        if not (exists and (emotesWheel.Visible or isRecentlyVisible)) then return end

        
        local actualPos = Vector2.new(input.Position.X, input.Position.Y)

        local absPos = emotesWheel.AbsolutePosition
        local absSize = emotesWheel.AbsoluteSize

        local inXBounds = (actualPos.X >= absPos.X) and (actualPos.X <= absPos.X + absSize.X)
        local inYBounds = (actualPos.Y >= absPos.Y) and (actualPos.Y <= absPos.Y + absSize.Y)
        if not (inXBounds and inYBounds) then return end

        local center = absPos + (absSize / 2)
        local dx = actualPos.X - center.X
        local dy = actualPos.Y - center.Y

        local distance = math.sqrt(dx*dx + dy*dy)
        local radius = math.min(absSize.X, absSize.Y) * 0.5
        if distance > radius then return end
        local dynamicDeadzone = radius * 0.2
        if distance < dynamicDeadzone then return end

        local angle = math.deg(math.atan2(dy, dx))
        local correctedAngle = (angle + 90 + (SECTOR_ANGLE / 2)) % 360
        local index = math.floor(correctedAngle / SECTOR_ANGLE) + 1
        if not (State.favoriteEnabled or State.currentMode == "animation" or isAuthenticPageActive() or (index == 1 and isRandomSlotActive())) then return end

        handleSectorAction(index)
    end))

    local function bindWheelHotkeys()
        if not ContextActionService then return end

        local keyToIndex = {
            [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4,
            [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6, [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8,
            [Enum.KeyCode.KeypadOne] = 1, [Enum.KeyCode.KeypadTwo] = 2, [Enum.KeyCode.KeypadThree] = 3, [Enum.KeyCode.KeypadFour] = 4,
            [Enum.KeyCode.KeypadFive] = 5, [Enum.KeyCode.KeypadSix] = 6, [Enum.KeyCode.KeypadSeven] = 7, [Enum.KeyCode.KeypadEight] = 8
        }

        local function onHotkey(actionName, inputState, inputObject)
            if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
            if State.hudEditorActive then return Enum.ContextActionResult.Pass end
            if UserInputService:GetFocusedTextBox() then return Enum.ContextActionResult.Pass end
            if State.customAnimationEditorActive and (not State.customAnimationEditingKey or not State.customAnimationEditingName or not (State.CustomAnimOverlay and State.CustomAnimOverlay.Parent)) then
                if State.exitCustomAnimationEditor then
                    State.exitCustomAnimationEditor()
                else
                    State.customAnimationEditorActive = false
                end
            end

            local index = keyToIndex[inputObject.KeyCode]
            if not index then return Enum.ContextActionResult.Pass end
            
            if isAuthenticPageActive() then
                return Enum.ContextActionResult.Pass
            end

            if not (State.favoriteEnabled or State.currentMode == "animation" or (index == 1 and isRandomSlotActive())) then
                return Enum.ContextActionResult.Pass
            end

            local exists, emotesWheel = checkEmotesMenuExists()
            local isRecentlyVisible = (tick() - State.lastWheelVisibleTime < 0.15)
            if not (exists and (emotesWheel.Visible or isRecentlyVisible)) then return Enum.ContextActionResult.Pass end

            local success, frontFrame = pcall(function()
                return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Front.EmotesButtons
            end)
            if success and frontFrame then
                local target = frontFrame:FindFirstChild(tostring(index))
                if target and target:IsA("ImageLabel") and target.Image ~= "" then
                    handleSectorAction(index)
                    if State.currentMode == "animation" and not State.favoriteEnabled then
                        pcall(function()
                            game:GetService("GuiService"):SetEmotesMenuOpen(false)
                        end)
                        pcall(function()
                            game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false
                        end)
                    end
                    return Enum.ContextActionResult.Sink
                end
            end

            return Enum.ContextActionResult.Pass
        end

        ContextActionService:UnbindAction("7yd7_EmoteWheelHotkeys")
        ContextActionService:BindActionAtPriority(
            "7yd7_EmoteWheelHotkeys",
            onHotkey,
            false,
            (Enum.ContextActionPriority.High.Value + 50),
            Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
            Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
            Enum.KeyCode.KeypadOne, Enum.KeyCode.KeypadTwo, Enum.KeyCode.KeypadThree, Enum.KeyCode.KeypadFour,
            Enum.KeyCode.KeypadFive, Enum.KeyCode.KeypadSix, Enum.KeyCode.KeypadSeven, Enum.KeyCode.KeypadEight
        )
    end

    bindWheelHotkeys()

    if UI.EmoteWalkButton then
        table.insert(State.guiConnections, UI.EmoteWalkButton.MouseButton1Click:Connect(function()
            safeButtonClick("EmoteWalk", toggleEmoteWalk)
        end))
    end

    if UI.Favorite then
        table.insert(State.guiConnections, UI.Favorite.MouseButton1Click:Connect(function()
            safeButtonClick("Favorite", toggleFavoriteMode)
        end))
    end

    if UI.SpeedEmote then
        table.insert(State.guiConnections, UI.SpeedEmote.MouseButton1Click:Connect(function()
            safeButtonClick("SpeedEmote", toggleSpeedEmote)
        end))
    end

    if UI.Reload then
        table.insert(State.guiConnections, UI.Reload.MouseButton1Click:Connect(function()
            safeButtonClick("AutoReload", toggleAutoReload)
        end))
    end

    if UI.Changepage then
        table.insert(State.guiConnections, UI.Changepage.MouseButton1Click:Connect(function()
            safeButtonClick("ChangePage", function()
                stopEmoteClickDetection()
                if State.animImageSpamConn then
                    State.animImageSpamConn:Disconnect()
                    State.animImageSpamConn = nil
                    State.animImageSpamMap = nil
                    State.animImageSpamTicks = nil
                    State.animImageSpamToken = State.animImageSpamToken + 1
                end
                
                if State.currentMode == "emote" then
                    State.savedEmotePage = State.currentPage
                    State.currentMode = "animation"
                    
                    local function applyAnimationModeUI()
                        State.suppressSearch = true
                        UI.Search.Text = State.animationSearchTerm
                        State.suppressSearch = false
                        if State.animationSearchTerm ~= "" then
                            searchAnimations(State.animationSearchTerm)
                        end
                        State.currentPage = State.savedAnimPage
                        State.totalPages = calculateTotalPages()
                        updatePageDisplay()
                        updateEmotes() 
                        updateScriptPriorityOverlay()
                        State.animationMonitorToken = State.animationMonitorToken + 1
                        local token = State.animationMonitorToken
                        State.isMonitoringClicks = true
                        task.spawn(function()
                            monitorAnimations(token)
                        end)
                    end

                    applyAnimationModeUI()
                    
                    local beforeVersion = State.animationCacheVersion
                    task.spawn(function()
                        fetchAllAnimations()
                        if State.currentMode ~= "animation" then return end
                        if State.animationCacheVersion ~= beforeVersion then
                            applyAnimationModeUI()
                        end
                    end)
                    
                    getgenv().Notify({
                        Title = '7yd7 | Animation',
                        Content = '📄 Changed to Emote > Animation Mode',
                        Duration = 3
                    })

                else
                    State.savedAnimPage = State.currentPage
                    State.currentMode = "emote"
                    clearCustomHitboxes()
                    State.suppressSearch = true
                    UI.Search.Text = State.emoteSearchTerm
                    State.suppressSearch = false
                    if State.emoteSearchTerm ~= "" and searchEmotes then
                        searchEmotes(State.emoteSearchTerm)
                    end
                    State.currentPage = State.savedEmotePage
                    State.totalPages = calculateTotalPages()
                    updatePageDisplay() 
                    updateEmotes()
                    updateScriptPriorityOverlay()
                    
                    if State.favoriteEnabled then
                        setupEmoteClickDetection()
                    end
                    
                    getgenv().Notify({
                        Title = '7yd7 | Emote', 
                        Content = '📄 Changed to Animation > Emote Mode',
                        Duration = 3
                    })
                end
            end)
        end))
    end



    if UI.SpeedBox then
        table.insert(State.guiConnections, UI.SpeedBox.FocusLost:Connect(function()
            if State.hudEditorActive then return end
            local speedValue = tonumber(UI.SpeedBox.Text) or 1
            Config.EmoteSpeed = speedValue
            SaveConfig()
        end))
    end

    table.insert(State.guiConnections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if State.hudEditorActive then return end
        local exists, emotesWheel = checkEmotesMenuExists()
        if not (exists and emotesWheel.Visible) then return end

        if input.KeyCode == Enum.KeyCode.Q then
            if UserInputService:GetFocusedTextBox() then return end
            previousPage()
        elseif input.KeyCode == Enum.KeyCode.E then
            if UserInputService:GetFocusedTextBox() then return end
            nextPage()
        elseif (input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl) then
            if not UserInputService:GetFocusedTextBox() and UI.Search then
                UI.Search:CaptureFocus()
            end
        end
    end))
end






function calculateSnap(element, newPos, currentName, allMovable)
    local SNAP_THRESHOLD = 8
    local parent = element.Parent
    if not parent then return newPos, nil, nil end
    local ps = parent.AbsoluteSize
    local pp = parent.AbsolutePosition
    local absX = pp.X + newPos.X.Scale * ps.X + newPos.X.Offset
    local absY = pp.Y + newPos.Y.Scale * ps.Y + newPos.Y.Offset
    local absW = element.AbsoluteSize.X
    local absH = element.AbsoluteSize.Y
    local sX, sY = absX, absY
    local didX, didY = false, false
    local guideX, guideY
    for oName, oEl in pairs(allMovable) do
        if oName ~= currentName then
            local oX = oEl.AbsolutePosition.X
            local oY = oEl.AbsolutePosition.Y
            local oW = oEl.AbsoluteSize.X
            local oH = oEl.AbsoluteSize.Y
            if not didX then
                if math.abs(absX - oX) < SNAP_THRESHOLD then sX = oX; didX = true; guideX = oX end
                if math.abs(absX - (oX + oW)) < SNAP_THRESHOLD then sX = oX + oW; didX = true; guideX = oX + oW end
                if math.abs((absX + absW) - oX) < SNAP_THRESHOLD then sX = oX - absW; didX = true; guideX = oX end
                if math.abs((absX + absW) - (oX + oW)) < SNAP_THRESHOLD then sX = oX + oW - absW; didX = true; guideX = oX + oW end
                if math.abs((absX + absW/2) - (oX + oW/2)) < SNAP_THRESHOLD then sX = oX + oW/2 - absW/2; didX = true; guideX = oX + oW/2 end
            end
            if not didY then
                if math.abs(absY - oY) < SNAP_THRESHOLD then sY = oY; didY = true; guideY = oY end
                if math.abs(absY - (oY + oH)) < SNAP_THRESHOLD then sY = oY + oH; didY = true; guideY = oY + oH end
                if math.abs((absY + absH) - oY) < SNAP_THRESHOLD then sY = oY - absH; didY = true; guideY = oY end
                if math.abs((absY + absH) - (oY + oH)) < SNAP_THRESHOLD then sY = oY + oH - absH; didY = true; guideY = oY + oH end
                if math.abs((absY + absH/2) - (oY + oH/2)) < SNAP_THRESHOLD then sY = oY + oH/2 - absH/2; didY = true; guideY = oY + oH/2 end
            end
        end
    end
    local fsx = (sX - pp.X) / ps.X
    local fsy = (sY - pp.Y) / ps.Y
    return UDim2.new(fsx, newPos.X.Offset, fsy, newPos.Y.Offset), guideX, guideY
end

local function hudColorToRGB(c)
    return {math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)}
end

local function copyProps(name)
    local src = Config.HUDProperties and Config.HUDProperties[name]
    if not src then return {} end
    local out = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            local t = {}
            for i, sv in pairs(v) do
                t[i] = sv
            end
            out[k] = t
        else
            out[k] = v
        end
    end
    return out
end

local function captureHUDState(n, el)
    if not n or not el then return nil end
    local cR = el:FindFirstChildWhichIsA("UICorner")
    local s = {
        name = n,
        pos = el.Position,
        size = el.Size,
        z = el.ZIndex,
        bgTrans = el.BackgroundTransparency,
        bgColor = el.BackgroundColor3,
        radius = cR and cR.CornerRadius or nil
    }
    if el:IsA("ImageLabel") or el:IsA("ImageButton") then
        s.imgTrans = el.ImageTransparency
        s.imgColor = el.ImageColor3
    end
    if el:IsA("TextLabel") or el:IsA("TextBox") then
        s.text = el.Text
        s.textTrans = el.TextTransparency
        s.textColor = el.TextColor3
        if el:IsA("TextBox") then
            s.placeholder = el.PlaceholderText
        end
    end
    s.props = copyProps(n)
    return s
end

local function pushUndo(state)
    if not state then return end
    if not HUD.UndoStack then HUD.UndoStack = {} end
    table.insert(HUD.UndoStack, state)
    if #HUD.UndoStack > 50 then
        table.remove(HUD.UndoStack, 1)
    end
end

local function sameUDim2(a, b)
    return a.X.Scale == b.X.Scale and a.X.Offset == b.X.Offset and a.Y.Scale == b.Y.Scale and a.Y.Offset == b.Y.Offset
end

local function sameUDim(a, b)
    return a.Scale == b.Scale and a.Offset == b.Offset
end

local function sameColor(a, b)
    return math.abs(a.R - b.R) < 0.001 and math.abs(a.G - b.G) < 0.001 and math.abs(a.B - b.B) < 0.001
end

local function applyHUDState(state)
    if not state or not state.name then return end
    local all = getAllHUDObjects()
    local el = all[state.name]
    if not el then return end

    if state.pos then
        el.Position = state.pos
        if not Config.HUDPositions then Config.HUDPositions = {} end
        Config.HUDPositions[state.name] = {state.pos.X.Scale, state.pos.X.Offset, state.pos.Y.Scale, state.pos.Y.Offset}
    end
    if state.size then
        el.Size = state.size
        if not Config.HUDSizes then Config.HUDSizes = {} end
        Config.HUDSizes[state.name] = {state.size.X.Scale, state.size.X.Offset, state.size.Y.Scale, state.size.Y.Offset}
    end
    if state.z ~= nil then el.ZIndex = state.z end
    if state.props and state.props.BgTrans ~= nil then el.BackgroundTransparency = state.bgTrans end
    if state.props and state.props.BgColor then el.BackgroundColor3 = state.bgColor end
    if el:IsA("ImageLabel") or el:IsA("ImageButton") then
        if state.props and state.props.ImgTrans ~= nil then el.ImageTransparency = state.imgTrans end
        if state.props and state.props.ImgColor then el.ImageColor3 = state.imgColor end
    end
    if el:IsA("TextLabel") or el:IsA("TextBox") then
        if state.props and state.props.Text ~= nil then el.Text = state.text end
        if state.props and state.props.TextTransparency ~= nil then el.TextTransparency = state.textTrans end
        if state.props and state.props.TxtColor then el.TextColor3 = state.textColor end
        if el:IsA("TextBox") and state.placeholder ~= nil then
            el.PlaceholderText = state.placeholder
        end
    end
    if state.radius then
        local cR = el:FindFirstChildWhichIsA("UICorner")
        if cR then cR.CornerRadius = state.radius end
    end

    if not Config.HUDProperties then Config.HUDProperties = {} end
    Config.HUDProperties[state.name] = state.props or {}
    SaveConfig()
    pcall(function() updateGUIColors() end)
end

local function undoLastHUD()
    if not State.hudEditorActive then return end
    if not HUD.UndoStack or #HUD.UndoStack == 0 then return end
    local state = table.remove(HUD.UndoStack)
    applyHUDState(state)
end

local function normalizeUDim2(u, ps)
    if not u or not ps or ps.X <= 0 or ps.Y <= 0 then
        return nil
    end
    local sx = u.X.Scale + (u.X.Offset / ps.X)
    local sy = u.Y.Scale + (u.Y.Offset / ps.Y)
    return sx, 0, sy, 0
end

local function tableToUDim2(v)
    if type(v) ~= "table" or #v ~= 4 then return nil end
    return UDim2.new(v[1], v[2], v[3], v[4])
end

local function normalizeHUDScale()
    local elems = getAllHUDObjects()
    for name, el in pairs(elems) do
        local parent = el and el.Parent
        if parent then
            local hasLayout = parent:FindFirstChildOfClass("UIListLayout")
            if hasLayout and not HUD.IsUnlocked then
                return
            end
            local ps = parent.AbsoluteSize
            if Config.HUDPositions and Config.HUDPositions[name] then
                local v = Config.HUDPositions[name]
                if type(v) == "table" and #v == 4 then
                    local sx, ox, sy, oy = v[1], v[2], v[3], v[4]
                    if ox ~= 0 or oy ~= 0 then
                        local nsx, nox, nsy, noy = normalizeUDim2(UDim2.new(sx, ox, sy, oy), ps)
                        if nsx then
                            Config.HUDPositions[name] = {nsx, nox, nsy, noy}
                            el.Position = UDim2.new(nsx, nox, nsy, noy)
                        end
                    end
                end
            end
            if Config.HUDSizes and Config.HUDSizes[name] then
                local v = Config.HUDSizes[name]
                if type(v) == "table" and #v == 4 then
                    local def = HUD.DefaultSizes and HUD.DefaultSizes[name]
                    local isDefault = def and sameUDim2(def, tableToUDim2(v) or UDim2.new(0,0,0,0))
                    if isDefault then
                        return
                    end
                    local sx, ox, sy, oy = v[1], v[2], v[3], v[4]
                    if ox ~= 0 or oy ~= 0 then
                        local nsx, nox, nsy, noy = normalizeUDim2(UDim2.new(sx, ox, sy, oy), ps)
                        if nsx then
                            Config.HUDSizes[name] = {nsx, nox, nsy, noy}
                            el.Size = UDim2.new(nsx, nox, nsy, noy)
                        end
                    end
                end
            end
        end
    end
    SaveConfig()
end

local function normalizeHUDScaleForElement(name, el, normalizePos, normalizeSize)
    if not name or not el or not el.Parent then return end
    if normalizePos == nil then normalizePos = true end
    if normalizeSize == nil then normalizeSize = true end
    local parent = el.Parent
    local hasLayout = parent:FindFirstChildOfClass("UIListLayout")
    if hasLayout and not HUD.IsUnlocked then return end
    local ps = parent.AbsoluteSize
    if ps.X <= 0 or ps.Y <= 0 then return end

    if normalizePos then
        local nsx, nox, nsy, noy = normalizeUDim2(el.Position, ps)
        if nsx then
            el.Position = UDim2.new(nsx, nox, nsy, noy)
            if not Config.HUDPositions then Config.HUDPositions = {} end
            Config.HUDPositions[name] = {nsx, nox, nsy, noy}
        end
    end

    if normalizeSize then
        local nsx, nox, nsy, noy = normalizeUDim2(el.Size, ps)
        if nsx then
            el.Size = UDim2.new(nsx, nox, nsy, noy)
            if not Config.HUDSizes then Config.HUDSizes = {} end
            Config.HUDSizes[name] = {nsx, nox, nsy, noy}
        end
    end

    SaveConfig()
end

function selectHUDElement(name, element)
    if HUD.SelectedElement == element then return end
    HUD.SelectedElement = element
    HUD.LastTouchedElement = element
    HUD.LastTouchedName = name

    local parent = element.Parent
    if UI and parent and (parent == UI.Top or parent == UI.Under) then
        local key = parent.Name
        local l = parent:FindFirstChildOfClass("UIListLayout") or (HUD.Layouts and HUD.Layouts[key])
        if l then
            HUD.Layouts[key] = l
            HUD.LayoutsRemoved[key] = true
            l.Parent = nil
        end
    end

    for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
    HUD.ResizeHandles = {}
    for _, c in pairs(HUD.ResizeConnections) do pcall(function() c:Disconnect() end) end
    HUD.ResizeConnections = {}

    local selectionGui = HUD.SelectionGui
    local wrapper = Instance.new("Frame")
    wrapper.Name = "SelectionWrapper"
    wrapper.BackgroundTransparency = 1
    wrapper.ZIndex = 1
    wrapper.Parent = selectionGui

    table.insert(HUD.ResizeHandles, wrapper)
    table.insert(HUD.ResizeConnections, RunService.RenderStepped:Connect(function()
        if HUD.SelectedElement == element and element.Parent then
            wrapper.Size = UDim2.fromOffset(element.AbsoluteSize.X, element.AbsoluteSize.Y)
            wrapper.Position = UDim2.fromOffset(element.AbsolutePosition.X, element.AbsolutePosition.Y)
        end
    end))

    local handlePositions = {
        TopLeft = {UDim2.new(0,0,0,0), Vector2.new(-1, -1)},
        Top = {UDim2.new(0.5,0,0,0), Vector2.new(0, -1)},
        TopRight = {UDim2.new(1,0,0,0), Vector2.new(1, -1)},
        Left = {UDim2.new(0,0,0.5,0), Vector2.new(-1, 0)},
        Right = {UDim2.new(1,0,0.5,0), Vector2.new(1, 0)},
        BottomLeft = {UDim2.new(0,0,1,0), Vector2.new(-1, 1)},
        Bottom = {UDim2.new(0.5,0,1,0), Vector2.new(0, 1)},
        BottomRight = {UDim2.new(1,0,1,0), Vector2.new(1, 1)}
    }

    for dir, data in pairs(handlePositions) do
        local h = Instance.new("Frame")
        h.Name = "Resize_"..dir
        h.Size = UDim2.new(0, 8, 0, 8)
        h.AnchorPoint = Vector2.new(0.5, 0.5)
        h.Position = data[1]
        h.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
        h.BorderColor3 = Color3.fromRGB(0, 0, 0)
        h.ZIndex = 11000
        h.Parent = wrapper

        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 4, 1, 4)
        btn.Position = UDim2.new(0.5, 0, 0.5, 0)
        btn.AnchorPoint = Vector2.new(0.5, 0.5)
        btn.BackgroundTransparency = 1
        btn.Text = ""
        btn.ZIndex = 11001
        btn.Parent = h

        local resizing = false
        local dragStart
        local startAbsSize
        local startAbsPos
        local resizeUndo

        table.insert(HUD.ResizeConnections, btn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                resizing = true
                resizeUndo = captureHUDState(name, element)
                dragStart = input.Position
                startAbsSize = element.AbsoluteSize
                startAbsPos = element.AbsolutePosition
            end
        end))

        table.insert(HUD.ResizeConnections, UserInputService.InputChanged:Connect(function(input)
            if not resizing then return end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                local pSize = element.Parent and element.Parent.AbsoluteSize or Vector2.new(1, 1)
                
                local dirVec = data[2]
                local newW = startAbsSize.X + (dirVec.X == 1 and delta.X or (dirVec.X == -1 and -delta.X or 0))
                local newH = startAbsSize.Y + (dirVec.Y == 1 and delta.Y or (dirVec.Y == -1 and -delta.Y or 0))
                local newX = startAbsPos.X + (dirVec.X == -1 and delta.X or 0)
                local newY = startAbsPos.Y + (dirVec.Y == -1 and delta.Y or 0)

                if newW < 20 then
                    if dirVec.X == -1 then newX = newX - (20 - newW) end
                    newW = 20
                end
                if newH < 20 then
                    if dirVec.Y == -1 then newY = newY - (20 - newH) end
                    newH = 20
                end

                local parentPos = element.Parent and element.Parent.AbsolutePosition or Vector2.new(0,0)
                local relX = (newX - parentPos.X) / pSize.X
                local relY = (newY - parentPos.Y) / pSize.Y

                element.Size = UDim2.new(newW / pSize.X, 0, newH / pSize.Y, 0)
                element.Position = UDim2.new(relX, 0, relY, 0)
            end
        end))

        table.insert(HUD.ResizeConnections, UserInputService.InputEnded:Connect(function(input)
             if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                 if resizing then
                     resizing = false
                     if resizeUndo and (not sameUDim2(resizeUndo.pos, element.Position) or not sameUDim2(resizeUndo.size, element.Size)) then
                         pushUndo(resizeUndo)
                     end
                     local rPs = element.Parent and element.Parent.AbsoluteSize or Vector2.new(1, 1)
                     local pXs = element.Position.X.Scale + (element.Position.X.Offset / rPs.X)
                     local pYs = element.Position.Y.Scale + (element.Position.Y.Offset / rPs.Y)
                     Config.HUDPositions[name] = {pXs, 0, pYs, 0}
                     if not Config.HUDSizes then Config.HUDSizes = {} end
                     local sXs = element.Size.X.Scale + (element.Size.X.Offset / rPs.X)
                     local sYs = element.Size.Y.Scale + (element.Size.Y.Offset / rPs.Y)
                     Config.HUDSizes[name] = {sXs, 0, sYs, 0}
                 end
             end
        end))
    end
end

function setupElementDragging(name, element, allMovable, snapGuideV, snapGuideH)
    element.Visible = true
    local stroke = Instance.new("UIStroke")
    stroke.Name = "HUDEditorStroke"
    stroke.Color = Color3.fromRGB(0, 255, 100)
    stroke.Thickness = 2
    stroke.Parent = element
    table.insert(HUD.Strokes, stroke)

    local isChild = false
    for _, friendly in pairs(HUD.FriendlyNames) do
        if name == friendly then
            isChild = true
            break
        end
    end

    local inputTarget = Instance.new("TextButton")
    inputTarget.Name = "HUDDragHandle_" .. name
    inputTarget.BackgroundTransparency = 1
    inputTarget.Text = ""
    inputTarget.ZIndex = isChild and 10 or 5
    inputTarget.Active = true
    inputTarget.Parent = HUD.SelectionGui

    table.insert(HUD.Connections, RunService.RenderStepped:Connect(function()
        if element and element.Parent then
            inputTarget.Size = UDim2.fromOffset(element.AbsoluteSize.X, element.AbsoluteSize.Y)
            inputTarget.Position = UDim2.fromOffset(element.AbsolutePosition.X, element.AbsolutePosition.Y)
        end
    end))

    local dragging = false
    local dragStart, startPos
    local dragUndo
    table.insert(HUD.Connections, inputTarget.InputBegan:Connect(function(input)
        if not State.hudEditorActive then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragUndo = captureHUDState(name, element)
            dragStart = input.Position
            startPos = element.Position
            stroke.Color = Color3.fromRGB(255, 255, 255)
            selectHUDElement(name, element)
        end
    end))

    table.insert(HUD.Connections, UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if not dragStart then return end
            local delta = input.Position - dragStart
            local ps = element.Parent and element.Parent.AbsoluteSize or Vector2.new(1, 1)
            local rawPos = UDim2.new(
                startPos.X.Scale + delta.X / ps.X, startPos.X.Offset,
                startPos.Y.Scale + delta.Y / ps.Y, startPos.Y.Offset
            )
            local snapped, gx, gy = calculateSnap(element, rawPos, name, allMovable)
            element.Position = snapped
            local ovP = HUD.Overlay and HUD.Overlay.AbsolutePosition or Vector2.new(0, 0)
            if snapGuideV then snapGuideV.Visible = (gx ~= nil); if gx then snapGuideV.Position = UDim2.fromOffset(gx - ovP.X, 0) end end
            if snapGuideH then snapGuideH.Visible = (gy ~= nil); if gy then snapGuideH.Position = UDim2.fromOffset(0, gy - ovP.Y) end end
        end
    end))

    table.insert(HUD.Connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if dragging then
                dragging = false
                stroke.Color = Color3.fromRGB(0, 255, 100)
                if snapGuideV then snapGuideV.Visible = false end
                if snapGuideH then snapGuideH.Visible = false end
                if dragUndo and not sameUDim2(dragUndo.pos, element.Position) then
                    pushUndo(dragUndo)
                end
                    local dPs = element.Parent and element.Parent.AbsoluteSize or Vector2.new(1, 1)
                    local dpXs = element.Position.X.Scale + (element.Position.X.Offset / dPs.X)
                    local dpYs = element.Position.Y.Scale + (element.Position.Y.Offset / dPs.Y)
                    element.Position = UDim2.new(dpXs, 0, dpYs, 0)
                    Config.HUDPositions[name] = {dpXs, 0, dpYs, 0}
                end
        end
    end))
end

applySavedPositions = function()
    local elems = getAllHUDObjects()
    for name, el in pairs(elems) do
        local customPos = Config.HUDPositions and Config.HUDPositions[name]
        if customPos and type(customPos) == "table" and #customPos == 4 then
            el.Position = UDim2.new(customPos[1], customPos[2], customPos[3], customPos[4])
        elseif HUD.DefaultPositions and HUD.DefaultPositions[name] then
             el.Position = HUD.DefaultPositions[name]
        end

        local customSz = Config.HUDSizes and Config.HUDSizes[name]
        if customSz and type(customSz) == "table" and #customSz == 4 then
            el.Size = UDim2.new(customSz[1], customSz[2], customSz[3], customSz[4])
        elseif HUD.DefaultSizes and HUD.DefaultSizes[name] then
             el.Size = HUD.DefaultSizes[name]
        end

        local props = Config.HUDProperties and Config.HUDProperties[name]
        if props then
            for k, v in pairs(props) do
                pcall(function()
                    if k == "Radius" or k == "CornerRadius" then
                        local cR = el:FindFirstChildWhichIsA("UICorner")
                        if cR and type(v) == "table" then
                             cR.CornerRadius = UDim.new(tonumber(v[1]) or 0, tonumber(v[2]) or 0)
                        end
                    elseif k == "RadiusString" or k == "PlaceholderTransparency" then
                    else
                        el[k] = v
                    end
                end)
            end
        end
    end
end

exitHUDEditor = function()
    if not State.hudEditorActive then return end
    State.hudEditorActive = false
    if SettingsLib and SettingsLib.UI and SettingsLib.UI:IsA("ScreenGui") and HUD.SettingsDisplayOrderPrev ~= nil then
        pcall(function()
            SettingsLib.UI.DisplayOrder = HUD.SettingsDisplayOrderPrev
        end)
        HUD.SettingsDisplayOrderPrev = nil
    end
    for _, conn in pairs(HUD.Connections) do pcall(function() conn:Disconnect() end) end
    HUD.Connections = {}
    for _, conn in pairs(HUD.ResizeConnections) do pcall(function() conn:Disconnect() end) end
    HUD.ResizeConnections = {}
    for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
    HUD.ResizeHandles = {}
    HUD.SelectedElement = nil
    for _, stroke in pairs(HUD.Strokes) do
        pcall(function() if stroke and stroke.Parent then stroke:Destroy() end end)
    end
    HUD.Strokes = {}

    if HUD.SelectionGui then
        pcall(function() HUD.SelectionGui:Destroy() end)
        HUD.SelectionGui = nil
    end
    for _, el in pairs(getMovableElements()) do
        local h = el:FindFirstChild("HUDDragHandle")
        if h then h:Destroy() end
        if el:FindFirstChildOfClass("UIListLayout") then
            for _, child in pairs(el:GetChildren()) do
                if child:IsA("GuiButton") or child:IsA("TextBox") then
                    child.Active = true
                end
            end
        end
    end
    if HUD.Overlay then
        for _, g in pairs(HUD.Overlay:GetChildren()) do
            if g.Name == "SnapGuide" then g:Destroy() end
        end
    end
    if HUD.Overlay and HUD.Overlay.Parent then HUD.Overlay:Destroy() end
    HUD.Overlay = nil
    if HUD.ForceVisibleConn then HUD.ForceVisibleConn:Disconnect(); HUD.ForceVisibleConn = nil end
    if UI.Search then UI.Search.TextEditable = true; UI.Search.Active = true end
    if UI.SpeedBox then UI.SpeedBox.TextEditable = true; UI.SpeedBox.Active = true end
    if UI._2Routenumber then UI._2Routenumber.TextEditable = true; UI._2Routenumber.Active = true end
    pcall(function() game:GetService("GuiService"):SetEmotesMenuOpen(false) end)
    pcall(function() game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel.Visible = false end)
end

enterHUDEditor = function()
    if State.hudEditorActive then return end
    State.hudEditorActive = true
    HUD.UndoStack = {}

    GuiService:SetEmotesMenuOpen(false)
    task.wait(0.15)

    local exists, emotesWheel = checkEmotesMenuExists()
    if not exists then State.hudEditorActive = false; return end
    emotesWheel.Visible = true

    HUD.ForceVisibleConn = RunService.Heartbeat:Connect(function()
        if not State.hudEditorActive then return end
        pcall(function()
            local _, ew = checkEmotesMenuExists()
            if ew then ew.Visible = true end
        end)
    end)

    local main = getSettingsMainFrame()
    if main then main.Visible = false end
    syncToggleVisibility()
    if SettingsLib and SettingsLib.UI and SettingsLib.UI:IsA("ScreenGui") then
        if HUD.SettingsDisplayOrderPrev == nil then
            HUD.SettingsDisplayOrderPrev = SettingsLib.UI.DisplayOrder
        end
        pcall(function() SettingsLib.UI.DisplayOrder = 99998 end)
    end
    ApplyUIVisibility()

    local selectionGui = game:GetService("CoreGui"):FindFirstChild("7yd7_HUDSelection")
    if not selectionGui then
        selectionGui = Instance.new("ScreenGui")
        selectionGui.Name = "7yd7_HUDSelection"
        selectionGui.IgnoreGuiInset = false
        selectionGui.DisplayOrder = 99999
        selectionGui.Parent = game:GetService("CoreGui")
    else
        selectionGui.IgnoreGuiInset = false
        selectionGui.DisplayOrder = 99999
    end
    HUD.SelectionGui = selectionGui

    local overlay = Instance.new("Frame")
    overlay.Name = "HUDEditorOverlay"
    overlay.Parent = SettingsLib.UI
    overlay.BackgroundTransparency = 1
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.ZIndex = 6000
    overlay.Active = false
    HUD.Overlay = overlay
    table.insert(HUD.Connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if not State.hudEditorActive then return end
        if input.KeyCode == Enum.KeyCode.Z then
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
                undoLastHUD()
            end
        end
    end))
    table.insert(HUD.Connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            local p = input.Position
            if HUD.SelectedElement then
                local e = HUD.SelectedElement
                local pos = e.AbsolutePosition
                local sz = e.AbsoluteSize
                if p.X < pos.X - 25 or p.X > pos.X + sz.X + 25 or p.Y < pos.Y - 25 or p.Y > pos.Y + sz.Y + 25 then
                    task.delay(0.1, function()
                        if HUD.SelectedElement == e then
                            HUD.SelectedElement = nil
                            for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
                            HUD.ResizeHandles = {}
                            for _, c in pairs(HUD.ResizeConnections) do pcall(function() c:Disconnect() end) end
                            HUD.ResizeConnections = {}
                        end
                    end)
                end
            end
        end
    end))

    local bc = Instance.new("Frame")
    bc.Parent = overlay
    bc.BackgroundTransparency = 1
    bc.AnchorPoint = Vector2.new(1, 0)
    bc.Position = UDim2.new(1, -10, 0, 10)
    bc.Size = UDim2.fromOffset(360, 42)
    bc.ZIndex = 6000

    local bl = Instance.new("UIListLayout")
    bl.FillDirection = Enum.FillDirection.Horizontal
    bl.Padding = UDim.new(0, 8)
    bl.HorizontalAlignment = Enum.HorizontalAlignment.Right
    bl.VerticalAlignment = Enum.VerticalAlignment.Center
    bl.Parent = bc

    local propertiesBtn = Instance.new("ImageButton")
    propertiesBtn.Parent = bc
    propertiesBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    propertiesBtn.BackgroundTransparency = 0.4
    propertiesBtn.Size = UDim2.fromOffset(42, 42)
    propertiesBtn.Image = "rbxassetid://111026029750357"
    propertiesBtn.ZIndex = 6001
    local propCorner = Instance.new("UICorner")
    propCorner.CornerRadius = UDim.new(0, 10)
    propCorner.Parent = propertiesBtn

    local exportBtn = Instance.new("ImageButton")
    exportBtn.Parent = bc
    exportBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    exportBtn.BackgroundTransparency = 0.4
    exportBtn.Size = UDim2.fromOffset(42, 42)
    exportBtn.Image = "rbxassetid://107588515524752"
    exportBtn.ZIndex = 6001
    local exportCorner = Instance.new("UICorner")
    exportCorner.CornerRadius = UDim.new(0, 10)
    exportCorner.Parent = exportBtn

    local importBtn = Instance.new("ImageButton")
    importBtn.Parent = bc
    importBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    importBtn.BackgroundTransparency = 0.4
    importBtn.Size = UDim2.fromOffset(42, 42)
    importBtn.Image = "rbxassetid://78317476576895"
    importBtn.ZIndex = 6001
    local importCorner = Instance.new("UICorner")
    importCorner.CornerRadius = UDim.new(0, 10)
    importCorner.Parent = importBtn

    local resetBtn = Instance.new("ImageButton")
    resetBtn.Parent = bc
    resetBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    resetBtn.BackgroundTransparency = 0.4
    resetBtn.Size = UDim2.fromOffset(42, 42)
    resetBtn.Image = "rbxassetid://123088523596870"
    resetBtn.ZIndex = 6001
    local resetCorner = Instance.new("UICorner")
    resetCorner.CornerRadius = UDim.new(0, 10)
    resetCorner.Parent = resetBtn

    local lockBtn = Instance.new("ImageButton")
    lockBtn.Parent = bc
    lockBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    lockBtn.BackgroundTransparency = 0.4
    lockBtn.Size = UDim2.fromOffset(42, 42)
    lockBtn.Image = HUD.IsUnlocked and "rbxassetid://137042445663198" or "rbxassetid://137985778533954"
    lockBtn.ZIndex = 6001
    local lockCorner = Instance.new("UICorner")
    lockCorner.CornerRadius = UDim.new(0, 10)
    lockCorner.Parent = lockBtn

    local addBtn = Instance.new("ImageButton")
    addBtn.Parent = bc
    addBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    addBtn.BackgroundTransparency = 0.4
    addBtn.Size = UDim2.fromOffset(42, 42)
    addBtn.Image = "rbxassetid://108445456753346"
    addBtn.ZIndex = 6001
    local addCorner = Instance.new("UICorner")
    addCorner.CornerRadius = UDim.new(0, 10)
    addCorner.Parent = addBtn

    local backBtn = Instance.new("ImageButton")
    backBtn.Parent = bc
    backBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    backBtn.BackgroundTransparency = 0.4
    backBtn.Size = UDim2.fromOffset(42, 42)
    backBtn.Image = "rbxassetid://79024388644722"
    backBtn.ZIndex = 6001
    local backCorner = Instance.new("UICorner")
    backCorner.CornerRadius = UDim.new(0, 10)
    backCorner.Parent = backBtn



    local function rebuildHUDOverlays()
        for _, conn in pairs(HUD.ResizeConnections) do pcall(function() conn:Disconnect() end) end
        HUD.ResizeConnections = {}
        for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
        HUD.ResizeHandles = {}
        for _, stroke in pairs(HUD.Strokes) do pcall(function() stroke:Destroy() end) end
        HUD.Strokes = {}
        if selectionGui then selectionGui:ClearAllChildren() end
        HUD.SelectedElement = nil
        
        local allMovable = getMovableElements()
        
        local snapGuideH = Instance.new("Frame")
        snapGuideH.Name = "SnapGuide"
        snapGuideH.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
        snapGuideH.BorderSizePixel = 0
        snapGuideH.Size = UDim2.new(1, 0, 0, 1)
        snapGuideH.ZIndex = 6002
        snapGuideH.Visible = false
        snapGuideH.Parent = selectionGui

        local snapGuideV = Instance.new("Frame")
        snapGuideV.Name = "SnapGuide"
        snapGuideV.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
        snapGuideV.BorderSizePixel = 0
        snapGuideV.Size = UDim2.new(0, 1, 1, 0)
        snapGuideV.ZIndex = 6002
        snapGuideV.Visible = false
        snapGuideV.Parent = selectionGui

        for name, element in pairs(allMovable) do
            setupElementDragging(name, element, allMovable, snapGuideV, snapGuideH)
        end
        
        updateHUDLayouts()
        
        applySavedPositions()
    end

    local function rebuildCustomFramesFromConfig()
        if UI.CustomFrames then
            for _, frame in pairs(UI.CustomFrames) do
                if frame and frame.Parent then frame:Destroy() end
            end
        end
        UI.CustomFrames = {}

        if not Config.CustomFrames then return end
        local _, emotesWheel = checkEmotesMenuExists()
        if not emotesWheel then return end

        for name, data in pairs(Config.CustomFrames) do
            local cf = Instance.new("Frame")
            cf.Name = name
            cf.Parent = emotesWheel
            cf.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            cf.BackgroundTransparency = 0.4
            cf.ZIndex = data and data.ZIndex or 3
            cf.BorderSizePixel = 0
            cf.Active = true

            local pos = Config.HUDPositions and Config.HUDPositions[name]
            local size = Config.HUDSizes and Config.HUDSizes[name]
            if pos and type(pos) == "table" and #pos == 4 then
                cf.Position = UDim2.new(pos[1], pos[2], pos[3], pos[4])
            else
                cf.Position = UDim2.new(0.5, 0, 0.5, 0)
            end
            if size and type(size) == "table" and #size == 4 then
                cf.Size = UDim2.new(size[1], size[2], size[3], size[4])
            else
                cf.Size = UDim2.new(0.3, 0, 0.3, 0)
            end

            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 10)
            corner.Parent = cf

            UI.CustomFrames[name] = cf
            HUD.DefaultPositions[name] = cf.Position
            HUD.DefaultSizes[name] = cf.Size
        end
    end

    local function applyHUDSettingsReplace(settings)
        local function normalizeImportTable(tbl)
            if type(tbl) ~= "table" then return {} end
            local allElems = getAllHUDObjects()
            for eName, v in pairs(tbl) do
                if type(v) == "table" and #v == 4 then
                    local sx, ox, sy, oy = v[1], v[2], v[3], v[4]
                    if ox ~= 0 or oy ~= 0 then
                        local el = allElems[eName]
                        local ps = el and el.Parent and el.Parent.AbsoluteSize
                        if ps and ps.X > 0 and ps.Y > 0 then
                            tbl[eName] = {sx + (ox / ps.X), 0, sy + (oy / ps.Y), 0}
                        end
                    end
                end
            end
            return tbl
        end
        Config.HUDPositions = normalizeImportTable(settings.HUDPositions or {})
        Config.HUDSizes = normalizeImportTable(settings.HUDSizes or {})
        Config.HUDProperties = settings.HUDProperties or {}
        Config.CustomFrames = settings.CustomFrames or {}
        HUD.LayoutsRemoved = {}
        SaveConfig()
        rebuildCustomFramesFromConfig()
        applySavedPositions()

        rebuildHUDOverlays()
        updateHUDLayouts()
        ApplyUIVisibility()
        pcall(function() updateGUIColors() end)
    end

    table.insert(HUD.Connections, lockBtn.MouseButton1Click:Connect(function()
        HUD.IsUnlocked = not HUD.IsUnlocked
        lockBtn.Image = HUD.IsUnlocked and "rbxassetid://137042445663198" or "rbxassetid://137985778533954"
        rebuildHUDOverlays()
        pcall(function() updateGUIColors() end)
        getgenv().Notify({ 
            Title = "7yd7 | HUD Editor", 
            Content = HUD.IsUnlocked and "🔓 Interior Unlocked! Children are now editable." or "🔒 Interior Locked! Top-level only.", 
            Duration = 2 
        })
    end))

    rebuildHUDOverlays()

    table.insert(HUD.Connections, exportBtn.MouseButton1Click:Connect(function()
        local function normalizeExportTable(tbl)
            if type(tbl) ~= "table" then return {} end
            local out = {}
            local allElems = getAllHUDObjects()
            for eName, v in pairs(tbl) do
                if type(v) == "table" and #v == 4 then
                    local sx, ox, sy, oy = v[1], v[2], v[3], v[4]
                    if ox ~= 0 or oy ~= 0 then
                        local el = allElems[eName]
                        local ps = el and el.Parent and el.Parent.AbsoluteSize
                        if ps and ps.X > 0 and ps.Y > 0 then
                            sx = sx + (ox / ps.X)
                            sy = sy + (oy / ps.Y)
                        end
                    end
                    out[eName] = {sx, 0, sy, 0}
                else
                    out[eName] = v
                end
            end
            return out
        end
        local function normalizeExportProps(props)
            if type(props) ~= "table" then return {} end
            local out = {}
            local allElems = getAllHUDObjects()
            for eName, p in pairs(props) do
                local ep = {}
                for k, v in pairs(p) do
                    if (k == "CornerRadius" or k == "Radius") and type(v) == "table" and #v == 2 then
                        local rs, ro = v[1], v[2]
                        if ro ~= 0 and rs == 0 then
                            local el = allElems[eName]
                            if el then
                                local minDim = math.min(el.AbsoluteSize.X, el.AbsoluteSize.Y)
                                if minDim > 0 then
                                    rs = ro / minDim
                                    ro = 0
                                end
                            end
                        end
                        ep[k] = {rs, ro}
                    else
                        ep[k] = v
                    end
                end
                out[eName] = ep
            end
            return out
        end
        local data = {
            Type = "HUD",
            Settings = {
                HUDPositions = normalizeExportTable(Config.HUDPositions or {}),
                HUDSizes = normalizeExportTable(Config.HUDSizes or {}),
                HUDProperties = normalizeExportProps(Config.HUDProperties or {}),
                CustomFrames = Config.CustomFrames or {}
            }
        }
        setclipboard(HttpService:JSONEncode(data))
        getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "✅ HUD settings copied", Duration = 2 })
    end))

    table.insert(HUD.Connections, importBtn.MouseButton1Click:Connect(function()
        local popup, content = CreatePopup("Import HUD", UDim2.fromOffset(320, 240))
        local popupRoot = HUD.SelectionGui or SettingsLib.UI
        if popupRoot and popup.Parent ~= popupRoot then
            popup.Parent = popupRoot
        end

        local baseZ = 7000
        popup.ZIndex = baseZ

        local backdrop = Instance.new("TextButton")
        backdrop.Name = "HUDImportBackdrop"
        backdrop.Parent = popup.Parent
        backdrop.Size = UDim2.fromScale(1, 1)
        backdrop.BackgroundTransparency = 1
        backdrop.Text = ""
        backdrop.AutoButtonColor = false
        backdrop.ZIndex = baseZ - 1
        backdrop.Active = true

        local scroll = Instance.new("ScrollingFrame")
        scroll.Parent = content
        scroll.BackgroundTransparency = 1
        scroll.BorderSizePixel = 0
        scroll.Position = UDim2.new(0.05, 0, 0, 5)
        scroll.Size = UDim2.new(0.9, 0, 0, 130)
        scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
        scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        scroll.ScrollBarThickness = 4
        scroll.Active = true
        scroll.ScrollingEnabled = true
        scroll.ScrollingDirection = Enum.ScrollingDirection.Y
        scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable

        local box = CreateInput(scroll, "Paste HUD JSON here...", "", true)
        box.Size = UDim2.new(1, -8, 0, 130)
        box.Position = UDim2.new(0, 0, 0, 0)
        box.TextYAlignment = Enum.TextYAlignment.Top
        box.ClearTextOnFocus = false

        local function updateCanvas()
            local padding = 8
            local h = math.max(130, (box.TextBounds.Y or 0) + padding)
            scroll.CanvasSize = UDim2.new(0, 0, 0, h)
        end
        box:GetPropertyChangedSignal("Text"):Connect(updateCanvas)
        box:GetPropertyChangedSignal("TextBounds"):Connect(updateCanvas)
        updateCanvas()

        local imp = CreateButton(content, "IMPORT HUD", (State.EmoteTheme and State.EmoteTheme.Accent) or Color3.fromRGB(0, 255, 150), UDim2.new(0.05, 0, 0.8, 0), UDim2.new(0.9, 0, 0, 35))

        imp.MouseButton1Click:Connect(function()
            local s, d = pcall(function() return HttpService:JSONDecode(box.Text) end)
            if s and type(d) == "table" then
                local settings = d.Settings or d
                if d.Type and d.Type ~= "HUD" then
                    getgenv().Notify({ Title = "Error", Content = "HUD import type mismatch!", Duration = 3 })
                    return
                end
                if type(settings) ~= "table" then
                    getgenv().Notify({ Title = "Error", Content = "Invalid HUD JSON", Duration = 3 })
                    return
                end
                applyHUDSettingsReplace(settings)
                HUD.UndoStack = {}
                if backdrop then backdrop:Destroy() end
                popup:Destroy()
                getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "✅ HUD settings imported", Duration = 2 })
            else
                getgenv().Notify({ Title = "Error", Content = "Invalid HUD JSON", Duration = 3 })
            end
        end)

        local close = Instance.new("TextButton")
        close.Size = UDim2.fromOffset(24, 24)
        close.Position = UDim2.new(1, -30, 0, 5)
        close.Text = "×"
        close.Font = Enum.Font.GothamBold
        close.TextSize = 20
        close.BackgroundTransparency = 1
        close.TextColor3 = Color3.new(1,1,1)
        close.ZIndex = baseZ + 2
        close.Active = true
        close.AutoButtonColor = false
        close.Parent = popup
        close.MouseButton1Click:Connect(function()
            if backdrop then backdrop:Destroy() end
            popup:Destroy()
        end)
        backdrop.MouseButton1Click:Connect(function()
            if backdrop then backdrop:Destroy() end
            popup:Destroy()
        end)

        local function bumpPopupZIndex(panel, z)
            if not panel then return end
            panel.ZIndex = z
            for _, d in ipairs(panel:GetDescendants()) do
                if d:IsA("GuiObject") then
                    d.ZIndex = z + 1
                end
            end
        end
        bumpPopupZIndex(popup, baseZ)
        close.ZIndex = baseZ + 2
    end))

    table.insert(HUD.Connections, backBtn.MouseButton1Click:Connect(function()
        exitHUDEditor()
    end))

    table.insert(HUD.Connections, resetBtn.MouseButton1Click:Connect(function()
        Config.HUDPositions = {}
        Config.HUDSizes = {}
        Config.CustomFrames = {}
        Config.HUDProperties = {}
        HUD.LayoutsRemoved = {}
        SaveConfig()
        
        local allElements = getAllHUDObjects()
        for name, el in pairs(allElements) do
            if name:match("^CustomFrame_") then
                el:Destroy()
                if UI.CustomFrames then UI.CustomFrames[name] = nil end
            else
                if HUD.DefaultPositions[name] then el.Position = HUD.DefaultPositions[name] end
                if HUD.DefaultSizes[name] then el.Size = HUD.DefaultSizes[name] end
                
                for internal, friendly in pairs(HUD.FriendlyNames) do
                    if name == friendly then
                        if internal:match("^Under%.") then
                            el.Parent = UI.Under
                        elseif internal:match("^Top%.") then
                            el.Parent = UI.Top
                        end
                        break
                    end
                end

                el.ZIndex = (name == "Top" or name == "Under") and 3 or (el:IsA("ImageButton") and 4 or 3)
                if name == "Under" then
                    el.BackgroundTransparency = 1
                else
                    el.BackgroundTransparency = (name == "Top" or name == "Reload" or name == "Changepage" or name == "EmoteWalkButton" or name == "SpeedBox" or name == "SpeedEmote" or name == "Favorite") and 0.4 or 1
                end
                
                if el:IsA("ImageButton") or el:IsA("ImageLabel") then
                    el.ImageTransparency = 0
                end
                
                if el:IsA("TextLabel") or el:IsA("TextBox") then
                    el.TextTransparency = 0.4
                    if HUD.DefaultTexts and HUD.DefaultTexts[name] then
                        el.Text = HUD.DefaultTexts[name]
                    end
                    if el:IsA("TextBox") and HUD.DefaultPlaceholders and HUD.DefaultPlaceholders[name] then
                        el.PlaceholderText = HUD.DefaultPlaceholders[name]
                    end
                end

                local cR = el:FindFirstChildWhichIsA("UICorner")
                if cR then
                    cR.CornerRadius = UDim.new(0, 10)
                end
            end
        end

        pcall(function() updateGUIColors() end)
        
        HUD.SelectedElement = nil
        for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
        HUD.ResizeHandles = {}
        for _, c in pairs(HUD.ResizeConnections) do pcall(function() c:Disconnect() end) end
        HUD.ResizeConnections = {}
        
        rebuildHUDOverlays()
        updateHUDLayouts()
        ApplyUIVisibility()
        State.totalPages = calculateTotalPages()
        if State.currentPage > State.totalPages then
            State.currentPage = State.totalPages
        end
        updatePageDisplay()
        
        getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "🔄 All designs and frames have been fully reset", Duration = 3 })
    end))

    local propertiesPanel = Instance.new("Frame")
    propertiesPanel.Name = "HUDPropertiesPanel"
    propertiesPanel.Parent = overlay
    propertiesPanel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    propertiesPanel.BackgroundTransparency = 0.4
    propertiesPanel.Size = UDim2.fromOffset(260, 150)
    propertiesPanel.AnchorPoint = Vector2.new(1, 0)
    propertiesPanel.Position = UDim2.new(1, -10, 0, 60)
    propertiesPanel.Visible = false
    propertiesPanel.ZIndex = 6005
    propertiesPanel.ClipsDescendants = true
    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 10)
    panelCorner.Parent = propertiesPanel
    
    local title = Instance.new("TextLabel")
    title.Parent = propertiesPanel
    title.BackgroundTransparency = 1
    title.Size = UDim2.new(1, 0, 0, 26)
    title.Position = UDim2.new(0, 0, 0, 2)
    title.Font = Enum.Font.SourceSansBold
    title.Text = "No Element"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.TextSize = 14
    title.TextScaled = true
    title.ZIndex = 6006

    local propContent = Instance.new("ScrollingFrame")
    propContent.Parent = propertiesPanel
    propContent.BackgroundTransparency = 1
    propContent.Position = UDim2.new(0, 0, 0, 28)
    propContent.Size = UDim2.new(1, 0, 1, -32)
    propContent.CanvasSize = UDim2.new(0, 0, 0, 0)
    propContent.ScrollBarThickness = 2
    propContent.Active = true
    propContent.ScrollingEnabled = true
    propContent.ZIndex = 6006

    local propLayout = Instance.new("UIListLayout")
    propLayout.Parent = propContent
    propLayout.SortOrder = Enum.SortOrder.LayoutOrder
    propLayout.Padding = UDim.new(0, 6)
    propLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    HUD.LastTouchedElement = nil
    HUD.LastTouchedName = nil

    local function createPropRow(label, lOrder, isLarge)
        local row = Instance.new("Frame")
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(0.92, 0, 0, isLarge and 50 or 26)
        row.LayoutOrder = lOrder
        row.ZIndex = 6006
        row.Parent = propContent

        local lbl = Instance.new("TextLabel")
        lbl.Parent = row
        lbl.Size = UDim2.new(0, 70, 0, 26)
        lbl.BackgroundTransparency = 1
        lbl.Text = label
        lbl.TextColor3 = Color3.fromRGB(180, 180, 180)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Font = Enum.Font.SourceSansBold
        lbl.TextSize = 12
        lbl.ZIndex = 6007

        local tbox = Instance.new("TextBox")
        tbox.Parent = row
        tbox.Size = UDim2.new(1, -75, 1, -4)
        tbox.Position = UDim2.new(0, 75, 0, 2)
        tbox.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        tbox.BackgroundTransparency = 0.3
        tbox.TextColor3 = Color3.fromRGB(255, 255, 255)
        tbox.Font = Enum.Font.Code
        tbox.TextSize = 12
        tbox.TextXAlignment = isLarge and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
        tbox.TextYAlignment = isLarge and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center
        tbox.ClearTextOnFocus = false
        tbox.TextWrapped = isLarge
        tbox.PlaceholderText = ""
        tbox.PlaceholderColor3 = Color3.fromRGB(80, 80, 80)
        tbox.ZIndex = 6007
        local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(0, 6); tc.Parent = tbox

        return row, tbox
    end

    local _, posBox = createPropRow("Position", 1)
    local _, sizeBox = createPropRow("Size", 2)
    local zRow, zBox = createPropRow("ZIndex", 3)
    local bgRow, bgBox = createPropRow("BgTrans", 4)
    local bgcRow, bgcBox = createPropRow("BgColor", 5)
    local imgRow, imgBox = createPropRow("ImgTrans", 6)
    local imgcRow, imgcBox = createPropRow("ImgColor", 7)
    local radRow, radBox = createPropRow("Radius", 8)
    local txtRow, txtBox = createPropRow("Text", 9, true)
    local phRow, phBox = createPropRow("Placeholder", 10, true)
    local ttrRow, ttrBox = createPropRow("TxtTrans", 11)
    local txtcRow, txtcBox = createPropRow("TxtColor", 12)

    local deleteRow = Instance.new("Frame")
    deleteRow.BackgroundTransparency = 1
    deleteRow.Size = UDim2.new(0.92, 0, 0, 28)
    deleteRow.LayoutOrder = 13
    deleteRow.ZIndex = 6006
    deleteRow.Parent = propContent

    local deleteBtn = Instance.new("TextButton")
    deleteBtn.Parent = deleteRow
    deleteBtn.Size = UDim2.new(1, 0, 1, 0)
    deleteBtn.BackgroundColor3 = Color3.fromRGB(170, 60, 60)
    deleteBtn.BackgroundTransparency = 0.1
    deleteBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    deleteBtn.Font = Enum.Font.GothamBold
    deleteBtn.TextSize = 12
    deleteBtn.Text = "Delete Custom Frame"
    deleteBtn.ZIndex = 6007
    local delCorner = Instance.new("UICorner"); delCorner.CornerRadius = UDim.new(0, 6); delCorner.Parent = deleteBtn



    local function parseUDim2(text)
        local s1, o1, s2, o2 = text:match("{%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*}%s*,%s*{%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*}")
        if s1 and o1 and s2 and o2 then
            return tonumber(s1), tonumber(o1), tonumber(s2), tonumber(o2)
        end
        local a, b = text:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)")
        if a and b then
            local va, vb = tonumber(a), tonumber(b)
            if va and vb then
                return 0, va, 0, vb
            end
        end
        return nil
    end

    local function formatUDim2(udim)
        return string.format("{%g, %g},{%g, %g}", udim.X.Scale, udim.X.Offset, udim.Y.Scale, udim.Y.Offset)
    end

    table.insert(HUD.Connections, propertiesBtn.MouseButton1Click:Connect(function()
        propertiesPanel.Visible = not propertiesPanel.Visible
    end))

    local function formatUDim(udim)
        return string.format("{%g, %g}", udim.Scale, udim.Offset)
    end

    local function formatRGB(c)
        return string.format("%d, %d, %d", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
    end

    local function parseRGB(text)
        local a, b, c = text:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)")
        if not a then return nil end
        local r, g, b2 = tonumber(a), tonumber(b), tonumber(c)
        if not r or not g or not b2 then return nil end
        local maxv = math.max(r, g, b2)
        if maxv <= 1 then
            r, g, b2 = r * 255, g * 255, b2 * 255
        end
        r = math.clamp(r, 0, 255)
        g = math.clamp(g, 0, 255)
        b2 = math.clamp(b2, 0, 255)
        return r, g, b2
    end

    table.insert(HUD.Connections, RunService.RenderStepped:Connect(function()
        if not propertiesPanel.Visible then return end
        local e = HUD.LastTouchedElement
        local eName = HUD.LastTouchedName
        if e and e.Parent then
            title.Text = string.format("[%s] %s", e.ClassName, eName or "Unknown")
            if not posBox:IsFocused() then posBox.Text = formatUDim2(e.Position) end
            if not sizeBox:IsFocused() then sizeBox.Text = formatUDim2(e.Size) end
            
            zRow.Visible = true
            if not zBox:IsFocused() then zBox.Text = tostring(e.ZIndex) end

            bgRow.Visible = true
            if not bgBox:IsFocused() then bgBox.Text = tostring(math.floor(e.BackgroundTransparency * 100) / 100) end

            if e:IsA("ImageLabel") or e:IsA("ImageButton") then
                imgRow.Visible = true
                if not imgBox:IsFocused() then imgBox.Text = tostring(math.floor(e.ImageTransparency * 100) / 100) end
            else
                imgRow.Visible = false
            end
            
            bgcRow.Visible = true
            if not bgcBox:IsFocused() then bgcBox.Text = formatRGB(e.BackgroundColor3) end
            
            if e:IsA("ImageLabel") or e:IsA("ImageButton") then
                imgcRow.Visible = true
                if not imgcBox:IsFocused() then imgcBox.Text = formatRGB(e.ImageColor3) end
            else
                imgcRow.Visible = false
            end
            
            if e:IsA("TextLabel") or e:IsA("TextBox") then
                ttrRow.Visible = true
                if not ttrBox:IsFocused() then ttrBox.Text = tostring(math.floor(e.TextTransparency * 100) / 100) end
                
                txtRow.Visible = true
                if not txtBox:IsFocused() then txtBox.Text = e.Text end

                txtcRow.Visible = true
                if not txtcBox:IsFocused() then txtcBox.Text = formatRGB(e.TextColor3) end
                
                if e:IsA("TextBox") then
                    phRow.Visible = true
                    if not phBox:IsFocused() then phBox.Text = e.PlaceholderText end
                else
                    phRow.Visible = false
                end
            else
                ttrRow.Visible = false
                txtRow.Visible = false
                phRow.Visible = false
                txtcRow.Visible = false
            end

            deleteRow.Visible = (eName and eName:match("^CustomFrame_")) and true or false


            local cR = e:FindFirstChildWhichIsA("UICorner")
            if cR then
                radRow.Visible = true
                if not radBox:IsFocused() then radBox.Text = formatUDim(cR.CornerRadius) end
            else
                radRow.Visible = false
            end
        else
            title.Text = "No Element Selected"
            zRow.Visible = false
            bgRow.Visible = false
            imgRow.Visible = false
            bgcRow.Visible = false
            imgcRow.Visible = false
            radRow.Visible = false
            ttrRow.Visible = false
            txtRow.Visible = false
            phRow.Visible = false
            txtcRow.Visible = false
            deleteRow.Visible = false
            if not posBox:IsFocused() then posBox.Text = "" end
            if not sizeBox:IsFocused() then sizeBox.Text = "" end
        end
        
        local totalH = propLayout.AbsoluteContentSize.Y + 10
        propContent.CanvasSize = UDim2.new(0, 0, 0, totalH)
        local vpY = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 800
        local maxH = math.floor(vpY * 0.55)
        propertiesPanel.Size = UDim2.fromOffset(260, math.min(maxH, totalH + 40))
    end))

    local function saveHUDProp(eName, propKey, val)
        if not Config.HUDProperties then Config.HUDProperties = {} end
        if not Config.HUDProperties[eName] then Config.HUDProperties[eName] = {} end
        Config.HUDProperties[eName][propKey] = val
        SaveConfig()
    end

    table.insert(HUD.Connections, deleteBtn.MouseButton1Click:Connect(function()
        local eName = HUD.LastTouchedName
        if not eName or not eName:match("^CustomFrame_") then return end
        local frame = UI.CustomFrames and UI.CustomFrames[eName]
        if frame and frame.Parent then frame:Destroy() end
        if UI.CustomFrames then UI.CustomFrames[eName] = nil end
        if Config.CustomFrames then Config.CustomFrames[eName] = nil end
        if Config.HUDPositions then Config.HUDPositions[eName] = nil end
        if Config.HUDSizes then Config.HUDSizes[eName] = nil end
        if Config.HUDProperties then Config.HUDProperties[eName] = nil end
        if HUD.DefaultPositions then HUD.DefaultPositions[eName] = nil end
        if HUD.DefaultSizes then HUD.DefaultSizes[eName] = nil end
        if HUD.DefaultTexts then HUD.DefaultTexts[eName] = nil end
        if HUD.DefaultPlaceholders then HUD.DefaultPlaceholders[eName] = nil end
        SaveConfig()

        HUD.SelectedElement = nil
        HUD.LastTouchedElement = nil
        HUD.LastTouchedName = nil
        for _, h in pairs(HUD.ResizeHandles) do pcall(function() h:Destroy() end) end
        HUD.ResizeHandles = {}
        for _, c in pairs(HUD.ResizeConnections) do pcall(function() c:Disconnect() end) end
        HUD.ResizeConnections = {}

        rebuildHUDOverlays()
        updateHUDLayouts()
        ApplyUIVisibility()
        pcall(function() updateGUIColors() end)
        getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "🗑️ Custom Frame deleted", Duration = 2 })
    end))



    table.insert(HUD.Connections, posBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local s1, o1, s2, o2 = parseUDim2(posBox.Text)
        if s1 then
            local prev = captureHUDState(eName, e)
            e.Position = UDim2.new(s1, o1, s2, o2)
            if prev and not sameUDim2(prev.pos, e.Position) then
                pushUndo(prev)
            end
            Config.HUDPositions[eName] = {s1, o1, s2, o2}
        end
    end))

    table.insert(HUD.Connections, sizeBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local s1, o1, s2, o2 = parseUDim2(sizeBox.Text)
        if s1 then
            local prev = captureHUDState(eName, e)
            e.Size = UDim2.new(s1, o1, s2, o2)
            if prev and not sameUDim2(prev.size, e.Size) then
                pushUndo(prev)
            end
            if not Config.HUDSizes then Config.HUDSizes = {} end
            Config.HUDSizes[eName] = {s1, o1, s2, o2}
        end
    end))

    table.insert(HUD.Connections, zBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local v = tonumber(zBox.Text)
        if v then
            local prev = captureHUDState(eName, e)
            e.ZIndex = v
            if prev and prev.z ~= e.ZIndex then
                pushUndo(prev)
            end
            saveHUDProp(eName, "ZIndex", v)
        end
    end))

    table.insert(HUD.Connections, bgBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local v = tonumber(bgBox.Text)
        if v then
            local prev = captureHUDState(eName, e)
            e.BackgroundTransparency = math.clamp(v, 0, 1)
            if prev and prev.bgTrans ~= e.BackgroundTransparency then
                pushUndo(prev)
            end
            saveHUDProp(eName, "BgTrans", e.BackgroundTransparency)
        end
    end))

    table.insert(HUD.Connections, imgBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local v = tonumber(imgBox.Text)
        if v and (e:IsA("ImageLabel") or e:IsA("ImageButton")) then
            local prev = captureHUDState(eName, e)
            e.ImageTransparency = math.clamp(v, 0, 1)
            if prev and prev.imgTrans ~= e.ImageTransparency then
                pushUndo(prev)
            end
            saveHUDProp(eName, "ImgTrans", e.ImageTransparency)
        end
    end))
    
    table.insert(HUD.Connections, bgcBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local r, g, b = parseRGB(bgcBox.Text)
        if r then
            if isThemeDefaultRGB(r, g, b) then
                if Config.HUDProperties and Config.HUDProperties[eName] then
                    Config.HUDProperties[eName].BgColor = nil
                    if next(Config.HUDProperties[eName]) == nil then
                        Config.HUDProperties[eName] = nil
                    end
                    SaveConfig()
                end
                pcall(function() updateGUIColors() end)
                return
            end
            local prev = captureHUDState(eName, e)
            local c = Color3.fromRGB(r, g, b)
            pcall(function() e.BackgroundColor3 = c end)
            if prev and not sameColor(prev.bgColor, e.BackgroundColor3) then
                pushUndo(prev)
            end
            saveHUDProp(eName, "BgColor", {r, g, b})
        end
    end))
    
    table.insert(HUD.Connections, imgcBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        if not (e:IsA("ImageLabel") or e:IsA("ImageButton")) then return end
        local r, g, b = parseRGB(imgcBox.Text)
        if r then
            if isThemeDefaultRGB(r, g, b) then
                if Config.HUDProperties and Config.HUDProperties[eName] then
                    Config.HUDProperties[eName].ImgColor = nil
                    if next(Config.HUDProperties[eName]) == nil then
                        Config.HUDProperties[eName] = nil
                    end
                    SaveConfig()
                end
                pcall(function() updateGUIColors() end)
                return
            end
            local prev = captureHUDState(eName, e)
            local c = Color3.fromRGB(r, g, b)
            pcall(function() e.ImageColor3 = c end)
            if prev and prev.imgColor and not sameColor(prev.imgColor, e.ImageColor3) then
                pushUndo(prev)
            end
            saveHUDProp(eName, "ImgColor", {r, g, b})
        end
    end))

    table.insert(HUD.Connections, radBox.FocusLost:Connect(function(enter)
        if not enter then return end
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local a, b = radBox.Text:match("{%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*}")
        if not a and not b then a, b = radBox.Text:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)") end
        if a and b then
            local va, vb = tonumber(a), tonumber(b)
            if va and vb then
                local cR = e:FindFirstChildWhichIsA("UICorner")
                if cR then
                    local prev = captureHUDState(eName, e)
                    if vb ~= 0 and va == 0 then
                        local minDim = math.min(e.AbsoluteSize.X, e.AbsoluteSize.Y)
                        if minDim > 0 then
                            va = vb / minDim
                            vb = 0
                        end
                    end
                    cR.CornerRadius = UDim.new(va, vb)
                    if prev and prev.radius and not sameUDim(prev.radius, cR.CornerRadius) then
                        pushUndo(prev)
                    end
                    saveHUDProp(eName, "CornerRadius", {va, vb})
                end
            end
        end
    end))

    table.insert(HUD.Connections, txtBox.FocusLost:Connect(function(enter)
        if not enter then return end
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        if e:IsA("TextLabel") or e:IsA("TextBox") then
            local prev = captureHUDState(eName, e)
            e.Text = txtBox.Text
            if prev and prev.text ~= e.Text then
                pushUndo(prev)
            end
            saveHUDProp(eName, "Text", txtBox.Text)
        end
    end))

    table.insert(HUD.Connections, phBox.FocusLost:Connect(function(enter)
        if not enter then return end
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        if e:IsA("TextBox") then
            local prev = captureHUDState(eName, e)
            e.PlaceholderText = phBox.Text
            if prev and prev.placeholder ~= e.PlaceholderText then
                pushUndo(prev)
            end
            saveHUDProp(eName, "PlaceholderText", phBox.Text)
        end
    end))

    table.insert(HUD.Connections, ttrBox.FocusLost:Connect(function(enter)
        if not enter then return end
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        local v = tonumber(ttrBox.Text)
        if v and (e:IsA("TextLabel") or e:IsA("TextBox")) then
            local prev = captureHUDState(eName, e)
            e.TextTransparency = math.clamp(v, 0, 1)
            if prev and prev.textTrans ~= e.TextTransparency then
                pushUndo(prev)
            end
            saveHUDProp(eName, "TextTransparency", e.TextTransparency)
        end
    end))

    table.insert(HUD.Connections, txtcBox.FocusLost:Connect(function()
        local e, eName = HUD.LastTouchedElement, HUD.LastTouchedName
        if not e or not e.Parent or not eName then return end
        if not (e:IsA("TextLabel") or e:IsA("TextBox")) then return end
        local r, g, b = parseRGB(txtcBox.Text)
        if r then
            if isThemeDefaultRGB(r, g, b) then
                if Config.HUDProperties and Config.HUDProperties[eName] then
                    Config.HUDProperties[eName].TxtColor = nil
                    if next(Config.HUDProperties[eName]) == nil then
                        Config.HUDProperties[eName] = nil
                    end
                    SaveConfig()
                end
                pcall(function() updateGUIColors() end)
                return
            end
            local prev = captureHUDState(eName, e)
            local c = Color3.fromRGB(r, g, b)
            pcall(function() e.TextColor3 = c end)
            if prev and prev.textColor and not sameColor(prev.textColor, e.TextColor3) then
                pushUndo(prev)
            end
            saveHUDProp(eName, "TxtColor", {r, g, b})
        end
    end))




    if UI.Search then UI.Search.TextEditable = false; UI.Search.Active = false; pcall(function() UI.Search:ReleaseFocus() end) end
    if UI.SpeedBox then UI.SpeedBox.TextEditable = false; UI.SpeedBox.Active = false; pcall(function() UI.SpeedBox:ReleaseFocus() end) end
    if UI._2Routenumber then UI._2Routenumber.TextEditable = false; UI._2Routenumber.Active = false; pcall(function() UI._2Routenumber:ReleaseFocus() end) end

    local allMovable = getMovableElements()
    local snapGuideH = Instance.new("Frame")
    snapGuideH.Name = "SnapGuide"
    snapGuideH.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
    snapGuideH.BorderSizePixel = 0
    snapGuideH.Size = UDim2.new(1, 0, 0, 1)
    snapGuideH.ZIndex = 6002
    snapGuideH.Visible = false
    snapGuideH.Parent = overlay

    local snapGuideV = Instance.new("Frame")
    snapGuideV.Name = "SnapGuide"
    snapGuideV.BackgroundColor3 = Color3.fromRGB(0, 170, 255)
    snapGuideV.BorderSizePixel = 0
    snapGuideV.Size = UDim2.new(0, 1, 1, 0)
    snapGuideV.ZIndex = 6002
    snapGuideV.Visible = false
    snapGuideV.Parent = overlay

    for name, element in pairs(allMovable) do
        setupElementDragging(name, element, getMovableElements(), snapGuideV, snapGuideH)
    end

    table.insert(HUD.Connections, addBtn.MouseButton1Click:Connect(function()
        local nameIndex = 1
        while UI.CustomFrames and UI.CustomFrames["CustomFrame_"..nameIndex] do
            nameIndex = nameIndex + 1
        end
        local newName = "CustomFrame_"..nameIndex
        
        local _, emotesWheel = checkEmotesMenuExists()
        local cf = Instance.new("Frame")
        cf.Name = newName
        cf.Parent = emotesWheel
        cf.BackgroundTransparency = 0.4
        cf.ZIndex = 3
        cf.BorderSizePixel = 0
        cf.Active = true
        cf.Size = UDim2.new(0.3, 0, 0.3, 0)
        cf.Position = UDim2.new(0.5, 0, 0.5, 0)
        
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = cf

        if not UI.CustomFrames then UI.CustomFrames = {} end
        UI.CustomFrames[newName] = cf

        HUD.DefaultSizes[newName] = UDim2.new(0.3, 0, 0.3, 0)
        HUD.DefaultPositions[newName] = UDim2.new(0.5, 0, 0.5, 0)

        Config.HUDPositions[newName] = {0.5, 0, 0.5, 0}
        if not Config.HUDSizes then Config.HUDSizes = {} end
        Config.HUDSizes[newName] = {0.3, 0, 0.3, 0}
        if not Config.CustomFrames then Config.CustomFrames = {} end
        Config.CustomFrames[newName] = {ZIndex = 3}

        pcall(function() updateGUIColors() end)

        setupElementDragging(newName, cf, getMovableElements(), snapGuideV, snapGuideH)
        selectHUDElement(newName, cf)
        
        getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "➕ Custom Frame added!", Duration = 2 })
    end))

    getgenv().Notify({ Title = "7yd7 | HUD Editor", Content = "✏️ Drag elements to reposition", Duration = 5 })
end

State.RefreshUI = function()
    State.totalPages = calculateTotalPages()
    updatePageDisplay()
    if State.currentMode == "animation" then
        updateAnimations()
    else
        updateEmotes()
    end
end

State.RefreshSettingsUI = function()
    if TogglesUI then
        for key, toggle in pairs(TogglesUI) do
            if Config[key] ~= nil and toggle.SetState then
                toggle.SetState(Config[key])
            end
        end
    end
end

function checkAndRecreateGUI()
    local exists, emotesWheel = checkEmotesMenuExists()
    if not exists then
        State.isGUICreated = false
        return
    end

    if not emotesWheel:FindFirstChild("Under") or not emotesWheel:FindFirstChild("Top") or
        not emotesWheel:FindFirstChild("EmoteWalkButton") or not emotesWheel:FindFirstChild("Favorite") or
        not emotesWheel:FindFirstChild("SpeedEmote") or not emotesWheel:FindFirstChild("SpeedBox") or
        not emotesWheel:FindFirstChild("Changepage") or not emotesWheel:FindFirstChild("Reload") then
        State.isGUICreated = false
        if createGUIElements() then
            updatePageDisplay()
            updateEmotes()
            loadSpeedEmoteConfig()
        end
    end
end

if player.Character then
    onCharacterAdded(player.Character)
end

player.CharacterAdded:Connect(function(char)
    character = char
    humanoid = char:WaitForChild("Humanoid")
    onCharacterAdded(char)
    
    task.spawn(function()
        local attempts = 0
        while attempts < 20 do
            if checkEmotesMenuExists() then
                task.wait(0.2)
                if createGUIElements() then
                    updatePageDisplay()
                    updateEmotes()
                    updateGUIColors()
                    loadSpeedEmoteConfig()
                end
                break
            end
            attempts = attempts + 1
            task.wait(0.1)
        end
    end)
end)


RunService.Heartbeat:Connect(function()
    if not State.isGUICreated then
        checkAndRecreateGUI()
    else
        updateGUIColors()
        enforceImages()
    end
end)

RunService.Stepped:Connect(function()
    if humanoid and State.currentEmoteTrack and typeof(State.currentEmoteTrack) == "Instance" and State.currentEmoteTrack:IsA("AnimationTrack") and State.currentEmoteTrack.IsPlaying then
        if humanoid.MoveDirection.Magnitude > 0 then
            if State.toolEquipped or (State.speedEmoteEnabled and not State.emotesWalkEnabled) then
                State.currentEmoteTrack:Stop()
                State.currentEmoteTrack = nil
            end
        end
    end
end)

task.spawn(function()
    loadFavoritesAnimations()
    fetchAllEmotes()
    fetchAllAnimations()
    loadSpeedEmoteConfig()
end)

StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
task.spawn(function()
    while true do
        local robloxGui = game:GetService("CoreGui"):FindFirstChild("RobloxGui")
        local emotesMenu = robloxGui and robloxGui:FindFirstChild("EmotesMenu")

        if not emotesMenu then
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, true)

        else
            local exists = emotesMenu:FindFirstChild("Children") and emotesMenu.Children:FindFirstChild("Main") and
                               emotesMenu.Children.Main:FindFirstChild("EmotesWheel")

            if exists then
                local emotesWheel = emotesMenu.Children.Main.EmotesWheel
                if not emotesWheel:FindFirstChild("Under") or not emotesWheel:FindFirstChild("Top") then
                    if createGUIElements then
                        createGUIElements()
                        loadSpeedEmoteConfig()
                    end
                    updateGUIColors()
                    updatePageDisplay()
                end
            end
        end

        task.wait(0.3)
    end
end)

if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
    SafeLoad("https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/OpenEmote.lua", "Open Emote")
    getgenv().Notify({
        Title = '7yd7 | Emote Mobile',
        Content = '📱 Added emote open button for ease of use',
        Duration = 10
    })
end

if UserInputService.KeyboardEnabled then
    getgenv().Notify({
        Title = '7yd7 | Emote PC',
        Content = '💻 Open menu press button "."',
        Duration = 10
    })
end
]============],
emoteSettings=[============[local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Player = Players.LocalPlayer

local function ColorToHex(c)
    return string.format("#%02x%02x%02x", math.round(c.R*255), math.round(c.G*255), math.round(c.B*255))
end

local function HexToColor(hex)
    local success, result = pcall(function()
        hex = hex:gsub("#", "")
        return Color3.fromRGB(tonumber(hex:sub(1,2), 16), tonumber(hex:sub(3,4), 16), tonumber(hex:sub(5,6), 16))
    end)
    return success and result or nil
end

local function GetUIContainer()
    if game:GetService("RunService"):IsStudio() then
        return Player:WaitForChild("PlayerGui")
    end
    local success, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if success and coreGui:FindFirstChild("RobloxGui") then
        return coreGui.RobloxGui
    end
    return Player:WaitForChild("PlayerGui")
end

local SettingsUI = Instance.new("ScreenGui")
SettingsUI.Name = "7yd7-Settings"
SettingsUI.ResetOnSpawn = false
SettingsUI.IgnoreGuiInset = true
SettingsUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SettingsUI.DisplayOrder = 999
SettingsUI.Parent = GetUIContainer()

local UIScale = Instance.new("UIScale")
UIScale.Parent = SettingsUI

local function UpdateUIScale()
    local ViewportSize = workspace.CurrentCamera.ViewportSize
    local rawScale = math.min(ViewportSize.X / 1000, ViewportSize.Y / 800)
    if ViewportSize.Y < 500 then
        rawScale = rawScale * 1.2
    end
    UIScale.Scale = math.clamp(rawScale, 0.55, 1.25)
end

UpdateUIScale()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(UpdateUIScale)

local Theme = {
    Background = Color3.fromRGB(24, 25, 28),
    Header = Color3.fromRGB(32, 34, 37),
    Section = Color3.fromRGB(32, 34, 37),
    Accent = Color3.fromRGB(0, 255, 150),
    Text = Color3.fromRGB(255, 255, 255),
    TextDim = Color3.fromRGB(150, 150, 150),
    Error = Color3.fromRGB(255, 75, 75),
    CornerRadius = UDim.new(0, 12),
    FontBold = Enum.Font.GothamBold,
    FontRegular = Enum.Font.Gotham
}

local Lib = {}
local ColorHistory = {
    Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 0, 0), Color3.fromRGB(0, 255, 0), Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 255, 0), Color3.fromRGB(255, 0, 255), Color3.fromRGB(0, 255, 255), Color3.fromRGB(120, 120, 120)
}

function Lib:Tween(obj, info, goal)
    local tween = TweenService:Create(obj, info, goal)
    tween:Play()
    return tween
end

function Lib:Create(className, properties, children)
    local obj = Instance.new(className)
    for k, v in pairs(properties) do
        obj[k] = v
    end
    if children then
        for _, child in pairs(children) do
            child.Parent = obj
        end
    end
    return obj
end

local PickerFrame = nil
local currentPickerCallback = nil
local pickerColor = Color3.new(1, 1, 1)
local pickerAlpha = 1

function Lib:OpenPicker(default, callback, includeAlpha)
    if PickerFrame then PickerFrame:Destroy() end
    
    currentPickerCallback = callback
    if typeof(default) == "table" then
        pickerColor = default.Color or Color3.new(1,1,1)
        pickerAlpha = default.Alpha or 1
    else
        pickerColor = default or Theme.Accent
        pickerAlpha = 1
    end
    
    local h, s, v = pickerColor:ToHSV()
    local alpha = pickerAlpha

    PickerFrame = Lib:Create("Frame", {
        Name = "AdvancedColorPicker",
        Parent = SettingsUI,
        BackgroundColor3 = Theme.Background,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(320, 480), 
        ZIndex = 5000
    }, {
        Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius}),
        Lib:Create("UIStroke", {Color = Theme.Section, Thickness = 2}),
        Lib:Create("TextLabel", {
            Position = UDim2.fromOffset(20, 15),
            Size = UDim2.fromOffset(200, 25),
            BackgroundTransparency = 1,
            Font = Theme.FontBold,
            Text = "ADVANCED COLOR SELECTOR",
            TextColor3 = Theme.Text,
            TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left
        })
    })

    local closeBtn = Lib:Create("TextButton", {
        Parent = PickerFrame,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -40, 0, 10),
        Size = UDim2.fromOffset(30, 30),
        Font = Theme.FontBold,
        Text = "×",
        TextColor3 = Theme.TextDim,
        TextSize = 28
    })
    closeBtn.MouseButton1Click:Connect(function() PickerFrame:Destroy(); PickerFrame = nil end)

    local MainArea = Lib:Create("Frame", {
        Parent = PickerFrame,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 50),
        Size = UDim2.new(1, -40, 0, 160)
    })

    local Wheel = Lib:Create("ImageButton", {
        Name = "Wheel",
        Parent = MainArea,
        Size = UDim2.fromOffset(160, 160),
        BackgroundTransparency = 1,
        Image = "rbxassetid://6020299385", 
        ScaleType = Enum.ScaleType.Fit,
        ZIndex = 10
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}) })

    local WheelCursor = Lib:Create("Frame", {
        Parent = Wheel,
        Size = UDim2.fromOffset(14, 14),
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex = 11,
        Active = false 
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}), Lib:Create("UIStroke", {Thickness = 2, Color = Color3.new(0,0,0)}) })

    local ValueSlider = Lib:Create("ImageButton", {
        Name = "ValueSlider",
        Parent = MainArea,
        Position = UDim2.fromOffset(180, 0),
        Size = UDim2.fromOffset(25, 160),
        BackgroundColor3 = Color3.new(1,1,1),
        ZIndex = 10
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 12)}) })

    local ValGradient = Lib:Create("UIGradient", {
        Parent = ValueSlider,
        Rotation = 90,
        Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(0, 0, 0))
    })

    local ValCursor = Lib:Create("Frame", {
        Parent = ValueSlider,
        Size = UDim2.new(1.3, 0, 0, 6),
        AnchorPoint = Vector2.new(0.15, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex = 11,
        Active = false
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}), Lib:Create("UIStroke", {Thickness = 1}) })

    local AlphaSlider = Lib:Create("ImageButton", {
        Name = "AlphaSlider",
        Parent = MainArea,
        Position = UDim2.fromOffset(220, 0),
        Size = UDim2.fromOffset(25, 160),
        BackgroundColor3 = Color3.new(1,1,1),
        Visible = includeAlpha == true,
        ZIndex = 10
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 12)}) })

    local AlphaGradient = Lib:Create("UIGradient", {
        Parent = AlphaSlider,
        Rotation = 90,
        Transparency = NumberSequence.new(0, 1)
    })

    local AlphaCursor = Lib:Create("Frame", {
        Parent = AlphaSlider,
        Size = UDim2.new(1.3, 0, 0, 6),
        AnchorPoint = Vector2.new(0.15, 0.5),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex = 11,
        Active = false
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}), Lib:Create("UIStroke", {Thickness = 1}) })

    if not includeAlpha then
        ValueSlider.Position = UDim2.fromOffset(200, 0)
        ValueSlider.Size = UDim2.fromOffset(40, 160)
    end

    local ActionArea = Lib:Create("Frame", {
        Parent = PickerFrame,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 215),
        Size = UDim2.new(1, -40, 0, 40)
    })

    local Preview = Lib:Create("Frame", {
        Parent = ActionArea,
        Size = UDim2.fromOffset(45, 45),
        Position = UDim2.fromOffset(0, -5),
        BackgroundColor3 = pickerColor
    }, { 
        Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}), 
        Lib:Create("UIStroke", {Thickness = 2, Color = Theme.Section}) 
    })

    local Hex = Lib:Create("TextBox", {
        Parent = ActionArea,
        Position = UDim2.fromOffset(60, 0),
        Size = UDim2.fromOffset(120, 35),
        BackgroundColor3 = Theme.Section,
        Font = Theme.FontRegular,
        Text = ColorToHex(pickerColor),
        TextColor3 = Theme.Text,
        TextSize = 14
    }, { Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius}) })

    local function CreateBtn(img, x, parent, color)
        local btn = Lib:Create("ImageButton", {
            Parent = parent,
            Position = UDim2.fromOffset(x, 0),
            Size = UDim2.fromOffset(35, 35),
            BackgroundColor3 = Theme.Section,
            Image = img,
            ImageColor3 = color or Theme.Text,
            ScaleType = Enum.ScaleType.Fit
        }, { 
            Lib:Create("UICorner", {CornerRadius = UDim.new(0, 10)}),
            Lib:Create("UIPadding", {
                PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6)
            })
        })
        return btn
    end

    local Apply = CreateBtn("rbxassetid://17790428935", 195, ActionArea, Theme.Accent)
    local Cancel = CreateBtn("rbxassetid://102910221413931", 240, ActionArea, Theme.Error)

    local Grid = Lib:Create("Frame", {
        Parent = PickerFrame,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 265),
        Size = UDim2.new(1, -40, 0, 90)
    })

    local function CreateInput(label, x, y, parent, default)
        local container = Lib:Create("Frame", {
            Parent = parent,
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(85, 38),
            BackgroundColor3 = Theme.Section
        }, {
            Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius}),
            Lib:Create("TextLabel", {
                Position = UDim2.new(0, 8, 0, -12),
                Size = UDim2.fromOffset(25, 15),
                BackgroundTransparency = 1,
                Font = Theme.FontBold,
                Text = label,
                TextColor3 = Theme.TextDim,
                TextSize = 10
            })
        })
        local box = Lib:Create("TextBox", {
            Parent = container,
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Font = Theme.FontRegular,
            Text = tostring(default),
            TextColor3 = Theme.Text,
            TextSize = 14,
            ClearTextOnFocus = false
        })
        return box
    end

    local rI = CreateInput("R", 0, 5, Grid, math.round(pickerColor.R*255))
    local gI = CreateInput("G", 95, 5, Grid, math.round(pickerColor.G*255))
    local bI = CreateInput("B", 190, 5, Grid, math.round(pickerColor.B*255))
    
    local hI = CreateInput("H", 0, 50, Grid, math.round(h*360))
    local sI = CreateInput("S", 95, 50, Grid, string.format("%.2f", s))
    local vI = CreateInput("V", 190, 50, Grid, string.format("%.2f", v))

    local Palette = Lib:Create("Frame", {
        Parent = PickerFrame,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 365),
        Size = UDim2.new(1, -40, 0, 45)
    }, {
        Lib:Create("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0, 8),
            HorizontalAlignment = Enum.HorizontalAlignment.Center
        })
    })

    local function SyncAll(source)
        pickerColor = Color3.fromHSV(h, s, v)
        Preview.BackgroundColor3 = pickerColor
        Preview.BackgroundTransparency = 1 - alpha
        
        ValGradient.Color = ColorSequence.new(Color3.fromHSV(h, s, 1), Color3.new(0, 0, 0))
        AlphaGradient.Color = ColorSequence.new(pickerColor, pickerColor)
        
        if source ~= "Wheel" then
            local angle = math.rad(180 - h * 360) 
            local dist = s * 80
            WheelCursor.Position = UDim2.fromOffset(80 + math.cos(angle) * dist, 80 + math.sin(angle) * dist)
        else
            local angle = math.rad(180 - h * 360)
            local dist = s * 80
            WheelCursor.Position = UDim2.fromOffset(80 + math.cos(angle) * dist, 80 + math.sin(angle) * dist)
        end
        ValCursor.Position = UDim2.fromScale(0, 1-v)
        AlphaCursor.Position = UDim2.fromScale(0, 1-alpha)
        
        if source ~= "Hex" then Hex.Text = ColorToHex(pickerColor) end
        
        if source ~= "RGB" then
            rI.Text = math.round(pickerColor.R * 255)
            gI.Text = math.round(pickerColor.G * 255)
            bI.Text = math.round(pickerColor.B * 255)
        end
        if source ~= "HSV" then
            hI.Text = math.round(h * 360)
            sI.Text = string.format("%.2f", s)
            vI.Text = string.format("%.2f", v)
        end
    end

    for i, color in ipairs(ColorHistory) do
        local swatch = Lib:Create("TextButton", {
            Parent = Palette,
            Size = UDim2.fromOffset(28, 28),
            BackgroundColor3 = color,
            Text = ""
        }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
        swatch.MouseButton1Click:Connect(function()
            h, s, v = color:ToHSV()
            SyncAll("Palette")
        end)
    end

    local function UpdateWheel(input)
        local pos = input.Position
        local rel = Vector2.new(pos.X - Wheel.AbsolutePosition.X, pos.Y - Wheel.AbsolutePosition.Y)
        local radius = Wheel.AbsoluteSize.X / 2
        local center = Vector2.new(radius, radius)
        local diff = rel - center
        local angle = math.atan2(diff.Y, diff.X)
        local dist = math.min(diff.Magnitude, radius)
        
        h = (180 - math.deg(angle)) % 360 / 360
        s = dist / radius
        SyncAll("Wheel")
    end

    local function UpdateValue(input)
        local pos = input.Position
        local size = ValueSlider.AbsoluteSize
        local absPos = ValueSlider.AbsolutePosition
        local relY = math.clamp((pos.Y - absPos.Y) / size.Y, 0, 1)
        v = 1 - relY
        SyncAll("Slider")
    end

    local function UpdateAlpha(input)
        local pos = input.Position
        local size = AlphaSlider.AbsoluteSize
        local absPos = AlphaSlider.AbsolutePosition
        local relY = math.clamp((pos.Y - absPos.Y) / size.Y, 0, 1)
        alpha = 1 - relY
        SyncAll("Alpha")
    end

    local wheelDown, valDown, alphaDown = false, false, false

    Wheel.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            wheelDown = true
            UpdateWheel(input)
        end
    end)

    ValueSlider.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            valDown = true
            UpdateValue(input)
        end
    end)

    AlphaSlider.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            alphaDown = true
            UpdateAlpha(input)
        end
    end)

    local connections = {}
    
    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if wheelDown then 
                UpdateWheel({Position = input.Position}) 
            elseif valDown then 
                UpdateValue({Position = input.Position}) 
            elseif alphaDown then 
                UpdateAlpha({Position = input.Position}) 
            end
        end
    end))

    table.insert(connections, UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            wheelDown, valDown, alphaDown = false, false, false
        end
    end))

    local function Cleanup()
        for _, conn in ipairs(connections) do
            if conn.Connected then conn:Disconnect() end
        end
        if PickerFrame then PickerFrame:Destroy(); PickerFrame = nil end
    end

    closeBtn.MouseButton1Click:Connect(Cleanup)
    Cancel.MouseButton1Click:Connect(Cleanup)

    Hex.FocusLost:Connect(function()
        local c = HexToColor(Hex.Text)
        if c then h, s, v = c:ToHSV(); SyncAll("Hex") else Hex.Text = ColorToHex(pickerColor) end
    end)

    local function HandleRGB()
        local r, g, b = tonumber(rI.Text) or 0, tonumber(gI.Text) or 0, tonumber(bI.Text) or 0
        local c = Color3.fromRGB(math.clamp(r,0,255), math.clamp(g,0,255), math.clamp(b,0,255))
        h, s, v = c:ToHSV(); SyncAll("RGB")
    end
    rI.FocusLost:Connect(HandleRGB); gI.FocusLost:Connect(HandleRGB); bI.FocusLost:Connect(HandleRGB)

    local function HandleHSV()
        local nh, ns, nv = tonumber(hI.Text) or 0, tonumber(sI.Text) or 0, tonumber(vI.Text) or 0
        h, s, v = (nh%360)/360, math.clamp(ns,0,1), math.clamp(nv,0,1)
        SyncAll("HSV")
    end
    hI.FocusLost:Connect(HandleHSV); sI.FocusLost:Connect(HandleHSV); vI.FocusLost:Connect(HandleHSV)

    Apply.MouseButton1Click:Connect(function()
        table.insert(ColorHistory, 1, pickerColor)
        table.remove(ColorHistory, 9)
        Cleanup()
        if includeAlpha then
            callback({Color = pickerColor, Alpha = alpha})
        else
            callback(pickerColor)
        end
    end)
    
    SyncAll()
end

local MainFrame = Lib:Create("Frame", {
    Name = "MainFrame",
    Parent = SettingsUI,
    BackgroundColor3 = Theme.Background,
    BorderSizePixel = 0,
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(320, 420)
}, {
    Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius})
})
MainFrame.Visible = false

local Dragging, DragStart, StartPos
MainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        Dragging = true
        DragStart = input.Position
        StartPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then Dragging = false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) and Dragging then
        local Delta = (input.Position - DragStart) / UIScale.Scale
        MainFrame.Position = UDim2.new(StartPos.X.Scale, StartPos.X.Offset + Delta.X, StartPos.Y.Scale, StartPos.Y.Offset + Delta.Y)
    end
end)

local Header = Lib:Create("Frame", {
    Name = "Header",
    Parent = MainFrame,
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 50)
})

local NavContainer = Lib:Create("ScrollingFrame", {
    Name = "NavContainer",
    Parent = Header,
    BackgroundTransparency = 1,
    Position = UDim2.new(0.05, 0, 0.2, 0),
    Size = UDim2.new(1, -65, 0, 35),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = Theme.Accent,
    ScrollingDirection = Enum.ScrollingDirection.X,
    ClipsDescendants = true
}, {
    Lib:Create("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 15),
        SortOrder = Enum.SortOrder.LayoutOrder
    })
})

local CloseBtn = Lib:Create("TextButton", {
    Name = "Close",
    Parent = Header,
    BackgroundTransparency = 1,
    Position = UDim2.new(1, -35, 0, 10),
    Size = UDim2.new(0, 25, 0, 25),
    Font = Theme.FontBold,
    Text = "×",
    TextColor3 = Theme.Text,
    TextSize = 25
}, {
    Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)})
})
CloseBtn.MouseButton1Click:Connect(function()
    MainFrame.Visible = false
end)

local TabContainers = {}
local ActiveTab = nil
local Components = {}

function Components:AddItem(parent, title, description)
    local hasDesc = description and description ~= ""
    local ItemContainer = Lib:Create("Frame", {
        Name = title,
        Parent = parent,
        BackgroundColor3 = Theme.Section,
        Size = UDim2.new(0.95, 0, 0, hasDesc and 60 or 45),
        AutomaticSize = Enum.AutomaticSize.Y
    }, {
        Lib:Create("UICorner", {CornerRadius = UDim.new(0, 10)}),
        Lib:Create("TextLabel", {
            Name = "Title",
            BackgroundTransparency = 1,
            Position = UDim2.new(0, 12, 0, hasDesc and 12 or 0),
            Size = UDim2.new(0.6, 0, hasDesc and 0 or 1, hasDesc and 18 or 0),
            Font = Theme.FontBold,
            Text = title,
            TextColor3 = Theme.Text,
            TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left
        }),
        Lib:Create("UIPadding", {PaddingBottom = UDim.new(0, 12)})
    })
    
    if hasDesc then
        Lib:Create("TextLabel", {
            Name = "Desc",
            Parent = ItemContainer,
            BackgroundTransparency = 1,
            Position = UDim2.new(0, 12, 0, 32),
            Size = UDim2.new(0.6, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            TextWrapped = true,
            Font = Theme.FontRegular,
            Text = description,
            TextColor3 = Theme.TextDim,
            TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top
        })
    end
    return ItemContainer
end

function Components:AddToggle(container, title, description, default, callback)
    local item = self:AddItem(container, title, description)
    local state = default or false
    
    local ToggleBg = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = state and Color3.fromRGB(0, 220, 130) or Color3.fromRGB(55, 58, 62),
        Position = UDim2.new(1, -55, 0.5, -10),
        Size = UDim2.new(0, 42, 0, 20),
        Text = ""
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}) })
    
    local Knob = Lib:Create("Frame", {
        Parent = ToggleBg,
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        Position = UDim2.new(state and 1 or 0, state and -19 or 3, 0.5, -8),
        Size = UDim2.new(0, 16, 0, 16)
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(1, 0)}) })
    
    local function updateVisuals(newState)
        state = newState
        Lib:Tween(ToggleBg, TweenInfo.new(0.15), {BackgroundColor3 = state and Color3.fromRGB(0, 220, 130) or Color3.fromRGB(55, 58, 62)})
        Lib:Tween(Knob, TweenInfo.new(0.15), {Position = UDim2.new(state and 1 or 0, state and -19 or 3, 0.5, -8)})
    end

    ToggleBg.MouseButton1Click:Connect(function()
        updateVisuals(not state)
        callback(state)
    end)
    
    return {
        SetState = function(newState)
            updateVisuals(newState)
        end
    }
end

function Components:AddDropdown(container, title, options, default, callback)
    local item = self:AddItem(container, title, nil)
    local selected = default or options[1]
    
    local DropBtn = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = Color3.fromRGB(24, 25, 28),
        Position = UDim2.new(1, -110, 0.5, -14),
        Size = UDim2.new(0, 100, 0, 28),
        Font = Theme.FontRegular,
        Text = selected .. "  ▼",
        TextColor3 = Theme.Text,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
    
    local IsOpen = false
    local DropList = Lib:Create("Frame", {
        Parent = SettingsUI,
        BackgroundColor3 = Color3.fromRGB(25, 27, 30),
        Size = UDim2.fromOffset(100, 0),
        Visible = false,
        ClipsDescendants = true,
        ZIndex = 200
    }, {
        Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}),
        Lib:Create("UIStroke", {Color = Theme.Accent, Thickness = 1})
    })
    
    local ListScroll = Lib:Create("ScrollingFrame", {
        Parent = DropList,
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(0, 28),
        Size = UDim2.new(1, 0, 1, -28),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness = 3,
        AutomaticCanvasSize = Enum.AutomaticSize.Y
    }, { Lib:Create("UIListLayout", {Padding = UDim.new(0, 1)}) })

    local SearchBox = Lib:Create("TextBox", {
        Parent = DropList,
        BackgroundColor3 = Theme.Background,
        Position = UDim2.fromOffset(4, 4),
        Size = UDim2.new(1, -8, 0, 22),
        Font = Theme.FontRegular,
        PlaceholderText = "Search...",
        Text = "",
        TextColor3 = Theme.Text,
        TextSize = 11
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 4)}) })
    
    local function RefreshOptions(filter)
        for _, v in pairs(ListScroll:GetChildren()) do if v:IsA("TextButton") then v:Destroy() end end
        for _, opt in pairs(options) do
            if not filter or string.find(string.lower(opt), string.lower(filter)) then
                local b = Lib:Create("TextButton", {
                    Parent = ListScroll,
                    BackgroundTransparency = 1,
                    Size = UDim2.new(1, 0, 0, 24),
                    Font = Theme.FontRegular,
                    Text = opt,
                    TextColor3 = Theme.Text,
                    TextSize = 11
                })
                b.MouseButton1Click:Connect(function()
                    selected = opt
                    DropBtn.Text = opt .. "  ▼"
                    IsOpen = false
                    DropList.Visible = false
                    callback(opt)
                end)
            end
        end
    end
    
    SearchBox:GetPropertyChangedSignal("Text"):Connect(function() RefreshOptions(SearchBox.Text) end)
    
    local Dropdown = {
        Button = DropBtn,
        Refresh = function(newOptions)
            if newOptions then options = newOptions end
            RefreshOptions(SearchBox.Text)
        end
    }
    
    RefreshOptions()
    
    DropBtn.MouseButton1Click:Connect(function()
        IsOpen = not IsOpen
        if IsOpen then
            local scale = UIScale.Scale
            local btnPos = DropBtn.AbsolutePosition
            local btnSize = DropBtn.AbsoluteSize
            local guiContainerSize = SettingsUI.AbsoluteSize or workspace.CurrentCamera.ViewportSize
            
            local listHeight = math.min(#options * 24 + 32, 200)
            DropList.Size = UDim2.fromOffset(110, listHeight)

            DropList.Position = UDim2.new(0, btnPos.X / scale, 0, (btnPos.Y + btnSize.Y + 4) / scale)
            DropList.Visible = true
            RefreshOptions(SearchBox.Text)
        else
            DropList.Visible = false
        end
    end)
    
    return Dropdown
end

function Components:AddSection(container, title)
    return Lib:Create("TextLabel", {
        Parent = container,
        BackgroundTransparency = 1,
        Size = UDim2.new(0.95, 0, 0, 25),
        Font = Theme.FontBold,
        Text = " — " .. title:upper() .. " — ",
        TextColor3 = Theme.Accent,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Center
    })
end

function Components:AddButton(container, title, callback)
    local item = self:AddItem(container, title, nil)
    local Btn = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = Theme.Accent,
        Position = UDim2.new(1, -75, 0.5, -12),
        Size = UDim2.new(0, 65, 0, 24),
        Font = Theme.FontBold,
        Text = "Click",
        TextColor3 = Theme.Background,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
    
    Btn.MouseButton1Click:Connect(callback)
    return Btn
end

function Components:AddInput(container, title, placeholder, default, callback)
    local item = self:AddItem(container, title, nil)
    local Input = Lib:Create("TextBox", {
        Parent = item,
        BackgroundColor3 = Color3.fromRGB(24, 25, 28),
        Position = UDim2.new(1, -110, 0.5, -12),
        Size = UDim2.new(0, 100, 0, 24),
        Font = Theme.FontRegular,
        PlaceholderText = placeholder or "...",
        Text = default or "",
        TextColor3 = Theme.Text,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
    
    Input.FocusLost:Connect(function() callback(Input.Text) end)
    
    local Reset = Lib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -135, 0.5, -10),
        Size = UDim2.new(0, 20, 0, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit
    })
    Reset.MouseButton1Click:Connect(function()
        Input.Text = default or ""
        callback(Input.Text)
    end)
    
    return { SetValue = function(val) Input.Text = val end }
end

function Components:AddTextArea(container, title, placeholder, default, callback)
    local item = self:AddItem(container, title, nil)
    item.Size = UDim2.new(0.95, 0, 0, 120)
    
    local TextArea = Lib:Create("TextBox", {
        Parent = item,
        BackgroundColor3 = Color3.fromRGB(24, 25, 28),
        Position = UDim2.new(0, 10, 0, 30),
        Size = UDim2.new(1, -20, 0, 80),
        Font = Theme.FontRegular,
        PlaceholderText = placeholder or "...",
        Text = default or "",
        TextColor3 = Theme.Text,
        TextSize = 12,
        ClearTextOnFocus = false,
        MultiLine = true,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
    
    TextArea.FocusLost:Connect(function() callback(TextArea.Text) end)
    return TextArea
end

function Components:AddIconButton(container, imageId, callback)
    local BtnHolder = Lib:Create("TextButton", {
        Parent = container,
        BackgroundColor3 = Color3.fromHex("18191c"),
        BackgroundTransparency = 1,
        Size = UDim2.new(0, 38, 0, 38),
        Text = ""
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 10)}) })
    
    local Btn = Lib:Create("ImageLabel", {
        Parent = BtnHolder,
        BackgroundTransparency = 1,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.new(0, 22, 0, 22),
        Image = "rbxassetid://" .. tostring(imageId):gsub("rbxassetid://", ""),
        ImageColor3 = Color3.fromRGB(200, 200, 200),
        ScaleType = Enum.ScaleType.Fit,
        Active = false
    })
    
    BtnHolder.MouseEnter:Connect(function()
        Lib:Tween(BtnHolder, TweenInfo.new(0.15), {BackgroundTransparency = 0, BackgroundColor3 = Theme.Accent})
        Lib:Tween(Btn, TweenInfo.new(0.15), {ImageColor3 = Color3.new(1, 1, 1)})
    end)
    BtnHolder.MouseLeave:Connect(function()
        Lib:Tween(BtnHolder, TweenInfo.new(0.15), {BackgroundTransparency = 1, BackgroundColor3 = Color3.fromHex("18191c")})
        Lib:Tween(Btn, TweenInfo.new(0.15), {ImageColor3 = Color3.fromRGB(200, 200, 200)})
    end)
    
    BtnHolder.MouseButton1Click:Connect(callback)
    return BtnHolder
end

function Components:AddFolder(container, title)
    local FolderContainer = Lib:Create("Frame", {
        Name = title .. "_Folder",
        Parent = container,
        BackgroundTransparency = 1,
        Size = UDim2.new(0.95, 0, 0, 35),
        AutomaticSize = Enum.AutomaticSize.Y
    }, { Lib:Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 0) }) })

    local IsOpen = false
    local FolderBtn = Lib:Create("TextButton", {
        Parent = FolderContainer,
        BackgroundColor3 = Theme.Section,
        Size = UDim2.new(1, 0, 0, 35),
        LayoutOrder = 0,
        Font = Theme.FontBold,
        Text = "  ▶  " .. title,
        TextColor3 = Theme.Text,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left
    }, { Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius}) })
    
    local Content = Lib:Create("Frame", {
        Parent = FolderContainer,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        Visible = false,
        ClipsDescendants = true
    }, { Lib:Create("UIListLayout", {Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder}) })
    
    FolderBtn.MouseButton1Click:Connect(function()
        IsOpen = not IsOpen
        FolderBtn.Text = (IsOpen and "  ▼  " or "  ▶  ") .. title
        Content.Visible = IsOpen
    end)
    
    return Content
end

function Components:AddColorPicker(container, title, default, callback)
    local item = self:AddItem(container, title, nil)
    local color = default or Theme.Accent
    
    local ColorBtn = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = color,
        Position = UDim2.new(1, -42, 0.5, -10),
        Size = UDim2.fromOffset(22, 22),
        Text = ""
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    ColorBtn.MouseButton1Click:Connect(function()
        Lib:OpenPicker(color, function(newC)
            color = newC
            ColorBtn.BackgroundColor3 = color
            callback(color)
        end)
    end)
    
    local Reset = Lib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -70, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit
    })
    Reset.MouseButton1Click:Connect(function()
        color = default or Theme.Accent
        ColorBtn.BackgroundColor3 = color
        callback(color)
    end)

    return { SetValue = function(c) color = c; ColorBtn.BackgroundColor3 = color end }
end

local function CreateTab(name, order)
    local TabContainer = Lib:Create("ScrollingFrame", {
        Name = name .. "Page",
        Parent = MainFrame,
        BackgroundTransparency = 1,
        Position = UDim2.new(0, 10, 0, 60),
        Size = UDim2.new(1, -20, 1, -70),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness = 4,
        ScrollBarImageTransparency = 0.2,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        Visible = order == 1,
        AutomaticCanvasSize = Enum.AutomaticSize.Y
    }, { Lib:Create("UIListLayout", {Padding = UDim.new(0, 10), HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder}) })
    
    local TabBtn = Lib:Create("TextButton", {
        Name = name,
        Parent = NavContainer,
        BackgroundTransparency = 1,
        Size = UDim2.new(0, 60, 1, 0),
        Font = Theme.FontBold,
        Text = name:gsub("%d", ""),
        TextColor3 = order == 1 and Theme.Text or Color3.fromRGB(120, 120, 120),
        TextSize = 14,
        LayoutOrder = order
    })
    
    local Underline = Lib:Create("Frame", {
        Parent = TabBtn,
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Position = UDim2.new(-0.05, 0, 1, 3),
        Size = UDim2.new(1.1, 0, 0, 2),
        Visible = order == 1
    })

    TabBtn.MouseButton1Click:Connect(function()
        if ActiveTab == name then return end
        for tName, container in pairs(TabContainers) do container.Visible = (tName == name) end
        for _, btn in pairs(NavContainer:GetChildren()) do
            if btn:IsA("TextButton") then
                btn.TextColor3 = Color3.fromRGB(120, 120, 120)
                if btn:FindFirstChild("Frame") then btn.Frame.Visible = false end
            end
        end
        TabBtn.TextColor3 = Theme.Text
        Underline.Visible = true
        ActiveTab = name
    end)
    
    TabContainers[name] = TabContainer
    return TabContainer
end

function Components:AddInputWithColor(container, title, placeholder, defaultText, defaultColor, callback)
    local item = self:AddItem(container, title, nil)
    local color = defaultColor or Color3.new(1, 1, 1)
    local text = defaultText or ""
    
    local Input = Lib:Create("TextBox", {
        Parent = item,
        BackgroundColor3 = Color3.fromRGB(24, 25, 28),
        Position = UDim2.new(1, -140, 0.5, -12),
        Size = UDim2.fromOffset(90, 24),
        Font = Theme.FontRegular,
        PlaceholderText = placeholder or "...",
        Text = text,
        TextColor3 = Theme.Text,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })
    
    local ColorBtn = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = color,
        Position = UDim2.new(1, -42, 0.5, -10),
        Size = UDim2.fromOffset(22, 22),
        Text = ""
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    ColorBtn.MouseButton1Click:Connect(function()
        Lib:OpenPicker(color, function(newC)
            color = newC
            ColorBtn.BackgroundColor3 = color
            callback(text, color)
        end)
    end)

    Input.FocusLost:Connect(function() text = Input.Text; callback(text, color) end)
    
    local Reset = Lib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -165, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://127493377027615",
        ScaleType = Enum.ScaleType.Fit
    })
    Reset.MouseButton1Click:Connect(function()
        text, color = defaultText or "", defaultColor or Color3.new(1,1,1)
        Input.Text = text
        ColorBtn.BackgroundColor3 = color
        callback(text, color)
    end)

    return { 
        SetValue = function(t, c) text, color = t or "", c or color; Input.Text, ColorBtn.BackgroundColor3 = text, color end,
        Button = ColorBtn,
        Item = item
    }
end

function Components:AddAssetColor(container, title, placeholder, defaultText, defaultColor, callback)
    local item = self:AddItem(container, title, nil)
    local color = defaultColor or Color3.new(1, 1, 1)
    local text = defaultText or ""
    
    local ColorBtn = Lib:Create("TextButton", {
        Parent = item,
        BackgroundColor3 = color,
        Position = UDim2.new(1, -42, 0.5, -10),
        Size = UDim2.fromOffset(22, 22),
        Text = ""
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    local EditBtn = Lib:Create("ImageButton", {
        Parent = item,
        BackgroundTransparency = 1,
        Position = UDim2.new(1, -75, 0.5, -10),
        Size = UDim2.fromOffset(20, 20),
        Image = "rbxassetid://117761881427472",
        ImageColor3 = Color3.fromRGB(200, 200, 200),
        ScaleType = Enum.ScaleType.Fit
    })

    local InputPanel = Lib:Create("Frame", {
        Parent = SettingsUI,
        BackgroundColor3 = Theme.Background,
        Position = UDim2.fromScale(0.5, 0.5),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.fromOffset(220, 80),
        Visible = false,
        ZIndex = 1100
    }, {
        Lib:Create("UICorner", {CornerRadius = Theme.CornerRadius}),
        Lib:Create("UIStroke", {Color = Theme.Section, Thickness = 2})
    })

    local In = Lib:Create("TextBox", {
        Parent = InputPanel,
        Size = UDim2.new(0.9, 0, 0, 30),
        Position = UDim2.new(0.05, 0, 0.2, 0),
        BackgroundColor3 = Color3.fromRGB(35, 38, 41),
        TextColor3 = Color3.new(1,1,1),
        PlaceholderText = placeholder or "Asset ID...",
        Text = text,
        Font = Theme.FontRegular,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    local Save = Lib:Create("TextButton", {
        Parent = InputPanel,
        Size = UDim2.new(0.4, 0, 0, 25),
        Position = UDim2.new(0.05, 0, 0.65, 0),
        BackgroundColor3 = Theme.Accent,
        Text = "Apply",
        Font = Theme.FontBold,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    local Cancel = Lib:Create("TextButton", {
        Parent = InputPanel,
        Size = UDim2.new(0.4, 0, 0, 25),
        Position = UDim2.new(0.55, 0, 0.65, 0),
        BackgroundColor3 = Theme.Section,
        Text = "Cancel",
        TextColor3 = Theme.Text,
        Font = Theme.FontBold,
        TextSize = 12
    }, { Lib:Create("UICorner", {CornerRadius = UDim.new(0, 6)}) })

    EditBtn.MouseButton1Click:Connect(function() InputPanel.Visible = true; In.Text = text end)
    Cancel.MouseButton1Click:Connect(function() InputPanel.Visible = false end)
    Save.MouseButton1Click:Connect(function() text = In.Text; InputPanel.Visible = false; callback(text, color) end)

    ColorBtn.MouseButton1Click:Connect(function()
        Lib:OpenPicker(color, function(newC)
            color = newC
            ColorBtn.BackgroundColor3 = color
            callback(text, color)
        end)
    end)

    return { 
        SetValue = function(t, c) text, color = t or "", c or color; In.Text, ColorBtn.BackgroundColor3 = text, color end,
        Button = ColorBtn,
        Item = item
    }
end

local Library = {
    UI = SettingsUI,
    CreateTab = CreateTab,
    AddToggle = function(...) return Components:AddToggle(...) end,
    AddDropdown = function(...) return Components:AddDropdown(...) end,
    AddColorPicker = function(...) return Components:AddColorPicker(...) end,
    AddButton = function(...) return Components:AddButton(...) end,
    AddInput = function(...) return Components:AddInput(...) end,
    AddSection = function(...) return Components:AddSection(...) end,
    AddTextArea = function(...) return Components:AddTextArea(...) end,
    AddIconButton = function(...) return Components:AddIconButton(...) end,
    AddFolder = function(...) return Components:AddFolder(...) end,
    AddItem = function(...) return Components:AddItem(...) end,
    AddInputWithColor = function(...) return Components:AddInputWithColor(...) end,
    AddAssetColor = function(...) return Components:AddAssetColor(...) end,
    OpenPicker = function(...) return Lib:OpenPicker(...) end,
    Create = function(self, ...) return Lib:Create(...) end
}

return Library
]============],
notify=[============[local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Player = Players.LocalPlayer
local PlayerGui = game.CoreGui

local NotificationGui = Instance.new("ScreenGui")
NotificationGui.Name = "NotificationSystem"
NotificationGui.Parent = PlayerGui
NotificationGui.ResetOnSpawn = false

local activeNotifications = {}
local notificationCount = 0

local NOTIFICATION_WIDTH = 280
local NOTIFICATION_HEIGHT = 70
local NOTIFICATION_SPACING = 8
local SLIDE_DISTANCE = 350
local ANIMATION_SPEED = 0.6

local function createNotification(title, content, duration)
    notificationCount = notificationCount + 1

    local notificationFrame = Instance.new("Frame")
    notificationFrame.Name = "Notification_" .. notificationCount
    notificationFrame.Size = UDim2.new(0, NOTIFICATION_WIDTH, 0, NOTIFICATION_HEIGHT)
    notificationFrame.BackgroundColor3 = Color3.fromRGB(27, 27, 27)
    notificationFrame.BackgroundTransparency = 0.15
    notificationFrame.BorderSizePixel = 0
    notificationFrame.Parent = NotificationGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = notificationFrame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 60, 60)
    stroke.Thickness = 1.2
    stroke.Transparency = 0.2
    stroke.Parent = notificationFrame

    local shadow = Instance.new("Frame")
    shadow.Size = UDim2.new(1, 4, 1, 4)
    shadow.Position = UDim2.new(0, -2, 0, -2)
    shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    shadow.BackgroundTransparency = 0.85
    shadow.BorderSizePixel = 0
    shadow.ZIndex = notificationFrame.ZIndex - 1
    shadow.Parent = notificationFrame

    local shadowCorner = Instance.new("UICorner")
    shadowCorner.CornerRadius = UDim.new(0, 8)
    shadowCorner.Parent = shadow

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, -16, 0, 22)
    titleLabel.Position = UDim2.new(0, 8, 0, 6)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = title
    titleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
    titleLabel.TextSize = 16
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextYAlignment = Enum.TextYAlignment.Center
    titleLabel.Font = Enum.Font.GothamSemibold
    titleLabel.Parent = notificationFrame

    local contentLabel = Instance.new("TextLabel")
    contentLabel.Name = "Content"
    contentLabel.Size = UDim2.new(1, -16, 0, 20)
    contentLabel.Position = UDim2.new(0, 8, 0, 30)
    contentLabel.BackgroundTransparency = 1
    contentLabel.Text = content
    contentLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
    contentLabel.TextSize = 13
    contentLabel.TextXAlignment = Enum.TextXAlignment.Left
    contentLabel.TextYAlignment = Enum.TextYAlignment.Center
    contentLabel.Font = Enum.Font.GothamMedium
    contentLabel.Parent = notificationFrame

    local closeButton = Instance.new("TextButton")
    closeButton.Size = UDim2.new(1, 0, 1, 0)
    closeButton.Position = UDim2.new(0, 0, 0, 0)
    closeButton.BackgroundTransparency = 1
    closeButton.Text = ""
    closeButton.Parent = notificationFrame

    local yPosition = (#activeNotifications * (NOTIFICATION_HEIGHT + NOTIFICATION_SPACING)) + 50
    notificationFrame.Position = UDim2.new(1, SLIDE_DISTANCE, 0, yPosition)
    table.insert(activeNotifications, notificationFrame)

    local function updatePositions()
        for i, notification in ipairs(activeNotifications) do
            local newY = ((i - 1) * (NOTIFICATION_HEIGHT + NOTIFICATION_SPACING)) + 50
            local tweenInfo = TweenInfo.new(ANIMATION_SPEED, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
            local tween = TweenService:Create(notification, tweenInfo, {
                Position = UDim2.new(1, -NOTIFICATION_WIDTH - 20, 0, newY)
            })
            tween:Play()
        end
    end

    local slideInTween = TweenService:Create(notificationFrame, 
        TweenInfo.new(ANIMATION_SPEED, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        {Position = UDim2.new(1, -NOTIFICATION_WIDTH - 20, 0, yPosition)}
    )
    slideInTween:Play()

    local function removeNotification()
        for i, notification in ipairs(activeNotifications) do
            if notification == notificationFrame then
                table.remove(activeNotifications, i)
                break
            end
        end

        local slideOutTween = TweenService:Create(notificationFrame,
            TweenInfo.new(ANIMATION_SPEED, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
            {Position = UDim2.new(1, SLIDE_DISTANCE, 0, notificationFrame.Position.Y.Offset)}
        )
        slideOutTween:Play()

        slideOutTween.Completed:Connect(function()
            notificationFrame:Destroy()
            updatePositions()
        end)
    end

    closeButton.MouseButton1Click:Connect(removeNotification)

    if duration and duration > 0 then
        task.wait(duration)
        if notificationFrame.Parent then
            removeNotification()
        end
    end
end

getgenv().Notify = function(options)
    local title = options.Title or "Notification"
    local content = options.Content or "No content provided"
    local duration = options.Duration or 5
    task.spawn(function()
        createNotification(title, content, duration)
    end)
end
]============],
openEmote=[============[local UIS = game:GetService("UserInputService") 
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local function makeDraggable(frame)
	local dragging = false
	local dragInput
	local dragStart
	local startPos
	local function update(input)
		local delta = input.Position - dragStart
		frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, 
			startPos.Y.Scale, startPos.Y.Offset + delta.Y)
	end
	frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or 
			input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	frame.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or 
			input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	UIS.InputChanged:Connect(function(input)
		if input == dragInput and dragging then
			update(input)
		end
	end)
end

local function setupHoverEffect(button)
	local originalSize = button.Size
	
	local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	
	button.MouseEnter:Connect(function()
		local newSize = UDim2.new(
			originalSize.X.Scale * 1.1,
			originalSize.X.Offset * 1.1,
			originalSize.Y.Scale * 1.1,
			originalSize.Y.Offset * 1.1
		)
		local tween = TweenService:Create(button, tweenInfo, {Size = newSize})
		tween:Play()
	end)
	
	button.MouseLeave:Connect(function()
		local tween = TweenService:Create(button, tweenInfo, {Size = originalSize})
		tween:Play()
	end)
	
	button.MouseButton1Click:Connect(function()
		local success, emotesMenu = pcall(function()
			return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel
		end)
		
		if success and emotesMenu then
			local isVisible = emotesMenu.Visible
			GuiService:SetEmotesMenuOpen(not isVisible)
		else
			GuiService:SetEmotesMenuOpen(true)
		end
	end)
end

local OpenEmoteMobile = Instance.new("ScreenGui")
local button = Instance.new("TextButton")
local UICorner = Instance.new("UICorner")
local ImageLabel = Instance.new("ImageLabel")
local UIListLayout = Instance.new("UIListLayout")
local UIAspectRatioConstraint = Instance.new("UIAspectRatioConstraint")

OpenEmoteMobile.IgnoreGuiInset = true
OpenEmoteMobile.Name = "OpenEmote (Mobile)"
OpenEmoteMobile.Parent = game.CoreGui
OpenEmoteMobile.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

button.Name = "button"
button.Parent = OpenEmoteMobile
button.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
button.BackgroundTransparency = 0.400
button.BorderSizePixel = 0
button.Position = UDim2.new(0.500268757, 0, 0, 30)
button.AnchorPoint = Vector2.new(0.5, 0.5)
button.Size = UDim2.new(0.0390930399, 0, 0.0694444478, 0)
button.ZIndex = 99999999
button.AutoButtonColor = false
button.Text = ""

UICorner.CornerRadius = UDim.new(0, 99999)
UICorner.Parent = button

ImageLabel.Parent = button
ImageLabel.BackgroundTransparency = 1.000
ImageLabel.Position = UDim2.new(0.1, 0, 0.1, 0)
ImageLabel.Size = UDim2.new(0.8, 0, 0.8, 0)
ImageLabel.Image = "rbxassetid://85867483111516"

UIListLayout.Parent = button
UIListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Center

UIAspectRatioConstraint.Parent = button
UIAspectRatioConstraint.AspectRatio = 1.000

makeDraggable(button)
setupHoverEffect(button)

RunService.Heartbeat:Connect(function()
	local success, mainMenu = pcall(function()
		return game:GetService("CoreGui").RobloxGui.EmotesMenu.Children.Main.EmotesWheel
	end)

	if success and mainMenu then
		if mainMenu.Visible then
			button.Visible = false
		else
			button.Visible = true 
		end
	else
		button.Visible = true 
	end
end)
]============],
}
local Configure = (function()
return function(Ports, Embedded, URLs, Patches)
    local legacy, settings, emotes, safechat = URLs.legacy, URLs.settings, URLs.emotes, URLs.safechat
    local classicChat = [[
local TextChatService=game:GetService("TextChatService")
for _, class in ipairs({"ChatWindowConfiguration","ChatInputBarConfiguration","ChannelTabsConfiguration","BubbleChatConfiguration"}) do
    local config=TextChatService:FindFirstChildOfClass(class)
    if config then __BP:Patch(config,"Enabled",false) end
end
local support=game:GetObjects("rbxassetid://122252029612413")[1]
assert(support,"The original classic-chat support asset was unavailable")
support.Parent=workspace
local playerGui=__BP:WaitForChild(game:GetService("Players").LocalPlayer,"PlayerGui",12)
local previousChat=playerGui:FindFirstChild("Chat")
if previousChat then __BP:Patch(previousChat,"Parent",nil) end
local suite=__BP:LoadSuite()
suite.launch("rbxassetid://111872120766790", {runscripts=true,deferred=true,nocache=false,nocirculardeps=true,debug=true,verbose=false})
__BP:WaitForChild(game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui",12),"Chat",12)
]]
    local original2006 = {idle={"107407916979702","107407916979702"},walk={"103979922296239"},run={"103979922296239"},jump={"119095524735341"},fall={"119095524735341"},climb={"132639392250396"}}
    local originalR15 = {idle={"507766666","507766951"},walk={"507777826"},run={"507767714"},jump={"507765000"},fall={"507767968"},climb={"507765644"},sit={"2506281703"},swim={"507784897"},swimidle={"507785072"}}
    local descriptors = {}
    for id in pairs(Ports) do descriptors[id] = {title=id,source=id} end
    local titles = {
        Topbar_2020="2020 classic topbar",Topbar_2016_A="2016 no-chat port",Topbar_2016_S="2016 Legacy port",Topbar_2014="2014 Legacy port",Topbar_2013="2013 Legacy port",Topbar_2012="2012 Legacy port",Topbar_OldChat="Original classic chat",
        SafeChat="Original safe chat",Backpack_Simple="Original simple backpack",Backpack_Advanced="Advanced classic backpack",Anims_R6_2008="Original 2008 R6 moveset",Anims_R6_2006="Original 2006 R6 preset",Anims_R15_2008="Original 2008 R15 preset",Anims_R15_Old="Original R15 preset",OldSounds="Classic sounds",Textures_2006="2006 textures",Textures_2016="2016 textures",Forcefield="Classic forcefield",BetterEmotes="Full 7yd7 emote port",
    }
    for id, title in pairs(titles) do descriptors[id].title = title end
    for _, id in ipairs({"Topbar_2016_A","Topbar_2016_S","Topbar_2014","Topbar_2013","Topbar_2012"}) do descriptors[id].models=true; descriptors[id].dependencies={legacy} end
    descriptors.Topbar_2020.dependencies = {settings}
    descriptors.SafeChat.dependencies = {safechat,URLs.safechatData}
    descriptors.Backpack_Advanced.models = true
    descriptors.BetterEmotes.requires = {"readfile","writefile","isfile","isfolder","makefolder"}
    descriptors.BetterEmotes.dependencies = {URLs.notify,URLs.emoteSettings,URLs.openEmote,emotes}
    descriptors.BetterEmotes.prepare = function(scope)
        scope:SetCoreGuiEnabled(scope.controller:GetService("StarterGui"),Enum.CoreGuiType.EmotesMenu,true)
        scope.environment.Notify=function(data)
            pcall(function() scope.controller:GetService("StarterGui"):SetCore("SendNotification",{Title=data.Title or "7yd7",Text=data.Content or data.Text or "",Duration=data.Duration or 5}) end)
        end
    end
    for _, id in ipairs({"Anims_R6_2008","Anims_R6_2006"}) do descriptors[id].rig="R6" end
    for _, id in ipairs({"Anims_R15_2008","Anims_R15_Old"}) do descriptors[id].rig="R15" end
    for _, id in ipairs({"Anims_R6_2006","Anims_R15_2008","Anims_R15_Old"}) do
        descriptors[id].prepare = function(scope)
            scope.environment.AnimationPreset = id == "Anims_R15_Old" and originalR15 or original2006
            scope.environment.ResolvePresetAssets = id ~= "Anims_R15_Old"
            scope.environment.ExpectedRig = descriptors[id].rig
        end
    end
    descriptors.Textures_2006.prepare=function(scope) scope.environment.WorldStyle="2006" end
    descriptors.Textures_2016.prepare=function(scope) scope.environment.WorldStyle="2016" end
    local sources={suite=Patches.Suite(Embedded.suite),["bp://classic-chat"]=classicChat}
    local transforms={legacy=Patches.Legacy,settings=Patches.Settings,safechat=Patches.SafeChat,emotes=Patches.Emotes}
    for _, key in ipairs({"legacy","settings","safechat","safechatData","emotes","emoteSettings","notify","openEmote"}) do
        if Embedded[key] then
            sources[URLs[key]]=transforms[key] and transforms[key](Embedded[key]) or Embedded[key]
        end
    end
    return {
        order={"topbar","safechat","backpack","animations","sounds","textures","forcefield","emotes"},
        portSources=Ports,
        map={
            topbar={["2020"]="Topbar_2020",["2016_Adv"]="Topbar_2016_A",["2016_Simp"]="Topbar_2016_S",["2014"]="Topbar_2014",["2013"]="Topbar_2013",["2012"]="Topbar_2012",Old_Chat="Topbar_OldChat"},
            safechat={["true"]="SafeChat"},backpack={simple="Backpack_Simple",advanced="Backpack_Advanced"},
            animations={R6_2008="Anims_R6_2008",R6_2006="Anims_R6_2006",R15_2008="Anims_R15_2008",R15_Old="Anims_R15_Old"},
            sounds={["true"]="OldSounds"},textures={["2006"]="Textures_2006",["2016"]="Textures_2016"},forcefield={["true"]="Forcefield"},emotes={["true"]="BetterEmotes"},
        },
        descriptors=descriptors,
        sources=sources,
        aliases={
            ["bp://legacy"]=legacy,["bp://project2016-settings"]=settings,["bp://emotes"]=emotes,["bp://safechat"]=safechat,
            ["https://raw.githubusercontent.com/lxte/Legacy/refs/heads/main/Source.luau"]=legacy,
            ["https://raw.githubusercontent.com/yeku/legacy/refs/heads/main/Source.luau"]=legacy,
            ["https://github.com/richie0866/rbxm-suite/releases/latest/download/rbxm-suite.lua"]="suite",
            ["https://raw.githubusercontent.com/yeku/forks/refs/heads/main/Scripts/RBXMSuite.luau"]="suite",
            ["https://raw.githubusercontent.com/xaviersupreme/Project2016/main/modules/settings.lua"]=settings,
            ["https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/Emotes.lua"]=emotes,
            ["https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/Settings.lua"]=URLs.emoteSettings,
            ["https://raw.githubusercontent.com/7yd7/Hub/refs/heads/Branch/GUIS/OpenEmote.lua"]=URLs.openEmote,
            ["https://raw.githubusercontent.com/7yd7/Menu-7yd7/refs/heads/Script/GUIS/Off-site/Notify.lua"]=URLs.notify,
            ["https://raw.githubusercontent.com/mehh0vcki/scripts/refs/heads/main/safechat.lua"]=safechat,
            ["https://raw.githubusercontent.com/mehh0vcki/scripts/refs/heads/main/static/safechat/2016.lua"]=URLs.safechatData,
        },
        sourcePatches={[legacy]=Patches.Legacy,[settings]=Patches.Settings,[safechat]=Patches.SafeChat,[emotes]=Patches.Emotes},
        patchModule=Patches.AssetModule,
    }
end

end)()
local Environment=(getgenv and getgenv()) or getfenv()
local previous=Environment.BloxyParadox
if type(previous)=="table" and previous.CanReload then
    local allowed,reason=previous:CanReload()
    if not allowed then warn("[Bloxy Paradox] "..reason); if previous.alive and previous.Open then previous.Open() end; return previous end
end
if type(previous)=="table" and previous.Unload then previous:Unload() end
local controller=Backend.new({game=game,task=task,loadstring=loadstring,setfenv=setfenv,environment=getfenv(),warn=warn},Instrument,Configure(Ports,Embedded,URLs,Patches))
Environment.BloxyParadox=controller
controller.ui:Run([============[-- Bloxy Paradox setup. Original project branding; direct category navigation.
local Installer = (function()
-- Setup choices and apply state. Port implementation and appearance live elsewhere.
local Installer = {}
Installer.__index = Installer
local traceback = debug and debug.traceback or tostring

Installer.Categories = {
    {id="topbar", title="Topbar", description="Choose the classic Roblox interface you want to use.", default="none", options={
        {value="none", title="Default", description="Use the experience's original topbar and chat."},
        {value="2020", title="2020 PC", description="Original 2020 icons, classic chat, and the complete classic settings menu."},
        {value="2016_Adv", title="2016 · native chat", description="2016 Legacy interface while keeping the experience's native chat."},
        {value="2016_Simp", title="2016 Legacy", description="The original 2016 interface, including classic chat."},
        {value="2014", title="2014", description="The original 2014 Legacy layout."},
        {value="2013", title="2013", description="The original 2013 Legacy layout."},
        {value="2012", title="2012", description="The original 2012 Legacy layout."},
        {value="Old_Chat", title="Classic chat only", description="Use the original classic-chat assets without changing the topbar."},
    }},
    {id="safechat", title="Safe chat", description="Use the original phrase menu with the current chat channels.", default="false", options={
        {value="false", title="Default", description="Leave the phrase menu off."},
        {value="true", title="2016 safe chat", description="Original menu and phrase tree. Left Ctrl closes the menu."},
    }},
    {id="backpack", title="Backpack", description="Choose how your tools appear in the hotbar and inventory.", default="none", options={
        {value="none", title="Default", description="Use the inventory supplied by your selected interface."},
        {value="simple", title="Simple 2008", description="The recovered original layout, with tool dragging, hotkeys and the mobile opener."},
        {value="advanced", title="Advanced", description="The original script is unavailable. This choice uses the complete Legacy 2016 backpack.", note="2016 fallback"},
    }},
    {id="animations", title="Animations", description="All four ports are shown. Select a port that matches your current character.", default="normal", options={
        {value="normal", title="Default", description="Use the character's original animation controller."},
        {value="R6_2008", title="2008 R6", description="Original desired-angle moveset for an R6 character."},
        {value="R6_2006", title="2006 R6", description="Classic movement preset for an R6 character."},
        {value="R15_2008", title="2008 R15", description="Classic movement preset for an R15 character."},
        {value="R15_Old", title="Old R15", description="Original R15 animation preset, including both idle variants."},
    }},
    {id="sounds", title="Sounds", description="Choose the character sound set.", default="false", options={
        {value="false", title="Default", description="Use the character's original sounds."},
        {value="true", title="Classic sounds", description="Original classic footstep and character sound assets."},
    }},
    {id="textures", title="Textures", description="Choose the world texture and sky style.", default="normal", options={
        {value="normal", title="Default", description="Use the experience's original textures and sky."},
        {value="2006", title="2006 textures", description="Original 2006 texture and sky assets."},
        {value="2016", title="2016 textures", description="Original 2016 texture and sky assets."},
    }},
    {id="forcefield", title="Forcefield", description="Choose the appearance used while your character has a forcefield.", default="false", options={
        {value="false", title="Default", description="Use the original forcefield appearance."},
        {value="true", title="Classic bubble", description="Original blue, two-shell forcefield bubble."},
    }},
    {id="emotes", title="Emotes", description="Use the complete 7yd7 emote port and editor.", default="false", options={
        {value="false", title="Default", description="Use the original emote wheel."},
        {value="true", title="Full 7yd7 emotes", description="HUD editor, themes, custom animation sets, saved pages, favorites, freeze, speed and mobile controls."},
    }},
}

local terminal = {Started=true, Default=true, Fallback=true, Error=true, Unchanged=true}
local byId = {}
for _, category in ipairs(Installer.Categories) do byId[category.id] = category end

function Installer.Layout(viewportWidth, viewportHeight)
    local width = math.max(0, math.min(860, viewportWidth-24))
    local height = math.max(0, math.min(620, viewportHeight-24))
    local narrow = width < 640
    local compact = height < 360
    local header, footer, gap = compact and 44 or 56, compact and 68 or 78, compact and 8 or 12
    local navHeight = narrow and (compact and 36 or 44) or 0
    local bodyTop = header+navHeight+gap
    local bodyHeight = math.max(0,height-bodyTop-footer-gap)
    local railWidth = narrow and 0 or 152
    local primaryWidth=math.min(180,math.max(100,width*0.48))
    return {width=width,height=height,narrow=narrow,compact=compact,header=header,footer=footer,
        nav={x=12,y=narrow and header or bodyTop,width=narrow and width-24 or railWidth,height=narrow and navHeight or bodyHeight},
        body={x=narrow and 12 or railWidth+24,y=bodyTop,width=math.max(0,width-(narrow and 24 or railWidth+36)),height=bodyHeight},
        footerY=height-footer,primaryWidth=primaryWidth,secondaryWidth=math.min(88,math.max(0,width-primaryWidth-36))}
end

function Installer.new(controller, options)
    options = options or {}
    local self = setmetatable({controller=controller,options=options,draft={},results={},view="topbar",theme="Light",visible=true,busy=false,phase="editing",listeners={},alive=true},Installer)
    for _, category in ipairs(Installer.Categories) do
        self.draft[category.id] = tostring(controller.applied[category.id] or category.default)
    end
    self.previousStatus = controller.onStatus
    self.statusHandler = function(id, state, message)
        if self.previousStatus then pcall(self.previousStatus,id,state,message) end
        if not self.alive or not byId[id] then return end
        local value = self.busy and self.snapshot[id] or self:Applied(id)
        self.results[id] = {state=state,message=tostring(message),value=value}
        if state=="Error" and not self.busy then self.phase="error" end
        self:Emit("status",id)
    end
    controller.onStatus = self.statusHandler
    return self
end

function Installer:Subscribe(callback)
    self.listeners[callback] = true
    return function() self.listeners[callback] = nil end
end
function Installer:Emit(reason, id)
    if not self.alive then return end
    for callback in pairs(self.listeners) do
        local ok,problem=pcall(callback,reason,id)
        if not ok and self.options.warn then self.options.warn(problem) end
    end
end
function Installer:Category(id) return byId[id] end
function Installer:Option(id, value)
    local category=byId[id]
    if category then for _, option in ipairs(category.options) do if option.value==value then return option end end end
end
function Installer:Label(id, value)
    local option=self:Option(id,value)
    return option and option.title or tostring(value)
end
function Installer:Applied(id) return tostring(self.controller.applied[id] or byId[id].default) end
function Installer:NeedsApply(id)
    return self.draft[id]~=self:Applied(id) or self.controller.failed[id]~=nil
end
function Installer:PendingCount()
    local count=0
    for _, category in ipairs(Installer.Categories) do if self:NeedsApply(category.id) then count+=1 end end
    return count
end
function Installer:Availability(id, value)
    local option = self:Option(id,value)
    if not option then return false,"Unknown option" end
    if value==byId[id].default then return true end
    local portId=self.controller.map[id] and self.controller.map[id][value]
    local descriptor=portId and self.controller.descriptors[portId]
    if not descriptor then return false,"This port is missing from the build." end
    local rig=self.options.rig and self.options.rig()
    if descriptor.rig and rig and descriptor.rig~=rig then
        return false,"Requires "..descriptor.rig..". Your current character is "..rig.."."
    end
    local environment=self.controller.host.environment
    if descriptor.models then
        if type(environment.getcustomasset or environment.getsynasset)~="function" then return false,"This classic model needs local-file and custom-asset support." end
        for _, name in ipairs({"isfile","isfolder","readfile","writefile","makefolder"}) do
            if type(environment[name])~="function" then return false,"This classic model needs local-file access." end
        end
    end
    for _, name in ipairs(descriptor.requires or {}) do
        if type(environment[name])~="function" then return false,"This port needs file access to load and save its settings." end
    end
    if descriptor.rig and not rig then return true,"Waiting for a character; rig compatibility will be checked again." end
    return true,option.note
end
function Installer:Select(id, value)
    if not self.alive or self.busy then return false end
    local allowed,reason=self:Availability(id,value)
    if not allowed then return false,reason end
    self.draft[id]=value
    self.phase="editing";self.fatalError=nil
    self:Emit("selection",id)
    return true
end
function Installer:SetView(id)
    if not byId[id] and id~="review" and id~="details" then return false end
    self.view=id;self:Emit("view");return true
end
function Installer:SetVisible(visible) self.visible=visible;self:Emit("visibility") end
function Installer:ToggleTheme() self.theme=self.theme=="Light" and "Dark" or "Light";self:Emit("theme") end
function Installer:ResetDraft()
    if self.busy then return false end
    for _, category in ipairs(Installer.Categories) do self.draft[category.id]=category.default end
    self.phase="editing";self.fatalError=nil;self:Emit("selection");return true
end
function Installer:RefreshCapabilities() self:Emit("capabilities") end
function Installer:Row(id)
    local result=self.results[id]
    if result and result.value==self.draft[id] then return result end
    local status=self.controller.status[id]
    if not self:NeedsApply(id) then
        return {state=status and status.state=="Fallback" and "Fallback" or (self.draft[id]==byId[id].default and "Default" or "Unchanged"),message=status and status.message or "",value=self.draft[id]}
    end
    local allowed,reason=self:Availability(id,self.draft[id])
    return {state=allowed and "Not applied" or "Unavailable",message=reason or "",value=self.draft[id]}
end
function Installer:Progress()
    local complete=0
    for _, category in ipairs(Installer.Categories) do if terminal[self:Row(category.id).state] then complete+=1 end end
    return complete,#Installer.Categories
end
function Installer:Details()
    local lines={"Bloxy Paradox setup"}
    if self.fatalError then table.insert(lines,self.fatalError) end
    for _, category in ipairs(Installer.Categories) do
        local row=self:Row(category.id)
        table.insert(lines,category.title..": "..self:Label(category.id,self.draft[category.id]).." | "..row.state)
        if row.message~="" then table.insert(lines,row.message) end
    end
    return table.concat(lines,"\n")
end
function Installer:Apply()
    if not self.alive or self.busy or self.controller.busy or self.controller.queued then return false,"Setup is already applying changes." end
    if self:PendingCount()==0 then return false,"There are no changes to apply." end
    self.view="review";self.fatalError=nil
    local blocked=false
    for _, category in ipairs(Installer.Categories) do
        local id=category.id
        local allowed,reason=self:Availability(id,self.draft[id])
        if self:NeedsApply(id) and not allowed then
            self.results[id]={state="Error",message=reason,value=self.draft[id]};blocked=true
        end
    end
    if blocked then self.phase="error";self:Emit("view");return false,"Choose compatible options before applying." end
    self.snapshot=table.clone(self.draft)
    for _, category in ipairs(Installer.Categories) do
        local id=category.id
        self.results[id]=self:NeedsApply(id) and {state="Waiting",message="",value=self.snapshot[id]} or self:Row(id)
    end
    self.busy=true;self.phase="applying";self.controller.queued=true
    self:Emit("view")
    local function run()
        if not self.alive then self.controller.queued=false;return end
        self.controller.queued=false
        local called,success,failures=xpcall(function() return self.controller:Apply(self.snapshot) end,traceback)
        if not self.alive then return end
        self.busy=false
        if not called then
            self.controller.busy=false
            self.fatalError=tostring(success)
        elseif not success then self.fatalError=table.concat(failures or {},"\n") end
        self.phase=called and success and "done" or "error"
        for _, category in ipairs(Installer.Categories) do
            local id=category.id
            if self.results[id].state=="Waiting" or self.results[id].state=="Checking" or self.results[id].state=="Loading" then
                self.results[id]={state=self:Applied(id)==self.snapshot[id] and (self.snapshot[id]==category.default and "Default" or "Started") or "Error",message=self.fatalError or "",value=self.snapshot[id]}
            end
        end
        self:Emit("finished")
    end
    local queued,problem=pcall(self.options.defer or task.defer,run)
    if not queued then
        self.controller.queued=false;self.busy=false;self.phase="error";self.fatalError=tostring(problem)
        for _,category in ipairs(Installer.Categories) do
            local row=self.results[category.id]
            if row.state=="Waiting" then row.state="Error";row.message=self.fatalError end
        end
        self:Emit("finished")
        return false,tostring(problem)
    end
    return true
end
function Installer:Destroy()
    self.alive=false;table.clear(self.listeners)
    if self.controller.onStatus==self.statusHandler then self.controller.onStatus=self.previousStatus end
    if self.busy then self.controller.queued=false end
end

return Installer

end)()
local controller = __BP.controller
local Players = game:GetService("Players")
local Input = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local player = Players.LocalPlayer
local model = Installer.new(controller, {
    rig=function()
        local humanoid=player.Character and player.Character:FindFirstChildOfClass("Humanoid")
        return humanoid and humanoid.RigType.Name
    end,
    defer=function(callback) return __BP:Spawn("defer",callback) end,
    warn=warn,
})
controller.installer = model

local palettes = {
    Light={surface=Color3.fromRGB(250,250,250),background=Color3.fromRGB(238,238,238),text=Color3.fromRGB(30,30,30),muted=Color3.fromRGB(90,90,90),border=Color3.fromRGB(195,195,195),accent=Color3.fromRGB(0,120,200),selected=Color3.fromRGB(225,239,250),onAccent=Color3.fromRGB(255,255,255),danger=Color3.fromRGB(165,30,30),warning=Color3.fromRGB(130,83,0),success=Color3.fromRGB(36,110,45)},
    Dark={surface=Color3.fromRGB(32,34,38),background=Color3.fromRGB(24,26,29),text=Color3.fromRGB(240,240,240),muted=Color3.fromRGB(180,182,186),border=Color3.fromRGB(81,85,91),accent=Color3.fromRGB(0,120,200),selected=Color3.fromRGB(34,59,81),onAccent=Color3.fromRGB(255,255,255),danger=Color3.fromRGB(255,145,145),warning=Color3.fromRGB(245,201,115),success=Color3.fromRGB(138,215,151)},
}
local permanentStyles, pageStyles = {}, {}
local navButtons, optionButtons, reviewRows = {}, {}, {}
local page, layout, detailsBox
local renderPage, refresh, relayout

local function make(class, parent, properties, owner)
    local object=(owner or __BP):Own(Instance.new(class))
    for key,value in pairs(properties or {}) do object[key]=value end
    object.Parent=parent
    return object
end
local function color(object, property, role, temporary)
    local bindings=temporary and pageStyles or permanentStyles
    bindings[object]=bindings[object] or {}
    bindings[object][property]=role
    object[property]=palettes[model.theme][role]
end
local function restyle()
    for _,bindings in ipairs({permanentStyles,pageStyles}) do
        for object,properties in pairs(bindings) do
            if object.Parent then for property,role in pairs(properties) do object[property]=palettes[model.theme][role] end end
        end
    end
end
local function corner(object, radius, owner)
    make("UICorner",object,{CornerRadius=UDim.new(0,radius or 6)},owner)
end
local function label(parent, name, text, size, owner)
    local object=make("TextLabel",parent,{Name=name,Text=text,Font=Enum.Font.Gotham,TextSize=size or 13,BackgroundTransparency=1,BorderSizePixel=0,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,TextWrapped=true,Size=UDim2.new(1,0,0,size or 18),AutomaticSize=Enum.AutomaticSize.Y},owner)
    color(object,"TextColor3","text",owner~=nil)
    return object
end
local function button(parent, name, text, owner)
    local object=make("TextButton",parent,{Name=name,Text=text,Font=Enum.Font.GothamMedium,TextSize=13,TextWrapped=true,BorderSizePixel=0,AutoButtonColor=true,Selectable=true,Active=true},owner)
    color(object,"BackgroundColor3","background",owner~=nil)
    color(object,"TextColor3","text",owner~=nil)
    corner(object,5,owner)
    return object
end
local function stack(parent, owner, padding)
    return make("UIListLayout",parent,{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,padding or 6)},owner)
end
local function padding(parent, amount, owner)
    make("UIPadding",parent,{PaddingLeft=UDim.new(0,amount),PaddingRight=UDim.new(0,amount),PaddingTop=UDim.new(0,amount),PaddingBottom=UDim.new(0,amount)},owner)
end

local gui=make("ScreenGui",gethui(),{Name="BloxyParadoxSetup",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=10000,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
local overlay=make("Frame",gui,{Name="Dimmer",Size=UDim2.fromScale(1,1),BackgroundColor3=Color3.new(0,0,0),BackgroundTransparency=0.55,BorderSizePixel=0,Active=true})
local window=make("Frame",gui,{Name="Window",AnchorPoint=Vector2.new(0.5,0.5),Position=UDim2.fromScale(0.5,0.5),ClipsDescendants=true,BorderSizePixel=0})
color(window,"BackgroundColor3","surface");corner(window,8)
local windowStroke=make("UIStroke",window,{Thickness=1,ApplyStrokeMode=Enum.ApplyStrokeMode.Border})
color(windowStroke,"Color","border")

local header=make("Frame",window,{Name="Header",BackgroundTransparency=1})
local logo=make("ImageLabel",header,{Name="Logo",BackgroundTransparency=1,Image="rbxthumb://type=Asset&id=131822012703327&w=420&h=420"})
local brand=label(header,"Brand","Bloxy Paradox",17)
brand.AutomaticSize=Enum.AutomaticSize.None;brand.TextWrapped=false;brand.Font=Enum.Font.GothamBold
local caption=label(header,"Caption","Classic setup",11)
caption.AutomaticSize=Enum.AutomaticSize.None;caption.TextWrapped=false;color(caption,"TextColor3","muted")
local themeButton=button(header,"Theme","Dark")
local closeButton=button(header,"Close","×")
closeButton.TextSize=22

local navigation=make("ScrollingFrame",window,{Name="Categories",BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.new(),ScrollBarThickness=3})
color(navigation,"ScrollBarImageColor3","muted")
local navLayout=stack(navigation)
for index,category in ipairs(Installer.Categories) do
    local tab=button(navigation,category.id,category.title)
    tab.LayoutOrder=index;tab.TextXAlignment=Enum.TextXAlignment.Left
    make("UIPadding",tab,{PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,4)})
    navButtons[category.id]=tab
    __BP:Connect(tab.Activated,function() model:SetView(category.id) end)
end

local content=make("ScrollingFrame",window,{Name="Choices",BackgroundTransparency=1,BorderSizePixel=0,CanvasSize=UDim2.new(),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ScrollBarThickness=4})
color(content,"ScrollBarImageColor3","muted")

local footer=make("Frame",window,{Name="Footer",BackgroundTransparency=1})
local separator=make("Frame",footer,{Name="Separator",Size=UDim2.new(1,-24,0,1),Position=UDim2.fromOffset(12,0),BorderSizePixel=0})
color(separator,"BackgroundColor3","border")
local summary=label(footer,"Summary","Choose a category to begin.",11)
summary.AutomaticSize=Enum.AutomaticSize.None;summary.TextYAlignment=Enum.TextYAlignment.Center
color(summary,"TextColor3","muted")
local detailsButton=button(footer,"Details","Details")
detailsButton.BackgroundTransparency=1
local resetButton=button(footer,"Defaults","Defaults")
local primaryButton=button(footer,"Primary","Review choices")
color(primaryButton,"BackgroundColor3","accent");color(primaryButton,"TextColor3","onAccent")
local progress=make("Frame",footer,{Name="Progress",Position=UDim2.fromOffset(12,1),Size=UDim2.new(1,-24,0,2),BorderSizePixel=0,Visible=false})
color(progress,"BackgroundColor3","border")
local progressFill=make("Frame",progress,{Name="Fill",Size=UDim2.fromScale(0,1),BorderSizePixel=0})
color(progressFill,"BackgroundColor3","accent")

local launcher=button(gui,"Reopen","Bloxy setup")
launcher.AnchorPoint=Vector2.new(0,1);launcher.Position=UDim2.new(0,12,1,-12);launcher.Size=UDim2.fromOffset(132,36);launcher.Visible=false
color(launcher,"BackgroundColor3","accent");color(launcher,"TextColor3","onAccent")

local stateLabels={Started="Started",Unchanged="Active",Default="Default",Waiting="Waiting",Checking="Checking",Loading="Starting",Fallback="Fallback",Error="Failed",Unavailable="Unavailable",["Not applied"]="Not applied"}
local function stateRole(state)
    if state=="Error" or state=="Unavailable" then return "danger" end
    if state=="Fallback" then return "warning" end
    if state=="Started" or state=="Unchanged" then return "success" end
    return "muted"
end
local function firstLine(message) return string.match(message or "","[^\r\n]+") or "" end
local function updateRows()
    for id,widgets in pairs(reviewRows) do
        local row=model:Row(id)
        widgets.value.Text=model:Label(id,model.draft[id])
        widgets.status.Text=stateLabels[row.state] or row.state
        color(widgets.status,"TextColor3",stateRole(row.state),true)
        local detail=""
        if row.state=="Error" or row.state=="Unavailable" or row.state=="Fallback" then detail=firstLine(row.message) end
        if row.state=="Error" and model:Applied(id)~=model.draft[id] then
            detail..=(detail~="" and "\n" or "").."Still using: "..model:Label(id,model:Applied(id))
        end
        widgets.detail.Text=detail;widgets.detail.Visible=detail~=""
        color(widgets.detail,"TextColor3",stateRole(row.state),true)
    end
    for id,tab in pairs(navButtons) do
        local selected=model.view==id
        color(tab,"BackgroundColor3",selected and "selected" or "background")
        tab.Font=selected and Enum.Font.GothamBold or Enum.Font.GothamMedium
    end
    for value,widgets in pairs(optionButtons) do
        local selected=model.draft[model.view]==value
        local allowed,reason=model:Availability(model.view,value)
        widgets.button.Active=allowed and not model.busy;widgets.button.Selectable=widgets.button.Active
        widgets.title.Text=(selected and "✓  " or "")..widgets.option.title
        color(widgets.button,"BackgroundColor3",selected and "selected" or "background",true)
        widgets.stroke.Thickness=selected and 2 or 1
        color(widgets.stroke,"Color",selected and "accent" or "border",true)
        color(widgets.title,"TextColor3",allowed and "text" or "muted",true)
        widgets.note.Text=reason or "";widgets.note.Visible=reason~=nil
        color(widgets.note,"TextColor3",allowed and "warning" or "danger",true)
    end
    if detailsBox then detailsBox.Text=model:Details() end
end

renderPage=function()
    local selected=GuiService.SelectedObject
    local transferFocus=page and selected and page.owned[selected]
    table.clear(pageStyles);table.clear(optionButtons);table.clear(reviewRows);detailsBox=nil
    page=__BP:Fork("installer-page")
    local body=make("Frame",content,{Name="Page",Size=UDim2.new(1,-8,0,0),AutomaticSize=Enum.AutomaticSize.Y,BackgroundTransparency=1},page)
    stack(body,page,8)
    local category=model:Category(model.view)
    local title=label(body,"Heading",category and category.title or (model.view=="details" and "Setup details" or "Review & apply"),19,page)
    title.Font=Enum.Font.GothamBold;title.LayoutOrder=1
    local description=label(body,"Description",category and category.description or (model.view=="details" and "Select the text to copy it, or use the Copy button when available." or "Choose a row to edit it. Changes take effect when you apply."),12,page)
    description.LayoutOrder=2;color(description,"TextColor3","muted",true)
    if category then
        for index,option in ipairs(category.options) do
            local choice=button(body,"option_"..option.value,"",page)
            choice.LayoutOrder=index+2;choice.Size=UDim2.new(1,0,0,64);choice.AutomaticSize=Enum.AutomaticSize.Y
            padding(choice,12,page);stack(choice,page,4)
            local stroke=make("UIStroke",choice,{ApplyStrokeMode=Enum.ApplyStrokeMode.Border,Thickness=1},page)
            local name=label(choice,"Title",option.title,14,page);name.Font=Enum.Font.GothamBold;name.LayoutOrder=1
            local text=label(choice,"Description",option.description,12,page);text.LayoutOrder=2;color(text,"TextColor3","muted",true)
            local note=label(choice,"Availability","",11,page);note.LayoutOrder=3
            optionButtons[option.value]={button=choice,title=name,note=note,stroke=stroke,option=option}
            page:Connect(choice.Activated,function() model:Select(category.id,option.value) end)
        end
    elseif model.view=="review" then
        for index,item in ipairs(Installer.Categories) do
            local row=button(body,"review_"..item.id,"",page)
            row.Size=UDim2.new(1,0,0,68);row.AutomaticSize=Enum.AutomaticSize.Y;row.LayoutOrder=index+2
            padding(row,10,page);stack(row,page,3)
            local name=label(row,"Category",item.title,11,page);name.LayoutOrder=1;color(name,"TextColor3","muted",true)
            local value=label(row,"Choice","",14,page);value.LayoutOrder=2;value.Font=Enum.Font.GothamBold
            local status=label(row,"Status","",11,page);status.LayoutOrder=3
            local detail=label(row,"Message","",12,page);detail.LayoutOrder=4
            reviewRows[item.id]={button=row,value=value,status=status,detail=detail}
            page:Connect(row.Activated,function() model:SetView(item.id) end)
        end
    else
        local back=button(body,"BackToReview","Back to review",page)
        back.Size=UDim2.new(1,0,0,36);back.LayoutOrder=3
        page:Connect(back.Activated,function() model:SetView("review") end)
        if type(controller.host.environment.setclipboard)=="function" then
            local copy=button(body,"CopyDetails","Copy details",page)
            copy.Size=UDim2.new(1,0,0,36);copy.LayoutOrder=4
            page:Connect(copy.Activated,function() pcall(controller.host.environment.setclipboard,model:Details()) end)
        end
        detailsBox=make("TextBox",body,{Name="Log",LayoutOrder=5,Text=model:Details(),TextEditable=false,ClearTextOnFocus=false,MultiLine=true,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,Font=Enum.Font.Code,TextSize=12,BackgroundTransparency=1,Size=UDim2.new(1,0,0,24),AutomaticSize=Enum.AutomaticSize.Y},page)
        color(detailsBox,"TextColor3","text",true)
    end
    content.CanvasPosition=Vector2.new(0,0)
    updateRows()
    if transferFocus then
        local selectedOption=optionButtons[model.draft[model.view]]
        local focus=selectedOption and selectedOption.button.Active and selectedOption.button
        if not focus and model.view=="review" then focus=reviewRows[Installer.Categories[1].id].button end
        GuiService.SelectedObject=focus or navButtons[model.view] or primaryButton
    end
end

refresh=function()
    window.Visible=model.visible;overlay.Visible=model.visible;launcher.Visible=not model.visible
    themeButton.Text=model.theme=="Light" and "Dark" or "Light"
    local pending=model:PendingCount()
    local complete,total=model:Progress()
    progress.Visible=model.busy;progressFill.Size=UDim2.fromScale(complete/total,1)
    resetButton.Active=not model.busy;resetButton.Selectable=not model.busy
    if model.busy then
        primaryButton.Text="Applying "..complete.." / "..total
        primaryButton.Active=false;primaryButton.Selectable=false
        summary.Text="Applying changes…"
    else
        primaryButton.Active=true;primaryButton.Selectable=true
        if model.view~="review" then primaryButton.Text="Review choices"
        elseif pending>0 then primaryButton.Text=(model.phase=="error" and "Retry " or "Apply ")..pending..(pending==1 and " change" or " changes")
        else primaryButton.Text="Close setup" end
        if model.phase=="error" then summary.Text="Review failed choices."
        elseif model.phase=="done" then summary.Text="Applied. Check in game."
        elseif pending==0 then summary.Text="No pending changes."
        else summary.Text=pending..(pending==1 and " pending change." or " pending changes.") end
    end
    color(summary,"TextColor3",model.phase=="error" and "danger" or "muted")
    updateRows()
end

local function viewport()
    local camera=workspace.CurrentCamera
    local size=camera and camera.ViewportSize
    return size and size.X>0 and size.Y>0 and size or Vector2.new(960,640)
end
relayout=function()
    local size=viewport()
    layout=Installer.Layout(size.X,size.Y)
    window.Size=UDim2.fromOffset(layout.width,layout.height)
    header.Size=UDim2.new(1,0,0,layout.header)
    local top=layout.compact and 6 or 10
    logo.Size=UDim2.fromOffset(30,30);logo.Position=UDim2.fromOffset(12,top)
    brand.Position=UDim2.fromOffset(50,top);brand.Size=UDim2.new(1,-172,0,22);brand.TextSize=layout.width<400 and 15 or 17
    caption.Position=UDim2.fromOffset(50,top+23);caption.Size=UDim2.new(1,-172,0,14);caption.Visible=not layout.compact
    themeButton.Position=UDim2.new(1,-114,0,top);themeButton.Size=UDim2.fromOffset(58,32)
    closeButton.Position=UDim2.new(1,-48,0,top);closeButton.Size=UDim2.fromOffset(36,32)
    navigation.Position=UDim2.fromOffset(layout.nav.x,layout.nav.y);navigation.Size=UDim2.fromOffset(layout.nav.width,layout.nav.height)
    navigation.AutomaticCanvasSize=layout.narrow and Enum.AutomaticSize.X or Enum.AutomaticSize.Y
    navigation.ScrollingDirection=layout.narrow and Enum.ScrollingDirection.X or Enum.ScrollingDirection.Y
    navLayout.FillDirection=layout.narrow and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
    for _,tab in pairs(navButtons) do tab.Size=layout.narrow and UDim2.fromOffset(112,layout.nav.height-4) or UDim2.new(1,-6,0,40) end
    content.Position=UDim2.fromOffset(layout.body.x,layout.body.y);content.Size=UDim2.fromOffset(layout.body.width,layout.body.height)
    footer.Position=UDim2.fromOffset(0,layout.footerY);footer.Size=UDim2.new(1,0,0,layout.footer)
    summary.Position=UDim2.fromOffset(12,5);summary.Size=UDim2.new(1,-88,0,24)
    detailsButton.Position=UDim2.new(1,-72,0,3);detailsButton.Size=UDim2.fromOffset(60,26)
    resetButton.Position=UDim2.fromOffset(12,32);resetButton.Size=UDim2.fromOffset(layout.secondaryWidth,layout.compact and 30 or 36)
    primaryButton.Position=UDim2.new(1,-12-layout.primaryWidth,0,32);primaryButton.Size=UDim2.fromOffset(layout.primaryWidth,layout.compact and 30 or 36)
end

__BP:Connect(themeButton.Activated,function() model:ToggleTheme() end)
__BP:Connect(closeButton.Activated,function() model:SetVisible(false) end)
__BP:Connect(launcher.Activated,function() model:SetVisible(true) end)
__BP:Connect(detailsButton.Activated,function() model:SetView("details") end)
__BP:Connect(resetButton.Activated,function() model:ResetDraft() end)
__BP:Connect(primaryButton.Activated,function()
    if model.busy then return end
    if model.view~="review" then model:SetView("review")
    elseif model:PendingCount()>0 then model:Apply()
    else model:SetVisible(false) end
end)
__BP:Connect(Input.InputBegan,function(input,processed)
    if processed then return end
    if input.KeyCode==Enum.KeyCode.F8 then model:SetVisible(not model.visible)
    elseif input.KeyCode==Enum.KeyCode.Escape and model.visible then model:SetVisible(false) end
end)

local function bindCharacter(character)
    local generation=__BP:Fork("installer-character")
    local function observeHumanoid(humanoid)
        if not humanoid:IsA("Humanoid") then return end
        generation:Connect(humanoid:GetPropertyChangedSignal("RigType"),function() model:RefreshCapabilities() end)
        model:RefreshCapabilities()
    end
    for _,child in ipairs(character:GetChildren()) do observeHumanoid(child) end
    generation:Connect(character.ChildAdded,observeHumanoid)
    model:RefreshCapabilities()
end
__BP:Connect(player.CharacterAdded,bindCharacter)
__BP:Connect(player:GetPropertyChangedSignal("Character"),function()
    if not player.Character then __BP:Drop("installer-character");model:RefreshCapabilities() end
end)
local function bindCamera()
    local generation=__BP:Fork("installer-camera")
    local camera=workspace.CurrentCamera
    if camera then generation:Connect(camera:GetPropertyChangedSignal("ViewportSize"),relayout) end
    relayout()
end
__BP:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"),bindCamera)

local unsubscribe=model:Subscribe(function(reason)
    if reason=="view" or reason=="capabilities" then renderPage() end
    if reason=="theme" then restyle() end
    refresh()
end)
local open=function() model:SetVisible(true) end
controller.Open=open
__BP:Add(function()
    unsubscribe();model:Destroy()
    if controller.Open==open then controller.Open=nil end
    if controller.installer==model then controller.installer=nil end
end)
if player.Character then bindCharacter(player.Character) end
bindCamera();renderPage();refresh()
]============],"@BloxyParadox/installer")
return controller
