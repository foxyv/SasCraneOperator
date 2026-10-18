-- SasCraneOperator: a crew member who works the dock crane for a cargo boat.
--
-- Cargo boats that have no crew positions get one: "Crane Operator", in the boat's crew chart. Put a
-- hired crew member who is assigned to the boat into it and, while the boat is docked beside a dock crane,
-- they load and unload the cargo that the Ships At Sea Logistics planner has marked for this port,
-- or that has been marked by hand, one piece at a time, sitting in the crane's seat while they work.
--
-- Ctrl+Alt+O  seats the first resting crew member of the boat you are next to as crane operator, or
--             takes the operator off again. Use it if dragging in the crew chart does not take.
-- Ctrl+Alt+H  sets where the operator stands on the boat when not at the crane: where you are standing.
-- F5          marks the piece of crane cargo you are looking at for the operator to move: to the boat
--             if it is on the dock, to the dock if it is in the hold. Again takes the mark off.
--
-- What it changes in the game: the crew position is added to the boat while the mod runs and is not
-- written to the save, so a save loads the same with or without the mod; the operator's name is
-- remembered in operators.txt beside this mod and they are seated again after a load. Cargo is moved
-- with the crane's own attach and set-down calls, and the stationary dock crane's joints are steered
-- so that the hook goes to the piece and carries it across.
--
-- Everything runs on the game thread, from game-thread timers. Key presses and hooks only queue work.

-- Settings in capitals are plain globals of this mod's own Lua state: a Lua chunk may only have 200
-- locals, and this one has more than that.
local ScriptDir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local OperatorsPath = ScriptDir .. "\\..\\operators.txt"
local SpotsPath = ScriptDir .. "\\..\\spots.txt"
local MarksPath = ScriptDir .. "\\..\\..\\SasLogistics\\crane_orders.txt"  -- written by the planner while "Send orders to the crane operator" is on


-- Which copy of this script is running. The log says a release name and a checksum of the file itself
-- (tools/check_lua.py --running compares it with the repository's), so there is never a doubt whether the
-- game loaded the version that was meant to be deployed.
SCRIPT_VERSION = "2026-10-18.8"
function ScriptChecksum()
    local file = io.open(debug.getinfo(1, "S").source:sub(2), "rb")
    if not file then return "unreadable", 0 end
    local text = file:read("*a")
    file:close()
    local hash = 2166136261  -- FNV-1a, 32 bits
    for i = 1, #text do hash = ((hash ~ text:byte(i)) * 16777619) & 0xFFFFFFFF end
    return string.format("%08X", hash), #text
end
do
    local checksum, bytes = ScriptChecksum()
    print("[SasCraneOperator] version " .. SCRIPT_VERSION .. ", file checksum " .. checksum .. " (" .. bytes .. " bytes)\n")
end

CATEGORY = "/Game/ShipsAtSea/Crew/CrewTaskCategories/DA_CrewTaskCategory_Engineering.DA_CrewTaskCategory_Engineering"
GROUP_NAME = "Crane Operator"
TOAST_CHANNEL = "Channel.Toast.Simple.Info"
TICK_MS = 500
MOTION_MS = 100            -- how often the crane's joints are steered
CRANE_REACH_CM = 10000     -- the boat's hold must be this close to a dock crane
CARGO_REACH_CM = 8000      -- dock cargo and dock areas must be this close to the crane

---------------------------------------------------------------------------------------------------
-- Helpers

local function Valid(obj)
    return obj ~= nil and type(obj) == "userdata" and pcall(function() return obj:IsValid() end) and obj:IsValid()
end

local function Live(className)
    local found = {}
    for _, obj in ipairs(FindAllOf(className) or {}) do
        local ok, full = pcall(function() return obj:GetFullName() end)
        if ok and not full:find("Default__", 1, true) then found[#found + 1] = obj end
    end
    return found
end

local function ClassName(obj)
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    return ok and name or ""
end

local function Same(a, b)
    if not Valid(a) or not Valid(b) then return false end
    local ok, same = pcall(function() return a:GetAddress() == b:GetAddress() end)
    return ok and same
end

local function Each(array, fn)
    if array == nil then return end
    array:ForEach(function(_, element) fn(element:get()) end)
end

local function Count(array)
    local n = 0
    pcall(function() Each(array, function() n = n + 1 end) end)
    return n
end

local function Dist(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2)
end

-- Distance in all three directions (Dist above ignores height).
function Dist3(a, b)
    return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
end

local function GuidStr(g)
    return string.format("%08X%08X%08X%08X", g.A & 0xFFFFFFFF, g.B & 0xFFFFFFFF, g.C & 0xFFFFFFFF, g.D & 0xFFFFFFFF)
end

local function MemberName(member)
    local ok, name = pcall(function() return member.CrewMemberName:ToString() end)
    return ok and name or "?"
end

local function Log(text)
    print("[SasCraneOperator] " .. text .. "\n")
end

-- Reloading. A reload (Ctrl+R) starts a new copy of this script, and the old copy's timers and hooks
-- may still be called for a moment while the game tears it down. Each copy writes its own id to a
-- file at load; a copy whose id is no longer the one in the file has been replaced, and does nothing
-- more, so it never touches the world while the new copy is setting itself up.
InstancePath = ScriptDir .. "\\..\\instance.txt"
InstanceId = string.format("%d-%d", os.time(), math.floor(os.clock() * 1000000) % 1000000)
do
    local file = io.open(InstancePath, "w")
    if file then
        file:write(InstanceId)
        file:close()
    end
end
StaleChecked, StaleNow = 0, false

function Stale()
    local now = os.clock()
    if now - StaleChecked < 0.2 then return StaleNow end
    StaleChecked = now
    local file = io.open(InstancePath, "r")
    if file then
        local id = file:read("*a")
        file:close()
        StaleNow = id ~= nil and id ~= "" and id ~= InstanceId
    end
    return StaleNow
end

local function Toast(text)
    Log(text)
    local ok, err = pcall(function()
        local library = StaticFindObject("/Script/SasGameplayMessageSystem.Default__SasToastFunctionLibrary")
        local controller = FindFirstOf("PlayerController")
        library:SendSimpleToast(controller, { TagName = FName(TOAST_CHANNEL) }, FText(text), controller)
    end)
    if not ok then Log("toast failed: " .. tostring(err):gsub("\n.*", "")) end
end

-- Clears an object reference. Which of the two forms this UE4SS build accepts is not documented.
local function ClearRef(object, property)
    if pcall(function() object[property] = nil end) and not Valid(object[property]) then return true end
    return pcall(function() object[property] = CreateInvalidObject() end)
end

---------------------------------------------------------------------------------------------------
-- Remembered operators: one crew member name per line.

local function ReadOperators()
    local names = {}
    local file = io.open(OperatorsPath, "r")
    if not file then return names end
    for line in file:lines() do
        local name = line:match("^%s*(.-)%s*$")
        if name ~= "" then names[name] = true end
    end
    file:close()
    return names
end

local Operators = ReadOperators()

local function Remember(name, on)
    Operators[name] = on or nil
    local file = io.open(OperatorsPath, "w")
    if not file then return end
    for remembered in pairs(Operators) do file:write(remembered, "\n") end
    file:close()
end

---------------------------------------------------------------------------------------------------
-- The crew position. Built the way the game builds them on a boat that has crew: a group owned by the
-- boat's crew component, a slot owned by the group, and an entry in the component's slot table. It
-- uses the game's own "Engineering" category, which has no jobs of its own.

-- The position is recognised by its group's name, so that it is still known after the mod is reloaded.
local function IsOurSlot(slot)
    if not Valid(slot) then return false end
    local ok, name = pcall(function() return slot.CrewGroup.GroupName:ToString() end)
    return ok and name == GROUP_NAME
end

local function CraneSlot(comp)
    local found = nil
    pcall(function()
        Each(comp.CrewGroups, function(group)
            Each(group.CrewSlots, function(slot)
                if not found and IsOurSlot(slot) then found = slot end
            end)
        end)
    end)
    return found
end

local function BuildPosition(comp, boat)
    local category = StaticFindObject(CATEGORY)
    if not Valid(category) then category = LoadAsset(CATEGORY) end
    local groupClass = StaticFindObject("/Script/Sas.SasCrewGroup")
    local slotClass = StaticFindObject("/Script/Sas.SasCrewSlot")
    if not Valid(category) or not Valid(groupClass) or not Valid(slotClass) then return false end

    local group = StaticConstructObject(groupClass, comp)
    if not Valid(group) then return false end
    local slot = StaticConstructObject(slotClass, group)
    if not Valid(slot) then return false end
    -- A boat with crew positions of its own keeps them; the new group is added after them, and its
    -- slot takes the next free number in the category so that it clashes with none of theirs.
    local index = 0
    comp.SlotMap:ForEach(function(key)
        local id = key:get()
        if Same(id.TaskGroupCategory, category) then index = math.max(index, id.SlotIndex + 1) end
    end)
    group.BoatCrewComponent = comp
    group.CrewTaskCategory = category
    group.GroupName = FText(GROUP_NAME)
    slot.CrewGroup = group
    slot.SlotId = { TaskGroupCategory = category, SlotIndex = index }
    slot.PrimarySlot = slot
    slot.bAllowTaskAssignment = true
    group.CrewSlots = { slot }
    local groups, categories, known = {}, {}, false
    Each(comp.CrewGroups, function(existing) groups[#groups + 1] = existing end)
    Each(comp.CrewTaskCategories, function(existing)
        categories[#categories + 1] = existing
        if Same(existing, category) then known = true end
    end)
    groups[#groups + 1] = group
    if not known then categories[#categories + 1] = category end
    comp.CrewTaskCategories = categories
    comp.CrewGroups = groups
    comp.SlotMap:Add({ TaskGroupCategory = category, SlotIndex = index }, slot)
    pcall(function()
        local info = boat:GetBoatInfo()
        if info.MaxCrewMembers < 1 then info.MaxCrewMembers = 1 end  -- lets a crew member be assigned to the boat
    end)
    -- A crew chart that was opened before the position existed has already copied the boat's (empty)
    -- list of groups; have it read the boat again.
    local refreshed = 0
    for _, chart in ipairs(Live("SasCrewChartViewModel")) do
        pcall(function()
            if Same(chart:GetBoatCrewComponent(), comp) then
                chart:Initialize(comp)
                refreshed = refreshed + 1
            end
        end)
    end
    Log(string.format("added the Crane Operator position to %s (%d open chart%s refreshed)", ClassName(boat), refreshed, refreshed == 1 and "" or "s"))
    return true
end

local BuildFailed = {}

-- Every cargo boat gets the position, alongside any crew positions it has of its own.
local function EnsurePositions()
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local boat = comp:GetOwner()
            if not Valid(boat) or not ClassName(boat):find("Cargo_Boat", 1, true) then return end
            if CraneSlot(comp) then return end
            local key = boat:GetFullName()
            if BuildFailed[key] then return end
            local ok, built = pcall(BuildPosition, comp, boat)
            if not ok or not built then
                BuildFailed[key] = true
                Log("could not add the position to " .. ClassName(boat) .. ": " .. tostring(built):gsub("\n.*", ""))
            end
        end)
    end
end

---------------------------------------------------------------------------------------------------
-- Seating. The game's own assign calls decline a slot it did not build, so the link is written on
-- both sides and each side is told it changed, as happens when the values arrive over the network.

local RereadCharts

-- Someone moved here from one of the boat's own crew positions has to leave that one first: the game
-- is asked to take them out of it, and if it does not, the link is cut by hand as well.
local function LeaveOtherSlot(member, slot)
    local old = nil
    pcall(function() old = member.CrewSlot end)
    if not Valid(old) or Same(old, slot) or IsOurSlot(old) then return end
    for _, employee in ipairs(Live("CompanyEmployeeComponent")) do
        pcall(function() employee:RemoveCrewMemberFromSlot(member) end)
    end
    if Same(old.CrewMember, member) then
        ClearRef(old, "CrewMember")
        pcall(function() old:OnRep_CrewMember(member) end)
    end
end

-- Writes the link between a crew member and a slot on both sides and tells each side it changed.
local function Link(member, slot)
    slot.CrewMember = member
    member.CrewSlot = slot
    member.CrewSlotId = { TaskGroupCategory = slot.SlotId.TaskGroupCategory, SlotIndex = slot.SlotId.SlotIndex }
    pcall(function() slot:OnRep_CrewMember(nil) end)
    pcall(function() member:OnRep_CrewSlot() end)
end

local function Seat(member, slot)
    LeaveOtherSlot(member, slot)
    Link(member, slot)
    Remember(MemberName(member), true)
    -- Without this the chart keeps showing them under "Resting" as well.
    pcall(function() RereadCharts(slot.CrewGroup.BoatCrewComponent) end)
end

-- Makes every open crew chart of this boat rebuild its lists. Asking a chart to read the boat it
-- already has does nothing, so it is pointed at another boat and back.
function RereadCharts(comp)
    local other = nil
    for _, candidate in ipairs(Live("SasBoatCrewComponent")) do
        if not other and not Same(candidate, comp) then other = candidate end
    end
    local done = 0
    for _, chart in ipairs(Live("SasCrewChartViewModel")) do
        pcall(function()
            if Same(chart:GetBoatCrewComponent(), comp) then
                if other then chart:Initialize(other) end
                chart:Initialize(comp)
                done = done + 1
            end
        end)
    end
    return done
end

local function Unseat(slot, forget)
    local member = slot.CrewMember
    ClearRef(slot, "CrewMember")
    if Valid(member) then
        if IsOurSlot(member.CrewSlot) then ClearRef(member, "CrewSlot") end
        pcall(function() slot:OnRep_CrewMember(member) end)
        pcall(function() member:OnRep_CrewSlot() end)
        if forget then Remember(MemberName(member), false) end
    end
    -- The chart's "Resting" list is not told by the above; without this the crew member vanishes from it.
    pcall(function() RereadCharts(slot.CrewGroup.BoatCrewComponent) end)
end

local function SlotBoat(slot)
    local ok, boat = pcall(function() return slot.CrewGroup.BoatCrewComponent:GetOwner() end)
    return ok and Valid(boat) and boat or nil
end

local function Resting(member)
    local ok, seated = pcall(function() return Valid(member.CrewSlot) end)
    return not (ok and seated)
end

-- Where a crew member stands against a boat's crew positions, for seating a remembered operator:
--   "resting"  no slot at all;
--   "orphan"   a slot is named that is no position of this boat holding them (a load can leave this
--              behind when the position did not exist yet), which the chart does not show anywhere;
--   "ours"     the crane position, of this boat or another;
--   "elsewhere" a real position of the boat that holds them.
function SeatState(member, comp)
    local old = nil
    pcall(function() old = member.CrewSlot end)
    if not Valid(old) then return "resting" end
    if IsOurSlot(old) then return "ours" end
    local listed, holds = false, false
    pcall(function()
        Each(comp.CrewGroups, function(group)
            Each(group.CrewSlots, function(slot)
                if Same(slot, old) then listed = true end
            end)
        end)
        holds = Same(old.CrewMember, member)
    end)
    if listed and holds then return "elsewhere" end
    return "orphan"
end

-- A remembered operator the game did not put back on their boat when the save loaded. The save names
-- the crane position as their slot, which did not exist yet while the boat was loading, and they are
-- left holding the boat's key but with no boat: not in the boat's crew, so not in the crew chart at
-- all. (Taking them off the boat and putting them on again by hand mends it; this does the same.)
-- The game is asked to read the boat key again first, then the link is written by hand.
RelinkTries = {}
AvatarTries = {}
AVATAR_TRIES_MAX = 12   -- the first three come quickly; the rest are spread out, in case the world needs longer
AVATAR_QUICK_TRIES = 3
AVATAR_SPACING_S = 8
AVATAR_SLOW_SPACING_S = 30

-- Where a crew member's character is against their boat, for the log.
function CharacterText(member, boat)
    local character = nil
    pcall(function() character = member.Character end)
    if not Valid(character) then return "no character in the world" end
    local text = ClassName(character)
    pcall(function() if character.bHidden then text = text .. ", HIDDEN" end end)
    pcall(function()
        local at, base = character:K2_GetActorLocation(), boat:K2_GetActorLocation()
        text = string.format("%s, %.0f m from the boat's origin", text, math.sqrt((at.X - base.X) ^ 2 + (at.Y - base.Y) ^ 2 + (at.Z - base.Z) ^ 2) / 100)
    end)
    return text
end

-- The data link mended above gives the person their place in the chart, but not their character on the
-- deck: the game makes that when it assigns them to the boat. So if there is none, the game is asked to
-- take them off the boat and assign them again, as is done by hand in the crew chart.
AvatarAt = {}        -- member name -> when the game was last asked for their character
AvatarReported = {}  -- member name -> true once the log has said that they now have one

function GiveAvatar(member, boat, comp)
    local name = MemberName(member)
    -- A few tries, a few seconds apart: the first can come before the world is ready to make a character.
    local spacing = (AvatarTries[name] or 0) >= AVATAR_QUICK_TRIES and AVATAR_SLOW_SPACING_S or AVATAR_SPACING_S
    if (AvatarTries[name] or 0) >= AVATAR_TRIES_MAX or os.clock() - (AvatarAt[name] or -1000) < spacing then return end
    AvatarTries[name] = (AvatarTries[name] or 0) + 1
    AvatarAt[name] = os.clock()
    local state = nil
    pcall(function() state = FindFirstOf("PlayerController").PlayerState end)
    for _, employee in ipairs(Live("CompanyEmployeeComponent")) do
        local owner = nil
        pcall(function() owner = employee:GetOwner() end)
        if Valid(state) and Valid(owner) and Same(owner, state) then
            Log(string.format("%s has no character on deck; asking the game to take them off the boat and assign them again (try %d of %d)",
                name, AvatarTries[name], AVATAR_TRIES_MAX))
            pcall(function() employee:RemoveCrewMemberFromBoat(member) end)
            pcall(function() employee:AssignCrewMemberToBoat(member) end)
            return
        end
    end
    Log(name .. " has no character on deck, and the player's employee component was not found to assign them again")
end

function RelinkOperators(comp, boat)
    local key = nil
    pcall(function() key = GuidStr(boat:GetBoatKey().ID) end)
    if not key then return end
    local function listed(member)
        local found = false
        Each(comp.CrewMembers, function(candidate)
            if Same(candidate, member) then found = true end
        end)
        return found
    end
    for _, company in ipairs(Live("SasCompanyCrewComponent")) do
        pcall(function()
            Each(company.CrewMembers, function(member)
                local name = MemberName(member)
                if not Operators[name] then return end
                local memberKey = nil
                pcall(function() memberKey = GuidStr(member.BoatKey.ID) end)
                if memberKey ~= key then return end
                if Valid(member.Boat) and listed(member) then
                    if not Valid(member.Character) and (RelinkTries[name] or 0) > 0 then
                        pcall(GiveAvatar, member, boat, comp)  -- mended by hand earlier, and still no one on deck
                    elseif Valid(member.Character) and AvatarTries[name] and not AvatarReported[name] then
                        AvatarReported[name] = true
                        Log(string.format("%s now has a character: %s (after %d request(s))", name, CharacterText(member, boat), AvatarTries[name]))
                    end
                    return
                end
                RelinkTries[name] = (RelinkTries[name] or 0) + 1
                if RelinkTries[name] > 2 then return end
                Log(name .. " holds this boat's key but is not on it; putting them back on the boat (try " .. RelinkTries[name] .. ")")
                pcall(function() member:OnRep_BoatKey() end)
                if not (Valid(member.Boat) and listed(member)) then
                    pcall(function() member.Boat = boat end)
                    if not listed(member) then
                        local before, members = {}, {}
                        Each(comp.CrewMembers, function(candidate)
                            before[#before + 1] = candidate
                            members[#members + 1] = candidate
                        end)
                        members[#members + 1] = member
                        comp.CrewMembers = members
                        pcall(function() comp:OnRep_CrewMembers(before) end)
                    end
                    pcall(function() member:OnRep_Boat(nil) end)
                end
                Log(string.format("%s is now %son the boat and %slisted by it (%s)", name,
                    Same(member.Boat, boat) and "" or "NOT ", listed(member) and "" or "NOT ", CharacterText(member, boat)))
                pcall(function() RereadCharts(comp) end)
            end)
        end)
    end
end

-- Where every crew member stands against every cargo boat, for the log: whether the boat lists them,
-- what slot they name and whether that slot is one the boat has and holds them. Written once a few
-- seconds after a boat gets its crane position, and on Ctrl+Alt+D.
-- The crew dump reads every crew member of the company, including those of boats that may not be loaded,
-- and one player's game closed in the middle of it (the log ended right after its first line). So it is only
-- run when asked for, with Ctrl+Alt+D, never by itself.
CrewDumpWanted = false

function DumpCrew(reason)
    Log("CREW: " .. reason)
    -- The boats and the key the game files each under, to set against the key each crew member holds.
    local keys = {}
    for _, owned in ipairs(Live("CompanyOwnedBoatsComponent")) do
        pcall(function()
            owned.ActiveBoats:ForEach(function(key, value)
                local boat = value:get()
                if Valid(boat) then keys[boat:GetAddress()] = GuidStr(key:get().ID) end
            end)
        end)
    end
    local listedBy = {}   -- member address -> the boat that lists them
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local boat = comp:GetOwner()
            if not Valid(boat) or not ClassName(boat):find("Cargo_Boat", 1, true) then return end
            Each(comp.CrewMembers, function(member) listedBy[member:GetAddress()] = ClassName(boat) end)
            local boatKey = keys[boat:GetAddress()]
            pcall(function() boatKey = boatKey or GuidStr(boat:GetBoatKey().ID) end)
            Log(string.format("CREW: %s (key %s), crane position %s, %d listed crew member(s)", ClassName(boat),
                boatKey or "?", CraneSlot(comp) and "yes" or "NO", Count(comp.CrewMembers)))
        end)
    end
    for _, company in ipairs(Live("SasCompanyCrewComponent")) do
        pcall(function()
            Each(company.CrewMembers, function(member)
                pcall(function()
                    local name = MemberName(member)
                    local boat, assigned = "none", "?"
                    pcall(function() if Valid(member.Boat) then boat = ClassName(member.Boat) end end)
                    pcall(function() assigned = tostring(member:IsAssignedToBoat()) end)
                    local old = nil
                    pcall(function() old = member.CrewSlot end)
                    local slotText = "no slot"
                    if Valid(old) then
                        local group, holds = "?", false
                        pcall(function() group = old.CrewGroup.GroupName:ToString() end)
                        pcall(function() holds = Same(old.CrewMember, member) end)
                        slotText = string.format("slot in group '%s'%s", group, holds and "" or " that does not hold them")
                    end
                    local index, category = -1, "?"
                    pcall(function() index = member.CrewSlotId.SlotIndex end)
                    pcall(function() category = member.CrewSlotId.TaskGroupCategory:GetFName():ToString() end)
                    local key = "?"
                    pcall(function() key = GuidStr(member.BoatKey.ID) end)
                    local where = "?"
                    pcall(function()
                        for _, comp in ipairs(Live("SasBoatCrewComponent")) do
                            if Same(comp:GetOwner(), member.Boat) then where = CharacterText(member, member.Boat) end
                        end
                    end)
                    Log(string.format("CREW:   %s: remembered operator %s, Boat %s, boat key %s, assigned to a boat %s, listed by %s, %s, named slot %s #%d, character: %s",
                        name, Operators[name] and "yes" or "no", boat, key, assigned, listedBy[member:GetAddress()] or "no boat",
                        slotText, category, index, where))
                end)
            end)
        end)
    end
end
RegisterKeyBind(Key.D, { ModifierKey.CONTROL, ModifierKey.ALT }, function() CrewDumpWanted = true end)
TowsWanted = false
RegisterKeyBind(Key.T, { ModifierKey.CONTROL, ModifierKey.ALT }, function() TowsWanted = true end)

-- Keeps every position consistent: an operator who has left the boat is taken off, and a remembered
-- operator who is aboard and resting is seated again (which is how a loaded save gets them back).
local ChartTries = {}
local SeatNoted = {}  -- member name -> when the reason for not seating them was last logged

local function TendPositions()
    -- A chart that does not show the position of a boat that now has it reads the boat again.
    for _, chart in ipairs(Live("SasCrewChartViewModel")) do
        pcall(function()
            local comp = chart:GetBoatCrewComponent()
            local shown = false
            pcall(function()
                Each(chart.CrewGroups, function(group)
                    if group.GroupName:ToString() == GROUP_NAME then shown = true end
                end)
            end)
            if Valid(comp) and not shown and CraneSlot(comp) then
                local key = chart:GetAddress()
                ChartTries[key] = (ChartTries[key] or 0) + 1
                if ChartTries[key] > 3 then return end
                RereadCharts(comp)
                Log(string.format("re-read a crew chart that was missing the position (try %d): it now shows %d group(s)",
                    ChartTries[key], Count(chart.CrewGroups)))
            end
        end)
    end
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local slot = CraneSlot(comp)
            if not slot then return end
            local boat = comp:GetOwner()
            if os.clock() > 0 then pcall(RelinkOperators, comp, boat) end
            local member = slot.CrewMember
            if Valid(member) then
                if not Same(member.Boat, boat) or not Same(member.CrewSlot, slot) then
                    -- Moved to another of the boat's positions: they are no longer the crane operator,
                    -- and are not to be put back here after a load.
                    local elsewhere = false
                    pcall(function() elsewhere = Valid(member.CrewSlot) and Same(member.Boat, boat) end)
                    Unseat(slot, elsewhere)
                end
                return
            end
            Each(comp.CrewMembers, function(candidate)
                local name = MemberName(candidate)
                if Valid(slot.CrewMember) or not Operators[name] then return end
                local state = SeatState(candidate, comp)
                if state == "resting" or state == "orphan" then
                    if state == "orphan" then Log(name .. " was left in a position this boat does not have; seating them as the crane operator") end
                    Seat(candidate, slot)
                    Toast(name .. " is back on crane duty")
                elseif os.clock() - (SeatNoted[name] or -1000) > 60 then
                    SeatNoted[name] = os.clock()
                    Log(string.format("%s is remembered as the crane operator but is %s, so is not seated", name,
                        state == "elsewhere" and "in another of the boat's positions" or "in a crane position"))
                end
            end)
        end)
    end
end

---------------------------------------------------------------------------------------------------
-- The crew chart. Dropping a crew member on the position, or taking them out of it, goes through the
-- game's own calls first; what they leave undone is finished here a moment later.

local Requests = {}  -- { kind = "seat" | "unseat" | "toggle", member = ..., slot = ..., wait = ticks }

local function Queue(kind, member, slot)
    Requests[#Requests + 1] = { kind = kind, member = member, slot = slot, wait = 1 }
end

local function HandleRequest(request)
    if request.kind == "seat" then
        local member, slot = request.member, request.slot
        if not Valid(member) or not Valid(slot) or Same(slot.CrewMember, member) then return end
        if not IsOurSlot(slot) then
            -- Into one of the boat's own positions. The game will not move someone out of the crane
            -- position, so they are taken out of it here and the game is asked again.
            if not IsOurSlot(member.CrewSlot) then return end
            Unseat(member.CrewSlot, true)
            -- Their slot label still names the crane position, and the game looks them up by it.
            pcall(function() member.CrewSlotId = { TaskGroupCategory = CreateInvalidObject(), SlotIndex = 0 } end)
            for _, employee in ipairs(Live("CompanyEmployeeComponent")) do
                pcall(function() employee:AssignCrewMemberToSlot(member, slot) end)
            end
            -- If the game still refuses, the move is written by hand, the way the game would write it.
            if not Same(member.CrewSlot, slot) and not Valid(slot.CrewMember) then
                Link(member, slot)
                Log(MemberName(member) .. " moved into the boat's own position by hand")
            end
            pcall(function() RereadCharts(slot.CrewGroup.BoatCrewComponent) end)
            Toast(MemberName(member) .. " is off crane duty")
            return
        end
        if not Same(member.Boat, SlotBoat(slot)) then
            Toast("Assign " .. MemberName(member) .. " to this boat first")
            return
        end
        if Valid(slot.CrewMember) then Unseat(slot, true) end
        Seat(member, slot)
        Toast(MemberName(member) .. " is now the crane operator")
    elseif request.kind == "unseat" then
        local member = request.member
        if not Valid(member) or not IsOurSlot(member.CrewSlot) then return end
        Unseat(member.CrewSlot, true)
        Toast(MemberName(member) .. " is off crane duty")
    end
end

-- A steadier hook. The deck crane sometimes lets a load go a moment after latching it, for the
-- game's own operators too. A load that comes off within a second and a half of being latched, while
-- you are at the controls, is latched again straight away. Letting go again soon after that is taken
-- as meant, and honoured.
STEADY_SECONDS = 1.5
local Latches = {}   -- crane address -> { cargo, at, caught }
local Catches = {}   -- loads to latch again: { crane, cargo }

local function DrivenByPlayer(crane)
    local ok, yes = pcall(function()
        return Same(crane.DriverComponent.Driver, FindFirstOf("PlayerController").Pawn)
    end)
    return ok and yes
end

local function OnLatched(crane)
    if not ClassName(crane):find("T02", 1, true) then return end
    local key = crane:GetAddress()
    local previous = Latches[key]
    local caught = previous and previous.caught and os.clock() - previous.caught < 5 and previous.caught or nil
    Latches[key] = { cargo = crane.AttachedCargo, at = os.clock(), caught = caught }
end

local function OnLetGo(crane)
    if not ClassName(crane):find("T02", 1, true) or not DrivenByPlayer(crane) then return end
    local latch = Latches[crane:GetAddress()]
    if not latch or not Valid(latch.cargo) or os.clock() - latch.at > STEADY_SECONDS then return end
    if latch.caught then return end  -- already caught once: this time it is meant
    latch.caught = os.clock()
    Catches[#Catches + 1] = { crane = crane, cargo = latch.cargo }
end

local function SteadyStep()
    if #Catches == 0 then return end
    local catches = Catches
    Catches = {}
    for _, catch in ipairs(catches) do
        pcall(function()
            if Valid(catch.crane) and Valid(catch.cargo) and not Valid(catch.crane.AttachedCargo) then
                catch.crane:ServerAttachCargo(catch.cargo)
                Log("steadied the hook: the " .. ClassName(catch.cargo) .. " came off just after latching and was latched again")
            end
        end)
    end
end

CRANE_BASE = "/Game/ShipsAtSea/Gameplay/Cargo/Crane/BP_CargoCrane_Base.BP_CargoCrane_Base_C"

local Hooks = {
    [CRANE_BASE .. ":OnCargoAttached_Base"] = function(context) OnLatched(context:get()) end,
    [CRANE_BASE .. ":OnCargoDetached_Base"] = function(context) OnLetGo(context:get()) end,
    ["/Script/Sas.SasCrewSlotViewModel:AssignCrewMemberToSlot"] = function(context, _, member)
        Queue("seat", member:get(), context:get():GetCrewSlot())
    end,
    ["/Script/Sas.SasCrewChartViewModel:AssignCrewMemberToSlot"] = function(_, _, member, slot)
        Queue("seat", member:get(), slot:get())
    end,
    ["/Script/Sas.SasCrewMemberViewModel:AssignCrewMemberToSlot"] = function(context, _, slot)
        Queue("seat", context:get():GetCrewMember(), slot:get())
    end,
    ["/Script/Sas.SasCrewSlotViewModel:RemoveCrewMemberFromSlot"] = function(context)
        Queue("unseat", context:get():GetCrewSlot().CrewMember, nil)
    end,
    ["/Script/Sas.SasCrewChartViewModel:RemoveCrewMemberFromSlot"] = function(_, _, member)
        Queue("unseat", member:get(), nil)
    end,
    ["/Script/Sas.SasCrewMemberViewModel:RemoveCrewMemberFromSlot"] = function(context)
        Queue("unseat", context:get():GetCrewMember(), nil)
    end,
}
local Hooked = {}

local function HookChart()
    for path, handler in pairs(Hooks) do
        if not Hooked[path] and pcall(RegisterHook, path, function(...) if not Stale() then pcall(handler, ...) end end) then
            Hooked[path] = true
        end
    end
end

---------------------------------------------------------------------------------------------------
-- Ctrl+Alt+O: seat or unseat without the chart.

local function NearestCraneSlot()
    local here = FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()
    local best, bestComp, bestDist = nil, nil, CRANE_REACH_CM
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local slot = CraneSlot(comp)
            if not slot then return end
            local d = Dist(comp:GetOwner():K2_GetActorLocation(), here)
            if d < bestDist then best, bestComp, bestDist = slot, comp, d end
        end)
    end
    return best, bestComp
end

local function ToggleOperator()
    local slot, comp = NearestCraneSlot()
    if not slot then
        Toast("No cargo boat with a Crane Operator position nearby")
        return
    end
    if Valid(slot.CrewMember) then
        local name = MemberName(slot.CrewMember)
        Unseat(slot, true)
        Toast(name .. " is off crane duty")
        return
    end
    local chosen = nil
    Each(comp.CrewMembers, function(candidate)
        if not chosen and Resting(candidate) then chosen = candidate end
    end)
    if not chosen then
        Toast("No resting crew member on this boat: assign one to the boat first")
        return
    end
    Seat(chosen, slot)
    Toast(MemberName(chosen) .. " is now the crane operator")
end

RegisterKeyBind(Key.O, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    Requests[#Requests + 1] = { kind = "toggle", wait = 0 }
end)

---------------------------------------------------------------------------------------------------
-- The work. The Logistics planner's highlight list says what to handle at this port: a GUID alone is
-- cargo to load, a GUID followed by "U" is cargo to unload.

local function ReadMarks()
    local load, unload, count = {}, {}, 0
    local file = io.open(MarksPath, "r")
    if not file then return load, unload, 0 end
    for line in file:lines() do
        local guid, kind = line:match("^(%x+)%s*(U?)%s*$")  -- only "U" means unload; any other letter is not a line we know
        if guid and #guid == 32 then
            if kind == "U" then unload[guid:upper()] = true else load[guid:upper()] = true end
            count = count + 1
        end
    end
    file:close()
    return load, unload, count
end

local function IsHold(area)
    return ClassName(area):find("BoatCargoArea", 1, true) ~= nil
end

local function CargoGuid(cargo)
    local ok, guid = pcall(function() return GuidStr(cargo:GetRepresentedInventoryItem().Guid) end)
    return ok and guid or nil
end

-- Does the area take pieces of this size? Medium and large cargo go to different dock areas. If the
-- game will not say, it is taken to.
local function TakesSize(area, cargo)
    local ok, takes = pcall(function()
        return area:GetInventory():IsSupportedCargoSize(cargo:GetRepresentedInventoryItem().ItemDefinition.CargoSize)
    end)
    return not ok or takes ~= false
end

-- Does the game accept the piece at exactly this place in the area?
local function FitsAt(area, cargo, place)
    if not TakesSize(area, cargo) then return false end
    local ok, found = pcall(function()
        local out = {}
        return area:GetInventory():FindPlaceForInventoryItemInGrid(cargo:GetRepresentedInventoryItem(), out,
            { DesiredGridTransform = { position = place.position, Rotation = place.rotation }, PositionRule = 0, RotationRule = 0 }, {})
    end)
    return ok and found == true
end

-- A free place for the piece in the area: the first the game finds, counting from the grid's corner.
-- (The game takes no notice of where it is asked to look.)
local function FindPlace(area, cargo, near)
    if not TakesSize(area, cargo) then return nil end
    local item = cargo:GetRepresentedInventoryItem()
    local want = { position = near or { X = 0, Y = 0, Z = 0 }, Rotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } }
    local out = {}
    local found = area:GetInventory():FindPlaceForInventoryItemInGrid(item, out,
        { DesiredGridTransform = want, PositionRule = 1, RotationRule = 1 }, {})
    out = out.OutGridTransform or out
    if not found or out.position == nil then return nil end
    return { position = { X = out.position.X, Y = out.position.Y, Z = out.position.Z },
             rotation = { Pitch = out.Rotation.Pitch, Yaw = out.Rotation.Yaw, Roll = out.Rotation.Roll } }
end

-- Is any of the boat's engines running?
local function EngineRunning(boat)
    for _, className in ipairs({ "BoatEngine", "BoatIntegratedPropulsor" }) do
        for _, engine in ipairs(Live(className)) do
            local ok, running = pcall(function()
                local owner = engine:GetAttachParentActor()
                if not Same(owner, boat) and not Same(engine:GetOwner(), boat) then return false end
                return engine:IsEngineRunning()
            end)
            if ok and running then return true end
        end
    end
    return false
end

-- Is the boat ready to work cargo? Docked: the game's mooring lines have caught, even while it is still pulling the
-- boat in (that takes a minute or two and the crane works meanwhile) (FormallyDocked),
-- or, for a boat too big to dock where its cargo has to go, lying still with its engines off
-- (LyingStill). The second is only enough for a boat working with cranes of its own: the dock's
-- crane needs the boat made fast beside it.
MOORED_SPEED_CM = 30

local function FormallyDocked(boat)
    local ok, docked = pcall(function()
        local docking = boat.DockingComponent
        return docking:IsDocked()
    end)
    return ok and docked == true
end

-- A boat heeled far over is no place to swing a load: the cargo is flung about and the boat with it.
-- Work stops while it is, and the attitude is logged (TILT:) so that a boat going over can be seen.
HOOK_PIECE_WAIT_S = 5     -- a piece found on the hook is left alone until the mooring check has run, and this long after
MooringChecked = nil      -- os.clock() when the bollards were last checked, nil until then
LoadedAt = os.clock()
HookWaitTold = false
HookNoDockTold = false
HookInspected = false
NextMooringTry = 0   -- os.clock() before which the bollards are not checked again

-- One look, when asked for with Ctrl+Alt+T (not by itself: it reads objects all over the world), at every tow link and every piece of cargo with something
-- attached to it, whether or not any work is going on (TOWS: lines).
function InspectTows()
    local lines = 0
    for _, className in ipairs({ "TowingComponent", "TowingBollard" }) do
        for _, thing in ipairs(Live(className)) do
            pcall(function()
                local towing = false
                pcall(function() towing = thing:IsTowing() end)
                if not towing then return end
                local other = nil
                pcall(function() other = thing:GetTowedActor() end)
                local text = "TOWS: " .. thing:GetFullName() .. " is towing"
                if Valid(other) then text = text .. " " .. other:GetFullName() end
                pcall(function() text = text .. " | owner " .. thing:GetOwner():GetFullName() end)
                Log(text)
                lines = lines + 1
            end)
        end
    end
    for _, cargo in ipairs(Live("HeavyCargo")) do
        pcall(function()
            local parts = {}
            local parent = cargo:GetAttachParentActor()
            if Valid(parent) then parts[#parts + 1] = "parent " .. parent:GetFullName() end
            local attached = {}
            cargo:GetAttachedActors(attached, true, true)
            for _, actor in ipairs(attached.OutActors or attached) do
                parts[#parts + 1] = "attached " .. actor:GetFullName()
            end
            if #parts > 0 and not (#parts == 1 and parts[1]:find("CargoArea", 1, true)) then
                Log("TOWS: cargo " .. cargo:GetFullName() .. " | " .. table.concat(parts, " | "))
                lines = lines + 1
            end
        end)
    end
    -- Each step is logged before it runs, so that a step that brings the game down names itself.
    Log("TOWS: step 1, the components of each cargo piece")
    for _, cargo in ipairs(Live("HeavyCargo")) do
        pcall(function()
            local kinds, odd = {}, false
            local children = cargo.RootComponent:GetChildrenComponents(true, {})
            for _, child in ipairs(children) do
                local kind = ClassName(child)
                kinds[#kinds + 1] = kind
                if not kind:find("StaticMesh", 1, true) and not kind:find("Box", 1, true) then odd = true end
            end
            if odd then Log("TOWS: " .. ClassName(cargo) .. " " .. cargo:GetFName():ToString() .. " has components " .. table.concat(kinds, ", ")) end
        end)
    end
    Log("TOWS: step 2, physics constraints")
    for _, constraint in ipairs(Live("PhysicsConstraintComponent")) do
        pcall(function()
            local text = constraint:GetFullName():match("PersistentLevel%.(.*)$") or constraint:GetFullName()
            local one, two = "?", "?"
            pcall(function() one = tostring(constraint.ConstraintActor1:GetFullName():match("PersistentLevel%.(.*)$")) end)
            pcall(function() two = tostring(constraint.ConstraintActor2:GetFullName():match("PersistentLevel%.(.*)$")) end)
            Log("TOWS: constraint " .. text .. " | actor 1 " .. one .. " | actor 2 " .. two)
        end)
    end
    Log("TOWS: step 3, rope actors")
    for _, rope in ipairs(Live("SplineRopeActor")) do
        pcall(function() Log("TOWS: rope " .. (rope:GetFullName():match("PersistentLevel%.(.*)$") or rope:GetFullName())) end)
    end
    Log("TOWS: step 4, docking tethers")
    local function Short(obj)
        local ok, name = pcall(function() return obj:GetFullName():match("PersistentLevel%.(.*)$") or obj:GetFullName() end)
        return ok and name or "?"
    end
    for _, comp in ipairs(Live("DockingTetherComponent")) do
        pcall(function()
            local tethers = comp.DockingTethers
            local count = 0
            pcall(function() count = #tethers end)
            Log("TOWS: " .. Short(comp) .. " has " .. count .. " tether(s)")
            for i = 1, count do
                pcall(function()
                    local tether = tethers[i]
                    local parts = {}
                    pcall(function() parts[#parts + 1] = "rope " .. Short(tether.SplineRope) end)
                    pcall(function() parts[#parts + 1] = "mooring target " .. Short(tether.MooringTarget) end)
                    pcall(function() parts[#parts + 1] = "target component " .. Short(tether.TargetComponent) end)
                    pcall(function() parts[#parts + 1] = string.format("length %.0f", tether.Length) end)
                    Log("TOWS:   tether " .. i .. ": " .. table.concat(parts, " | "))
                end)
            end
        end)
    end
    Log("TOWS: looked at the tow links and attached cargo (" .. lines .. " line(s) above)")
end

-- Telemetry for a piece found on the hook: what it hangs from, what is attached to it, and whether any
-- boat is towing something. (A tow rope to a crate dragged the boat over when it was put in the hold.)
function InspectHookPiece(held)
    local parts = {}
    pcall(function() parts[#parts + 1] = "parent " .. tostring(held:GetAttachParentActor():GetFullName()) end)
    pcall(function()
        local attached = {}
        held:GetAttachedActors(attached, true, true)
        for _, actor in ipairs(attached.OutActors or attached) do
            parts[#parts + 1] = "attached " .. tostring(actor:GetFullName())
        end
    end)
    for _, comp in ipairs(Live("TowingComponent")) do
        pcall(function()
            local towed = comp:GetTowedActor()
            local line = comp:GetFullName() .. " towing " .. (Valid(towed) and towed:GetFullName() or "nothing")
            parts[#parts + 1] = line
        end)
    end
    Log("HOOK PIECE: " .. ClassName(held) .. " | " .. table.concat(parts, " | "))
end
TILT_STOP_DEG = 25
TiltLoggedAt = 0

function BoatTilt(boat)
    local roll, pitch = 0, 0
    pcall(function()
        local rotation = boat:K2_GetActorRotation()
        roll, pitch = rotation.Roll, rotation.Pitch
    end)
    return roll, pitch
end

local function LyingStill(boat)
    local velocity = boat:GetVelocity()
    return math.sqrt(velocity.X ^ 2 + velocity.Y ^ 2) <= MOORED_SPEED_CM and not EngineRunning(boat)
end

-- Where the docked boat with a seated operator lies: its hold, the cranes that will do the work, and
-- the dock areas. A boat with cranes of its own uses those (large-container docks have no crane of
-- their own); any other uses the dock crane beside its hold.
local function WorkSite(comp)
    local boat = comp:GetOwner()
    local formal = FormallyDocked(boat)
    if not formal and not LyingStill(boat) then
        return nil, "the boat is not made fast to a dock" .. (EngineRunning(boat) and " (engine running)" or " (engine off, still moving)")
    end
    local roll, pitch = BoatTilt(boat)
    if math.abs(roll) > TILT_STOP_DEG or math.abs(pitch) > TILT_STOP_DEG then
        if os.clock() - TiltLoggedAt > 5 then
            TiltLoggedAt = os.clock()
            Log(string.format("TILT: the boat is heeled over (roll %.0f, pitch %.0f degrees); not working cargo until it rights itself", roll, pitch))
        end
        return nil, "the boat is heeled over"
    end
    local hold = nil
    for _, area in ipairs(Live("CargoArea")) do
        if not hold and IsHold(area) and Same(area:GetAttachParentActor(), boat) then hold = area end
    end
    if not hold then return nil, "the boat's hold was not found" end
    local deck = {}
    for _, candidate in ipairs(Live("CargoCrane")) do
        if Same(candidate:GetAttachParentActor(), boat) then deck[#deck + 1] = candidate end
    end
    if #deck > 0 then return { boat = boat, hold = hold, cranes = deck, crane = deck[1], deck = true } end
    local at = hold:K2_GetActorLocation()
    local crane, craneDist = nil, CRANE_REACH_CM
    for _, candidate in ipairs(Live("CargoCrane")) do
        local d = Dist(candidate:K2_GetActorLocation(), at)
        if d < craneDist and not Valid(candidate:GetAttachParentActor()) then crane, craneDist = candidate, d end
    end
    if not crane then
        return nil, string.format("no dock crane within %.0f m of the boat's hold", CRANE_REACH_CM / 100)
    end
    if not formal then return nil, "the dock's crane only works for a boat made fast to the dock" end
    return { boat = boat, hold = hold, cranes = { crane }, crane = crane, deck = false }
end

-- Where an area's grid sits in the world: its corner, and the directions its X and Y cells run in.
local function GridFrame(area)
    local origin = area.OriginComponent
    local at, yaw = origin:K2_GetComponentLocation(), math.rad(origin:K2_GetComponentRotation().Yaw)
    return at, { X = math.cos(yaw), Y = math.sin(yaw) }, { X = -math.sin(yaw), Y = math.cos(yaw) }
end

-- The floor cell of an area closest to a point, and that cell's centre in the world.
local function CellNear(area, point)
    local at, across, along = GridFrame(area)
    local size = area:GetInventory().GridSize
    local dx, dy = point.X - at.X, point.Y - at.Y
    local gx = math.max(0, math.min(size.X - 1, math.floor((dx * across.X + dy * across.Y) / 25)))
    local gy = math.max(0, math.min(size.Y - 1, math.floor((dx * along.X + dy * along.Y) / 25)))
    local cx, cy = (gx + 0.5) * 25, (gy + 0.5) * 25
    return { X = gx, Y = gy, Z = 0 }, { X = at.X + across.X * cx + along.X * cy, Y = at.Y + across.Y * cx + along.Y * cy, Z = at.Z }
end

-- Dock areas in the cranes' reach. With a dock crane, the port's own cargo area comes first; with the
-- boat's own cranes, the areas closest to one of them, each with the cell nearest that crane, so
-- that what is set down there stays within the arm's reach.
local function DockAreas(site)
    local at = site.crane:K2_GetActorLocation()
    local areas = {}
    for _, area in ipairs(Live("CargoArea")) do
        if not IsHold(area) then
            local d = Dist(area:K2_GetActorLocation(), at)
            if d < CARGO_REACH_CM then
                if site.deck then
                    local best, near = math.huge, nil
                    for _, crane in ipairs(site.cranes) do
                        local ok, cell, centre = pcall(CellNear, area, crane:K2_GetActorLocation())
                        if ok and Dist(centre, crane:K2_GetActorLocation()) < best then
                            best, near = Dist(centre, crane:K2_GetActorLocation()), cell
                        end
                    end
                    areas[#areas + 1] = { area = area, order = best, near = near }
                else
                    local rank = ClassName(area) == "BP_CargoArea_C" and 0 or 1
                    areas[#areas + 1] = { area = area, order = rank * 1e9 + d }
                end
            end
        end
    end
    table.sort(areas, function(a, b) return a.order < b.order end)
    return areas
end

-- Stacks. An area's grid says which item fills each cell (Z is up, 0 is the floor). A piece with
-- nothing under it is floating, which is what is left when a piece below it has been taken away.

local function Height(cargo)
    local ok, z = pcall(function() return cargo:K2_GetActorLocation().Z end)
    return ok and z or 0
end

local function CellKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Looking at every cell of an area takes tens of milliseconds, and was done every few seconds for each
-- area while the operator was idle, which showed as a stutter. What an area holds is told by its list of
-- pieces and where each stands, which is cheap to read; an area that has not changed since a look that
-- found nothing floating is not looked at again.
FloatChecked = {}   -- area address -> what the area held at the last look that found nothing

function AreaContents(inventory)
    local parts = {}
    Each(inventory.GridInventoryItems.Entries, function(placed)
        pcall(function()
            local at, turn = placed.GridTransform.position, placed.GridTransform.Rotation
            -- The turn counts: a piece turned where it stands covers other cells from the same position.
            parts[#parts + 1] = placed.InventoryItem:GetAddress() .. ":" .. at.X .. "," .. at.Y .. "," .. at.Z .. "," .. turn.Yaw
        end)
    end)
    table.sort(parts)
    return table.concat(parts, ";")
end

-- The lowest floating piece in the area and where it comes to rest when let straight down, or nil.
local function FindFloating(area)
    local inventory = area:GetInventory()
    local contents, areaKey = nil, area:GetAddress()
    local okContents, listed = pcall(AreaContents, inventory)
    if okContents then
        contents = listed
        if FloatChecked[areaKey] == contents then return nil end
    end
    local owner, cells = {}, {}
    inventory.CellsOccupancyMap:ForEach(function(key, value)
        local cell, item = key:get(), value:get()
        if not Valid(item) then return end
        local id = item:GetAddress()
        owner[CellKey(cell.X, cell.Y, cell.Z)] = id
        cells[id] = cells[id] or {}
        table.insert(cells[id], { X = cell.X, Y = cell.Y, Z = cell.Z })
    end)
    local found, foundZ, foundDrop = nil, nil, 0
    for id, list in pairs(cells) do
        local lowest = math.huge
        for _, cell in ipairs(list) do lowest = math.min(lowest, cell.Z) end
        local supported = lowest <= 0
        for _, cell in ipairs(list) do
            local below = owner[CellKey(cell.X, cell.Y, cell.Z - 1)]
            if below and below ~= id then supported = true end
        end
        if not supported and (foundZ == nil or lowest < foundZ) then
            local drop = 0
            for d = 1, lowest do
                local free = true
                for _, cell in ipairs(list) do
                    local there = owner[CellKey(cell.X, cell.Y, cell.Z - d)]
                    if there and there ~= id then free = false end
                end
                if not free then break end
                drop = d
            end
            if drop > 0 then found, foundZ, foundDrop = id, lowest, drop end
        end
    end
    if not found then
        FloatChecked[areaKey] = contents
        return nil
    end

    local place = nil
    Each(inventory.GridInventoryItems.Entries, function(placed)
        if not place and Valid(placed.InventoryItem) and placed.InventoryItem:GetAddress() == found then
            local at, turn = placed.GridTransform.position, placed.GridTransform.Rotation
            place = { position = { X = at.X, Y = at.Y, Z = at.Z - foundDrop },
                      rotation = { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll } }
        end
    end)
    if not place then return nil end
    for _, cargo in ipairs(Live("HeavyCargo")) do
        local ok, same = pcall(function() return cargo:GetRepresentedInventoryItem():GetAddress() == found end)
        if ok and same then return cargo, place end
    end
    return nil
end

local SettleTries = {}  -- cargo guid -> times it has been let down, so a piece that will not settle is left alone

-- A floating piece in the hold or on the dock, to be let down before anything else is moved.
local CanReach  -- (site, move) -> true if one of the site's cranes can be steered to both places

local function NextSettle(site)
    local areas = { site.hold }
    for _, dock in ipairs(DockAreas(site)) do areas[#areas + 1] = dock.area end
    for _, area in ipairs(areas) do
        local ok, cargo, place = pcall(FindFloating, area)
        if ok and cargo then
            local guid = CargoGuid(cargo) or "?"
            SettleTries[guid] = (SettleTries[guid] or 0) + 1
            if SettleTries[guid] <= 3 then
                local move = { cargo = cargo, to = area, place = place, settle = true }
                -- Out of the boat's own cranes' reach: let down the unseen way, not left hanging.
                if site.deck and not CanReach(site, move) then
                    Log("letting down a " .. ClassName(cargo) .. " left hanging where the cranes do not reach")
                    move.stage = true
                end
                return move
            end
        end
    end
    -- Dock areas further off, where cargo has been taken from by bringing it over: a piece left
    -- hanging there is let down the same unseen way the cargo was brought over.
    local at = site.boat:K2_GetActorLocation()
    for _, area in ipairs(Live("CargoArea")) do
        local near = false
        for _, known in ipairs(areas) do if Same(known, area) then near = true end end
        if not near and not IsHold(area) and Dist(area:K2_GetActorLocation(), at) < STAGE_RANGE_CM then
            local ok, cargo, place = pcall(FindFloating, area)
            if ok and cargo then
                local guid = CargoGuid(cargo) or "?"
                SettleTries[guid] = (SettleTries[guid] or 0) + 1
                if SettleTries[guid] <= 3 then
                    Log("letting down a " .. ClassName(cargo) .. " left hanging in a dock area the cranes do not reach")
                    return { cargo = cargo, to = area, place = place, settle = true, stage = true }
                end
            end
        end
    end
    return nil
end

-- Making room. When a piece to load will not fit, a space is cleared for it the way a person would:
-- pick the spot on the hold's floor where the fewest pieces are in the way, and move those pieces
-- into gaps elsewhere on the floor. The moves are worked out on a copy of the hold's grid first, one
-- after the other, so each is possible when its turn comes; if the pieces in the way of a spot
-- cannot all be found a gap, the next spot is tried.

TIDY_ROUNDS = 3     -- plans made for one stuck piece before giving up
local TidyPlan = {}       -- moves still to make: { cargo, place }
local TidyRounds = 0
local TidyTold = false
local TidyReport = ""

local function CellName(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Every piece in an area as a box of cells: its corner, its size, and where the game anchors it.
local function Boxes(area)
    local inventory = area:GetInventory()
    local boxes = {}
    inventory.CellsOccupancyMap:ForEach(function(key, value)
        local cell, item = key:get(), value:get()
        if not Valid(item) then return end
        local id = item:GetAddress()
        local box = boxes[id]
        if not box then
            box = { id = id, low = { X = cell.X, Y = cell.Y, Z = cell.Z }, high = { X = cell.X, Y = cell.Y, Z = cell.Z }, count = 0 }
            boxes[id] = box
        end
        box.count = box.count + 1
        for _, axis in ipairs({ "X", "Y", "Z" }) do
            box.low[axis], box.high[axis] = math.min(box.low[axis], cell[axis]), math.max(box.high[axis], cell[axis])
        end
    end)
    Each(inventory.GridInventoryItems.Entries, function(placed)
        local box = Valid(placed.InventoryItem) and boxes[placed.InventoryItem:GetAddress()]
        if box then
            local at, turn = placed.GridTransform.position, placed.GridTransform.Rotation
            box.anchor = { X = at.X - box.low.X, Y = at.Y - box.low.Y, Z = at.Z - box.low.Z }
            box.rotation = { Pitch = turn.Pitch, Yaw = turn.Yaw, Roll = turn.Roll }
        end
    end)
    for _, box in pairs(boxes) do
        box.size = { X = box.high.X - box.low.X + 1, Y = box.high.Y - box.low.Y + 1, Z = box.high.Z - box.low.Z + 1 }
    end
    return boxes, inventory.GridSize
end

-- An area's pieces as boxes, kept until the area's contents change (reading every cell is slow).
BoxesCache = {}   -- area address -> { contents =, boxes = }

function CachedBoxes(area)
    local key = area:GetAddress()
    local ok, contents = pcall(AreaContents, area:GetInventory())
    local entry = BoxesCache[key]
    if ok and entry and entry.contents == contents then return entry.boxes end
    local boxes = Boxes(area)
    BoxesCache[key] = { contents = ok and contents or nil, boxes = boxes }
    return boxes
end

local function Fill(grid, box, with)
    for x = box.low.X, box.low.X + box.size.X - 1 do
        for y = box.low.Y, box.low.Y + box.size.Y - 1 do
            for z = box.low.Z, box.low.Z + box.size.Z - 1 do
                grid[CellName(x, y, z)] = with
            end
        end
    end
end

local function Free(grid, x0, y0, size)
    for x = x0, x0 + size.X - 1 do
        for y = y0, y0 + size.Y - 1 do
            for z = 0, size.Z - 1 do
                if grid[CellName(x, y, z)] then return false end
            end
        end
    end
    return true
end

-- The first gap on the floor that takes a box of this size, or nil.
local function FloorGap(grid, limit, size)
    for y = 0, limit.Y - size.Y do
        for x = 0, limit.X - size.X do
            if Free(grid, x, y, size) then return x, y end
        end
    end
    return nil
end

-- Where a piece of this size can go in the grid when the floor has no gap for it: standing squarely
-- on top of other pieces. Every cell under it must be filled by a piece that is staying where it is
-- (not one still to be moved, and not the spot being cleared), and the cells it takes must be free.
-- The lowest such place, or nil. Returns the cell and its height.
local function StackGap(grid, limit, size, leaving)
    for z = 1, limit.Z - size.Z do
        for y = 0, limit.Y - size.Y do
            for x = 0, limit.X - size.X do
                local ok = true
                for i = x, x + size.X - 1 do
                    for j = y, y + size.Y - 1 do
                        local under = grid[CellName(i, j, z - 1)]
                        if under == nil or under == "reserved" or under == "kept" or leaving[under] then ok = false end
                        if not ok then break end
                    end
                    if not ok then break end
                end
                if ok then
                    for i = x, x + size.X - 1 do
                        for j = y, y + size.Y - 1 do
                            for k = z, z + size.Z - 1 do
                                if grid[CellName(i, j, k)] then ok = false end
                            end
                        end
                    end
                end
                if ok then return x, y, z end
            end
        end
    end
    return nil
end

-- Works out the moves that clear a space for a piece of this size. Returns the list of moves, each
-- { id, x, y, z }, in the order to make them, or nil if no spot can be cleared. A piece moved aside
-- goes to a gap on the floor, or failing that on top of other pieces.
local function PlanSpace(boxes, limit, want)
    local best = nil
    local shapes = { { X = want.X, Y = want.Y, Z = want.Z } }
    if want.X ~= want.Y then shapes[2] = { X = want.Y, Y = want.X, Z = want.Z } end
    for _, shape in ipairs(shapes) do
        for y0 = 0, limit.Y - shape.Y do
            for x0 = 0, limit.X - shape.X do
                -- What stands in this spot, and everything standing on those pieces.
                local inWay, queue = {}, {}
                local function add(box)
                    if not inWay[box.id] then
                        inWay[box.id] = true
                        queue[#queue + 1] = box
                    end
                end
                for _, box in pairs(boxes) do
                    if box.low.X < x0 + shape.X and box.high.X >= x0 and box.low.Y < y0 + shape.Y and box.high.Y >= y0 then add(box) end
                end
                local index = 1
                while index <= #queue do
                    local under = queue[index]
                    index = index + 1
                    for _, box in pairs(boxes) do
                        if box.low.Z > under.low.Z and box.low.X <= under.high.X and box.high.X >= under.low.X
                            and box.low.Y <= under.high.Y and box.high.Y >= under.low.Y then
                            add(box)
                        end
                    end
                end
                if not best or #queue < #best then
                    local ok = true
                    for _, box in ipairs(queue) do
                        if not box.anchor then ok = false end
                    end
                    -- Try it on a copy of the grid: top pieces first, bigger ones before smaller.
                    local grid = {}
                    for _, box in pairs(boxes) do Fill(grid, box, box.id) end
                    for x = x0, x0 + shape.X - 1 do
                        for y = y0, y0 + shape.Y - 1 do
                            for z = 0, limit.Z - 1 do
                                local key = CellName(x, y, z)
                                grid[key] = grid[key] or "reserved"
                            end
                        end
                    end
                    table.sort(queue, function(a, b)
                        if a.low.Z ~= b.low.Z then return a.low.Z > b.low.Z end
                        return a.size.X * a.size.Y > b.size.X * b.size.Y
                    end)
                    local moves = {}
                    for _, box in ipairs(queue) do
                        if ok then
                            Fill(grid, box, nil)
                            for x = x0, x0 + shape.X - 1 do  -- its old cells inside the spot stay kept for the new piece
                                for y = y0, y0 + shape.Y - 1 do
                                    for z = 0, limit.Z - 1 do grid[CellName(x, y, z)] = grid[CellName(x, y, z)] or "reserved" end
                                end
                            end
                            local x, y = FloorGap(grid, limit, box.size)
                            local z = 0
                            if not x then x, y, z = StackGap(grid, limit, box.size, inWay) end
                            if x then
                                Fill(grid, { low = { X = x, Y = y, Z = z }, size = box.size }, box.id)
                                moves[#moves + 1] = { id = box.id, x = x, y = y, z = z }
                            else
                                ok = false
                            end
                        end
                    end
                    if ok then
                        best = moves
                        if #best == 0 then return best end
                    end
                end
            end
        end
    end
    return best
end

-- Rearranging the whole hold. Clearing one spot fails when the pieces in the way have nowhere to go
-- because the floor is full of other pieces that could themselves be stacked or slid together. This
-- looks at the hold as a puzzle: it makes the move, of one piece that has nothing on it to a place it
-- fits and stands squarely on the floor or on other pieces, that does the most to open a space for
-- the waiting piece; then the next, until the space is there. Moves that turn out not to be needed
-- are taken out again afterwards. The work is done on a copy of the grid; nothing moves until the
-- plan is made.

COMPACT_MOVES = 12        -- most moves in a plan
COMPACT_BUDGET_S = 1.0    -- most time spent on one plan, in seconds, shared between the space wanted and bigger ones
COMPACT_WIDTH = 3        -- the best moves a wandering climb picks between
COMPACT_ATTEMPTS = 1000  -- climbs tried before giving up; the time limit is what really stops it

-- A state is a list of the pieces with where they are. The hold is kept as its floor columns: one number
-- for each, with a bit set for every height that is filled (bit 0 the floor), so that whether a piece fits
-- somewhere is a few integer operations on the columns it would stand over.
function CompactColumns(state, lim)
    local cols = {}
    for x = 0, lim.X - 1 do
        for y = 0, lim.Y - 1 do cols[x * lim.Y + y] = 0 end
    end
    for _, p in ipairs(state) do CompactLift(cols, lim, p, true) end
    return cols
end

-- Puts a piece's cells into the columns (put) or takes them out.
function CompactLift(cols, lim, p, put)
    local bits = ((1 << p.sz) - 1) << p.z
    for x = p.x, p.x + p.sx - 1 do
        local base = x * lim.Y
        for y = p.y, p.y + p.sy - 1 do
            if put then cols[base + y] = cols[base + y] | bits else cols[base + y] = cols[base + y] & ~bits end
        end
    end
end

-- Is nothing standing on the piece?
function CompactClear(cols, lim, p)
    local top = p.z + p.sz
    if top >= lim.Z then return true end
    local above = 1 << top
    for x = p.x, p.x + p.sx - 1 do
        for y = p.y, p.y + p.sy - 1 do
            if (cols[x * lim.Y + y] & above) ~= 0 then return false end
        end
    end
    return true
end

-- Can the piece (already lifted out of the columns) stand with its corner at nx, ny, nz: the cells free, and
-- squarely on the floor or on other pieces?
function CompactFits(cols, lim, p, nx, ny, nz)
    local bits = ((1 << p.sz) - 1) << nz
    local below = nz > 0 and (1 << (nz - 1)) or 0
    for x = nx, nx + p.sx - 1 do
        local base = x * lim.Y
        for y = ny, ny + p.sy - 1 do
            local column = cols[base + y]
            if (column & bits) ~= 0 then return false end
            if nz > 0 and (column & below) == 0 then return false end
        end
    end
    return true
end

-- How near the hold is to having a space for the piece: the most of its footprint that is free to
-- its height in one spot (the goal is all of it), then how much floor is free at all. One number,
-- larger is better.
function CompactScore(cols, lim, want)
    local height = math.min(want.Z, lim.Z)
    local mask = (1 << height) - 1
    local free, total = {}, 0
    for x = 0, lim.X - 1 do
        for y = 0, lim.Y - 1 do
            local f = (cols[x * lim.Y + y] & mask) == 0 and 1 or 0
            free[x * lim.Y + y] = f
            total = total + f
        end
    end
    local W = lim.Y + 1
    local sum = {}
    for x = 0, lim.X do sum[x * W] = 0 end
    for y = 0, lim.Y do sum[y] = 0 end
    for x = 1, lim.X do
        for y = 1, lim.Y do
            sum[x * W + y] = free[(x - 1) * lim.Y + (y - 1)] + sum[(x - 1) * W + y] + sum[x * W + y - 1] - sum[(x - 1) * W + y - 1]
        end
    end
    local best = 0
    local shapes = { { want.X, want.Y } }
    if want.X ~= want.Y then shapes[2] = { want.Y, want.X } end
    for _, shape in ipairs(shapes) do
        local w, h = shape[1], shape[2]
        for x0 = 0, lim.X - w do
            for y0 = 0, lim.Y - h do
                local n = sum[(x0 + w) * W + y0 + h] - sum[x0 * W + y0 + h] - sum[(x0 + w) * W + y0] + sum[x0 * W + y0]
                if n > best then best = n end
            end
        end
    end
    return best * 1000 + total, best >= want.X * want.Y
end

function CompactMoved(state, i, at)
    local copy = {}
    for k, p in ipairs(state) do copy[k] = p end
    local p = state[i]
    copy[i] = { id = p.id, x = at[1], y = at[2], z = at[3], sx = p.sx, sy = p.sy, sz = p.sz, movable = p.movable }
    return copy
end

-- What the pieces' places are, as text, for telling a state already seen.
function CompactParts(state)
    local parts = {}
    for k, p in ipairs(state) do parts[k] = p.x .. "," .. p.y .. "," .. p.z end
    return parts
end

-- Plays a list of moves ({ index, x, y, z }) from the start, and says whether each is possible in its
-- turn and the last leaves a space.
function CompactReplay(start, moves, lim, want)
    local state = start
    for _, move in ipairs(moves) do
        local cols = CompactColumns(state, lim)
        local p = state[move[1]]
        if not CompactClear(cols, lim, p) then return false end
        CompactLift(cols, lim, p, false)
        if not CompactFits(cols, lim, p, move[2], move[3], move[4]) then return false end
        state = CompactMoved(state, move[1], { move[2], move[3], move[4] })
    end
    local _, done = CompactScore(CompactColumns(state, lim), lim, want)
    return done
end

-- One climb: at each step the moves are scored with the fitness above and the best is made (the first
-- climb), or one of the best few picked at random (the later ones, which wander off the first climb's
-- dead ends). Nil if the space is not found within COMPACT_MOVES moves or the time.
function CompactClimb(start, lim, want, deadline, wander)
    local state = start
    local parts = CompactParts(state)
    local seen, moved, plan = { [table.concat(parts, ";")] = true }, {}, {}
    local cols = CompactColumns(state, lim)
    local _, done = CompactScore(cols, lim, want)
    while not done do
        if #plan >= COMPACT_MOVES or os.clock() > deadline then return nil end
        local top = {}   -- the best few moves so far, best first: { i, x, y, z, key = }
        for i, p in ipairs(state) do
            if p.movable and (moved[i] or 0) < 2 and CompactClear(cols, lim, p) then
                CompactLift(cols, lim, p, false)  -- lifted out while its other places are tried
                local here = parts[i]
                for nz = 0, lim.Z - p.sz do
                    for ny = 0, lim.Y - p.sy do
                        for nx = 0, lim.X - p.sx do
                            if not (nx == p.x and ny == p.y and nz == p.z) and CompactFits(cols, lim, p, nx, ny, nz) then
                                parts[i] = nx .. "," .. ny .. "," .. nz
                                if not seen[table.concat(parts, ";")] then
                                    local stand = { x = nx, y = ny, z = nz, sx = p.sx, sy = p.sy, sz = p.sz }
                                    CompactLift(cols, lim, stand, true)
                                    local key = CompactScore(cols, lim, want)
                                    CompactLift(cols, lim, stand, false)
                                    key = key * 10 - (moved[i] or 0) * 2 - (nz > 0 and 1 or 0)
                                    if #top < COMPACT_WIDTH or key > top[#top].key then
                                        top[#top + 1] = { i, nx, ny, nz, key = key }
                                        table.sort(top, function(a, b) return a.key > b.key end)
                                        if #top > COMPACT_WIDTH then top[#top] = nil end
                                    end
                                end
                            end
                        end
                    end
                end
                parts[i] = here
                CompactLift(cols, lim, p, true)
            end
            if os.clock() > deadline then return nil end
        end
        if #top == 0 then return nil end
        local pick = wander and top[math.random(1, #top)] or top[1]
        plan[#plan + 1] = pick
        moved[pick[1]] = (moved[pick[1]] or 0) + 1
        state = CompactMoved(state, pick[1], { pick[2], pick[3], pick[4] })
        parts = CompactParts(state)
        seen[table.concat(parts, ";")] = true
        cols = CompactColumns(state, lim)
        _, done = CompactScore(cols, lim, want)
    end
    return plan
end

-- The moves ({ id, x, y, z }) that open a space of this size in the hold, or nil.
function CompactSpace(boxes, lim, want)
    local state = {}
    for _, box in pairs(boxes) do
        state[#state + 1] = { id = box.id, x = box.low.X, y = box.low.Y, z = box.low.Z,
                              sx = box.size.X, sy = box.size.Y, sz = box.size.Z, movable = box.anchor ~= nil }
    end
    table.sort(state, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        if a.y ~= b.y then return a.y < b.y end
        return a.z < b.z
    end)
    local start = state
    math.randomseed(20261016)  -- the same hold gets the same plan
    -- The space the piece needs first. If the climb does not find it in time, a slightly bigger space:
    -- whatever opens a bigger space opens the piece's, and the climb sometimes finds the roomier one
    -- more readily (a 4x3x3 may be opened by the plan for a 4x4x3).
    local targets = { { want, 0.4 } }
    for _, bigger in ipairs({ { want.X, want.Y + 1, want.Z }, { want.X, want.Y, want.Z + 1 },
                              { want.X + 1, want.Y, want.Z }, { want.X, want.Y + 1, want.Z + 1 } }) do
        if bigger[1] <= lim.X and bigger[2] <= lim.Y and bigger[3] <= lim.Z then
            targets[#targets + 1] = { { X = bigger[1], Y = bigger[2], Z = bigger[3] }, 0.3 }
        end
    end
    local plan = nil
    local spent = 0
    for _, target in ipairs(targets) do
        local share = math.min(target[2], 1 - spent) * COMPACT_BUDGET_S
        if share <= 0 then break end
        spent = spent + target[2]
        local deadline = os.clock() + share
        for attempt = 1, COMPACT_ATTEMPTS do
            plan = CompactClimb(start, lim, target[1], deadline, attempt > 1)
            if plan or os.clock() > deadline then break end
        end
        if plan then break end
    end
    if not plan then return nil end
    -- Take out the moves that turn out not to be needed.
    local shortened = true
    while shortened and #plan > 1 do
        shortened = false
        for k = 1, #plan do
            local trial = {}
            for j, move in ipairs(plan) do
                if j ~= k then trial[#trial + 1] = move end
            end
            if CompactReplay(start, trial, lim, want) then
                plan = trial
                shortened = true
                break
            end
        end
    end
    local moves = {}
    for _, move in ipairs(plan) do
        moves[#moves + 1] = { id = start[move[1]].id, x = move[2], y = move[3], z = move[4] }
    end
    return moves
end

-- Plans the clearing of a space in the hold for a piece that does not fit. True if there is a plan.
local function PlanTidy(site, waiting)
    if TidyRounds >= TIDY_ROUNDS then return false end
    TidyRounds = TidyRounds + 1
    local from = waiting.CargoArea
    local theirs = Boxes(from)[waiting:GetRepresentedInventoryItem():GetAddress()]
    if not theirs then return false end
    local boxes, limit = Boxes(site.hold)
    local cells = { X = limit.X, Y = limit.Y, Z = limit.Z }
    local moves = PlanSpace(boxes, cells, theirs.size)
    local rearranged = false
    if not moves then
        local ok, found = pcall(CompactSpace, boxes, cells, theirs.size)
        if not ok then Log("rearranging the hold failed: " .. tostring(found):gsub("\n.*", "")) end
        if ok and found then
            moves, rearranged = found, true
        end
    end
    local report = string.format("a %dx%dx%d piece does not fit: %s", theirs.size.X, theirs.size.Y, theirs.size.Z,
        moves and (#moves .. (rearranged and " move(s) to rearrange the hold" or " piece(s) to move aside")) or "no spot can be cleared")
    if report ~= TidyReport then
        TidyReport = report
        Log(report)
        if not moves then
            local parts = {}
            for _, box in pairs(boxes) do
                parts[#parts + 1] = string.format("%dx%dx%d at %d,%d,%d", box.size.X, box.size.Y, box.size.Z, box.low.X, box.low.Y, box.low.Z)
            end
            table.sort(parts)
            Log(string.format("TIDY: hold grid %dx%dx%d, %d piece(s): %s", limit.X, limit.Y, limit.Z, #parts,
                table.concat(parts, "; "):sub(1, 1500)))
        end
    end
    if not moves or #moves == 0 then return false end
    local actors = {}
    for _, cargo in ipairs(Live("HeavyCargo")) do
        pcall(function() actors[cargo:GetRepresentedInventoryItem():GetAddress()] = cargo end)
    end
    TidyPlan = {}
    for _, move in ipairs(moves) do
        local box, cargo = boxes[move.id], actors[move.id]
        if not cargo then
            TidyPlan = {}
            return false
        end
        TidyPlan[#TidyPlan + 1] = { cargo = cargo, place = {
            position = { X = move.x + box.anchor.X, Y = move.y + box.anchor.Y, Z = (move.z or 0) + box.anchor.Z },
            rotation = box.rotation } }
    end
    return true
end

local function NextTidy(site, waiting)
    if #TidyPlan == 0 and not PlanTidy(site, waiting) then return nil end
    local step = table.remove(TidyPlan, 1)
    if not Valid(step.cargo) or not Same(step.cargo.CargoArea, site.hold) then
        TidyPlan = {}
        return nil
    end
    return { cargo = step.cargo, to = site.hold, place = step.place, settle = true, tidy = true }
end

CELL_SIZE_CM = 25
local Unreachable = {}  -- cargo guid -> true for pieces the boat's own cranes cannot get to; left alone
local Skip = {}         -- cargo guid -> true for pieces passed over for now, while another is looked for

-- A piece with others standing on it is not pulled out from under them. The topmost piece standing on
-- it is first moved aside, to a gap on the floor of the same area away from the piece, or failing
-- that wherever the game finds room that is not on top of it again. Nil when nothing is on it.
local function ClearAbove(site, cargo)
    local area = cargo.CargoArea
    if not Valid(area) then return nil end
    local boxes, limit = Boxes(area)
    local target = boxes[cargo:GetRepresentedInventoryItem():GetAddress()]
    if not target then return nil end
    local function over(box, under)
        return box.low.Z > under.low.Z and box.low.X <= under.high.X and box.high.X >= under.low.X
            and box.low.Y <= under.high.Y and box.high.Y >= under.low.Y
    end
    local top = nil
    for _, box in pairs(boxes) do
        if box ~= target and over(box, target) and box.anchor and (not top or box.high.Z > top.high.Z) then top = box end
    end
    if not top then return nil end
    local actor = nil
    for _, candidate in ipairs(Live("HeavyCargo")) do
        pcall(function()
            if candidate:GetRepresentedInventoryItem():GetAddress() == top.id then actor = candidate end
        end)
    end
    if not actor then return nil end
    if Unreachable[CargoGuid(actor) or "?"] then return "blocked" end  -- what is on it cannot be moved

    local grid = {}
    for _, box in pairs(boxes) do Fill(grid, box, box.id) end
    for x = target.low.X, target.high.X do  -- keep the piece's own column clear
        for y = target.low.Y, target.high.Y do
            for z = 0, limit.Z - 1 do grid[CellName(x, y, z)] = grid[CellName(x, y, z)] or "kept" end
        end
    end
    Fill(grid, top, nil)
    local place = nil
    local x, y = FloorGap(grid, { X = limit.X, Y = limit.Y, Z = limit.Z }, top.size)
    if x then
        place = { position = { X = x + top.anchor.X, Y = y + top.anchor.Y, Z = top.anchor.Z }, rotation = top.rotation }
    else
        local offered = FindPlace(area, actor)
        if offered then
            local p = offered.position
            local onIt = p.X <= target.high.X and p.X + top.size.X - 1 >= target.low.X
                and p.Y <= target.high.Y and p.Y + top.size.Y - 1 >= target.low.Y
            if not onIt then place = offered end
        end
    end
    if not place then return nil end
    Log("moving a " .. ClassName(actor) .. " off the " .. ClassName(cargo) .. " it stands on")
    return { cargo = actor, to = area, place = place, settle = true, tidy = true, under = cargo }
end

PLACES_TRIED = 16  -- free spots tried, nearest a crane first, when looking for a place in reach
local PlaceInReach  -- (site, area, cargo) -> a place in the area a crane can reach with the piece,
                    -- or nil and a hand-over move when the neatest place is the other crane's
local Relayed = {}  -- cargo guid -> true once handed over, so a piece is never passed back and forth
local NeedsStaging  -- (site, cargo) -> true if a piece to load stands where no crane of the site gets to it
local StagingPlace  -- (site, area, cargo) -> a place in the area a crane can then pick the piece up from
local Staged = {}   -- cargo guid -> true once brought to the dock by the boat
STAGE_RANGE_CM = 100000  -- pieces to load this close to the boat are brought to its dock
local Relay         -- (site, cargo, docks) -> a move across the hold to where the other crane can unload it

-- The next piece to move: unloading first, so that the hold has room for what is loaded after, and
-- from the top of a stack down, so that as little as possible is left hanging.
-- Pieces that cannot be fitted into the hold as it stands. They are left alone, and written to
-- loadfail.txt next to the Logistics mod's files so that the planner stops counting on them and plans
-- again. They stay left alone until the hold has more free room than when they were found not to
-- fit (something came off), or the boat is another one: loading other cargo or moving it about
-- cannot make room for them, and trying again each time only wastes the crane's work.
NoRoom = {}           -- cargo guid -> true
NoRoomFree = nil      -- free cells in the hold when the pieces were found not to fit
NoRoomBoat = nil      -- the boat whose hold it was
NoRoomPath = ScriptDir .. "\\..\\..\\SasLogistics\\loadfail.txt"

function WriteNoRoom()
    local file = io.open(NoRoomPath, "w")
    if not file then return end
    for guid in pairs(NoRoom) do file:write(guid, "\n") end
    file:close()
end

function ClearNoRoom()
    if next(NoRoom) == nil then return end
    NoRoom, NoRoomFree, NoRoomBoat = {}, nil, nil
    WriteNoRoom()
end

-- How many cells of the boat's hold are free.
function HoldFree(site)
    local ok, free = pcall(function()
        local size = site.hold:GetInventory().GridSize
        local used = 0
        for _, box in pairs(CachedBoxes(site.hold)) do used = used + box.size.X * box.size.Y * box.size.Z end
        return size.X * size.Y * size.Z - used
    end)
    return ok and free or nil
end

function MarkNoRoom(site, cargo)
    local guid = CargoGuid(cargo)
    if not guid then return end
    NoRoom[guid] = true
    NoRoomFree, NoRoomBoat = HoldFree(site), site.boat
    local name = "piece"
    pcall(function() name = cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
    Log("the " .. ClassName(cargo) .. " cannot be fitted into the hold as it stands; leaving it, and telling the planner")
    Toast("The " .. name .. " does not fit in the hold")
    WriteNoRoom()
end

-- Pieces left alone for want of room are looked at again once something has come off the hold, or when
-- it is another boat's hold.
-- Taking cargo off for room. The planner lists, in removable.txt next to its other files, the pieces aboard
-- that it would leave on the dock at this port anyway (they are not delivered by its route). When a piece to
-- load cannot be made room for even by rearranging the hold, the biggest of those still in the hold is
-- taken off first and the loading tried again. Nothing is taken off unless it is needed.
RemovablePath = ScriptDir .. "\\..\\..\\SasLogistics\\removable.txt"
Activated = {}   -- cargo guid -> true for the pieces taken off to make room, so that they go as unloads

function ReadRemovable()
    local guids = {}
    local file = io.open(RemovablePath, "r")
    if not file then return guids end
    for line in file:lines() do
        local guid = line:match("^(%x+)%s*$")
        if guid and #guid == 32 then guids[guid:upper()] = true end
    end
    file:close()
    return guids
end

-- The biggest removable piece in the hold, now marked to go, or nil when there is none left.
function TakeOffForRoom(site)
    local removable = ReadRemovable()
    if next(removable) == nil then return nil end
    local boxes = CachedBoxes(site.hold)
    local best, bestVolume = nil, -1
    for _, cargo in ipairs(Live("HeavyCargo")) do
        local guid = CargoGuid(cargo)
        local area = nil
        pcall(function() area = cargo.CargoArea end)
        if guid and removable[guid] and not Activated[guid] and Same(area, site.hold) then
            local box = boxes[cargo:GetRepresentedInventoryItem():GetAddress()]
            local volume = box and box.size.X * box.size.Y * box.size.Z or 0
            if volume > bestVolume then best, bestVolume = cargo, volume end
        end
    end
    if best then Activated[CargoGuid(best)] = true end
    return best
end

-- The pieces being taken off for room are unloads like any other, and go before anything is loaded.
function ApplyActivated(unload)
    for guid in pairs(Activated) do unload[guid] = true end
end

function RefreshNoRoom(site)
    if next(NoRoom) == nil then return end
    local free = HoldFree(site)
    if not Same(NoRoomBoat, site.boat) or (free and NoRoomFree and free > NoRoomFree) then ClearNoRoom() end
end

local function NextMove(site, load, unload)
    local at = site.crane:K2_GetActorLocation()
    RefreshNoRoom(site)
    ApplyActivated(unload)
    local toUnload, toLoad = {}, {}
    for _, cargo in ipairs(Live("HeavyCargo")) do
        local guid = CargoGuid(cargo)
        local area = nil
        pcall(function() area = cargo.CargoArea end)
        if guid and Valid(area) and not Unreachable[guid] and not Skip[guid] and not NoRoom[guid] then
            if unload[guid] and Same(area, site.hold) then
                toUnload[#toUnload + 1] = cargo
            elseif load[guid] and not IsHold(area) and Dist(cargo:K2_GetActorLocation(), at) < STAGE_RANGE_CM then
                toLoad[#toLoad + 1] = cargo
            end
        end
    end
    local function topFirst(a, b) return Height(a) > Height(b) end
    table.sort(toUnload, topFirst)
    -- Loading goes biggest first, with the small pieces last as gap fillers: widest on the floor, then
    -- tallest, then the top of a stack first. Simulated on real footprints, this loads far more of what
    -- the planner promised than taking the pieces in whatever order they stand (tests/sim_loading.py).
    local shape = {}
    for _, cargo in ipairs(toLoad) do
        shape[cargo] = { 0, 0 }
        pcall(function()
            local box = CachedBoxes(cargo.CargoArea)[cargo:GetRepresentedInventoryItem():GetAddress()]
            if box then shape[cargo] = { box.size.X * box.size.Y, box.size.Z } end
        end)
    end
    table.sort(toLoad, function(a, b)
        local sa, sb = shape[a], shape[b]
        if sa[1] ~= sb[1] then return sa[1] > sb[1] end
        if sa[2] ~= sb[2] then return sa[2] > sb[2] end
        return topFirst(a, b)
    end)
    local docks = #toUnload > 0 and DockAreas(site) or {}
    for _, cargo in ipairs(toUnload) do
        local ok, clear = pcall(ClearAbove, site, cargo)
        if ok and clear and clear ~= "blocked" then return clear end
        if not (ok and clear == "blocked") then
            for _, dock in ipairs(docks) do
                local place, handOver = PlaceInReach(site, dock.area, cargo)
                if handOver then return handOver end
                if place then
                    local move = { cargo = cargo, to = dock.area, place = place }
                    -- Only where a crane really gets the piece to: the game would put it in any dock
                    -- area, however far from the boat, and the piece would simply appear there.
                    if MoveWithinReach(site, move) then return move end
                end
            end
            if site.deck then
                -- Neither crane can take it straight to the dock: perhaps one can bring it across the
                -- hold to where the other can.
                local ok2, relay = pcall(Relay, site, cargo, docks)
                if not ok2 then Log("planning a hand-over failed: " .. tostring(relay):gsub("\n.*", "")) end
                if ok2 and relay then return relay end
            end
            -- No dock area is within reach of a crane from here: the piece stays where it is until
            -- the boat is somewhere else. (The mark is not lost; it is looked at again after moving.)
            local guid = CargoGuid(cargo)
            if guid and not Unreachable[guid] then
                Unreachable[guid] = true
                local name = "piece"
                pcall(function() name = cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
                Log("no dock area is within reach of the crane for the " .. ClassName(cargo) .. "; leaving it aboard")
                local tooFar = false
                local okWhy, why = pcall(ExplainUnreachable, site, cargo, docks)
                if okWhy then tooFar = why == "piece" else Log("REACH: could not explain: " .. (tostring(why):gsub("\n.*", ""))) end
                if tooFar then
                    Toast("The " .. name .. " is too far from the dock crane to lift from where it lies")
                else
                    Toast("The " .. name .. " cannot be put ashore from here: the dock is out of the crane's reach")
                end
            end
        end
    end
    -- Pieces the cranes can get to first; bringing others closer comes after.
    local farOff = {}
    for _, cargo in ipairs(toLoad) do
        local okFar, needs = pcall(NeedsStaging, site, cargo)
        farOff[cargo] = okFar and needs and not Staged[CargoGuid(cargo) or "?"]
    end
    for _, cargo in ipairs(toLoad) do
        local ok, clear = nil, nil
        if not farOff[cargo] then ok, clear = pcall(ClearAbove, site, cargo) end
        if ok and clear and clear ~= "blocked" then return clear end
        if not farOff[cargo] and not (ok and clear == "blocked") then
            local place, handOver = PlaceInReach(site, site.hold, cargo)
            if handOver then return handOver end
            if place then
                TidyRounds, TidyTold, TidyPlan = 0, false, {}
                return { cargo = cargo, to = site.hold, place = place }
            end
        end
    end
    -- A piece the warehouse put out in a dock area the cranes do not get to is first brought to the
    -- dock area by the boat, the way the warehouse would have put it there.
    for _, cargo in ipairs(toLoad) do
        local ok, needs = pcall(NeedsStaging, site, cargo)
        local guid = CargoGuid(cargo) or "?"
        if ok and needs and not Staged[guid] then
            -- Anything standing on it goes first, aside within its own area and the same unseen way,
            -- so that nothing is left hanging in the air there.
            local okClear, clear = pcall(ClearAbove, site, cargo)
            if okClear and clear and clear ~= "blocked" then
                clear.stage = true
                Log("moving a " .. ClassName(clear.cargo) .. " off the " .. ClassName(cargo) .. " before bringing it over")
                return clear
            end
            for _, dock in ipairs(DockAreas(site)) do
                if not Same(dock.area, cargo.CargoArea) then
                    local okPlace, place = pcall(StagingPlace, site, dock.area, cargo)
                    if okPlace and place then
                        Staged[guid] = true  -- brought over once; if it is still out of reach after, it stays put
                        Log("bringing the " .. ClassName(cargo) .. " to the " .. ClassName(dock.area) .. " first: it is out of the crane's reach where it stands")
                        return { cargo = cargo, to = dock.area, place = place, settle = true, stage = true }
                    end
                end
            end
        end
    end
    if #toLoad > 0 then
        local ok, tidy = pcall(NextTidy, site, toLoad[1])
        if not ok then Log("planning room in the hold failed: " .. tostring(tidy):gsub("\n.*", "")) end
        if ok and tidy then return tidy end
        -- Not even by rearranging: a piece the planner would leave on the dock anyway is taken off, if there is one.
        local off = TakeOffForRoom(site)
        if off then
            local name = "piece"
            pcall(function() name = off:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
            Log("no room for the " .. ClassName(toLoad[1]) .. " even by rearranging: taking the " .. ClassName(off) .. " off, which the planner would leave on the dock anyway")
            Toast("Taking the " .. name .. " off to make room")
            TidyRounds, TidyTold, TidyPlan = 0, false, {}
            return NextMove(site, load, unload)
        end
        -- No room can be made for the first piece: it is left, and the next is tried.
        MarkNoRoom(site, toLoad[1])
        TidyRounds, TidyTold, TidyPlan = 0, false, {}
        if #toLoad > 1 then return NextMove(site, load, unload) end
        return nil, "no room in the hold"
    end
    TidyRounds = 0
    if #toUnload > 0 then return nil, "nothing to unload can be put on the dock from here" end
    return nil
end

local Manual = {}        -- cargo guid -> "load" or "unload", for pieces marked by hand with F5
local Job = nil          -- the piece being moved, see StartJob
local Failed = {}        -- cargo guid -> times the crane could not keep it on the hook
local Rest = 0           -- ticks until the operator starts the next piece
local Working = false    -- was there work when last looked
local Moved = 0
local Complaint = nil

-- The operator's place at the crane. While there is work they sit in the dock crane's seat, put
-- there with the crane's own driver component; when it is done they go back to where they stood on
-- the boat. A crew member cannot walk there: the boat's deck has no walkable route for them.

SEAT_SECONDS = 3   -- in the seat before the first lift
local AtCrane = nil      -- { crane, character, boat, controller, home }

local function CraneDriver(crane)
    local ok, driver = pcall(function() return crane.DriverComponent.Driver end)
    return ok and Valid(driver) and driver or nil
end

local function SendTo(character, place)
    pcall(function() character:K2_SetActorLocation(place, false, {}, true) end)
end

-- Is the character standing on this boat (on its hull, or on something fixed to it)?
local function StandsOn(character, boat)
    local ok, on = pcall(function()
        local under = character.BasedMovement.MovementBase:GetOwner()
        for _ = 1, 6 do
            if not Valid(under) then return false end
            if Same(under, boat) then return true end
            under = under:GetAttachParentActor()
        end
        return false
    end)
    return ok and on
end

-- A place on the boat, kept relative to the boat so that it still holds after the boat has moved
-- and turned.
local function ToBoat(boat, place)
    local at, yaw = boat:K2_GetActorLocation(), math.rad(boat:K2_GetActorRotation().Yaw)
    local dx, dy = place.X - at.X, place.Y - at.Y
    return { X = dx * math.cos(yaw) + dy * math.sin(yaw), Y = -dx * math.sin(yaw) + dy * math.cos(yaw), Z = place.Z - at.Z }
end

local function FromBoat(boat, spot)
    local at, yaw = boat:K2_GetActorLocation(), math.rad(boat:K2_GetActorRotation().Yaw)
    return { X = at.X + spot.X * math.cos(yaw) - spot.Y * math.sin(yaw),
             Y = at.Y + spot.X * math.sin(yaw) + spot.Y * math.cos(yaw), Z = at.Z + spot.Z }
end

local function HelmExit(boat)
    local ok, exit = pcall(function() return boat.DriverComponent:GetDriverExitLocation() end)
    return ok and exit and exit.X and exit or nil
end

local Spots = {}   -- crew member name -> where they stand on their boat, relative to the boat
local Pinned = {}  -- crew member name -> true when that place was set with Ctrl+Alt+H; kept in spots.txt

local function ReadPinned()
    local file = io.open(SpotsPath, "r")
    if not file then return end
    for line in file:lines() do
        local name, x, y, z = line:match("^(.-)|([%-%d%.]+)|([%-%d%.]+)|([%-%d%.]+)%s*$")
        if name and name ~= "" then
            Spots[name] = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
            Pinned[name] = true
        end
    end
    file:close()
end

local function WritePinned()
    local file = io.open(SpotsPath, "w")
    if not file then return end
    for name in pairs(Pinned) do
        file:write(string.format("%s|%.1f|%.1f|%.1f\n", name, Spots[name].X, Spots[name].Y, Spots[name].Z))
    end
    file:close()
end

ReadPinned()

-- Notes where the operator stands while they are on the boat and away from the wheel, so that they
-- can be sent back to their own spot. The place at the wheel is yours and is never remembered.
local function NoteSpot(name, character, boat)
    if Pinned[name] then return end
    if not Valid(character) or not StandsOn(character, boat) then return end
    local here, helm = character:K2_GetActorLocation(), HelmExit(boat)
    if helm and Dist(here, helm) < 200 then return end
    Spots[name] = ToBoat(boat, here)
end

-- Where the operator goes back to: their own spot on the boat if one is known, otherwise the place
-- beside the helm where someone leaving the wheel is put, otherwise the hold.
local function HomeOnBoat(site, name)
    if Spots[name] then return Spots[name] end
    local helm = HelmExit(site.boat)
    if helm then return ToBoat(site.boat, helm) end
    local hold = site.hold:K2_GetActorLocation()
    return ToBoat(site.boat, { X = hold.X, Y = hold.Y, Z = hold.Z + 150 })
end

-- In the seat the crew member's own behaviour is stopped; left running, it has them eat crisps and
-- stretch at the controls.
local function EnterCrane(site, character, name)
    NoteSpot(name, character, site.boat)
    local controller = character.Controller
    pcall(function() controller.BrainComponent:StopLogic("crane") end)
    pcall(function() character:StopAnimMontage(nil) end)
    site.crane.DriverComponent:SetDriver(character)
    pcall(function() character:StopAnimMontage(nil) end)
    AtCrane = { crane = site.crane, character = character, boat = site.boat, controller = controller,
                home = HomeOnBoat(site, name) }
end

local function LeaveCrane()
    local at = AtCrane
    AtCrane = nil
    if not at or not Valid(at.character) then return end
    if Valid(at.crane) and Same(CraneDriver(at.crane), at.character) then
        at.crane.DriverComponent:RemoveCurrentDriver()
    end
    if Valid(at.boat) then  -- back to their spot on the boat, wherever the boat is now
        local home = FromBoat(at.boat, at.home)
        SendTo(at.character, { X = home.X, Y = home.Y, Z = home.Z + 20 })
    end
    pcall(function() at.controller.BrainComponent:RestartLogic() end)
end

-- A crew member found in a crane's seat that this run of the mod did not put there (the mod was
-- reloaded while they worked) is taken out and sent back to their boat's hold.
local StrandedChecked = false

local function RecoverStranded()
    for _, crane in ipairs(Live("CargoCrane")) do
        pcall(function()
            local driver = CraneDriver(crane)
            if not driver or not ClassName(driver):find("CrewMember", 1, true) then return end
            crane.DriverComponent:RemoveCurrentDriver()
            local boat = driver.CrewMember.Boat
            for _, area in ipairs(Live("CargoArea")) do
                if IsHold(area) and Same(area:GetAttachParentActor(), boat) then
                    local at = area:K2_GetActorLocation()
                    SendTo(driver, { X = at.X, Y = at.Y, Z = at.Z + 150 })
                end
            end
            Log("took a crew member left in a crane's seat back to their boat")
        end)
    end
end

-- Ctrl+Alt+H: the operator of the boat you are on stands where you are standing.
local function SetSpotHere()
    local pawn = FindFirstOf("PlayerController").Pawn
    local here = pawn:K2_GetActorLocation()
    local chosen, chosenBoat, best = nil, nil, CRANE_REACH_CM
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local slot = CraneSlot(comp)
            if not slot or not Valid(slot.CrewMember) then return end
            local d = Dist(comp:GetOwner():K2_GetActorLocation(), here)
            if d < best then chosen, chosenBoat, best = slot.CrewMember, comp:GetOwner(), d end
        end)
    end
    if not chosen then
        Toast("No crane operator on a boat near you")
        return
    end
    if not StandsOn(pawn, chosenBoat) then
        Toast("Stand on the boat, where the crane operator should wait")
        return
    end
    local name = MemberName(chosen)
    Spots[name] = ToBoat(chosenBoat, here)
    Pinned[name] = true
    WritePinned()
    if AtCrane and Same(AtCrane.character, chosen.Character) then
        AtCrane.home = Spots[name]
    elseif Valid(chosen.Character) then
        SendTo(chosen.Character, { X = here.X, Y = here.Y, Z = here.Z + 20 })
    end
    Toast(name .. " will wait here when not at the crane")
end

---------------------------------------------------------------------------------------------------
-- Moving the crane. Each kind of crane is a set of joints, each of which goes smoothly to whatever
-- value it is given, and a model of where those values put the end of its arm. The figures were
-- measured in game by moving one joint at a time.

CELL_CM = 25
DRUM_MIN, DRUM_MAX = 10, 1000
PHASE_SECONDS = 12  -- a step that has not finished by then is given up on and the next one starts
-- The deck crane latches a piece with its hook joint this far above the piece's lifting point, as
-- the game's own operators do. Latching pulls the piece up to the hook; from much lower it would still
-- sit in its place, and the game would set it straight back down.
HOOK_ON_LIFT_CM = 55

local function Turn(degrees)  -- into -180 .. 180
    return (degrees + 180) % 360 - 180
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- The stationary dock crane (T01). The platform swivels (degrees, all the way round), the boom is
-- hoisted (degrees, 0 to 50), the boom telescopes (0 to 230, two centimetres a unit) and the cable
-- drum pays out (centimetres). The boom is 445 cm long from a pivot 25 cm behind and 335 cm above the
-- crane's origin and lies 2.1 degrees below level at hoist 0; the hook hangs 53 cm plus the paid-out
-- cable below its tip. Lying flat, the hook only gets as high as the tallest stack on a medium dock,
-- so when a higher tip is asked for the boom is raised and run out further to keep its reach, as far
-- as it goes; the tip returned is where it really ends up.
BOOM_CM, BOOM_BACK_CM, BOOM_UP_CM, BOOM_DROOP_DEG = 445, 25, 335, 2.1
TELESCOPE_CM_PER_UNIT, TELESCOPE_MAX, HOIST_MAX = 2, 230, 50

local DockCrane = {
    match = "StationaryCrane_T01",
    joints = { swivel = "Joint_SwivelPlatform", hoist = "Joint_BoomHoist", telescope = "Joint_TelescopicBoom", drum = "Joint_CableDrum",
               turn = "Joint_HookRotator" },
    speed = { swivel = 35, hoist = 20, telescope = 90, drum = 120, turn = 60 },   -- units a second
    close = { swivel = 1.5, hoist = 1.0, telescope = 4, drum = 8, turn = 2 },     -- near enough to count as there
    parked = { swivel = 0, hoist = 0, telescope = 0, drum = DRUM_MIN },
    wraps = true,
    hookBelow = 53,
    -- The furthest a piece can stand from the crane's base, in the plane, for the hook to get over
    -- it with the boom fully run out (with a margin). Beyond that the arm below stops at full
    -- stretch, short of the piece, and the piece would be pulled to the hook instead.
    maxOut = (BOOM_CM + TELESCOPE_MAX * TELESCOPE_CM_PER_UNIT) * math.cos(math.rad(BOOM_DROOP_DEG)) - BOOM_BACK_CM - 15,
}

function DockCrane.Arm(crane, point, tipZ)
    local base, yaw = crane:K2_GetActorLocation(), crane:K2_GetActorRotation().Yaw
    local dx, dy = point.X - base.X, point.Y - base.Y
    local out = math.sqrt(dx * dx + dy * dy)
    local level = math.cos(math.rad(BOOM_DROOP_DEG))
    local hoist, telescope = 0, 0
    local run = out + BOOM_BACK_CM               -- from the pivot, in the plane
    local need = run / level                     -- boom length that reaches it with the boom down
    if need >= BOOM_CM then
        telescope = Clamp((need - BOOM_CM) / TELESCOPE_CM_PER_UNIT, 0, TELESCOPE_MAX)
        local longest = BOOM_CM + TELESCOPE_MAX * TELESCOPE_CM_PER_UNIT
        local up = tipZ and (tipZ - base.Z - BOOM_UP_CM) or -math.huge   -- tip height asked for, above the pivot
        local flatUp = -math.sqrt(math.max(need * need - run * run, 0))
        if up > flatUp and run < longest then
            -- Raise the boom to put the tip that high, running it out to keep the reach, as far as it goes.
            up = math.min(up, math.sqrt(longest * longest - run * run), run * math.tan(math.rad(HOIST_MAX - BOOM_DROOP_DEG)))
            hoist = Clamp(math.deg(math.atan(up, run)) + BOOM_DROOP_DEG, 0, HOIST_MAX)
            telescope = Clamp((math.sqrt(run * run + up * up) - BOOM_CM) / TELESCOPE_CM_PER_UNIT, 0, TELESCOPE_MAX)
        end
    else  -- closer than the shortest boom lying flat: raise it
        hoist = Clamp(BOOM_DROOP_DEG + math.deg(math.acos(Clamp(run / BOOM_CM, 0, 1))), 0, HOIST_MAX)
    end
    local length = BOOM_CM + telescope * TELESCOPE_CM_PER_UNIT
    local endZ = base.Z + BOOM_UP_CM + length * math.sin(math.rad(hoist - BOOM_DROOP_DEG))
    return { pose = { swivel = Turn(math.deg(math.atan(dy, dx)) - yaw), hoist = hoist, telescope = telescope }, tipZ = endZ }
end

-- The knuckle-boom deck crane (T02) on the class 3 cargo ship. The platform swivels (degrees, stopping
-- at half a turn either way). The lower arm pivots 20 cm behind and 266 cm above the crane's origin,
-- is 268.5 cm long and stands at 33.2 degrees plus 42.2 for each unit of hoist (it rests on its stop
-- at 7.3 degrees below hoist -0.6). The upper arm, from the knuckle to its end, is 359 cm plus 792 for
-- each unit of telescope (1118 at most), set at 48 degrees below the lower arm plus 50 for each unit
-- of bend. The hook hangs 47 cm to the left of the arm, 3 cm beyond its end and 78 cm plus the
-- paid-out cable below it.
KNUCKLE = { pivotBack = 20, pivotUp = 266, lower = 268.5, lowerAt = 33.2, lowerPerUnit = 42.2, lowerMin = 7.3,
                  upper = 359, upperPerUnit = 792, upperMax = 1118, bendAt = -48, bendPerUnit = 50,
                  side = 47, ahead = 3 }

local DeckCrane = {
    match = "StationaryCrane_T02",
    joints = { swivel = "Joint_SwivelPlatform", hoist = "Joint_BoomHoist", bend = "Joint_UpperArmBender",
               telescope = "Joint_TelescopicBoom", drum = "Joint_CableDrum", turn = "Joint_HookRotator" },
    speed = { swivel = 30, hoist = 0.6, bend = 0.6, telescope = 0.25, drum = 120, turn = 60 },
    close = { swivel = 1.5, hoist = 0.02, bend = 0.02, telescope = 0.01, drum = 8, turn = 2 },
    parked = { swivel = 0, hoist = 0, bend = 0, telescope = 0, drum = DRUM_MIN },
    wraps = false,
    hookBelow = 78,
    feel = true,
    -- The arm's end is at least this high above the crane's foot while it swings, with the hook up:
    -- a load then hangs clear of the cargo on deck. The arm keeps its reach while it rises, so a load
    -- is not pulled in against the crane.
    travelUp = 700,
}

-- The joints that put the arm's end over a point with the end at a height; nil if it cannot reach.
-- The arm is kept as short as will do, and the height is moved up or down a little if need be.
function DeckCrane.Arm(crane, point, tipZ)
    local k = KNUCKLE
    local base, yaw = crane:K2_GetActorLocation(), crane:K2_GetActorRotation().Yaw
    local dx, dy = point.X - base.X, point.Y - base.Y
    local out = math.sqrt(dx * dx + dy * dy)
    if out <= k.side + 1 then return nil end
    local hookOut = math.sqrt(out * out - k.side * k.side)
    local swivel = Turn(math.deg(math.atan(dy, dx)) - math.deg(math.atan(k.side, hookOut)) - yaw)
    if math.abs(swivel) > 179 then return nil end
    local reach = hookOut - k.ahead
    local tryHeights = { 0, 25, 50, 100, 150, 200, 250, 300 }
    for _, lift in ipairs(tryHeights) do
        local up = (tipZ or point.Z + 200) - base.Z + lift
        if base.Z + up - DeckCrane.hookBelow - DRUM_MIN >= point.Z - 1 then  -- the hook must still get as high as the point
            local fx, fz = reach + k.pivotBack, up - k.pivotUp
            local d = math.sqrt(fx * fx + fz * fz)
            local telescope = 0
            while telescope <= (k.upperMax - k.upper) / k.upperPerUnit + 1e-6 do
                local upper = k.upper + telescope * k.upperPerUnit
                if d <= k.lower + upper and d >= math.abs(k.lower - upper) then
                    local cosA = (k.lower * k.lower + d * d - upper * upper) / (2 * k.lower * d)
                    local lower = math.deg(math.atan(fz, fx) + math.acos(Clamp(cosA, -1, 1)))
                    local kx = -k.pivotBack + k.lower * math.cos(math.rad(lower))
                    local kz = k.pivotUp + k.lower * math.sin(math.rad(lower))
                    local upperAngle = math.deg(math.atan(up - kz, reach - kx))
                    local hoist = (lower - k.lowerAt) / k.lowerPerUnit
                    local bend = (upperAngle - lower - k.bendAt) / k.bendPerUnit
                    if lower >= k.lowerMin and hoist <= 1 and bend >= -1 and bend <= 1 then
                        return { pose = { swivel = swivel, hoist = math.max(hoist, -1), bend = bend, telescope = telescope },
                                 tipZ = base.Z + up }
                    end
                end
                telescope = telescope + 0.02
            end
        end
    end
    return nil
end

local Models = { DockCrane, DeckCrane }

local function ModelOf(crane)
    local name = ClassName(crane)
    for _, model in ipairs(Models) do
        if name:find(model.match, 1, true) and Valid(crane[model.joints.swivel]) and Valid(crane[model.joints.drum]) then
            return model
        end
    end
    return nil
end

-- How much cable puts the hook at a height, below an arm end at another.
local function DrumFor(model, tipZ, hookZ)
    return Clamp(tipZ - model.hookBelow - hookZ, DRUM_MIN, DRUM_MAX)
end

local Steer = nil  -- { crane, model, goal }: where the joints are being taken

-- Is the crane at the goal? With `loose`, near enough to go straight on to the next step of a route:
-- the joints ease in slowly over their last stretch, and waiting for that at every step of a route is
-- what made the crane move, stop, move.
PASS_LOOSENESS = 8

local function There(crane, model, goal, loose)
    local factor = loose and PASS_LOOSENESS or 1
    for part, name in pairs(model.joints) do
        if goal[part] ~= nil then
            local off = goal[part] - crane[name]:GetCurrentValue()
            if part == "swivel" and model.wraps then off = Turn(off) end
            if math.abs(off) > model.close[part] * factor then return false end
        end
    end
    return true
end

-- Crane sounds. The game plays a crane's motor sounds from its controls: each tick the blueprint is
-- told how hard each part is being driven and how fast it moves (Update...SoundLoop). The operator
-- moves the joints by their targets, not the controls, so nothing tells it and the crane is silent.
-- This tells it instead, from how fast each joint actually moved since the last step.
SOUND_PARTS = { swivel = "UpdateRotatorSoundLoop", hoist = "UpdateHoistSoundLoop", bend = "UpdateHoistSoundLoop",
                telescope = "UpdateBoomSoundLoop", drum = "UpdateCableSoundLoop", turn = "UpdateHookSoundLoop" }
SoundLast = nil       -- { crane, values = part -> joint value at the last step, at = os.clock() }
SoundReported = false
SOUND_IDLE_SECONDS = 1.5
SoundIdleSince = nil
SoundPlaying = false  -- the motor loop has been started by the mod and not yet stopped

-- The Update...SoundLoop functions only set parameters (pitch and volume) on the crane's loop sound;
-- the loop itself, and a start and a stop sound, are played by the game when somebody takes the
-- controls. The operator never does, so the loop is started here and stopped when the crane is idle.
function SoundComponent(crane, property)
    local ok, comp = pcall(function() return crane[property] end)
    if ok and Valid(comp) then return comp end
    return nil
end

function StartMotorSound(crane)
    if SoundPlaying then return end
    SoundPlaying = true
    local start, loop = SoundComponent(crane, "CraneStartComp"), SoundComponent(crane, "CraneLoopComp")
    if start then pcall(function() start:Play(0.0) end) end
    if loop then
        local ok, err = pcall(function() loop:Play(0.0) end)
        Log("crane sounds: loop " .. (ok and "started" or ("failed to start: " .. tostring(err):gsub("\n.*", ""))))
    else
        Log("crane sounds: this crane has no loop sound component")
    end
end

function StopMotorSound(crane)
    if not SoundPlaying then return end
    SoundPlaying = false
    local stop, loop = SoundComponent(crane, "CraneStopComp"), SoundComponent(crane, "CraneLoopComp")
    if loop then pcall(function() loop:Stop() end) end
    if stop then pcall(function() stop:Play(0.0) end) end
end

function CraneSounds(crane, model)
    local now = os.clock()
    local last = SoundLast
    local values = {}
    for part, name in pairs(model.joints) do
        local ok, v = pcall(function() return crane[name]:GetCurrentValue() end)
        if ok then values[part] = v end
    end
    SoundLast = { crane = crane, values = values, at = now }
    if not last or not Same(last.crane, crane) or not model then return end
    local dt = math.max(now - last.at, 0.01)
    local loudest = {}  -- one call per sound loop, from the part driving it hardest
    for part, v in pairs(values) do
        local fn = SOUND_PARTS[part]
        if fn and last.values[part] then
            local diff = v - last.values[part]
            if part == "swivel" and model.wraps then diff = Turn(diff) end
            local velocity = diff / dt
            local drive = Clamp(velocity / math.max(model.speed[part] or 1, 0.001), -1, 1)
            if not loudest[fn] or math.abs(drive) > math.abs(loudest[fn].drive) then
                loudest[fn] = { drive = drive, velocity = velocity }
            end
        end
    end
    local moving = false
    for _, d in pairs(loudest) do
        if math.abs(d.drive) > 0.05 then moving = true end
    end
    if moving then StartMotorSound(crane) end
    for fn, d in pairs(loudest) do
        local ok, err = pcall(function() crane[fn](crane, d.drive, d.velocity) end)
        if not SoundReported then
            SoundReported = true
            Log("crane sounds: " .. fn .. (ok and " called" or (" failed: " .. tostring(err):gsub("\n.*", ""))))
        end
    end
end

-- Quiets the motor sounds once the crane stops.
function CraneSoundsStop(crane)
    if not Valid(crane) then return end
    for _, fn in pairs(SOUND_PARTS) do pcall(function() crane[fn](crane, 0.0, 0.0) end) end
    StopMotorSound(crane)
    SoundLast = nil
end

-- One step of every joint towards its goal, at that joint's speed.
local function SteerStep()
    local s = Steer
    if not s then
        -- The motor is let run on through the short gaps between the steps of a route, and shut off
        -- only once the crane has been still for a moment.
        if SoundLast then
            SoundIdleSince = SoundIdleSince or os.clock()
            if os.clock() - SoundIdleSince > SOUND_IDLE_SECONDS then
                CraneSoundsStop(SoundLast.crane)
                SoundIdleSince = nil
            end
        end
        return
    end
    SoundIdleSince = nil
    pcall(CraneSounds, s.crane, s.model)
    if not Valid(s.crane) then
        Steer = nil
        return
    end
    for part, name in pairs(s.model.joints) do
        if s.goal[part] ~= nil then
            local joint = s.crane[name]
            local now = joint:GetCurrentValue()
            local off = s.goal[part] - now
            local wraps = part == "swivel" and s.model.wraps
            if wraps then off = Turn(off) end
            local step = s.model.speed[part] * MOTION_MS / 1000 * 2  -- aimed a little ahead: the joint eases towards it
            local to = now + Clamp(off, -step, step)
            if wraps then to = Turn(to) end
            joint:SetTargetValue(to)
        end
    end
    if There(s.crane, s.model, s.goal, s.pass) then Steer = nil end
end

-- The cell a piece stands on in its area and how many cells it covers each way.
local function Footing(area, cargo)
    local item = cargo:GetRepresentedInventoryItem():GetAddress()
    local low, high = { X = math.huge, Y = math.huge, Z = math.huge }, { X = -math.huge, Y = -math.huge, Z = -math.huge }
    local count = 0
    area:GetInventory().CellsOccupancyMap:ForEach(function(key, value)
        local held = value:get()
        if Valid(held) and held:GetAddress() == item then
            count = count + 1
            local cell = key:get()
            for _, axis in ipairs({ "X", "Y", "Z" }) do
                low[axis], high[axis] = math.min(low[axis], cell[axis]), math.max(high[axis], cell[axis])
            end
        end
    end)
    if low.X == math.huge then return nil end
    local yaw = 0
    Each(area:GetInventory().GridInventoryItems.Entries, function(placed)
        if Valid(placed.InventoryItem) and placed.InventoryItem:GetAddress() == item then yaw = placed.GridTransform.Rotation.Yaw end
    end)
    return { Z = low.Z, across = high.X - low.X + 1, along = high.Y - low.Y + 1, yaw = yaw,
             height = high.Z - low.Z + 1, count = count }
end

-- How many degrees the piece can be turned and look the same: a solid block looks the same turned half
-- round (180), and a square one turned a quarter round too (90). Anything of another shape is turned to
-- face exactly (360), except that it is treated as a block when it is nearly one (180) so that it is not
-- turned further than it has to be.
function SymmetryOf(footing)
    local volume = footing.across * footing.along * footing.height
    if footing.count == volume and footing.across == footing.along then return 90 end
    return 180
end

-- Where the hook has to be to take the piece where it stands, and to set it down in its new place.
local function JobPoints(move)
    local cargo = move.cargo
    local from = cargo.CargoArea
    local footing = Footing(from, cargo)
    if not footing then return nil end
    local hookAt = cargo:K2_GetActorLocation()
    local top = hookAt.Z + 120
    pcall(function()
        local hook = cargo.CargoHook:K2_GetComponentLocation()
        hookAt, top = { X = hook.X, Y = hook.Y, Z = hook.Z }, hook.Z
    end)
    local fromAt = GridFrame(from)
    local hookUp = top - (fromAt.Z + footing.Z * CELL_CM)   -- the hook's height above the piece's foot

    local toAt, across, along = GridFrame(move.to)
    local wide, long = footing.across, footing.along
    if math.abs(Turn(move.place.rotation.Yaw - footing.yaw)) > 45 and math.abs(Turn(move.place.rotation.Yaw - footing.yaw)) < 135 then
        wide, long = long, wide  -- set down turned a quarter
    end
    local gx, gy = (move.place.position.X + wide / 2) * CELL_CM, (move.place.position.Y + long / 2) * CELL_CM
    local pick = { X = hookAt.X, Y = hookAt.Y, Z = top + 15 }  -- just above it, not pressing on it
    local drop = { X = toAt.X + across.X * gx + along.X * gy, Y = toAt.Y + across.Y * gx + along.Y * gy,
                   Z = toAt.Z + move.place.position.Z * CELL_CM + hookUp }
    return pick, drop, hookUp
end

-- How high the arm's end travels: high enough for the hook to clear both places by a metre, and for
-- a crane that says so, no lower than its travelling height.
local function TravelTip(model, pick, drop, crane)
    local tip = math.max(pick.Z, drop.Z) + 100 + model.hookBelow + DRUM_MIN
    if model.travelUp and crane then tip = math.max(tip, crane:K2_GetActorLocation().Z + model.travelUp) end
    return tip
end

-- The crane to do a move. A dock crane is the only one there is; of a boat's own cranes, the one that
-- can reach both places, preferring the one the operator is already sitting in and then the nearer.
-- The second answer is false when no crane can be steered there and the piece is moved the plain way.
function CraneName(crane)  -- the crane's object name, which tells a ship's cranes apart in the log
    local ok, name = pcall(function() return crane:GetFName():ToString() end)
    return ok and name or "a crane"
end
local function ChooseCrane(site, move, character)
    if not site.deck then return site.crane, ModelOf(site.crane) ~= nil end
    local ok, pick, drop = pcall(JobPoints, move)
    local best, bestScore, nearest, nearestDist = nil, math.huge, nil, math.huge
    local notes = {}
    for _, crane in ipairs(site.cranes) do
        local driver = CraneDriver(crane)
        if (not driver or Same(driver, character)) and crane:IsPowered() then
            local model = ModelOf(crane)
            local at = crane:K2_GetActorLocation()
            if ok and pick then
                local d = Dist(at, pick) + Dist(at, drop)
                if d < nearestDist then nearest, nearestDist = crane, d end
                if model then
                    local tip = TravelTip(model, pick, drop, crane)
                    if model.Arm(crane, pick, tip) and model.Arm(crane, drop, tip) then
                        local score = d - ((AtCrane and Same(AtCrane.crane, crane)) and 500 or 0)
                        if score < bestScore then best, bestScore = crane, score end
                        notes[#notes + 1] = string.format("%s reaches it (%.0f m to go, score %.0f)", CraneName(crane), d / 100, score / 100)
                    else
                        notes[#notes + 1] = CraneName(crane) .. " cannot reach both places"
                    end
                end
            elseif not nearest then
                nearest = crane
            end
        end
    end
    if best then
        if AtCrane and not Same(AtCrane.crane, best) then
            Log("choosing " .. CraneName(best) .. " for the " .. ClassName(move.cargo) .. ": " .. table.concat(notes, "; "))
        end
        return best, true
    end
    if not ok or not pick then
        Log("no crane can be steered for this move: its places could not be worked out (" .. tostring(pick):gsub("\n.*", "") .. ")")
    else
        Log(string.format("no crane can reach both places for this move: pick-up %.0f %.0f %.0f, set-down %.0f %.0f %.0f",
            pick.X, pick.Y, pick.Z, drop.X, drop.Y, drop.Z))
    end
    return nearest, false
end

-- Can a crane of the site really take this piece from where it is to where it is going? A deck
-- crane is asked its arm model. The dock crane's boom is as long as it is: the piece and its place
-- must both be within it.
function MoveWithinReach(site, move)
    if site.deck then return CanReach(site, move) end
    local model = ModelOf(site.crane)
    if not model or not model.maxOut then return true end
    local ok, pick, drop = pcall(JobPoints, move)
    if not ok or not pick or not drop then return false end
    local base = site.crane:K2_GetActorLocation()
    return Dist(pick, base) <= model.maxOut and Dist(drop, base) <= model.maxOut
end

CanReach = function(site, move)
    local ok, pick, drop = pcall(JobPoints, move)
    if not ok or not pick then return false end
    for _, crane in ipairs(site.cranes) do
        local model = ModelOf(crane)
        if model then
            local tip = TravelTip(model, pick, drop, crane)
            if model.Arm(crane, pick, tip) and model.Arm(crane, drop, tip) then return true end
        end
    end
    return false
end

-- Where the hook takes a piece where it stands now.
local function PickPoint(cargo)
    local ok, at = pcall(function() return cargo.CargoHook:K2_GetComponentLocation() end)
    if not ok or not at then at = cargo:K2_GetActorLocation() end
    return { X = at.X, Y = at.Y, Z = at.Z + 15 }
end

-- Can this crane be steered to both points with a load?
local function Reaches(crane, a, b)
    local model = ModelOf(crane)
    if not model then return false end
    local tip = TravelTip(model, a, b, crane)
    return model.Arm(crane, a, tip) ~= nil and model.Arm(crane, b, tip) ~= nil
end

-- The free spots in an area that take the piece the way it stands now, each with its place in the
-- grid, its middle in the world, and how neat it is:
--   * on the floor, the share of the spot's edge that is up against another piece or the area's side,
--     so that pieces go in rows and blocks, not scattered with gaps between;
--   * on top of a piece of exactly the same size, squarely, which is neater still.
NEAT_STACK = 1.1

local function FreeSpots(area, cargo)
    local mine = Boxes(cargo.CargoArea)[cargo:GetRepresentedInventoryItem():GetAddress()]
    if not mine or not mine.anchor then return {} end
    local size = { X = mine.size.X, Y = mine.size.Y, Z = mine.size.Z }
    local boxes, limit = Boxes(area)
    local grid = {}
    for _, box in pairs(boxes) do
        if box.id ~= mine.id then Fill(grid, box, box.id) end
    end
    local at, across, along = GridFrame(area)
    local function centreOf(x, y)
        local cx, cy = (x + size.X / 2) * CELL_SIZE_CM, (y + size.Y / 2) * CELL_SIZE_CM
        return { X = at.X + across.X * cx + along.X * cy, Y = at.Y + across.Y * cx + along.Y * cy }
    end
    local function blocked(x, y)
        return x < 0 or y < 0 or x >= limit.X or y >= limit.Y or grid[CellName(x, y, 0)] ~= nil
    end
    -- Which floor columns are taken up to the piece's height, and a running count of them, so that
    -- whether a spot is free is a few sums instead of a look at every cell it covers.
    local taken, sum = {}, {}
    for x = 0, limit.X - 1 do
        taken[x] = {}
        for y = 0, limit.Y - 1 do
            local full = false
            for z = 0, math.min(size.Z, limit.Z) - 1 do
                if grid[CellName(x, y, z)] then
                    full = true
                    break
                end
            end
            taken[x][y] = full and 1 or 0
        end
    end
    for x = -1, limit.X - 1 do sum[x] = { [-1] = 0 } end
    for y = -1, limit.Y - 1 do sum[-1][y] = 0 end
    for x = 0, limit.X - 1 do
        for y = 0, limit.Y - 1 do
            sum[x][y] = taken[x][y] + sum[x - 1][y] + sum[x][y - 1] - sum[x - 1][y - 1]
        end
    end
    local function takenIn(x0, y0, x1, y1)
        return sum[x1][y1] - sum[x0 - 1][y1] - sum[x1][y0 - 1] + sum[x0 - 1][y0 - 1]
    end
    local spots = {}
    for y = 0, limit.Y - size.Y do
        for x = 0, limit.X - size.X do
            if takenIn(x, y, x + size.X - 1, y + size.Y - 1) == 0 then
                local touching, edge = 0, 2 * (size.X + size.Y)
                for i = 0, size.X - 1 do
                    if blocked(x + i, y - 1) then touching = touching + 1 end
                    if blocked(x + i, y + size.Y) then touching = touching + 1 end
                end
                for j = 0, size.Y - 1 do
                    if blocked(x - 1, y + j) then touching = touching + 1 end
                    if blocked(x + size.X, y + j) then touching = touching + 1 end
                end
                spots[#spots + 1] = {
                    place = { position = { X = x + mine.anchor.X, Y = y + mine.anchor.Y, Z = mine.anchor.Z }, rotation = mine.rotation },
                    centre = centreOf(x, y),
                    neat = touching / edge,
                }
            end
        end
    end
    -- Squarely on top of a piece the same size with nothing on it yet, if the area is tall enough.
    for _, box in pairs(boxes) do
        if box.id ~= mine.id and box.size.X == size.X and box.size.Y == size.Y and box.high.Z + size.Z < limit.Z then
            local z, clear = box.high.Z + 1, true
            for i = box.low.X, box.high.X do
                for j = box.low.Y, box.high.Y do
                    for k = z, z + size.Z - 1 do
                        if grid[CellName(i, j, k)] then clear = false end
                    end
                end
            end
            if clear then
                spots[#spots + 1] = {
                    place = { position = { X = box.low.X + mine.anchor.X, Y = box.low.Y + mine.anchor.Y, Z = z + mine.anchor.Z },
                              rotation = mine.rotation },
                    centre = centreOf(box.low.X, box.low.Y),
                    neat = NEAT_STACK,
                }
            end
        end
    end
    return spots
end

-- The neatest spots within a crane's reach of it, furthest first among the equally neat: an area is
-- filled from the far side in, so nothing already set down is in the way of what comes after.
NEAT_REACH_CM = 1150

-- On the dock the "furthest" is from the boat, not from the crane: with the crane beside the hold the
-- point furthest from it can be right against the boat, and filling that first walls the boat in. `far`
-- gives a spot's distance from the boat; without it the distance from the crane is used.
local function Neatest(spots, at, count, far, reach)
    local ranked = {}
    for _, spot in ipairs(spots) do
        local d = Dist(spot.centre, at)
        if d <= (reach or NEAT_REACH_CM) then ranked[#ranked + 1] = { spot = spot, d = far and far(spot.centre) or d } end
    end
    table.sort(ranked, function(a, b)
        local na, nb = math.floor(a.spot.neat * 20), math.floor(b.spot.neat * 20)  -- neatness in steps of 5 %
        if na ~= nb then return na > nb end
        return a.d > b.d
    end)
    local out = {}
    for index = 1, math.min(#ranked, count) do out[index] = ranked[index].spot end
    return out
end

local function Nearest(spots, at, count)
    local ranked = {}
    for _, spot in ipairs(spots) do ranked[#ranked + 1] = { spot = spot, d = Dist(spot.centre, at) } end
    table.sort(ranked, function(a, b) return a.d < b.d end)
    local out = {}
    for index = 1, math.min(#ranked, count) do out[index] = ranked[index].spot end
    return out
end

-- How far a point on the dock is from the boat: from the edge of its hold, as the hold is laid out in the
-- world (0 over the hold).
function BoatFar(site)
    local at, across, along = GridFrame(site.hold)
    local size = site.hold:GetInventory().GridSize
    local width, depth = size.X * CELL_SIZE_CM, size.Y * CELL_SIZE_CM
    return function(point)
        local dx, dy = point.X - at.X, point.Y - at.Y
        local u, v = dx * across.X + dy * across.Y, dx * along.X + dy * along.Y
        local over_u, over_v = math.max(0, -u, u - width), math.max(0, -v, v - depth)
        return math.sqrt(over_u * over_u + over_v * over_v)
    end
end

-- Why a piece to unload found no dock place: it lies further from the dock crane than its boom runs out
-- (then no dock area helps), or the dock areas have no spot the boom reaches. Written to the log as REACH:
-- lines with the numbers, and returns "piece" or "dock".
function ExplainUnreachable(site, cargo, docks)
    local model = ModelOf(site.crane)
    local base = site.crane:K2_GetActorLocation()
    local maxOut = model and model.maxOut or -1
    local here = cargo:K2_GetActorLocation()
    local pieceAway = Dist(here, base)
    Log(string.format("REACH: the %s lies %.0f cm from the crane (its boom runs out to %.0f cm)", ClassName(cargo), pieceAway, maxOut))
    for _, dock in ipairs(docks) do
        local spots = FreeSpots(dock.area, cargo)
        local inReach = 0
        for _, spot in ipairs(spots) do
            if maxOut < 0 or Dist(spot.centre, base) <= maxOut then inReach = inReach + 1 end
        end
        Log(string.format("REACH: %s %.0f cm from the crane: %d free spot(s), %d within the boom's reach",
            ClassName(dock.area), Dist(dock.area:K2_GetActorLocation(), base), #spots, inReach))
    end
    if #docks == 0 then Log("REACH: there is no dock area within reach of the crane at all") end
    if maxOut >= 0 and pieceAway > maxOut then return "piece" end
    return "dock"
end

-- The cranes that can reach the piece where it stands, nearest first.
local function Pickers(site, cargo)
    local pick = PickPoint(cargo)
    local found = {}
    for _, crane in ipairs(site.cranes) do
        if Reaches(crane, pick, pick) then found[#found + 1] = crane end
    end
    table.sort(found, function(a, b) return Dist(a:K2_GetActorLocation(), pick) < Dist(b:K2_GetActorLocation(), pick) end)
    return found
end

-- A hand-over to a given place: crane B reaches the place, and a spot in the hold is found that crane
-- A carries the piece to from where it stands and that B reaches as well.
local function HandOverTo(site, cargo, area, place, holdSpots)
    local pickers = Pickers(site, cargo)
    if #pickers == 0 then return nil end
    local pick = PickPoint(cargo)
    local _, target = JobPoints({ cargo = cargo, to = area, place = place })
    if not target then return nil end
    for _, other in ipairs(site.cranes) do
        if Reaches(other, target, target) then
            for _, spot in ipairs(Nearest(holdSpots, other:K2_GetActorLocation(), PLACES_TRIED * 2)) do
                if FitsAt(site.hold, cargo, spot.place) then
                    local move = { cargo = cargo, to = site.hold, place = spot.place, settle = true }
                    local _, across = JobPoints(move)
                    if across and Reaches(other, across, target) then
                        for _, crane in ipairs(pickers) do
                            if not Same(crane, other) and Reaches(crane, pick, across) then return move end
                        end
                    end
                end
            end
        end
    end
    return nil
end

NeedsStaging = function(site, cargo)
    local at = site.crane:K2_GetActorLocation()
    if Dist(cargo:K2_GetActorLocation(), at) > CARGO_REACH_CM then return true end
    if not site.deck then
        -- A dock crane's boom only runs out so far: a piece standing further than that, say in the
        -- dock area on the far side, is brought to the nearer area first, not pulled to the hook.
        local model = ModelOf(site.crane)
        if model and model.maxOut and Dist(PickPoint(cargo), at) > model.maxOut then return true end
        return false
    end
    return #Pickers(site, cargo) == 0
end

StagingPlace = function(site, area, cargo)
    if not site.deck then
        local model = ModelOf(site.crane)
        if model and model.maxOut then
            -- The neatest place in the area that the boom reaches, nearest the crane first.
            local base = site.crane:K2_GetActorLocation()
            local far = not Same(area, site.hold) and BoatFar(site) or nil
            for _, spot in ipairs(Neatest(FreeSpots(area, cargo), base, PLACES_TRIED, far, model.maxOut)) do
                if FitsAt(area, cargo, spot.place) then
                    local _, at = JobPoints({ cargo = cargo, to = area, place = spot.place })
                    if at and Dist(at, base) <= model.maxOut then return spot.place end
                end
            end
            Log("no place in the " .. ClassName(area) .. " is within reach of the crane for the " .. ClassName(cargo))
        end
        return FindPlace(area, cargo)
    end
    local spots = FreeSpots(area, cargo)
    local far = not Same(area, site.hold) and BoatFar(site) or nil
    for _, crane in ipairs(site.cranes) do
        for _, spot in ipairs(Neatest(spots, crane:K2_GetActorLocation(), PLACES_TRIED, far)) do
            if FitsAt(area, cargo, spot.place) then
                local _, at = JobPoints({ cargo = cargo, to = area, place = spot.place })
                if at and Reaches(crane, at, at) then return spot.place end
            end
        end
    end
    return nil
end

PlaceInReach = function(site, area, cargo)
    if not site.deck then
        if Same(area, site.hold) then return FindPlace(area, cargo) end
        -- Setting down on the dock: the neatest place the boom reaches, furthest from the boat first.
        local model = ModelOf(site.crane)
        local ok, found = pcall(function()
            for _, spot in ipairs(Neatest(FreeSpots(area, cargo), site.crane:K2_GetActorLocation(), PLACES_TRIED, BoatFar(site),
                                          model and model.maxOut or nil)) do
                if FitsAt(area, cargo, spot.place) and MoveWithinReach(site, { cargo = cargo, to = area, place = spot.place }) then
                    return spot.place
                end
            end
            return nil
        end)
        if not ok then Log("choosing a place on the dock failed: " .. tostring(found):gsub("\n.*", "")) end
        return ok and found or FindPlace(area, cargo)
    end
    local fallback = FindPlace(area, cargo)
    local handOver = nil
    local ok, found = pcall(function()
        local spots = FreeSpots(area, cargo)
        local refused, outOfReach = 0, 0
        -- The neatest places near either crane first. One that the crane holding the piece cannot
        -- reach, but the other can, is reached by handing the piece over through the hold.
        local cranes = {}
        for _, crane in ipairs(site.cranes) do cranes[#cranes + 1] = crane:K2_GetActorLocation() end
        local far = not Same(area, site.hold) and BoatFar(site) or nil
        local best = {}
        for _, crane in ipairs(cranes) do
            for _, spot in ipairs(Neatest(spots, crane, 8, far)) do best[#best + 1] = spot end
        end
        table.sort(best, function(a, b) return math.floor(a.neat * 20) > math.floor(b.neat * 20) end)
        local guid = CargoGuid(cargo) or "?"
        local holdSpots = nil
        for _, spot in ipairs(best) do
            if FitsAt(area, cargo, spot.place) then
                if CanReach(site, { cargo = cargo, to = area, place = spot.place }) then return spot.place end
                if not Relayed[guid] and not Same(area, site.hold) then  -- loads are not passed across the hold
                    holdSpots = holdSpots or FreeSpots(site.hold, cargo)
                    local move = HandOverTo(site, cargo, area, spot.place, holdSpots)
                    if move then
                        Relayed[guid] = true
                        move.handOver = true
                        Log("handing the " .. ClassName(cargo) .. " over: its place is one only the other crane reaches")
                        handOver = move
                        return nil
                    end
                end
            end
        end
        -- The neatest spots near a crane that can reach the piece, so that the same crane can carry it
        -- there; then simply the nearest, in case none of the neat ones can be reached.
        for _, crane in ipairs(Pickers(site, cargo)) do
            local tries = Neatest(spots, crane:K2_GetActorLocation(), PLACES_TRIED, far)
            for _, spot in ipairs(Nearest(spots, crane:K2_GetActorLocation(), PLACES_TRIED)) do tries[#tries + 1] = spot end
            for _, spot in ipairs(tries) do
                if not FitsAt(area, cargo, spot.place) then
                    refused = refused + 1
                elseif not CanReach(site, { cargo = cargo, to = area, place = spot.place }) then
                    outOfReach = outOfReach + 1
                else
                    return spot.place
                end
            end
        end
        Log(string.format("no place in reach in %s: %d free spot(s) on the floor, the game refused %d and %d were out of reach",
            ClassName(area), #spots, refused, outOfReach))
        return nil
    end)
    if handOver then return nil, handOver end
    if ok and found then return found end
    if not ok then Log("looking for a place in reach failed: " .. tostring(found):gsub("\n.*", "")) end
    return fallback
end

-- A hand-over: crane A, which reaches the piece, carries it across the hold to a spot crane B also
-- reaches, from where B can take it on to a dock place only B reaches. The next round then finds the
-- straight move from there.
Relay = function(site, cargo, docks)
    local pickers = Pickers(site, cargo)
    if #pickers == 0 then return nil end
    local pick = PickPoint(cargo)
    for _, other in ipairs(site.cranes) do
        -- A dock place the other crane can reach.
        local target = nil
        for _, dock in ipairs(docks) do
            if not target then
                for _, spot in ipairs(Nearest(FreeSpots(dock.area, cargo), other:K2_GetActorLocation(), PLACES_TRIED)) do
                    if not target and FitsAt(dock.area, cargo, spot.place) then
                        local _, dropAt = JobPoints({ cargo = cargo, to = dock.area, place = spot.place })
                        if dropAt and Reaches(other, dropAt, dropAt) then target = dropAt end
                    end
                end
            end
        end
        if target then
            -- A spot in the hold that a picker reaches with the piece and the other crane reaches too.
            for _, spot in ipairs(Nearest(FreeSpots(site.hold, cargo), other:K2_GetActorLocation(), PLACES_TRIED * 2)) do
                if FitsAt(site.hold, cargo, spot.place) then
                    local move = { cargo = cargo, to = site.hold, place = spot.place, settle = true }
                    local _, across = JobPoints(move)
                    if across and Reaches(other, across, target) then
                        for _, crane in ipairs(pickers) do
                            if not Same(crane, other) and Reaches(crane, pick, across) then
                                Log("handing the " .. ClassName(cargo) .. " over: one crane brings it across the hold for the other to unload")
                                return move
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- What stands under the load's way. The load goes up where it is, in along its bearing to the drawn-in
-- reach, round at that reach, and out to its new place; along that way, and to either side of it by
-- the load's half-width, a trace straight down finds the top of whatever is there (cargo, the boat's
-- superstructure, the other crane, the dock's buildings). The crane and the load itself are ignored.
TRACE_STEP_CM = 50
DRAWN_IN_CM = 450      -- about how far out the hook hangs with the deck crane's boom drawn in
local Kismet = nil

local function TopAt(crane, cargo, x, y, fromZ)
    if not Valid(Kismet) then Kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
    local colour = { R = 0, G = 0, B = 0, A = 0 }
    local hit = {}
    local found = Kismet:LineTraceSingle(crane, { X = x, Y = y, Z = fromZ }, { X = x, Y = y, Z = fromZ - 3000 }, 0, false,
        { crane, cargo }, 0, hit, true, colour, colour, 0.0)
    if not found then return nil end
    hit = hit.OutHit or hit
    local at = hit.ImpactPoint or hit.Location
    return at and at.Z or nil
end

-- The highest point under the load's way from one place to the other, or nil if nothing was found.
local function HighestOnTheWay(crane, cargo, from, to, halfWidth)
    local base = crane:K2_GetActorLocation()
    local function polar(point)
        local dx, dy = point.X - base.X, point.Y - base.Y
        return math.sqrt(dx * dx + dy * dy), math.atan(dy, dx)
    end
    local r1, a1 = polar(from)
    local r2, a2 = polar(to)
    local inner = math.min(DRAWN_IN_CM, r1, r2)
    local points = {}
    local function line(ra, rb, angle)
        local steps = math.max(1, math.ceil(math.abs(rb - ra) / TRACE_STEP_CM))
        for i = 0, steps do
            local r = ra + (rb - ra) * i / steps
            points[#points + 1] = { r = r, a = angle }
        end
    end
    line(r1, inner, a1)
    local turn = Turn(math.deg(a2 - a1))
    local steps = math.max(1, math.ceil(math.abs(math.rad(turn)) * inner / TRACE_STEP_CM))
    for i = 0, steps do points[#points + 1] = { r = inner, a = a1 + math.rad(turn) * i / steps } end
    line(inner, r2, a2)

    local fromZ = base.Z + 2500
    local highest = nil
    for _, point in ipairs(points) do
        local cx, cy = base.X + point.r * math.cos(point.a), base.Y + point.r * math.sin(point.a)
        local sx, sy = -math.sin(point.a) * halfWidth, math.cos(point.a) * halfWidth  -- across the way
        local fx, fy = math.cos(point.a) * halfWidth, math.sin(point.a) * halfWidth   -- along the way
        for _, offset in ipairs({ { 0, 0 }, { sx, sy }, { -sx, -sy }, { fx, fy }, { -fx, -fy } }) do
            local ok, z = pcall(TopAt, crane, cargo, cx + offset[1], cy + offset[2], fromZ)
            if ok and z and (not highest or z > highest) then highest = z end
        end
    end
    -- What the arm itself sweeps over while it swings drawn in: the ground between the crane and the
    -- drawn-in reach, all the way round the swing.
    local armHighest = nil
    for _, radius in ipairs({ 150, 250, 350 }) do
        if radius < inner then
            local arcSteps = math.max(1, math.ceil(math.abs(math.rad(turn)) * radius / TRACE_STEP_CM))
            for i = 0, arcSteps do
                local a = a1 + math.rad(turn) * i / arcSteps
                local ok, z = pcall(TopAt, crane, cargo, base.X + radius * math.cos(a), base.Y + radius * math.sin(a), fromZ)
                if ok and z and z < base.Z + 1500 and (not armHighest or z > armHighest) then armHighest = z end
            end
        end
    end
    return highest, #points, armHighest
end

-- Starts the crane on a move. A crane this mod cannot steer, or a move it cannot work out, is done the
-- plain way: the piece is lifted where it stands and set down a few seconds later.
local function StartJob(move)
    local crane, cargo = move.crane, move.cargo
    local job = { crane = crane, cargo = cargo, to = move.to, place = move.place, settle = move.settle,
                  guid = CargoGuid(cargo), phase = move.stage and "stage" or "plain", ticks = 0, model = ModelOf(crane),
                  fromArea = cargo.CargoArea }
    if job.model and move.steer and not move.stage then
        local ok, pick, drop = pcall(JobPoints, move)
        if ok and pick then
            job.pick, job.drop = pick, drop
            job.tip = TravelTip(job.model, pick, drop, crane)
            -- High enough that the load, hanging below the hook, passes over everything under its way
            -- with a metre to spare.
            pcall(function()
                local _, _, hang = JobPoints(move)
                local half = 150
                pcall(function()
                    local centre, extent = {}, {}
                    cargo:GetActorBounds(true, centre, extent, false)
                    extent = extent.BoxExtent or extent
                    half = math.sqrt(extent.X * extent.X + extent.Y * extent.Y)
                end)
                local highest, sampled, armHighest = HighestOnTheWay(crane, cargo, pick, drop, half)
                if armHighest and armHighest + 150 > job.tip then  -- the arm's end clears what it sweeps over
                    Log(string.format("raising the arm %.1f m to swing clear of what is beside the crane", (armHighest + 150 - job.tip) / 100))
                    job.tip = armHighest + 150
                end
                if highest then
                    local need = highest + hang + 100 + job.model.hookBelow + DRUM_MIN
                    if need > job.tip then
                        Log(string.format("carrying the %s %.1f m higher to clear what is under its way (%d points looked at)",
                            ClassName(cargo), (need - job.tip) / 100, sampled))
                        job.tip = need
                    end
                end
            end)
            -- And over the cargo around the
            -- place it is going to and the place it comes from, with a metre to spare.
            pcall(function()
                local _, _, hang = JobPoints(move)
                local tallest = -math.huge
                for _, other in ipairs(Live("HeavyCargo")) do
                    if not Same(other, cargo) then
                        local at = other:K2_GetActorLocation()
                        if Dist(at, drop) < 900 or Dist(at, pick) < 900 then
                            local centre, extent = {}, {}
                            other:GetActorBounds(true, centre, extent, false)
                            centre, extent = centre.Origin or centre, extent.BoxExtent or extent
                            tallest = math.max(tallest, centre.Z + extent.Z)
                        end
                    end
                end
                if tallest > -math.huge then
                    job.tip = math.max(job.tip, tallest + hang + 100 + job.model.hookBelow + DRUM_MIN)
                end
            end)
            -- Clearance asked for may be more than the arm can give at both ends. Then the highest the
            -- arm reaches at both is used, down to the plain carrying height.
            -- Up to 80 cm of the metre to spare may be given up; lower than that the load would drag
            -- over what is under it, so the piece is left alone instead.
            local wanted = job.tip
            local floor = math.max(TravelTip(job.model, pick, drop, crane), wanted - 80)
            local tip = wanted
            while tip > floor and not (job.model.Arm(crane, pick, tip) and job.model.Arm(crane, drop, tip)) do
                tip = math.max(floor, tip - 20)
            end
            local fits = job.model.Arm(crane, pick, tip) and job.model.Arm(crane, drop, tip)
            if not fits then
                Log(string.format("the arm cannot carry the %s high enough to clear what is under its way (wanted %.0f); leaving it",
                    ClassName(cargo), wanted))
                if job.guid then Unreachable[job.guid] = true end
                local name = "piece"
                pcall(function() name = cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
                Toast("The " .. name .. " cannot be lifted clear of the cargo around it")
                Job = nil
                return
            end
            if tip < wanted then
                Log(string.format("the arm cannot carry the %s quite as high as wanted; carrying it %.1f m lower, still clear",
                    ClassName(cargo), (wanted - tip) / 100))
                job.tip = tip
            end
            job.phase = "clear"
        end
        -- How the piece faces now against how its place in its area faces, and so how it must face in
        -- the world once set down in its new place.
        pcall(function()
            local from = cargo.CargoArea
            local footing = Footing(from, cargo)
            local fromYaw = from.OriginComponent:K2_GetComponentRotation().Yaw + footing.yaw
            local toYaw = move.to.OriginComponent:K2_GetComponentRotation().Yaw + move.place.rotation.Yaw
            job.finalYaw = Turn(cargo:K2_GetActorRotation().Yaw - fromYaw + toYaw)
            job.symmetry = SymmetryOf(footing)
            job.footing = string.format("%dx%dx%d, %d cells", footing.across, footing.along, footing.height, footing.count)
        end)
    end
    Job = job
end

local function Goto(job, goal, pass)
    Steer = { crane = job.crane, model = job.model, goal = goal, pass = pass }
    job.ticks = 0
end

local function WithDrum(pose, drum)
    local goal = { drum = drum }
    for part, value in pairs(pose) do goal[part] = value end
    return goal
end

-- Where the hook hangs now.
local function HookNow(crane)
    local ok, at = pcall(function() return crane.HookJoint:K2_GetComponentLocation() end)
    if ok and at then return at end
    return crane:K2_GetActorLocation()
end

-- The steps that take a crane to a pose. A crane with a travelling height that has to swing far first
-- lifts its arm to that height where it is, then swings at that height straight to the new pose.
local WAYPOINT_CM = 120  -- the arm is drawn in and run out in steps this long, each at the carrying height

local function SwingRoute(crane, model, target, tipZ, point)
    if not model.travelUp or target.swivel == nil then return { target } end
    local base = crane:K2_GetActorLocation()
    local hook = HookNow(crane)
    local function polar(at)
        local dx, dy = at.X - base.X, at.Y - base.Y
        return math.sqrt(dx * dx + dy * dy), math.atan(dy, dx)
    end
    local r1, a1 = polar(hook)
    local r2, a2 = r1, a1
    if point then r2, a2 = polar(point) end
    local now = crane[model.joints.swivel]:GetCurrentValue()
    local steps = {}
    local function at(r, a)
        local arm = model.Arm(crane, { X = base.X + r * math.cos(a), Y = base.Y + r * math.sin(a), Z = 0 }, tipZ)
        if arm then steps[#steps + 1] = WithDrum(arm.pose, DRUM_MIN) end
    end
    -- Up where it is, at the carrying height.
    at(r1, a1)
    if math.abs(target.swivel - now) >= 10 then
        -- Drawn in along its bearing, a step at a time so the load keeps its height all the way.
        local inner = math.min(DRAWN_IN_CM, r1, r2)
        local count = math.max(1, math.ceil((r1 - inner) / WAYPOINT_CM))
        for i = 1, count do at(r1 + (inner - r1) * i / count, a1) end
        -- Round at that reach, then out along the new bearing the same way.
        local turnSteps = math.max(1, math.ceil(math.abs(Turn(math.deg(a2 - a1))) / 45))
        for i = 1, turnSteps do at(inner, a1 + math.rad(Turn(math.deg(a2 - a1))) * i / turnSteps) end
        count = math.max(1, math.ceil((r2 - inner) / WAYPOINT_CM))
        for i = 1, count - 1 do at(inner + (r2 - inner) * i / count, a2) end
    elseif point then
        local count = math.max(1, math.ceil(math.abs(r2 - r1) / WAYPOINT_CM))
        for i = 1, count - 1 do at(r1 + (r2 - r1) * i / count, a1 + math.rad(Turn(math.deg(a2 - a1))) * i / count) end
    end
    steps[#steps + 1] = target
    return steps
end

local function GoRoute(job, goals)
    job.route = goals
    Goto(job, table.remove(job.route, 1), #job.route > 0)
end

-- While a load is on the hook its collision box is drawn in a little on every side, so that it does
-- not catch on the pieces it is lowered between or lifted from among; it is given back its size once
-- it is set down. Every box drawn in is remembered, so none is left small if a job ends some other way.
SLIM_CM = 10
local Slimmed = {}  -- cargo address -> { cargo, box, extent }

local function Slim(cargo)
    local key = cargo:GetAddress()
    if Slimmed[key] then return end
    local box = cargo.SolidCollision
    local extent = box:GetUnscaledBoxExtent()
    local full = { X = extent.X, Y = extent.Y, Z = extent.Z }
    box:SetBoxExtent({ X = math.max(5, full.X - SLIM_CM), Y = math.max(5, full.Y - SLIM_CM), Z = math.max(5, full.Z - SLIM_CM / 2) }, false)
    Slimmed[key] = { cargo = cargo, box = box, extent = full }
end

-- Lifting a load out from among others, and lowering it in between them, is done with the load not
-- colliding at all: drawing its box in was not enough, so something else on it catches too. Its
-- collision is given back once it is clear of them, or set down.
local Passing = {}  -- cargo address -> cargo, for loads with their collision off

local function PassThrough(cargo, on)
    local key = cargo:GetAddress()
    if on then
        if Passing[key] then return end
        cargo:SetActorEnableCollision(false)
        Passing[key] = cargo
    elseif Passing[key] then
        pcall(function() cargo:SetActorEnableCollision(true) end)
        Passing[key] = nil
    end
end

local function Unslim(except)
    for key, slim in pairs(Slimmed) do
        if not except or not Same(slim.cargo, except) then
            pcall(function() if Valid(slim.box) then slim.box:SetBoxExtent(slim.extent, true) end end)
            Slimmed[key] = nil
        end
    end
    for key, cargo in pairs(Passing) do
        if not except or not Same(cargo, except) then
            pcall(function() if Valid(cargo) then cargo:SetActorEnableCollision(true) end end)
            Passing[key] = nil
        end
    end
end

-- Drop telemetry. ServerDetachCargo is given the place in the area the piece is to take, and the game
-- puts the piece there, so a piece released a little off it jumps the last bit. DROP: lines record
-- where the piece was when let go, where it was sent, and (DROP+: a second later) where it ended up.
DropWatch = {}  -- { cargo, label, at, released, target }

local function Where(p)
    return p and string.format("%.0f %.0f %.0f", p.X, p.Y, p.Z) or "?"
end

function DropNote(label, crane, cargo, area, place)
    local ok, err = pcall(function()
        local at = cargo:K2_GetActorLocation()
        local hook = HookNow(crane)
        local want = place and place.position
        local d3 = want and math.sqrt((at.X - want.X) ^ 2 + (at.Y - want.Y) ^ 2 + (at.Z - want.Z) ^ 2) or -1
        local roll, pitch = 0, 0
        pcall(function() roll, pitch = BoatTilt(area:GetAttachParentActor()) end)
        Log(string.format("DROP: %s the %s into the %s | piece at %s | hook at %s | sent to %s | %.0f cm from it | rotation %s | boat roll %.0f pitch %.0f",
            label, ClassName(cargo), ClassName(area), Where(at), Where(hook), Where(want), d3,
            place and place.rotation and string.format("%.0f", place.rotation.Yaw or 0) or "?", roll, pitch))
        DropWatch[#DropWatch + 1] = { cargo = cargo, label = label, at = os.clock(), released = at, target = want }
    end)
    if not ok then Log("DROP: could not be recorded: " .. tostring(err):gsub("\n.*", "")) end
end

-- A dock's bollard (mooring point) that has been carried off by a piece of cargo. One was found 3 m above
-- its pier, 21 cm from the box hanging on the crane, and a boat tied to it pulled itself over when the box
-- was put aboard. The points of a pier are numbered along it and spaced evenly, so one that has strayed
-- from the middle of its two neighbours and lies against a piece of cargo is put back between them.
MOORING_STRAY_CM = 150       -- further than this from the middle of its neighbours counts as strayed
MOORING_CARGO_CM = 450       -- and it must lie this close to a piece of cargo (one hung 2 m from a box's middle)
MOORING_PAIR_MAX_CM = 800    -- the neighbours must be this close to each other to be a pier's row

-- A location read from the game is a view of memory that later reads reuse: copy the numbers out.
function Copy3(v)
    return { X = v.X, Y = v.Y, Z = v.Z }
end

function RepairMooring()
    local points = {}
    for _, point in ipairs(Live("MooringPoint")) do
        pcall(function()
            local name = point:GetFName():ToString()
            local stem, number = name:match("^(.-)_(%d+)$")
            if stem then points[stem .. "_" .. number] = { point = point, stem = stem, number = tonumber(number), at = Copy3(point:K2_GetActorLocation()) } end
        end)
    end
    local cargoAt = {}
    for _, cargo in ipairs(Live("HeavyCargo")) do
        pcall(function() cargoAt[#cargoAt + 1] = Copy3(cargo:K2_GetActorLocation()) end)
    end
    local repaired, counted = 0, 0
    for _ in pairs(points) do counted = counted + 1 end
    Log("MOORING: checking " .. counted .. " mooring point(s) against " .. #cargoAt .. " piece(s) of cargo")
    local failed = nil
    for _, entry in pairs(points) do
        local ok, err = pcall(function()
            local before = points[entry.stem .. "_" .. (entry.number - 1)]
            local after = points[entry.stem .. "_" .. (entry.number + 1)]
            if not before or not after or Dist3(before.at, after.at) > MOORING_PAIR_MAX_CM then return end
            local middle = { X = (before.at.X + after.at.X) / 2, Y = (before.at.Y + after.at.Y) / 2, Z = (before.at.Z + after.at.Z) / 2 }
            local off = Dist3(entry.at, middle)
            if off <= MOORING_STRAY_CM then return end
            local near = math.huge
            for _, c in ipairs(cargoAt) do near = math.min(near, Dist3(entry.at, c)) end
            if near > MOORING_CARGO_CM then
                Log(string.format("MOORING: %s is %.0f cm from its place between its neighbours but %.0f cm from any cargo; leaving it",
                    entry.point:GetFName():ToString(), off, near))
                return
            end
            Log(string.format("MOORING: %s is %.0f cm from its place between its neighbours and %.0f cm from a piece of cargo; putting it back at %.0f %.0f %.0f",
                entry.point:GetFName():ToString(), off, near, middle.X, middle.Y, middle.Z))
            pcall(function() entry.point:K2_DetachFromActor(1, 1, 1) end)
            entry.point:K2_SetActorLocation(middle, false, {}, true)
            repaired = repaired + 1
            MooringFixed[#MooringFixed + 1] = { point = entry.point, middle = middle, at = os.clock() }
        end)
        if not ok and not failed then failed = err end
    end
    if failed then Log("MOORING: the check failed on a point: " .. (tostring(failed):gsub("\n.*", ""))) end
    return repaired, counted, #cargoAt
end
MooringFixed = {}

-- Two seconds after a repair, say whether the bollard stayed where it was put.
MooringLooks = {}

-- The same look again a few seconds after a piece was let go, to see whether a bollard keeps following it.
function MooringLooksTick()
    local keep = {}
    for _, look in ipairs(MooringLooks) do
        if os.clock() >= look.at then
            pcall(function()
                Log("MOORING: (a few seconds after the drop)")
                if Valid(look.cargo) then MooringNear(look.cargo, look.cargo:K2_GetActorLocation()) end
            end)
        else
            keep[#keep + 1] = look
        end
    end
    MooringLooks = keep
end

function MooringFixedTick()
    local keep = {}
    for _, fixed in ipairs(MooringFixed) do
        if os.clock() - fixed.at >= 2 then
            pcall(function()
                local now = fixed.point:K2_GetActorLocation()
                Log(string.format("MOORING: %s is now %.0f cm from where it was put", fixed.point:GetFName():ToString(), Dist3(now, fixed.middle)))
            end)
        else
            keep[#keep + 1] = fixed
        end
    end
    MooringFixed = keep
end

-- Mooring points close to a piece that was found on the hook (a bollard was seen following such a piece).
-- Locations only: this reads nothing else of the mooring points.
function MooringNear(cargo, at)
    local near, total = 0, 0
    for _, point in ipairs(Live("MooringPoint")) do
        pcall(function()
            total = total + 1
            local where = point:K2_GetActorLocation()
            local d = Dist3(where, at)
            if d < 800 then
                near = near + 1
                Log(string.format("MOORING: %s is %.0f cm from the %s at %.0f %.0f %.0f", point:GetFName():ToString(), d, ClassName(cargo), where.X, where.Y, where.Z))
            end
        end)
    end
    Log("MOORING: " .. near .. " of " .. total .. " mooring point(s) within 8 m of the " .. ClassName(cargo))
end

function DropWatchTick()
    local keep = {}
    for _, w in ipairs(DropWatch) do
        if os.clock() - w.at >= 1.0 then
            pcall(function()
                if not Valid(w.cargo) then
                    Log("DROP+: the " .. w.label .. " piece is gone")
                    return
                end
                local now = w.cargo:K2_GetActorLocation()
                if w.label:find("left on the hook", 1, true) then
                    pcall(MooringNear, w.cargo, now)
                    MooringLooks[#MooringLooks + 1] = { cargo = w.cargo, at = os.clock() + 4 }
                    MooringLooks[#MooringLooks + 1] = { cargo = w.cargo, at = os.clock() + 12 }
                end
                local moved = math.sqrt((now.X - w.released.X) ^ 2 + (now.Y - w.released.Y) ^ 2 + (now.Z - w.released.Z) ^ 2)
                local off = w.target and math.sqrt((now.X - w.target.X) ^ 2 + (now.Y - w.target.Y) ^ 2 + (now.Z - w.target.Z) ^ 2) or -1
                Log(string.format("DROP+: the %s now at %s: moved %.0f cm since release, %.0f cm from where it was sent",
                    ClassName(w.cargo), Where(now), moved, off))
            end)
        else
            keep[#keep + 1] = w
        end
    end
    DropWatch = keep
end

local function SetDown(job)
    if not Valid(job.crane) or not Valid(job.cargo) then return end
    local arrived = false
    if Same(job.crane.AttachedCargo, job.cargo) then
        DropNote("setting down", job.crane, job.cargo, job.to, job.place)
        job.crane:ServerDetachCargo(job.to, job.place.position, job.place.rotation)
        arrived = true
    elseif Same(job.cargo.CargoArea, job.to) then
        -- It came off the hook on the way but ended up where it was going: that counts.
        Log("the " .. ClassName(job.cargo) .. " came off the hook on the way but landed where it was going")
        arrived = true
    else
        Log("the " .. ClassName(job.cargo) .. " came off the hook on the way and is not where it was going")
    end
    -- A hand-marked piece that has got to the side it was marked for is done, however it got there.
    if arrived and job.guid and Manual[job.guid] then
        local inHold = IsHold(job.to)
        if (Manual[job.guid] == "load") == inHold then
            Manual[job.guid] = nil
            if job.settle then Moved = Moved + 1 end
        end
    end
    if arrived and not job.settle then
        Moved = Moved + 1
        if job.guid then
            Manual[job.guid] = nil  -- done; without this it would be carried straight back
            Relayed[job.guid] = nil
        end
    end
end

-- While a crane carries a piece over an area the game lights up, in green, the cells it would be set
-- down on. Someone at the controls has that cleared when they let go; setting a piece down from
-- here does not, so the lit cells are put out by hand.
local GhostReport = false

local function ClearGhost(area)
    pcall(function()
        local lit = area.CargoRepresentationComponent.HighlightedCellsMap
        local count = 0
        lit:ForEach(function(_, value)
            local cell = value:get()
            if Valid(cell) then
                cell:SetVisibility(false, false)
                count = count + 1
            end
        end)
        local emptied = count > 0 and pcall(function() lit:Empty() end)
        if count > 0 and not GhostReport then
            GhostReport = true
            Log(string.format("put out %d lit cell(s) left under a set-down piece (list emptied: %s)", count, tostring(emptied)))
        end
    end)
end

-- The steps of moving one piece. Each waits for the crane to get where the step before sent it.
-- Bumps, for testing. While a load hangs on the hook, its outline is compared with those of the
-- cargo around it, and each time it runs into another piece a BUMP line goes to the log: when, in
-- which step, how deep, where both are, the crane's joints and the carrying height. Kept until it is
-- no longer wanted for testing.
local BUMP_DEPTH_CM = 5

local function Outline(actor)
    local centre, extent = {}, {}
    actor:GetActorBounds(true, centre, extent, false)
    centre, extent = centre.Origin or centre, extent.BoxExtent or extent
    return { X = centre.X, Y = centre.Y, Z = centre.Z }, { X = extent.X, Y = extent.Y, Z = extent.Z }
end

local function WatchBumps(job)
    local c, e = Outline(job.cargo)
    job.bumped = job.bumped or {}
    for _, other in ipairs(Live("HeavyCargo")) do
        if not Same(other, job.cargo) and Dist(other:K2_GetActorLocation(), c) < 800 then
            local oc, oe = Outline(other)
            local dx = e.X + oe.X - math.abs(c.X - oc.X)
            local dy = e.Y + oe.Y - math.abs(c.Y - oc.Y)
            local dz = e.Z + oe.Z - math.abs(c.Z - oc.Z)
            local key = other:GetAddress()
            if dx > BUMP_DEPTH_CM and dy > BUMP_DEPTH_CM and dz > BUMP_DEPTH_CM then
                if not job.bumped[key] then
                    job.bumped[key] = true
                    local joints = {}
                    for part, name in pairs(job.model.joints) do
                        joints[#joints + 1] = string.format("%s %.2f", part, job.crane[name]:GetCurrentValue())
                    end
                    table.sort(joints)
                    Log(string.format("BUMP: the %s ran into a %s while '%s' (%.1f s into the step): overlap %.0f x %.0f x %.0f cm | load at %.0f %.0f %.0f | other at %.0f %.0f %.0f | carrying height %.0f | %s",
                        ClassName(job.cargo), ClassName(other), job.phase, job.ticks * MOTION_MS / 1000, dx, dy, dz,
                        c.X, c.Y, c.Z, oc.X, oc.Y, oc.Z, job.tip or 0, table.concat(joints, ", ")))
                end
            else
                job.bumped[key] = nil  -- apart again: the next contact is logged as a new bump
            end
        end
    end
end

local function JobStep()
    local job = Job
    if not job then return end
    if not Valid(job.crane) or not Valid(job.cargo) then
        Job, Steer = nil, nil
        return
    end
    job.ticks = job.ticks + 1
    local seconds = job.ticks * MOTION_MS / 1000
    local arrived = Steer == nil or seconds > PHASE_SECONDS
    local carrying = job.phase == "to drop" or job.phase == "lower to drop" or job.phase == "set down"
        or job.phase == "turn" or job.phase == "aim" or job.phase == "settle in"
        or (job.phase == "lift" and seconds >= 0.8 and job.lifted)
    if carrying and job.model and job.ticks % 3 == 0 and Same(job.crane.AttachedCargo, job.cargo) then pcall(WatchBumps, job) end
    if carrying and not Same(job.crane.AttachedCargo, job.cargo) then
        pcall(PassThrough, job.cargo, false)  -- off the hook: it must not fall through what is under it
        -- Loads come off this hook now and then, for the game's own operators too. While it is still
        -- hanging by the hook it is latched again, a few times at most.
        local near = false
        pcall(function()
            near = Dist(job.crane.HookJoint:K2_GetComponentLocation(), job.cargo.CargoHook:K2_GetComponentLocation()) < 300
                and math.abs(job.crane.HookJoint:K2_GetComponentLocation().Z - job.cargo.CargoHook:K2_GetComponentLocation().Z) < 300
        end)
        if near and not Same(job.cargo.CargoArea, job.to) and (job.relatched or 0) < 3 then
            job.relatched = (job.relatched or 0) + 1
            job.crane:ServerAttachCargo(job.cargo)
            Log("the " .. ClassName(job.cargo) .. " came off the hook on the way and was latched again")
            return
        end
        -- Otherwise where it landed decides: in its new place it counts as moved, anywhere else it is
        -- fetched again.
        Steer, job.route = nil, nil
        if Same(job.cargo.CargoArea, job.to) and not job.settle then
            Log("the " .. ClassName(job.cargo) .. " came off the hook on the way but landed where it was going")
            Moved = Moved + 1
            if job.guid then Manual[job.guid] = nil end
        else
            Log("the " .. ClassName(job.cargo) .. " came off the hook on the way; it will be fetched again")
        end
        Goto(job, { drum = DRUM_MIN })
        job.phase = "done"
        return
    end
    -- Caught on something: the crane is being driven but the hook has not moved for a second. Lift a
    -- metre and go on with the way from there, a few times at most.
    local moving = job.phase == "to pick" or job.phase == "lower to pick" or job.phase == "to drop" or job.phase == "lower to drop"
    if job.model and job.model.feel and moving and Steer ~= nil and job.ticks % 10 == 0 and job.ticks > 0 then
        local hook = HookNow(job.crane)
        local far = false  -- still well short of where it is being taken, not just easing in
        for part, name in pairs(job.model.joints) do
            local goal = Steer.goal[part]
            if goal ~= nil and math.abs(goal - job.crane[name]:GetCurrentValue()) > job.model.close[part] * 5 then far = true end
        end
        local stuck = far and job.lastHook3 and Dist(hook, job.lastHook3) < 5 and math.abs(hook.Z - job.lastHook3.Z) < 5
        job.lastHook3 = { X = hook.X, Y = hook.Y, Z = hook.Z }
        if stuck and (job.unstuck or 0) < 3 then
            job.unstuck = (job.unstuck or 0) + 1
            job.lastHook3 = nil
            job.tip = (job.tip or hook.Z) + 100
            local up = job.model.Arm(job.crane, hook, math.max(job.tip, hook.Z + job.model.hookBelow + DRUM_MIN + 100))
            Log("the crane is caught on something; lifting a metre and carrying on")
            job.route = job.route or {}
            table.insert(job.route, 1, Steer.goal)  -- then on to where it was going
            if up then Goto(job, WithDrum(up.pose, DRUM_MIN)) else Goto(job, { drum = DRUM_MIN }) end
            return
        end
    end
    if job.route and #job.route > 0 then  -- part way along a route: on to its next step
        if arrived then
            local goal = table.remove(job.route, 1)
            Goto(job, goal, #job.route > 0)  -- passed through on the way, unless it is the last
        end
        return
    end

    if job.phase == "park" then
        if arrived then Job = nil end  -- the route above has been driven to its end
        return
    elseif job.phase == "stage" then
        if job.ticks == 1 then
            pcall(function() job.cargo:SetActorHiddenInGame(true) end)
            job.crane:ServerAttachCargo(job.cargo)
        elseif job.ticks >= 3 then
            SetDown(job)
            pcall(function() job.cargo:SetActorHiddenInGame(false) end)
            ClearGhost(job.to)
            local name = "cargo"
            pcall(function() name = job.cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
            if Same(job.to, job.fromArea) then
                Log("moved the " .. ClassName(job.cargo) .. " aside within its own area")
            else
                Toast("Moving " .. name .. " to the nearest dock")
            end
            Job, Rest = nil, 1
        end
        return
    elseif job.phase == "plain" then
        if job.ticks == 1 then job.crane:ServerAttachCargo(job.cargo) end
        if seconds >= 4 then
            SetDown(job)
            Job, Rest = nil, math.floor(8000 / TICK_MS)
        end
    elseif job.phase == "clear" then          -- hook up out of the way first
        Goto(job, { drum = DRUM_MIN })
        job.phase = "to pick"
    elseif job.phase == "to pick" and arrived then
        job.arm = job.model.Arm(job.crane, job.pick, job.tip)
        if not job.arm then
            if job.model.feel then
                -- The ship's own cranes leave a piece they cannot get to where it is, never pull it across.
                Log("the crane cannot get to the " .. ClassName(job.cargo) .. " after all; leaving it")
                if job.guid then Unreachable[job.guid] = true end
                local name = "piece"
                pcall(function() name = job.cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
                Toast("The " .. name .. " is out of reach of the ship's cranes")
                Goto(job, { drum = DRUM_MIN })
                job.phase = "done"
                return
            end
            Log("the crane cannot reach the pick-up after all; moving the piece the plain way")
            job.phase, job.ticks = "plain", 0
            return
        end
        GoRoute(job, SwingRoute(job.crane, job.model, WithDrum(job.arm.pose, DRUM_MIN), job.tip, job.pick))
        job.phase = "lower to pick"
    elseif job.phase == "lower to pick" and arrived then
        if job.model.feel then
            -- Let the hook down by watching it, not by the model: it has to end up on the piece's
            -- lifting point, which the model alone does not get close enough to.
            job.phase, job.ticks, job.aims, job.aimPick = "aim pick", 0, 0, nil
            Steer = nil
        else
            Goto(job, WithDrum(job.arm.pose, DrumFor(job.model, job.arm.tipZ, job.pick.Z)))
            job.phase = "attach"
        end
    elseif job.phase == "aim pick" then
        -- Puts the hook squarely over the piece's lifting point before it comes down: where the hook
        -- actually is against where the point is, and the arm moved by the difference, until it is
        -- within a few centimetres. The model of the arm alone can leave it half a metre or more off.
        if job.ticks % 8 ~= 0 or (Steer ~= nil and seconds < 3) then return end
        local hook = job.crane.HookJoint:K2_GetComponentLocation()
        local lift = job.cargo.CargoHook:K2_GetComponentLocation()
        local ex, ey = lift.X - hook.X, lift.Y - hook.Y
        local off = math.sqrt(ex * ex + ey * ey)
        if off <= 4 or job.aims >= 5 then
            Log(string.format("AIM: hook %.0f cm from the %s's lifting point after %d correction(s)", off, ClassName(job.cargo), job.aims))
            job.phase, job.ticks, job.lastHook, job.still = "descend", 0, nil, 0
            Steer = nil
            return
        end
        job.aims = job.aims + 1
        job.aimPick = job.aimPick or { X = job.pick.X, Y = job.pick.Y, Z = job.pick.Z }
        job.aimPick = { X = job.aimPick.X + ex, Y = job.aimPick.Y + ey, Z = job.aimPick.Z }
        local arm = job.model.Arm(job.crane, job.aimPick, job.arm.tipZ)
        if arm then
            job.arm = arm
            local drum = job.crane[job.model.joints.drum]:GetCurrentValue()
            Steer = { crane = job.crane, model = job.model, goal = WithDrum(arm.pose, drum) }
            job.ticks = 0
        else
            Log(string.format("AIM: the arm cannot get the hook the last %.0f cm over the %s; going down from here", off, ClassName(job.cargo)))
            job.aims = 99
        end
    elseif job.phase == "descend" then
        if job.ticks % 3 ~= 0 then return end
        local hook = job.crane.HookJoint:K2_GetComponentLocation()
        local lift = job.cargo.CargoHook:K2_GetComponentLocation()
        local want = lift.Z + HOOK_ON_LIFT_CM + 10 * (job.tries or 0)  -- a little higher on each new try
        local moved = job.lastHook and math.abs(job.lastHook - hook.Z) or 99
        job.lastHook = hook.Z
        job.still = moved < 1.5 and job.still + 1 or 0
        if hook.Z <= want + 3 or job.still >= 4 or seconds > PHASE_SECONDS then
            -- On it, or resting on something and going no lower.
            Steer = nil
            job.phase, job.ticks = "attach", 0
            job.hookGap = hook.Z - lift.Z
            return
        end
        local drum = job.crane[job.model.joints.drum]:GetCurrentValue()
        local goal = WithDrum(job.arm.pose, Clamp(drum + math.min(hook.Z - want, 60), DRUM_MIN, DRUM_MAX))
        Steer = { crane = job.crane, model = job.model, goal = goal }
    elseif job.phase == "attach" and arrived then
        pcall(PassThrough, job.cargo, true)
        job.crane:ServerAttachCargo(job.cargo)
        job.heldAtOnce = Same(job.crane.AttachedCargo, job.cargo)
        -- Lift at once, before the game decides the piece is still in its place and sets it down. The
        -- deck crane lifts the first stretch with its arm, straight up off the stack, and only then
        -- reels in the cable.
        if job.model.feel then
            local drum = job.crane[job.model.joints.drum]:GetCurrentValue()
            local up = job.model.Arm(job.crane, HookNow(job.crane), job.arm.tipZ + 80)
            if up then
                Goto(job, WithDrum(up.pose, drum))
            else
                Goto(job, { drum = DRUM_MIN })
            end
        end
        job.ticks = 0
        job.phase = "lift"
    elseif job.phase == "lift" and seconds >= 0.8 then
        if not Same(job.crane.AttachedCargo, job.cargo) then
            -- The piece did not stay on the hook. Say where the hook was against where it should be,
            -- and try again from a little higher, or give the piece up.
            job.tries = (job.tries or 0) + 1
            pcall(PassThrough, job.cargo, false)  -- not on the hook: it must stand on what is under it again
            local hookAt, liftAt = "?", "?"
            pcall(function()
                local h = job.crane.HookJoint:K2_GetComponentLocation()
                hookAt = string.format("%.0f %.0f %.0f", h.X, h.Y, h.Z)
            end)
            pcall(function()
                local c = job.cargo.CargoHook:K2_GetComponentLocation()
                liftAt = string.format("%.0f %.0f %.0f", c.X, c.Y, c.Z)
            end)
            Log(string.format("the %s did not stay on the hook (try %d): hook at %s, its lifting point at %s, gap %s cm, on the hook straight after attaching: %s",
                ClassName(job.cargo), job.tries, hookAt, liftAt, job.hookGap and string.format("%.0f", job.hookGap) or "?",
                tostring(job.heldAtOnce)))
            if job.tries < 3 then
                job.pick.Z = job.pick.Z - 15
                if job.model.feel then
                    job.phase, job.ticks, job.lastHook, job.still = "descend", 0, nil, 0
                else
                    Goto(job, WithDrum(job.arm.pose, DrumFor(job.model, job.arm.tipZ, job.pick.Z)))
                    job.phase = "attach"
                end
                return
            end
            Failed[job.guid or "?"] = (Failed[job.guid or "?"] or 0) + 1
            if (Failed[job.guid or "?"] or 0) >= 2 and job.guid then
                Manual[job.guid] = nil
                Toast("Crane operator could not lift a " .. ClassName(job.cargo):gsub("^BP_", ""):gsub("_C$", ""))
            end
            Goto(job, { drum = DRUM_MIN })
            job.phase = "done"
            return
        end
        job.lifted = true
        pcall(Slim, job.cargo)
        Goto(job, { drum = DRUM_MIN })
        job.phase = "to drop"
    elseif job.phase == "to drop" and arrived then
        pcall(PassThrough, job.cargo, false)  -- reeled up clear of its neighbours
        job.arm = job.model.Arm(job.crane, job.drop, job.tip)
        if not job.arm then  -- out of reach after all: carry on the plain way
            SetDown(job)
            Job, Rest = nil, math.floor(4000 / TICK_MS)
            return
        end
        GoRoute(job, SwingRoute(job.crane, job.model, WithDrum(job.arm.pose, DRUM_MIN), job.tip, job.drop))
        job.phase = "lower to drop"
    elseif job.phase == "lower to drop" and arrived then
        if job.finalYaw and job.model.joints.turn then
            job.phase, job.ticks, job.turnSign, job.lastError = "turn", 0, TurnSigns[ClassName(job.crane)] or 1, nil
            job.turnTarget, job.turnSeen, job.turnWrong = nil, nil, 0
            Steer = nil
        elseif job.model.feel then
            pcall(PassThrough, job.cargo, true)
            job.phase, job.ticks, job.aims = "aim", 0, 0
            Steer = nil
        else
            Goto(job, WithDrum(job.arm.pose, DrumFor(job.model, job.arm.tipZ, job.drop.Z)))
            job.phase = "set down"
        end
    elseif job.phase == "aim" then
        -- Puts the load squarely over its place before lowering it: where the load's lifting point
        -- actually is against where it should be, and the arm moved by the difference, until it is
        -- within a few centimetres. The model of the arm alone is out by a little.
        if job.ticks % 8 ~= 0 or (Steer ~= nil and seconds < 3) then return end
        local at = job.cargo.CargoHook:K2_GetComponentLocation()
        local ex, ey = job.drop.X - at.X, job.drop.Y - at.Y
        if math.sqrt(ex * ex + ey * ey) <= 4 or job.aims >= 5 then
            job.phase, job.ticks, job.lastLoad, job.still = "settle in", 0, nil, 0
            Steer = nil
            return
        end
        job.aims = job.aims + 1
        job.aim = job.aim or { X = job.drop.X, Y = job.drop.Y, Z = job.drop.Z }
        job.aim = { X = job.aim.X + ex, Y = job.aim.Y + ey, Z = job.aim.Z }
        local arm = job.model.Arm(job.crane, job.aim, job.arm.tipZ)
        if arm then
            job.arm = arm
            local drum = job.crane[job.model.joints.drum]:GetCurrentValue()
            Steer = { crane = job.crane, model = job.model, goal = WithDrum(arm.pose, drum) }
            job.ticks = 0
        end
    elseif job.phase == "settle in" then
        -- Lets the load down by watching it, until its lifting point is where it will be once the
        -- load stands in its place, or the load rests on something and goes no lower.
        if job.ticks % 3 ~= 0 then return end
        local load = job.cargo.CargoHook:K2_GetComponentLocation()
        local want = job.drop.Z + 5
        local moved = job.lastLoad and math.abs(job.lastLoad - load.Z) or 99
        job.lastLoad = load.Z
        job.still = moved < 1.5 and job.still + 1 or 0
        if load.Z <= want or job.still >= 4 or seconds > PHASE_SECONDS then
            Steer = nil
            job.phase, job.ticks = "set down", 0
            return
        end
        local drum = job.crane[job.model.joints.drum]:GetCurrentValue()
        local goal = WithDrum(job.arm.pose, Clamp(drum + math.min(load.Z - want, 60), DRUM_MIN, DRUM_MAX))
        Steer = { crane = job.crane, model = job.model, goal = goal }
    elseif job.phase == "turn" then
        -- Turns the hook until the load faces the way its new place does. One facing is chosen at the
        -- start and kept (a piece looks the same turned half round, so the nearer of the two), and each
        -- turn is let settle before the next is worked out: the load follows the hook a little behind,
        -- so judging it while it is still swinging round makes the crane turn one way, then the other.
        if job.ticks % 4 ~= 0 then return end
        local yaw = job.cargo:K2_GetActorRotation().Yaw
        local joint = job.crane[job.model.joints.turn]
        local now = joint:GetCurrentValue()
        if not job.turnTarget then
            local step = job.symmetry or 180
            local best, bestError = job.finalYaw, math.huge
            for k = 0, math.floor(360 / step) - 1 do
                local candidate = Turn(job.finalYaw + k * step)
                local off = math.abs(Turn(candidate - yaw))
                if off < bestError then best, bestError = candidate, off end
            end
            job.turnTarget = best
        end
        local settled = job.turnSeen ~= nil and math.abs(now - job.turnSeen.joint) < 0.8
            and math.abs(Turn(yaw - job.turnSeen.yaw)) < 1.0
        job.turnSeen = { joint = now, yaw = yaw }
        local error = Turn(job.turnTarget - yaw)
        if math.abs(error) <= 3 or seconds > 12 then
            Log(string.format("TURN: the %s (%s; looks the same every %s degrees) is %.0f degrees off its facing after %d turn(s) and %.1f s%s",
                ClassName(job.cargo), job.footing or "shape not read", job.symmetry and tostring(job.symmetry) or "180?",
                math.abs(error), job.turnSteps or 0, seconds, job.turnSign == 1 and "" or " (hook turn runs the other way)"))
            if job.model.feel then
                pcall(PassThrough, job.cargo, true)
                job.phase, job.ticks, job.aims = "aim", 0, 0
                Steer = nil
            else
                Goto(job, WithDrum(job.arm.pose, DrumFor(job.model, job.arm.tipZ, job.drop.Z)))
                job.phase = "set down"
            end
            return
        end
        if not settled then return end  -- still turning: wait for it before judging
        -- A turn that has settled and left the load further from its facing than before went the wrong
        -- way; two such in a row turn the other way (and that is remembered for this kind of crane).
        if job.lastError and math.abs(error) > math.abs(job.lastError) + 4 then
            job.turnWrong = (job.turnWrong or 0) + 1
            if job.turnWrong >= 2 then
                job.turnSign, job.turnWrong = -job.turnSign, 0
                TurnSigns[ClassName(job.crane)] = job.turnSign
            end
        else
            job.turnWrong = 0
        end
        job.lastError = error
        job.turnSteps = (job.turnSteps or 0) + 1
        local goal = now + job.turnSign * error
        if goal > 179 then goal = goal - 360 elseif goal < -179 then goal = goal + 360 end  -- the same way round, from the other side
        goal = Clamp(goal, -179, 179)
        Steer = { crane = job.crane, model = job.model, goal = { turn = goal } }
    elseif job.phase == "set down" and arrived then
        SetDown(job)
        job.ticks = 0
        job.phase = "release"
    elseif job.phase == "release" and seconds >= 0.6 then
        pcall(Unslim)
        ClearGhost(job.to)
        Goto(job, { drum = DRUM_MIN })
        job.phase = "done"
    elseif job.phase == "done" and arrived then
        ClearGhost(job.to)
        Job, Rest = nil, math.floor(1000 / TICK_MS)
    end
end

TurnSigns = {}  -- crane class -> which way the hook's turn moves the load, once found
local ParkTries = 0

local Pending = nil  -- { move, cargo, crane, at }: chosen, not yet started

-- Puts a crane back as it was found in one go: the route up, drawn in, round and down into its
-- resting pose is worked out once and driven as a job, not a step re-planned every second.
local function StartPark(crane, model)
    local route = { model.parked }
    if model.travelUp then
        local base, yaw = crane:K2_GetActorLocation(), math.rad(crane:K2_GetActorRotation().Yaw)
        local rest = { X = base.X + 553 * math.cos(yaw) - 47 * math.sin(yaw), Y = base.Y + 553 * math.sin(yaw) + 47 * math.cos(yaw), Z = base.Z }
        local high = math.max(base.Z + model.travelUp, HookNow(crane).Z + model.hookBelow + DRUM_MIN)
        local over = model.Arm(crane, rest, high)
        if over then
            route = SwingRoute(crane, model, WithDrum(over.pose, DRUM_MIN), high, rest)
            route[#route + 1] = model.parked
        end
    end
    local first = table.remove(route, 1)
    Job = { phase = "park", crane = crane, cargo = crane, model = model, ticks = 0, route = route }
    Steer = { crane = crane, model = model, goal = first, pass = #route > 0 }
    Log(string.format("putting the crane back: %d step(s)", #route + 1))
end

-- When a boat with an operator on duty docks, say so at once: the crane does not start until the boat is made
-- fast and the orders reach her, which can take most of a minute, and a silent wait looks like a broken mod.
ReadyTold = {}     -- boat address -> true once told, until the boat undocks
ReadyToldAt = -1000

function NoteDocking(boat, name)
    local key = boat:GetAddress()
    local docked = false
    pcall(function() docked = boat.DockingComponent:IsDocked() == true end)
    if not docked then
        ReadyTold[key] = nil
    elseif not ReadyTold[key] then
        ReadyTold[key] = true
        ReadyToldAt = os.clock()
        Toast(name .. " is getting ready to work the crane")
    end
end

-- The docking watcher. Work looks for work only when its idle wait is up (two seconds, or five after finding
-- nothing), so the operator could notice the boat being made fast long after it was. This is looked at every
-- half second instead: when the game first calls the boat made fast, the wait is cancelled so that the very
-- next step looks for work. The game's docking flags are logged when they change (DOCK: lines), to show how
-- long the game itself takes from the boat docking to calling it made fast.
DockSeen = {}   -- boat address -> "docked,pulling" as last seen

function WatchBoat(boat, name)
    local key = boat:GetAddress()
    local docked, pulling = false, false
    pcall(function()
        local docking = boat.DockingComponent
        docked, pulling = docking:IsDocked() == true, docking.bIsPulling == true
    end)
    local now = string.format("%s,%s", tostring(docked), tostring(pulling))
    local before = DockSeen[key]
    if now == before then return false end
    DockSeen[key] = now
    Log(string.format("DOCK: %s: docked %s, being pulled in %s", ClassName(boat), tostring(docked), tostring(pulling)))
    pcall(NoteDocking, boat, name)
    if docked then  -- the lines have caught (the pull-in may go on): look for work at once
        Rest = 0
        return true
    end
    return false
end

function WatchDocking()
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local slot = CraneSlot(comp)
            if slot and Valid(slot.CrewMember) then WatchBoat(comp:GetOwner(), MemberName(slot.CrewMember)) end
        end)
    end
end

WhyNot, WaitToldAbout = nil, false
local function Work()
    if not Job and (next(Slimmed) or next(Passing)) then pcall(Unslim) end
    if not StrandedChecked then
        StrandedChecked = true
        RecoverStranded()
    end
    if Halted then return end  -- stopped with Ctrl+Alt+S
    if Job then return end  -- the piece in hand is seen to by JobStep
    if Rest > 0 then
        Rest = Rest - 1
        return
    end
    Rest = math.floor(2000 / TICK_MS)  -- look for work every two seconds when idle

    local site, operator, character = nil, nil, nil
    local why = nil
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        if not site then
            pcall(function()
                local slot = CraneSlot(comp)
                if slot and Valid(slot.CrewMember) then
                    local reason
                    pcall(NoteDocking, comp:GetOwner(), MemberName(slot.CrewMember))
                    site, reason = WorkSite(comp)
                    why = why or (not site and (MemberName(slot.CrewMember) .. " is not working: " .. tostring(reason)) or nil)
                    operator = site and MemberName(slot.CrewMember) or nil
                    character = site and slot.CrewMember.Character or nil
                end
            end)
        end
    end
    if why ~= WhyNot then  -- said when it changes, so the log does not fill up
        WhyNot = why
        if why then Log(why) end
    end
    -- Work is marked but the boat is not made fast yet: say so once, so that waiting is not mistaken
    -- for the operator being broken.
    if not why then
        WaitToldAbout = false
    elseif not WaitToldAbout and why:find("made fast", 1, true) and os.clock() - ReadyToldAt > 120 then
        local _, _, count = ReadMarks()
        if count > 0 or next(Manual) ~= nil then
            WaitToldAbout = true
            Toast((why:match("^(.-) is not working") or "The crane operator") .. " is waiting for the boat to be made fast to the dock")
        end
    end
    -- Someone else in a crane's seat (you, usually) means that crane is taken; the operator does not.
    local free = {}
    for _, crane in ipairs(site and site.cranes or {}) do
        local driver = CraneDriver(crane)
        if not driver or Same(driver, character) then free[#free + 1] = crane end
    end
    local inSite = false
    for _, crane in ipairs(free) do
        if AtCrane and Same(AtCrane.crane, crane) then inSite = true end
    end
    if AtCrane and (not site or not inSite or not Same(AtCrane.character, character)) then
        LeaveCrane()  -- the boat has left, the operator was changed, or the crane is no longer theirs
    end
    if site and not AtCrane then pcall(NoteSpot, operator, character, site.boat) end
    if site and AtCrane then site.crane = AtCrane.crane end
    if not site then Unreachable, Staged, Activated = {}, {}, {} end
    local move, complaint = nil, nil
    local load, unload, fresh = nil, nil, false
    if site and #free > 0 then
        for _, crane in ipairs(free) do
            local held = crane.AttachedCargo
            if Valid(held) then
                -- A piece a crane would not set down where it was sent: put it wherever its area has room.
                -- Not in the first minutes after the game loads: the game puts the piece into its area in
                -- one jump, and doing that while the world is still settling threw the boat over (twice).
                if not HookInspected then
                    HookInspected = true
                    pcall(InspectHookPiece, held)
                end
                if not MooringChecked or os.clock() - MooringChecked < HOOK_PIECE_WAIT_S then
                    if not HookWaitTold then
                        HookWaitTold = true
                        Log("a piece is on the hook; leaving it until the dock's bollards have been checked before setting it down")
                    end
                    return
                end
                -- Onto the dock, never into the boat: a piece found on the hook can still be tied to the dock
                -- (a bollard's rope), and putting it in the hold pulled the boat over by it.
                local back, place = nil, nil
                for _, dock in ipairs(DockAreas(site)) do
                    local found = FindPlace(dock.area, held, dock.near)
                    if found then back, place = dock.area, found break end
                end
                if not place and not HookNoDockTold then
                    HookNoDockTold = true
                    Log("a piece is on the hook and no dock area has room for it; leaving it there rather than putting it in the hold")
                end
                if place then
                    Log("a piece was left on the hook, setting it down where there is room")
                    DropNote("left on the hook, setting down", crane, held, back, place)
                    crane:ServerDetachCargo(back, place.position, place.rotation)
                end
                return
            end
        end
        -- The move chosen a moment ago, kept while the crane is put back and seats are changed.
        if Pending and Valid(Pending.cargo) and Valid(Pending.crane) and os.clock() - Pending.at < 60 then
            move = Pending.move
        else
            Pending = nil
        end
        if not move then move = NextSettle(site) end
        if not move then
            local count
            load, unload, count = ReadMarks()
            for guid, way in pairs(Manual) do  -- the way a hand-marked piece goes was fixed when it was marked
                if way == "unload" then unload[guid] = true else load[guid] = true end
                count = count + 1
            end
            if count > 0 then
                move, complaint = NextMove(site, load, unload)
                fresh = true
            end
        end
    end
    if move and not (Pending and Pending.move == move) then
        if move.stage then
            move.crane, move.steer = site.crane, false
        else
            move.crane, move.steer = ChooseCrane(site, move, character)
        end
        if not move.crane then move = nil end
        if move and site.deck and not move.steer and not move.stage then
            -- Neither of the boat's own cranes reaches it. It is left where it is rather than pulled
            -- across to the hook, and the next piece is looked at straight away.
            local guid = CargoGuid(move.cargo) or "?"
            Unreachable[guid] = true
            local name = "piece"
            pcall(function() name = move.cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
            Toast("The " .. name .. " is out of reach of the ship's cranes")
            move = nil
            Rest = 1
            return
        end
    end
    -- Batching: before changing seats for a piece, everything the crane already in use can do is done.
    -- Other pieces are tried in turn, passing over each that wants the other crane, a few at most.
    if fresh and move and move.crane and move.steer and AtCrane and not move.stage and not Same(AtCrane.crane, move.crane) then
        local first = move
        -- Looking ahead must not leave marks behind for pieces passed over.
        local relayedBefore, stagedBefore = {}, {}
        for k, v in pairs(Relayed) do relayedBefore[k] = v end
        for k, v in pairs(Staged) do stagedBefore[k] = v end
        Skip = {}
        for _ = 1, 6 do
            Skip[CargoGuid(move.cargo) or "?"] = true
            if move.under then Skip[CargoGuid(move.under) or "?"] = true end  -- a piece cleared off another passes over both
            local other = NextMove(site, load, unload)
            if not other then break end
            other.crane, other.steer = ChooseCrane(site, other, character)
            if other.crane and other.steer and Same(other.crane, AtCrane.crane) then
                Log("staying in this crane: the " .. ClassName(other.cargo) .. " first, the " .. ClassName(first.cargo) .. " after")
                move = other
                break
            end
            move = other
        end
        Skip = {}
        if not Same(move.crane, AtCrane.crane) then move = first end
        Relayed, Staged = relayedBefore, stagedBefore
        local guid = CargoGuid(move.cargo) or "?"
        if move.handOver then Relayed[guid] = true end
        if move.stage then Staged[guid] = true end
    end
    if move and move.crane then Pending = { move = move, cargo = move.cargo, crane = move.crane, at = os.clock() } end
    if move and AtCrane and not Same(AtCrane.crane, move.crane) then
        -- The other crane suits this piece: put this one back and change seats.
        local model = ModelOf(AtCrane.crane)
        if model and not There(AtCrane.crane, model, model.parked) and ParkTries < 2 then
            ParkTries = ParkTries + 1
            StartPark(AtCrane.crane, model)
            return
        end
        LeaveCrane()
    end
    if move and not AtCrane and Valid(character) then
        site.crane = move.crane
        EnterCrane(site, character, operator)
        Rest = math.floor(SEAT_SECONDS * 1000 / TICK_MS)
        return
    end
    if not move and AtCrane then
        -- Put the crane back as it was found before getting out of the seat.
        local crane = AtCrane.crane
        local model = Valid(crane) and ModelOf(crane) or nil
        if model and not There(crane, model, model.parked) and ParkTries < 2 then
            ParkTries = ParkTries + 1
            StartPark(crane, model)
            return
        end
        LeaveCrane()
    end
    ParkTries = 0
    if move then
        if not Working and not move.settle then
            Working = true
            Moved = 0
            Toast(operator .. " has started working the crane")
        end
        if move.tidy then
            if not TidyTold then
                TidyTold = true
                Toast(operator .. " is making room in the hold")
            end
        end
        Complaint = nil
        Pending = nil
        StartJob(move)  -- reads the piece's ID before any lift: a piece on the hook no longer answers
        return
    end
    if not move then Rest = math.floor(5000 / TICK_MS) end  -- nothing to start: look again in five seconds
    if complaint and complaint ~= Complaint then
        Complaint = complaint
        Toast("Crane operator has stopped, " .. complaint)
    end
    if Working and not complaint then
        Working = false
        Toast(string.format("Crane operator has finished, %d piece%s moved", Moved, Moved == 1 and "" or "s"))
    end
end

---------------------------------------------------------------------------------------------------
-- Marking by hand. F5 marks the piece of crane cargo in the middle of the view, from on foot or from
-- a crane's camera. A marked piece carries one of the game's own in-world markers, like those the
-- game shows for a tracked mission, saying where it is going.

MARK_RANGE_CM = 8000
HINT_MARK, HINT_UNMARK = "F5 TO MARK FOR THE CRANE", "F5 TO TAKE THE MARK OFF"
TO_BOAT, TO_DOCK = "TO BOAT", "TO DOCK"
MARKER_ICON = "/Game/ShipsAtSea/UI/WorldMap/Materials/Circle/MI_CargoMapIcon_Green.MI_CargoMapIcon_Green"
MARKER_TAG = "UIMapMarker.Type.Marker.Mission.Cargo.M"
local MarkerClass = nil
local Markers = {}       -- cargo guid -> { actor = marker, title = ... }
local StraysCleared = false

local function ItemName(cargo)
    local ok, name = pcall(function() return cargo:GetRepresentedInventoryItem():GetDisplayName():ToString() end)
    return ok and name or "cargo"
end

-- How far along the view the line of sight enters the box, or nil if it misses.
local function RayBox(from, dir, centre, extent)
    local near, far = 0, MARK_RANGE_CM
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        local low, high = centre[axis] - extent[axis], centre[axis] + extent[axis]
        if math.abs(dir[axis]) < 1e-6 then
            if from[axis] < low or from[axis] > high then return nil end
        else
            local a, b = (low - from[axis]) / dir[axis], (high - from[axis]) / dir[axis]
            if a > b then a, b = b, a end
            near, far = math.max(near, a), math.min(far, b)
            if near > far then return nil end
        end
    end
    return near
end

local function CargoBox(cargo)
    local centre, extent = {}, {}
    local ok = pcall(function() cargo:GetActorBounds(true, centre, extent, false) end)
    centre, extent = centre.Origin or centre, extent.BoxExtent or extent
    if ok and centre.X and extent.X then
        return centre, { X = extent.X, Y = extent.Y, Z = extent.Z }
    end
    local at = cargo:K2_GetActorLocation()  -- bounds not available: a metre and a half around its origin
    return { X = at.X, Y = at.Y, Z = at.Z + 60 }, { X = 75, Y = 75, Z = 75 }
end

local function LookedAtCargo()
    local camera = FindFirstOf("PlayerController").PlayerCameraManager
    local from, turn = camera:GetCameraLocation(), camera:GetCameraRotation()
    local pitch, yaw = math.rad(turn.Pitch), math.rad(turn.Yaw)
    local dir = { X = math.cos(pitch) * math.cos(yaw), Y = math.cos(pitch) * math.sin(yaw), Z = math.sin(pitch) }
    local best, bestAt = nil, MARK_RANGE_CM
    for _, cargo in ipairs(Live("HeavyCargo")) do
        pcall(function()
            if Dist(cargo:K2_GetActorLocation(), from) > MARK_RANGE_CM then return end
            local centre, extent = CargoBox(cargo)
            local hit = RayBox(from, dir, centre, extent)
            if hit and hit < bestAt then best, bestAt = cargo, hit end
        end)
    end
    return best
end

local function ToggleMark()
    Halted = false
    local cargo = LookedAtCargo()
    local guid = cargo and CargoGuid(cargo)
    if not guid then
        Toast("Look at a piece of crane cargo to mark it")
        return
    end
    local area = cargo.CargoArea
    if not Valid(area) then
        Toast("That cargo is not on a dock or in a hold")
        return
    end
    if Manual[guid] then
        Manual[guid] = nil
        Toast("Mark removed from " .. ItemName(cargo))
    else
        Manual[guid] = IsHold(area) and "unload" or "load"  -- kept, even while the piece is passed across the hold
        Unreachable[guid] = nil        Complaint = nil  -- if the operator is stuck, have them say why again
        Toast(string.format("%s marked to go to the %s", ItemName(cargo), IsHold(area) and "dock" or "boat"))
    end
end

local function IsOurMarker(marker)
    local ok, ours = pcall(function()
        local title = marker.MarkerData.WidgetTitle:ToString()
        return title == TO_BOAT or title == TO_DOCK or title == HINT_MARK or title == HINT_UNMARK
    end)
    return ok and ours
end

local function SpawnMarker(cargo, title)
    if not Valid(MarkerClass) then
        for _, component in ipairs(FindAllOf("SasEmployeeMissionComponent") or {}) do
            local ok, class = pcall(function() return component.MissionMarkerClass end)
            if ok and Valid(class) and not Valid(MarkerClass) then MarkerClass = class end
        end
    end
    local controller = FindFirstOf("PlayerController")
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not Valid(MarkerClass) or not Valid(controller) or not Valid(statics) then return nil end
    local at = cargo:K2_GetActorLocation()
    local transform = { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
                        Translation = { X = at.X, Y = at.Y, Z = at.Z + 100 },
                        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }
    local marker = statics:BeginDeferredActorSpawnFromClass(controller, MarkerClass, transform, 1, nil, 0)
    if not Valid(marker) then return nil end
    statics:FinishSpawningActor(marker, transform, 0)
    pcall(function()
        local icon = StaticFindObject(MARKER_ICON)
        if not Valid(icon) then icon = LoadAsset(MARKER_ICON) end
        marker.MarkerData.Icon.ResourceObject = icon
        marker.MarkerData.Icon.ImageSize = { X = 86.0, Y = 86.0 }
    end)
    pcall(function() marker.MarkerData.MissionMarkerTag.TagName = FName(MARKER_TAG) end)
    local data = marker.MarkerData
    pcall(function() data.WidgetTitle = FText(title) end)
    pcall(function() data.Instigator = controller end)
    pcall(function() data.AttachedToActor = cargo end)
    pcall(function() data.Location = { X = at.X, Y = at.Y, Z = at.Z } end)
    pcall(function() marker:Update(marker.MarkerData) end)
    pcall(function() marker:K2_AttachToActor(cargo, FName("None"), 1, 1, 1, false) end)
    pcall(function() marker:SetVisibility(true) end)
    return marker
end

-- Keeps one marker over each hand-marked piece, and none over anything else.
local function UpdateMarkers()
    if not StraysCleared then
        StraysCleared = true
        for _, marker in ipairs(FindAllOf("MissionMarker") or {}) do  -- left by an earlier load of this mod
            if IsOurMarker(marker) then pcall(function() marker:K2_DestroyActor() end) end
        end
    end
    if next(Manual) == nil and next(Markers) == nil then return end
    local wanted = {}
    if next(Manual) ~= nil then
        for _, cargo in ipairs(Live("HeavyCargo")) do
            local guid = CargoGuid(cargo)
            if guid and Manual[guid] then
                local area = nil
                pcall(function() area = cargo.CargoArea end)
                if Valid(area) then wanted[guid] = { cargo = cargo, title = Manual[guid] == "unload" and TO_DOCK or TO_BOAT } end
            end
        end
    end
    for guid in pairs(Manual) do
        if not wanted[guid] then Manual[guid] = nil end  -- the piece is gone
    end
    for guid, shown in pairs(Markers) do
        local want = wanted[guid]
        if not want or want.title ~= shown.title or not Valid(shown.actor) then
            pcall(function() shown.actor:K2_DestroyActor() end)
            Markers[guid] = nil
        end
    end
    for guid, want in pairs(wanted) do
        if not Markers[guid] then
            local ok, marker = pcall(SpawnMarker, want.cargo, want.title)
            if ok and marker then Markers[guid] = { actor = marker, title = want.title } end
        end
    end
end

-- The hint. While a crane operator is on duty nearby, the piece you are looking at carries a small
-- marker of its own saying what F5 will do with it: mark it, or take its mark off. It is the piece
-- F5 acts on, so with stacked pieces you can see which one that is before pressing.
-- Shift+F5 switches the hint off and on; switched off, it stays off after a restart.
HINT_RANGE_CM = 3000
local Hint = nil  -- { cargo, title, actor }
HintOffPath = ScriptDir .. "\\..\\hint_off.txt"
HintOff = io.open(HintOffPath, "r") ~= nil
HintToggleWanted = false

local function OperatorNearby(here)
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        local ok, near = pcall(function()
            local slot = CraneSlot(comp)
            return slot and Valid(slot.CrewMember) and Dist(comp:GetOwner():K2_GetActorLocation(), here) < 10000
        end)
        if ok and near then return true end
    end
    return false
end

local function DropHint()
    if Hint then pcall(function() Hint.actor:K2_DestroyActor() end) end
    Hint = nil
end

local function UpdateHint()
    local here = FindFirstOf("PlayerController").PlayerCameraManager:GetCameraLocation()
    local cargo = not HintOff and OperatorNearby(here) and LookedAtCargo() or nil
    if cargo and Dist(cargo:K2_GetActorLocation(), here) > HINT_RANGE_CM then cargo = nil end
    if not cargo then
        DropHint()
        return
    end
    local guid = CargoGuid(cargo)
    local title = (guid and Manual[guid]) and HINT_UNMARK or HINT_MARK
    if Hint and Same(Hint.cargo, cargo) and Hint.title == title and Valid(Hint.actor) then return end
    DropHint()
    local ok, marker = pcall(SpawnMarker, cargo, title)
    if ok and marker then
        pcall(function() marker:K2_AddActorWorldOffset({ X = 0, Y = 0, Z = 120 }, false, {}, true) end)  -- above its other marker
        Hint = { cargo = cargo, title = title, actor = marker }
    end
end

-- STOP. Ctrl+Alt+S stops the crane operator at once: the piece being moved is let alone where it is (it may
-- still hang from the hook), every mark by hand is taken off, and nothing new is started, planner orders
-- included, until Ctrl+Alt+S is pressed again, or a new mark is made (F5, Ctrl+Alt+L, Ctrl+Alt+U).
Halted = false
StopWanted = false

function StopOperator()
    if Halted then
        Halted = false
        Rest = 1
        Toast("The crane operator carries on")
        return
    end
    Halted = true
    local was = Job ~= nil
    Job, Steer, Pending = nil, nil, nil
    for guid in pairs(Manual) do Manual[guid] = nil end
    pcall(Unslim)
    Log("STOP: the crane operator was stopped" .. (was and " in the middle of a piece" or ""))
    Toast(was and "Crane operator stopped. The piece may still hang from the hook; press Ctrl+Alt+S to carry on"
              or "Crane operator stopped. Press Ctrl+Alt+S to carry on")
end

RegisterKeyBind(Key.S, { ModifierKey.CONTROL, ModifierKey.ALT }, function() StopWanted = true end)

-- Load all / Unload all. Ctrl+Alt+L marks every piece standing on the docks near your boat to go aboard, and
-- Ctrl+Alt+U marks everything in your boat's hold to go ashore, the same marks F5 makes by hand, so the
-- operator works through them as usual (biggest first, and says when the hold or the dock is full). Pressing
-- the same key again, when everything is already marked, takes those marks off.
MARK_ALL_BOAT_CM = 6000    -- your boat's hold must be within this of you
MARK_ALL_DOCK_CM = 20000   -- dock cargo within this of the hold is marked to load
LoadAllWanted, UnloadAllWanted = false, false

function NearestHold(here)
    local best, bestDist = nil, MARK_ALL_BOAT_CM
    for _, area in ipairs(Live("CargoArea")) do
        if IsHold(area) then
            local d = Dist(area:K2_GetActorLocation(), here)
            if d < bestDist then best, bestDist = area, d end
        end
    end
    return best
end

-- Marks (or, when all are marked already, unmarks) the pieces that go the given way ("load" or "unload") for
-- the given hold. Returns how many were marked (negative: how many marks were taken off), and the total.
function MarkAll(way, hold)
    local origin = hold:K2_GetActorLocation()
    local pieces = {}
    for _, cargo in ipairs(Live("HeavyCargo")) do
        local guid = CargoGuid(cargo)
        local area = nil
        pcall(function() area = cargo.CargoArea end)
        if guid and Valid(area) then
            local candidate
            if way == "unload" then
                candidate = Same(area, hold)
            else
                candidate = not IsHold(area) and Dist(cargo:K2_GetActorLocation(), origin) < MARK_ALL_DOCK_CM
            end
            if candidate then pieces[#pieces + 1] = guid end
        end
    end
    local marked = 0
    for _, guid in ipairs(pieces) do
        if Manual[guid] == way then marked = marked + 1 end
    end
    if #pieces > 0 and marked == #pieces then
        for _, guid in ipairs(pieces) do Manual[guid] = nil end
        return -marked, #pieces
    end
    for _, guid in ipairs(pieces) do
        Manual[guid] = way
        Unreachable[guid] = nil
    end
    Complaint = nil  -- if the operator is stuck, have them say why again
    return #pieces, #pieces
end

local function MarkEverything(way)
    Halted = false
    local here = FindFirstOf("PlayerController").Pawn:K2_GetActorLocation()
    local hold = NearestHold(here)
    if not hold then
        Toast("Stand near your boat first: no boat's hold is within " .. MARK_ALL_BOAT_CM / 100 .. " m")
        return
    end
    local done, total = MarkAll(way, hold)
    if total == 0 then
        Toast(way == "load" and "There is nothing on the docks near the boat to load" or "The hold is empty")
    elseif done < 0 then
        Toast(string.format("Marks taken off %d piece(s)", -done))
    elseif way == "load" then
        Toast(string.format("%d piece(s) marked to load", done))
    else
        Toast(string.format("%d piece(s) marked to unload", done))
    end
end

RegisterKeyBind(Key.L, { ModifierKey.CONTROL, ModifierKey.ALT }, function() LoadAllWanted = true end)
RegisterKeyBind(Key.U, { ModifierKey.CONTROL, ModifierKey.ALT }, function() UnloadAllWanted = true end)

local MarkWanted = false
RegisterKeyBind(Key.F5, function()
    MarkWanted = true
end)
RegisterKeyBind(Key.F5, { ModifierKey.SHIFT }, function()
    HintToggleWanted = true
end)

local SpotWanted = false
RegisterKeyBind(Key.H, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    SpotWanted = true
end)

---------------------------------------------------------------------------------------------------

local Ticks = 0

-- Timing telemetry. A frame hitch is a call that takes long on the game thread, so every heavy
-- function is timed. PROFILE: lines say, once a minute, which functions took the most in total; SLOW:
-- lines are one call, or one whole step of the mod, that held the game up for too long.
SLOW_CALL_MS = 25
Prof = {}          -- name -> { calls, total, worst } since the last report
ProfReportAt = os.clock() + 60

function ProfAdd(name, ms)
    local p = Prof[name]
    if not p then
        p = { calls = 0, total = 0, worst = 0 }
        Prof[name] = p
    end
    p.calls, p.total, p.worst = p.calls + 1, p.total + ms, math.max(p.worst, ms)
    if ms >= SLOW_CALL_MS then Log(string.format("SLOW: %s took %.0f ms", name, ms)) end
end

function Profile(name, fn)
    return function(...)
        local t0 = os.clock()
        local r = table.pack(fn(...))
        ProfAdd(name, (os.clock() - t0) * 1000)
        return table.unpack(r, 1, r.n)
    end
end

function ProfReport()
    if os.clock() < ProfReportAt then return end
    ProfReportAt = os.clock() + 60
    local rows = {}
    for name, p in pairs(Prof) do rows[#rows + 1] = { name = name, p = p } end
    Prof = {}
    if #rows == 0 then return end
    table.sort(rows, function(a, b) return a.p.total > b.p.total end)
    local parts = {}
    for i = 1, math.min(#rows, 8) do
        local r = rows[i]
        parts[#parts + 1] = string.format("%s %d call(s) %.0f ms total, worst %.0f", r.name, r.p.calls, r.p.total, r.p.worst)
    end
    Log("PROFILE (last minute): " .. table.concat(parts, " | "))
end

-- The heavy calls, timed wherever they are made from. In a function of its own, which has its own
-- allowance of local variables.
function InstallProfiling()
for _, spec in ipairs({
    { "NextMove", function() return NextMove end, function(f) NextMove = f end },
    { "UpdateMarkers", function() return UpdateMarkers end, function(f) UpdateMarkers = f end },
    { "UpdateHint", function() return UpdateHint end, function(f) UpdateHint = f end },
    { "Boxes", function() return Boxes end, function(f) Boxes = f end },
    { "FreeSpots", function() return FreeSpots end, function(f) FreeSpots = f end },
    { "DockAreas", function() return DockAreas end, function(f) DockAreas = f end },
    { "ClearAbove", function() return ClearAbove end, function(f) ClearAbove = f end },
    { "PlanTidy", function() return PlanTidy end, function(f) PlanTidy = f end },
    { "PlaceInReach", function() return PlaceInReach end, function(f) PlaceInReach = f end },
    { "NeedsStaging", function() return NeedsStaging end, function(f) NeedsStaging = f end },
    { "StagingPlace", function() return StagingPlace end, function(f) StagingPlace = f end },
    { "Relay", function() return Relay end, function(f) Relay = f end },
    { "TravelTip", function() return TravelTip end, function(f) TravelTip = f end },
    { "WatchBumps", function() return WatchBumps end, function(f) WatchBumps = f end },
    { "CraneSounds", function() return CraneSounds end, function(f) CraneSounds = f end },
    { "SteadyStep", function() return SteadyStep end, function(f) SteadyStep = f end },
    { "EnsurePositions", function() return EnsurePositions end, function(f) EnsurePositions = f end },
    { "TendPositions", function() return TendPositions end, function(f) TendPositions = f end },
    { "HookChart", function() return HookChart end, function(f) HookChart = f end },
    { "LookedAtCargo", function() return LookedAtCargo end, function(f) LookedAtCargo = f end },
    { "FindPlace", function() return FindPlace end, function(f) FindPlace = f end },
    { "FindFloating", function() return FindFloating end, function(f) FindFloating = f end },
    { "JobPoints", function() return JobPoints end, function(f) JobPoints = f end },
    { "Live", function() return Live end, function(f) Live = f end },
}) do
    local current = spec[2]()
    if type(current) == "function" then spec[3](Profile(spec[1], current)) end
end
end
InstallProfiling()

-- A gap between two steps much longer than the timer's own interval means the game thread was held
-- up by something other than this mod. LastTickAt is the wall clock time of the step before.
LastTickAt = nil

function Lap(laps, name)
    local now = os.clock()
    laps[#laps + 1] = string.format("%s %.0f", name, (now - laps.at) * 1000)
    laps.at = now
end

-- What an earlier copy of the mod may have left behind: a piece let go with its collision off,
-- because the copy was replaced while the piece was on the hook. Pieces a crane is holding now keep
-- theirs off.
function RestoreAfterReload()
    local held = {}
    for _, crane in ipairs(FindAllOf("CargoCrane") or {}) do
        pcall(function()
            local cargo = crane.AttachedCargo
            if Valid(cargo) then held[cargo:GetAddress()] = true end
        end)
    end
    local fixed = 0
    for _, cargo in ipairs(FindAllOf("HeavyCargo") or {}) do
        pcall(function()
            if not cargo:GetFullName():find("Default__", 1, true) and not held[cargo:GetAddress()]
                and not cargo:GetActorEnableCollision() then
                cargo:SetActorEnableCollision(true)
                fixed = fixed + 1
            end
        end)
    end
    if fixed > 0 then Log("after a reload: collision switched back on for " .. fixed .. " piece(s) left without it") end
end

LoopInGameThreadWithDelay(TICK_MS, function()
    if Stale() then return false end
    local stepStart = os.clock()
    local laps = { at = stepStart }
    if LastTickAt and stepStart - LastTickAt > 1.0 then
        Log(string.format("HITCH: %.1f s since the last step; the game thread was away (job: %s, steering: %s)",
            stepStart - LastTickAt, Job and tostring(Job.phase) or "none", Steer and "yes" or "no"))
    end
    LastTickAt = stepStart
    Ticks = Ticks + 1
    -- The dock's bollards are checked once the world is there to check: a slow load can leave no mooring
    -- point or piece of cargo to see at 40 s, and a check that saw none must not count. Until it has seen
    -- both it looks again every 10 s, and a piece found on the hook waits for it (see NextMove).
    if not MooringChecked and stepStart - LoadedAt > 40 and stepStart >= NextMooringTry then
        NextMooringTry = stepStart + 10
        local ok, count, points, pieces = pcall(RepairMooring)
        if ok and points > 0 and pieces > 0 then
            MooringChecked = os.clock()
            if count > 0 then Toast("Put " .. count .. " dock bollard(s) back where they belong") end
        else
            Log("MOORING: the world is not loaded yet (" .. tostring(points) .. " mooring point(s), " .. tostring(pieces) .. " piece(s) of cargo); looking again in 10 s")
        end
    end
    if #MooringFixed > 0 then pcall(MooringFixedTick) end
    if #MooringLooks > 0 then pcall(MooringLooksTick) end
    if #DropWatch > 0 then pcall(DropWatchTick) end
    if #Requests > 0 then
        local waiting = {}
        for _, request in ipairs(Requests) do
            if request.wait > 0 then
                request.wait = request.wait - 1
                waiting[#waiting + 1] = request
            elseif request.kind == "toggle" then
                local ok, err = pcall(ToggleOperator)
                if not ok then Log("toggle failed: " .. tostring(err):gsub("\n.*", "")) end
            else
                local ok, err = pcall(HandleRequest, request)
                if not ok then Log("chart request failed: " .. tostring(err):gsub("\n.*", "")) end
            end
        end
        Requests = waiting
    end
    if StopWanted then
        StopWanted = false
        local ok, err = pcall(StopOperator)
        if not ok then Log("stopping failed: " .. (tostring(err):gsub("\n.*", ""))) end
        pcall(UpdateMarkers)
    end
    for way, wanted in pairs({ load = LoadAllWanted, unload = UnloadAllWanted }) do
        if wanted then
            if way == "load" then LoadAllWanted = false else UnloadAllWanted = false end
            local ok, err = pcall(MarkEverything, way)
            if not ok then Log("marking everything failed: " .. (tostring(err):gsub("\n.*", ""))) end
            DropHint()
            pcall(UpdateMarkers)
        end
    end
    if MarkWanted then
        MarkWanted = false
        local ok, err = pcall(ToggleMark)
        if not ok then Log("marking failed: " .. tostring(err):gsub("\n.*", "")) end
        DropHint()
        pcall(UpdateMarkers)
    end
    if HintToggleWanted then
        HintToggleWanted = false
        HintOff = not HintOff
        if HintOff then
            local file = io.open(HintOffPath, "w")
            if file then file:close() end
        else
            os.remove(HintOffPath)
        end
        Toast(HintOff and "Cargo hint off (Shift+F5 turns it back on)" or "Cargo hint on")
        Log("the F5 hint is now " .. (HintOff and "off" or "on"))
    end
    if CrewDumpWanted then
        CrewDumpWanted = false
        pcall(DumpCrew, "asked for with Ctrl+Alt+D")
    end
    if TowsWanted then
        TowsWanted = false
        pcall(InspectTows)
    end
    if SpotWanted then
        SpotWanted = false
        local ok, err = pcall(SetSpotHere)
        if not ok then Log("setting the spot failed: " .. tostring(err):gsub("\n.*", "")) end
    end
    Lap(laps, "requests")
    if Ticks == 6 then pcall(RestoreAfterReload) end
    if Ticks % 2 == 0 then pcall(UpdateMarkers) end
    Lap(laps, "markers")
    pcall(UpdateHint)
    pcall(WatchDocking)
    Lap(laps, "hint")
    if Ticks % 4 == 0 then
        pcall(EnsurePositions)
        pcall(TendPositions)
        pcall(HookChart)
    end
    Lap(laps, "positions")
    local ok, err = pcall(Work)
    if not ok then
        Job = nil
        Rest = math.floor(10000 / TICK_MS)
        Log("work failed: " .. tostring(err):gsub("\n.*", ""))
    end
    Lap(laps, "work")
    local took = (os.clock() - stepStart) * 1000
    if took >= 25 then Log(string.format("SLOW step breakdown (ms): %s", table.concat(laps, ", "))) end
    ProfAdd("whole 0.5 s step", took)
    ProfReport()
    return false
end)

LoopInGameThreadWithDelay(MOTION_MS, function()
    if Stale() then return false end
    local stepStart = os.clock()
    pcall(SteadyStep)
    local ok, err = pcall(JobStep)
    if not ok then
        Job, Steer = nil, nil
        Rest = math.floor(10000 / TICK_MS)
        Log("moving a piece failed: " .. tostring(err):gsub("\n.*", ""))
    end
    ok, err = pcall(SteerStep)
    if not ok then
        Steer = nil
        Log("steering the crane failed: " .. tostring(err):gsub("\n.*", ""))
    end
    ProfAdd("whole 0.1 s step", (os.clock() - stepStart) * 1000)
    return false
end)

WriteNoRoom()  -- nothing is reported as not fitting at the start
Log("loaded: cargo boats get a Crane Operator crew position; Ctrl+Alt+O seats or unseats the operator; F5 marks the cargo you look at")

-- For the tests (tests/lua_harness.py): when a test sets SAS_TEST before loading this script, the local
-- functions and state the tests need are handed out in SasTest. In the game SAS_TEST is never set, and
-- this does nothing.
if SAS_TEST then
    SasTest = {
        Turn = Turn, Clamp = Clamp, DockCrane = DockCrane, DeckCrane = DeckCrane, ModelOf = ModelOf,
        GetRest = function() return Rest end, SetRest = function(n) Rest = n end, WatchBoat = WatchBoat,
        StopOperator = StopOperator, Work = Work, GetHalted = function() return Halted end,
        MarkAll = MarkAll, GetManual = function() return Manual end, Boxes = Boxes, Footing = Footing, FloorGap = FloorGap, PlanSpace = PlanSpace, Neatest = Neatest, ReadMarks = ReadMarks,
        JobStep = JobStep, SteerStep = SteerStep,
        SetJob = function(job) Job, Steer = job, nil end,
        GetJob = function() return Job end,
        GetSteer = function() return Steer end,
    }
end
