-- PBZAutoQTE: passes on-screen QTEs for Phantom Blade Zero (single player).
-- An accessibility mod, made with players with motor disabilities in mind. MIT License.
--
-- Facts (from the game files and measurements in the game):
--   * Every timed QTE is an AbilityTask_RegisterQTE: ListenInputAction is the key it waits for (also the randomly
--     drawn one), TaskType tells a single press from repeated presses and a long press.
--   * Injecting the input action through Enhanced Input is seen by the QTE like a real press (rider QTEs, measured).
--
-- Keys: F3 = auto QTE on/off.
-- Settings are remembered in settings.txt next to this mod; set `log = true` below for autoqte.log.

local CFG = {
    enabled = true,
    pressDelay = 0.10,   -- seconds of real time before the first press (the prompt has to be up)
    pulse = 0.05,        -- seconds down / seconds up, so that repeated-press QTEs count every press
    pressLength = 0.15,  -- seconds a single-press QTE stays down
    maxTask = 6.0,       -- seconds; a task still listed after this is finished and only waiting for cleanup
    keyDebounce = 0.25,
    log = false,         -- true = write autoqte.log next to this mod (for bug reports)
}

-- Folder of this mod (…/ue4ss/Mods/PBZAutoQTE/), so nothing depends on where the game is installed.
local MOD_DIR = (function()
    -- Called directly (not through pcall, which would report pcall itself as level 1).
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:gsub("^@", ""):gsub("\\", "/"):match("^(.*/)Scripts/[^/]*$")
    return dir or "Mods/PBZAutoQTE/" -- UE4SS runs with the ue4ss folder as working directory
end)()

local LOG_PATH = MOD_DIR .. "autoqte.log"
local logFile = CFG.log and io.open(LOG_PATH, "a") or nil
local function log(...)
    if not logFile then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    logFile:write(os.date("%H:%M:%S "), table.concat(parts, "\t"), "\n")
    logFile:flush()
end

local S = { tasks = {} }

local function valid(o) return o ~= nil and o:IsValid() end

local function findLive(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        if valid(o) and not o:GetFName():ToString():find("^Default__") then return o end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Persistent on/off state.
local STATE_PATH = MOD_DIR .. "settings.txt"

local function saveState()
    local f = io.open(STATE_PATH, "w")
    if f then f:write(string.format("enabled=%d\n", CFG.enabled and 1 or 0)) f:close() end
end

local function loadState()
    local f = io.open(STATE_PATH, "r")
    if not f then return false end
    local text = f:read("a")
    f:close()
    local e = text:match("enabled=(%d)")
    if e then CFG.enabled = e == "1" end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- On-screen tips (game's own text tip).
local TIP_TAG = { TagName = FName("UI.ExtensionPoint.TextTips") }
local TIP_CLASS = "/Game/PBZContent/UI/FrontEnd/WB_TextTipsObj.WB_TextTipsObj_C"

local function statusText() return "Auto QTE: " .. (CFG.enabled and "ON" or "OFF") end

local function hideTip()
    if S.tipHandle then
        pcall(function()
            local ext = findLive("UIExtensionSubsystem")
            if valid(ext) then ext:UnregisterExtension(S.tipHandle) end
        end)
    end
    S.tipHandle, S.tipHideAt = nil, nil
end

local function showTip(text, clock)
    hideTip()
    local ok, err = pcall(function()
        local ext = findLive("UIExtensionSubsystem")
        local cls = StaticFindObject(TIP_CLASS)
        if not (valid(ext) and valid(cls)) then return end
        ext:UnregisterExtensionByTag(TIP_TAG)
        local obj = StaticConstructObject(cls, ext)
        obj.ShowText = FText(text)
        S.tipHandle = ext:K2_RegisterExtensionAsData(TIP_TAG, obj, 0)
    end)
    if not ok then log("TIP error", err) end
    S.tipHideAt = clock + 3.0
end

-- ---------------------------------------------------------------------------------------------
local function press(action)
    if not valid(S.input) then S.input = findLive("EnhancedInputLocalPlayerSubsystem") end
    S.input:InjectInputVectorForAction(action, { X = 1.0, Y = 0.0, Z = 0.0 }, {}, {})
end

local KINDS = { [0] = "press", [1] = "repeat", [2] = "hold" } -- EQTETaskType
local STATE_FAIL, STATE_SUCCESS = 2, 3                        -- EQTETaskProgressType

local function handleTask(task, clock, alive)
    local addr = task:GetAddress()
    alive[addr] = true
    local st = S.tasks[addr]
    if not st then
        local action = task.ListenInputAction
        st = { first = clock, action = action, kind = KINDS[task.TaskType] or "press" }
        S.tasks[addr] = st
        log("TASK", valid(action) and action:GetFName():ToString() or "-", st.kind, string.format("total=%.2f", task.TotalTime))
    end
    if st.over or not valid(st.action) then return end
    local held = clock - st.first - CFG.pressDelay
    -- A finished task stays listed until garbage collection and must not get any more presses.
    local state = task.EQTETaskProgressType
    if state == STATE_FAIL or state == STATE_SUCCESS or task.bInputActionCompleted or clock - st.first > CFG.maxTask
        or (st.kind == "press" and held > CFG.pressLength)
        or (st.kind == "repeat" and task.CurrentProgress >= 100) then
        st.over = true
        log("DONE", st.kind, string.format("after %.2fs state=%s progress=%.0f time=%.2f", clock - st.first, tostring(state),
            task.CurrentProgress, task.CurrentTime))
        return
    end
    if held < 0 then return end
    if st.kind ~= "repeat" or math.floor(held / CFG.pulse) % 2 == 0 then press(st.action) end
end

local function tick()
    local clock = os.clock()
    if S.tipHideAt and clock >= S.tipHideAt then hideTip() end
    if S.tipPending then
        local text = S.tipPending
        S.tipPending = nil
        showTip(text, clock)
    end
    if not S.announced then
        local pc = findLive("PlayerController")
        if valid(pc) and valid(pc.Pawn) then
            S.announced = true
            S.tipPending = statusText()
        end
    end
    if not CFG.enabled then return end
    local alive = {}
    for _, task in ipairs(FindAllOf("AbilityTask_RegisterQTE") or {}) do
        if valid(task) and not task:GetFName():ToString():find("^Default__") then handleTask(task, clock, alive) end
    end
    for addr in pairs(S.tasks) do
        if not alive[addr] then S.tasks[addr] = nil end
    end
end

local errors = 0
LoopInGameThreadAfterFrames(1, function()
    local ok, err = pcall(tick)
    if not ok then
        errors = errors + 1
        if errors <= 20 then log("ERROR", err) end
    end
    return false
end)

pcall(function()
    RegisterKeyBind(Key.F3, function()
        local clock = os.clock()
        if clock - (S.keyAt or -100) < CFG.keyDebounce then return end
        S.keyAt = clock
        CFG.enabled = not CFG.enabled
        saveState()
        S.tipPending = statusText()
        log("STATUS enabled=" .. tostring(CFG.enabled))
    end)
end)

log("PBZAutoQTE loaded")
if not loadState() then saveState() end
log("STATUS enabled=" .. tostring(CFG.enabled))
print("[PBZAutoQTE] loaded\n")
