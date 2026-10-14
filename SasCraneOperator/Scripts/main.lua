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

local ScriptDir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
local OperatorsPath = ScriptDir .. "\\..\\operators.txt"
local SpotsPath = ScriptDir .. "\\..\\spots.txt"
local MarksPath = ScriptDir .. "\\..\\..\\SasLogistics\\highlight.txt"

local CATEGORY = "/Game/ShipsAtSea/Crew/CrewTaskCategories/DA_CrewTaskCategory_Engineering.DA_CrewTaskCategory_Engineering"
local GROUP_NAME = "Crane Operator"
local TOAST_CHANNEL = "Channel.Toast.Simple.Info"
local TICK_MS = 500
local MOTION_MS = 100            -- how often the crane's joints are steered
local CRANE_REACH_CM = 10000     -- the boat's hold must be this close to a dock crane
local CARGO_REACH_CM = 8000      -- dock cargo and dock areas must be this close to the crane
local MAX_SPEED_CM = 60          -- if the game will not say whether the boat is docked: still enough to count as it

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
    group.BoatCrewComponent = comp
    group.CrewTaskCategory = category
    group.GroupName = FText(GROUP_NAME)
    slot.CrewGroup = group
    slot.SlotId = { TaskGroupCategory = category, SlotIndex = 0 }
    slot.PrimarySlot = slot
    slot.bAllowTaskAssignment = true
    group.CrewSlots = { slot }
    comp.CrewTaskCategories = { category }
    comp.CrewGroups = { group }
    comp.SlotMap:Add({ TaskGroupCategory = category, SlotIndex = 0 }, slot)
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

-- Cargo boats with no crew positions of their own get the position; boats that have crew are left alone.
local function EnsurePositions()
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        pcall(function()
            local boat = comp:GetOwner()
            if not Valid(boat) or not ClassName(boat):find("Cargo_Boat", 1, true) then return end
            if Count(comp.CrewGroups) > 0 then return end
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

local function Seat(member, slot)
    slot.CrewMember = member
    member.CrewSlot = slot
    member.CrewSlotId = { TaskGroupCategory = slot.SlotId.TaskGroupCategory, SlotIndex = 0 }
    pcall(function() slot:OnRep_CrewMember(nil) end)
    pcall(function() member:OnRep_CrewSlot() end)
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

-- Keeps every position consistent: an operator who has left the boat is taken off, and a remembered
-- operator who is aboard and resting is seated again (which is how a loaded save gets them back).
local ChartTries = {}

local function TendPositions()
    -- A chart that still shows no groups for a boat that now has the position reads the boat again.
    for _, chart in ipairs(Live("SasCrewChartViewModel")) do
        pcall(function()
            local comp = chart:GetBoatCrewComponent()
            if Valid(comp) and Count(chart.CrewGroups) == 0 and CraneSlot(comp) then
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
            local member = slot.CrewMember
            if Valid(member) then
                if not Same(member.Boat, boat) or not Same(member.CrewSlot, slot) then Unseat(slot, false) end
                return
            end
            Each(comp.CrewMembers, function(candidate)
                if not Valid(slot.CrewMember) and Operators[MemberName(candidate)] and Resting(candidate) then
                    Seat(candidate, slot)
                    Toast(MemberName(candidate) .. " is back on crane duty")
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
        if not Valid(member) or not IsOurSlot(slot) or Same(slot.CrewMember, member) then return end
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

local Hooks = {
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
        if not Hooked[path] and pcall(RegisterHook, path, function(...) pcall(handler, ...) end) then
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
        local guid, kind = line:match("^(%x+)%s*(%a?)%s*$")
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

local function FindPlace(area, cargo)
    local item = cargo:GetRepresentedInventoryItem()
    local zero = { position = { X = 0, Y = 0, Z = 0 }, Rotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } }
    local out = {}
    local found = area:GetInventory():FindPlaceForInventoryItemInGrid(item, out,
        { DesiredGridTransform = zero, PositionRule = 1, RotationRule = 1 }, {})
    out = out.OutGridTransform or out
    if not found or out.position == nil then return nil end
    return { position = { X = out.position.X, Y = out.position.Y, Z = out.position.Z },
             rotation = { Pitch = out.Rotation.Pitch, Yaw = out.Rotation.Yaw, Roll = out.Rotation.Roll } }
end

-- Is the boat made fast to the dock, with the pull-in finished? If the game will not say, a boat
-- that is all but still counts.
local function IsDocked(boat)
    local ok, docked = pcall(function()
        local docking = boat.DockingComponent
        return docking:IsDocked() and not docking.bIsPulling
    end)
    if ok then return docked end
    local velocity = boat:GetVelocity()
    return math.sqrt(velocity.X ^ 2 + velocity.Y ^ 2) <= MAX_SPEED_CM
end

-- Where the docked boat with a seated operator lies: its hold, the dock crane in reach, and the dock areas.
local function WorkSite(comp)
    local boat = comp:GetOwner()
    if not IsDocked(boat) then return nil end
    local hold = nil
    for _, area in ipairs(Live("CargoArea")) do
        if not hold and IsHold(area) and Same(area:GetAttachParentActor(), boat) then hold = area end
    end
    if not hold then return nil end
    local at = hold:K2_GetActorLocation()
    local crane, craneDist = nil, CRANE_REACH_CM
    for _, candidate in ipairs(Live("CargoCrane")) do
        local d = Dist(candidate:K2_GetActorLocation(), at)
        if d < craneDist and not Valid(candidate:GetAttachParentActor()) then crane, craneDist = candidate, d end
    end
    if not crane then return nil end
    return { boat = boat, hold = hold, crane = crane }
end

-- Dock areas in the crane's reach, the port's own cargo area first.
local function DockAreas(site)
    local at = site.crane:K2_GetActorLocation()
    local areas = {}
    for _, area in ipairs(Live("CargoArea")) do
        if not IsHold(area) then
            local d = Dist(area:K2_GetActorLocation(), at)
            if d < CARGO_REACH_CM then
                local rank = ClassName(area) == "BP_CargoArea_C" and 0 or 1
                areas[#areas + 1] = { area = area, order = rank * 1e9 + d }
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

-- The lowest floating piece in the area and where it comes to rest when let straight down, or nil.
local function FindFloating(area)
    local inventory = area:GetInventory()
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
    if not found then return nil end

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
local function NextSettle(site)
    local areas = { site.hold }
    for _, dock in ipairs(DockAreas(site)) do areas[#areas + 1] = dock.area end
    for _, area in ipairs(areas) do
        local ok, cargo, place = pcall(FindFloating, area)
        if ok and cargo then
            local guid = CargoGuid(cargo) or "?"
            SettleTries[guid] = (SettleTries[guid] or 0) + 1
            if SettleTries[guid] <= 3 then
                return { cargo = cargo, to = area, place = place, settle = true }
            end
        end
    end
    return nil
end

-- The next piece to move: unloading first, so that the hold has room for what is loaded after, and
-- from the top of a stack down, so that as little as possible is left hanging.
local function NextMove(site, load, unload)
    local at = site.crane:K2_GetActorLocation()
    local toUnload, toLoad = {}, {}
    for _, cargo in ipairs(Live("HeavyCargo")) do
        local guid = CargoGuid(cargo)
        local area = nil
        pcall(function() area = cargo.CargoArea end)
        if guid and Valid(area) then
            if unload[guid] and Same(area, site.hold) then
                toUnload[#toUnload + 1] = cargo
            elseif load[guid] and not IsHold(area) and Dist(cargo:K2_GetActorLocation(), at) < CARGO_REACH_CM then
                toLoad[#toLoad + 1] = cargo
            end
        end
    end
    local function topFirst(a, b) return Height(a) > Height(b) end
    table.sort(toUnload, topFirst)
    table.sort(toLoad, topFirst)
    local docks = #toUnload > 0 and DockAreas(site) or {}
    for _, cargo in ipairs(toUnload) do
        for _, dock in ipairs(docks) do
            local place = FindPlace(dock.area, cargo)
            if place then return { cargo = cargo, to = dock.area, place = place } end
        end
    end
    for _, cargo in ipairs(toLoad) do
        local place = FindPlace(site.hold, cargo)
        if place then return { cargo = cargo, to = site.hold, place = place } end
    end
    if #toLoad > 0 then return nil, "no room in the hold" end
    if #toUnload > 0 then return nil, "no room on the dock" end
    return nil
end

local Manual = {}        -- cargo guid -> true, for pieces marked by hand with F5
local Job = nil          -- the piece being moved, see StartJob
local Rest = 0           -- ticks until the operator starts the next piece
local Working = false    -- was there work when last looked
local Moved = 0
local Complaint = nil

-- The operator's place at the crane. While there is work they sit in the dock crane's seat, put
-- there with the crane's own driver component; when it is done they go back to where they stood on
-- the boat. A crew member cannot walk there: the boat's deck has no walkable route for them.

local SEAT_SECONDS = 3   -- in the seat before the first lift
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
-- Moving the crane. The stationary dock crane has four joints that matter here, each of which goes
-- smoothly to whatever value it is given: the platform swivels (degrees), the boom is hoisted
-- (degrees, 0 to 50), the boom telescopes (0 to 230, two centimetres a unit) and the cable drum pays
-- out (centimetres, 10 to 1000). The figures below were measured on the crane in game: the boom is
-- 445 cm long from a pivot 25 cm behind and 335 cm above the crane's origin, and lies 2.1 degrees
-- below level at hoist 0; the hook hangs 53 cm plus the paid-out cable below the boom's tip.

local CELL_CM = 25
local BOOM_CM, BOOM_BACK_CM, BOOM_UP_CM, BOOM_DROOP_DEG = 445, 25, 335, 2.1
local TELESCOPE_CM_PER_UNIT, TELESCOPE_MAX, HOIST_MAX = 2, 230, 50
local HOOK_BELOW_TIP_CM, DRUM_MIN, DRUM_MAX = 53, 10, 1000
local JOINT = { swivel = "Joint_SwivelPlatform", hoist = "Joint_BoomHoist", telescope = "Joint_TelescopicBoom", drum = "Joint_CableDrum" }
local SPEED = { swivel = 35, hoist = 20, telescope = 90, drum = 120 }   -- units a second
local CLOSE = { swivel = 1.5, hoist = 1.0, telescope = 4, drum = 8 }    -- near enough to count as there
local PARKED = { swivel = 0, hoist = 0, telescope = 0, drum = DRUM_MIN }
local PHASE_SECONDS = 12  -- a step that has not finished by then is given up on and the next one starts

local function Turn(degrees)  -- into -180 .. 180
    return (degrees + 180) % 360 - 180
end

local function Clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Does this crane have the joints the figures above describe?
local function CanSteer(crane)
    return ClassName(crane):find("StationaryCrane_T01", 1, true) ~= nil and Valid(crane[JOINT.swivel]) and Valid(crane[JOINT.drum])
end

-- The swivel, hoist and telescope that put the boom's tip over a point, and how high the tip then is.
local function Reach(crane, point)
    local base, yaw = crane:K2_GetActorLocation(), crane:K2_GetActorRotation().Yaw
    local dx, dy = point.X - base.X, point.Y - base.Y
    local out = math.sqrt(dx * dx + dy * dy)
    local level = math.cos(math.rad(BOOM_DROOP_DEG))
    local hoist, telescope = 0, 0
    local need = (out + BOOM_BACK_CM) / level   -- boom length that reaches it with the boom down
    if need >= BOOM_CM then
        telescope = Clamp((need - BOOM_CM) / TELESCOPE_CM_PER_UNIT, 0, TELESCOPE_MAX)
    else  -- closer than the shortest boom lying flat: raise it
        hoist = Clamp(BOOM_DROOP_DEG + math.deg(math.acos(Clamp((out + BOOM_BACK_CM) / BOOM_CM, 0, 1))), 0, HOIST_MAX)
    end
    local length = BOOM_CM + telescope * TELESCOPE_CM_PER_UNIT
    local tipZ = base.Z + BOOM_UP_CM + length * math.sin(math.rad(hoist - BOOM_DROOP_DEG))
    return { swivel = Turn(math.deg(math.atan(dy, dx)) - yaw), hoist = hoist, telescope = telescope }, tipZ
end

-- The whole pose that puts the hook at a point.
local function HookAt(crane, point)
    local pose, tipZ = Reach(crane, point)
    pose.drum = Clamp(tipZ - HOOK_BELOW_TIP_CM - point.Z, DRUM_MIN, DRUM_MAX)
    return pose
end

local Steer = nil  -- { crane, goal = { swivel, hoist, telescope, drum } }: where the joints are being taken

local function There(crane, goal)
    for part, name in pairs(JOINT) do
        if goal[part] ~= nil then
            local off = goal[part] - crane[name]:GetCurrentValue()
            if part == "swivel" then off = Turn(off) end
            if math.abs(off) > CLOSE[part] then return false end
        end
    end
    return true
end

-- One step of every joint towards its goal, at that joint's speed.
local function SteerStep()
    local s = Steer
    if not s then return end
    if not Valid(s.crane) then
        Steer = nil
        return
    end
    for part, name in pairs(JOINT) do
        if s.goal[part] ~= nil then
            local joint = s.crane[name]
            local now = joint:GetCurrentValue()
            local off = s.goal[part] - now
            if part == "swivel" then off = Turn(off) end
            local step = SPEED[part] * MOTION_MS / 1000 * 2  -- aimed a little ahead: the joint eases towards it
            local to = now + Clamp(off, -step, step)
            if part == "swivel" then to = Turn(to) end
            joint:SetTargetValue(to)
        end
    end
    if There(s.crane, s.goal) then Steer = nil end
end

-- Where an area's grid sits in the world: its corner, and the directions its X and Y cells run in.
local function GridFrame(area)
    local origin = area.OriginComponent
    local at, yaw = origin:K2_GetComponentLocation(), math.rad(origin:K2_GetComponentRotation().Yaw)
    return at, { X = math.cos(yaw), Y = math.sin(yaw) }, { X = -math.sin(yaw), Y = math.cos(yaw) }
end

-- The cell a piece stands on in its area and how many cells it covers each way.
local function Footing(area, cargo)
    local item = cargo:GetRepresentedInventoryItem():GetAddress()
    local low, high = { X = math.huge, Y = math.huge, Z = math.huge }, { X = -math.huge, Y = -math.huge, Z = -math.huge }
    area:GetInventory().CellsOccupancyMap:ForEach(function(key, value)
        local held = value:get()
        if Valid(held) and held:GetAddress() == item then
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
    return { Z = low.Z, across = high.X - low.X + 1, along = high.Y - low.Y + 1, yaw = yaw }
end

-- Works out where the hook has to go to pick the piece up and to set it down, and starts the crane
-- towards it. A crane this mod cannot steer, or a piece it cannot place in the world, is moved the
-- plain way: lifted where it stands and set down a few seconds later.
local function StartJob(site, move)
    local crane, cargo = site.crane, move.cargo
    local job = { crane = crane, cargo = cargo, to = move.to, place = move.place, settle = move.settle,
                  guid = CargoGuid(cargo), phase = "plain", ticks = 0 }
    local ok = pcall(function()
        if not CanSteer(crane) then return end
        local from = cargo.CargoArea
        local footing = Footing(from, cargo)
        if not footing then return end
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
        job.pick = { X = hookAt.X, Y = hookAt.Y, Z = top + 15 }  -- just above it, not pressing on it
        job.drop = { X = toAt.X + across.X * gx + along.X * gy, Y = toAt.Y + across.Y * gx + along.Y * gy,
                     Z = toAt.Z + move.place.position.Z * CELL_CM + hookUp }
        job.phase = "clear"
    end)
    if not ok then job.phase = "plain" end
    Job = job
end

local function Goto(job, goal)
    Steer = { crane = job.crane, goal = goal }
    job.ticks = 0
end

local function SetDown(job)
    if Valid(job.crane) and Valid(job.cargo) and Same(job.crane.AttachedCargo, job.cargo) then
        job.crane:ServerDetachCargo(job.to, job.place.position, job.place.rotation)
        if not job.settle then
            Moved = Moved + 1
            if job.guid then Manual[job.guid] = nil end  -- done; without this it would be carried straight back
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

    if job.phase == "plain" then
        if job.ticks == 1 then job.crane:ServerAttachCargo(job.cargo) end
        if seconds >= 4 then
            SetDown(job)
            Job, Rest = nil, math.floor(8000 / TICK_MS)
        end
    elseif job.phase == "clear" then          -- hook up out of the way first
        Goto(job, { drum = DRUM_MIN })
        job.phase = "to pick"
    elseif job.phase == "to pick" and arrived then
        local pose = Reach(job.crane, job.pick)
        pose.drum = DRUM_MIN
        Goto(job, pose)
        job.phase = "lower to pick"
    elseif job.phase == "lower to pick" and arrived then
        Goto(job, HookAt(job.crane, job.pick))
        job.phase = "attach"
    elseif job.phase == "attach" and arrived then
        job.crane:ServerAttachCargo(job.cargo)
        job.ticks = 0
        job.phase = "lift"
    elseif job.phase == "lift" and seconds >= 0.8 then
        Goto(job, { drum = DRUM_MIN })
        job.phase = "to drop"
    elseif job.phase == "to drop" and arrived then
        local pose = Reach(job.crane, job.drop)
        pose.drum = DRUM_MIN
        Goto(job, pose)
        job.phase = "lower to drop"
    elseif job.phase == "lower to drop" and arrived then
        Goto(job, HookAt(job.crane, job.drop))
        job.phase = "set down"
    elseif job.phase == "set down" and arrived then
        SetDown(job)
        job.ticks = 0
        job.phase = "release"
    elseif job.phase == "release" and seconds >= 0.6 then
        ClearGhost(job.to)
        Goto(job, { drum = DRUM_MIN })
        job.phase = "done"
    elseif job.phase == "done" and arrived then
        ClearGhost(job.to)
        Job, Rest = nil, math.floor(1000 / TICK_MS)
    end
end

local ParkTries = 0

local function Work()
    if not StrandedChecked then
        StrandedChecked = true
        RecoverStranded()
    end
    if Job then return end  -- the piece in hand is seen to by JobStep
    if Rest > 0 then
        Rest = Rest - 1
        return
    end
    Rest = math.floor(2000 / TICK_MS)  -- look for work every two seconds when idle

    local site, operator, character = nil, nil, nil
    for _, comp in ipairs(Live("SasBoatCrewComponent")) do
        if not site then
            pcall(function()
                local slot = CraneSlot(comp)
                if slot and Valid(slot.CrewMember) then
                    site = WorkSite(comp)
                    operator = site and MemberName(slot.CrewMember) or nil
                    character = site and slot.CrewMember.Character or nil
                end
            end)
        end
    end
    -- Someone else in the seat (you, usually) means the crane is taken; the operator in it does not.
    local driver = site and CraneDriver(site.crane) or nil
    local taken = driver ~= nil and not Same(driver, character)
    if AtCrane and (not site or taken or not Same(AtCrane.crane, site.crane) or not Same(AtCrane.character, character)) then
        LeaveCrane()  -- the boat has left, the operator was changed, or the crane is no longer theirs
    end
    if site and not AtCrane then pcall(NoteSpot, operator, character, site.boat) end
    local move, complaint = nil, nil
    if site and not taken and site.crane:IsPowered() then
        local held = site.crane.AttachedCargo
        if Valid(held) then
            -- A piece the crane would not set down where it was sent: put it wherever its area has room.
            local back = Valid(held.CargoArea) and held.CargoArea or site.hold
            local place = FindPlace(back, held)
            if place then
                Log("a piece was left on the hook, setting it down where there is room")
                site.crane:ServerDetachCargo(back, place.position, place.rotation)
            end
            return
        end
        move = NextSettle(site)
        if not move then
            local load, unload, count = ReadMarks()
            for guid in pairs(Manual) do  -- which way a hand-marked piece goes depends on where it is
                load[guid], unload[guid], count = true, true, count + 1
            end
            if count > 0 then move, complaint = NextMove(site, load, unload) end
        end
    end
    if move and not AtCrane and Valid(character) then
        EnterCrane(site, character, operator)
        Rest = math.floor(SEAT_SECONDS * 1000 / TICK_MS)
        return
    end
    if not move and AtCrane then
        -- Put the crane back as it was found before getting out of the seat.
        local crane = AtCrane.crane
        if Valid(crane) and CanSteer(crane) and not There(crane, PARKED) and ParkTries < 15 then
            ParkTries = ParkTries + 1
            Steer = { crane = crane, goal = PARKED }
            Rest = math.floor(1000 / TICK_MS)
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
        Complaint = nil
        StartJob(site, move)  -- reads the piece's ID before any lift: a piece on the hook no longer answers
        return
    end
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

local MARK_RANGE_CM = 8000
local TO_BOAT, TO_DOCK = "TO BOAT", "TO DOCK"
local MARKER_ICON = "/Game/ShipsAtSea/UI/WorldMap/Materials/Circle/MI_CargoMapIcon_Green.MI_CargoMapIcon_Green"
local MARKER_TAG = "UIMapMarker.Type.Marker.Mission.Cargo.M"
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
        return centre, { X = extent.X + 10, Y = extent.Y + 10, Z = extent.Z + 10 }
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
        Manual[guid] = true
        Toast(string.format("%s marked to go to the %s", ItemName(cargo), IsHold(area) and "dock" or "boat"))
    end
end

local function IsOurMarker(marker)
    local ok, ours = pcall(function()
        local title = marker.MarkerData.WidgetTitle:ToString()
        return title == TO_BOAT or title == TO_DOCK
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
                if Valid(area) then wanted[guid] = { cargo = cargo, title = IsHold(area) and TO_DOCK or TO_BOAT } end
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

local MarkWanted = false
RegisterKeyBind(Key.F5, function()
    MarkWanted = true
end)

local SpotWanted = false
RegisterKeyBind(Key.H, { ModifierKey.CONTROL, ModifierKey.ALT }, function()
    SpotWanted = true
end)

---------------------------------------------------------------------------------------------------

local Ticks = 0

LoopInGameThreadWithDelay(TICK_MS, function()
    Ticks = Ticks + 1
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
    if MarkWanted then
        MarkWanted = false
        local ok, err = pcall(ToggleMark)
        if not ok then Log("marking failed: " .. tostring(err):gsub("\n.*", "")) end
        pcall(UpdateMarkers)
    end
    if SpotWanted then
        SpotWanted = false
        local ok, err = pcall(SetSpotHere)
        if not ok then Log("setting the spot failed: " .. tostring(err):gsub("\n.*", "")) end
    end
    if Ticks % 2 == 0 then pcall(UpdateMarkers) end
    if Ticks % 4 == 0 then
        pcall(EnsurePositions)
        pcall(TendPositions)
        pcall(HookChart)
    end
    local ok, err = pcall(Work)
    if not ok then
        Job = nil
        Rest = math.floor(10000 / TICK_MS)
        Log("work failed: " .. tostring(err):gsub("\n.*", ""))
    end
    return false
end)

LoopInGameThreadWithDelay(MOTION_MS, function()
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
    return false
end)

Log("loaded: cargo boats get a Crane Operator crew position; Ctrl+Alt+O seats or unseats the operator; F5 marks the cargo you look at")
