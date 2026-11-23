--!strict
-- @discord: nuttynutella
-- @robloxId: Chandalatish
-- Harpoon rope. A player shoots a harpoon; if it sticks in another ship, a floating drowned or a monster, a rope
-- links that thing to the shooter's ship. Players on the reel shorten or lengthen the rope, and a tight rope pulls
-- both ends together. It is NOT a RopeConstraint: physics ropes go unstable on huge or welded models, so the rope
-- is just a number (length) checked every frame against the real distance between its two ends.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AmmoConfig = require(Shared.Config.Ammo)
local Ballistics = require(Shared.Logic.Ballistics)
local Cooldowns = require(Shared.Logic.Cooldowns)
local Log = require(Shared.Log)
local Schema = require(Shared.Logic.Schema)
local Tether = require(Shared.Logic.Tether)
local TetherConfig = require(Shared.Config.Tether)
local DebugService = require(script.Parent.Parent.Core.DebugService)
local EffectsService = require(script.Parent.Parent.Core.EffectsService)
local InteractionService = require(script.Parent.Parent.Core.InteractionService)
local NetService = require(script.Parent.Parent.Core.NetService)
local DrownedService = require(script.Parent.DrownedService)
local EnemyService = require(script.Parent.EnemyService)
local InventoryService = require(script.Parent.InventoryService)
local OverboardService = require(script.Parent.OverboardService)
local ProjectileService = require(script.Parent.ProjectileService)
local ShipService = require(script.Parent.ShipService)

-- Everything the server tracks for one rope.
-- anchor = Attachment on our ship, tip = Attachment on whatever got hit; the Beam is drawn between them.
-- length = how long the rope "is" right now. If the ends are further apart than this, the rope is stretched.
-- input  = each reeler's held direction (1 in, -1 out, 0 hold).
-- strainOwed / strainTimer = damage saved up between ticks for monsters that can't be pulled.
type Line = {
	id: string,
	owner: Player,
	ship: ShipService.Ship,
	kind: string, -- "Ship" | "Drowned" | "Enemy"
	target: Model,
	targetShip: ShipService.Ship?,
	anchor: Attachment,
	tip: Attachment,
	beam: Beam,
	length: number,
	minLength: number,
	snapTimer: number,
	reelers: { Player },
	input: { [Player]: number },
	strain: number,
	strainOwed: number,
	strainTimer: number,
	publishTimer: number,
}

-- Priority: the bootstrap inits services in this order, so the ones this file calls are ready first.
local TetherService = {
	Priority = 165,
}

local CFG = TetherConfig
local LOGIC: Tether.Config = TetherConfig :: any
local TAG = "Tether"
local STATION = "Reel"
-- A rotation whose X axis points straight down. Beams bend along their attachments' X axis
-- (CurveSize), so pointing it down makes a slack rope sag toward the water instead of sideways.
local DOWN = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, -1, 0), Vector3.new(1, 0, 0))
local HARPOON = (AmmoConfig.TYPES :: any)[CFG.AMMO]

local log = Log.new("TetherService")
local lines: { [string]: Line } = {} -- every live rope by id
local byOwner: { [Player]: Line } = {} -- one rope per gun, so one per shooter
local nextId = 0
local fireCooldowns = Cooldowns.new()

-- Small helpers ------------------------------------------------------------------------------------------------------

-- Server time is shared with clients, so "ready at" timestamps mean the same thing on both sides.
local function now(): number
	return workspace:GetServerTimeNow()
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function alive(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function toast(player: Player, key: string, kind: string)
	NetService.fireClient("UI/Toast", player, key, kind)
end

-- Ships only move on the water plane, so pulls ignore height.
local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Masses are made-up config numbers, not part mass: they decide who moves more when the rope pulls.
local function shipMass(ship: ShipService.Ship): number
	return (CFG.SHIP_MASS :: any)[ship.className] or CFG.SHIP_MASS.Sloop
end

-- An enemy with no listed mass is treated as immovable (math.huge); Tether.split gives it 0 speed.
local function enemyMass(model: Model): number
	local kind = model:GetAttribute("EnemyKind")
	local mass = if typeof(kind) == "string" then CFG.ENEMY_MASS[kind] else nil
	return mass or math.huge
end

local function linesOn(ship: ShipService.Ship): number
	local n = 0
	for _, line in lines do
		if line.ship == ship then
			n += 1
		end
	end
	return n
end

-- A player can only work one reel at a time; this finds which one.
local function lineOfReeler(player: Player): Line?
	for _, line in lines do
		if line.input[player] ~= nil then
			return line
		end
	end
	return nil
end

local function setReady(player: Player, at: number)
	player:SetAttribute("HarpoonReadyAt", at)
end

-- Reelers 

-- Attributes replicate on their own, so the client HUD reads the reeler list from the anchor.
local function publishReelers(line: Line)
	local ids = {}
	for _, p in line.reelers do
		table.insert(ids, tostring(p.UserId))
	end
	line.anchor:SetAttribute("Reelers", table.concat(ids, ","))
end

-- Refused if the player is busy at another station, the reel is full, or they already reel another rope.
local function addReeler(line: Line, player: Player): boolean
	if player:GetAttribute("Station") ~= nil or #line.reelers >= CFG.REELERS or lineOfReeler(player) then
		return false
	end
	table.insert(line.reelers, player)
	line.input[player] = 0
	player:SetAttribute("Station", STATION)
	player:SetAttribute("ReelTether", line.id)
	InteractionService.addUser(line.anchor, player)
	publishReelers(line)
	return true
end

local function removeReeler(line: Line, player: Player)
	local i = table.find(line.reelers, player)
	if not i then
		return
	end
	table.remove(line.reelers, i)
	line.input[player] = nil
	-- only clear Station if it is still ours (they might already be on a cannon)
	if player:GetAttribute("Station") == STATION then
		player:SetAttribute("Station", nil)
	end
	player:SetAttribute("ReelTether", nil)
	if line.anchor.Parent then
		InteractionService.removeUser(line.anchor, player)
		publishReelers(line)
	end
end

-- Two ropes can hold the same target; don't clear its Tethered flag while another one still does.
local function stillHeld(model: Model, except: Line): boolean
	for _, line in lines do
		if line ~= except and line.target == model then
			return true
		end
	end
	return false
end

-- Ending a rope 

-- One place that tears a rope down, whatever the reason. The first check makes it safe to call twice.
-- Order matters: reelers are collected before they're removed so they still get the toast,
-- and the tow velocities are cleared so neither ship keeps drifting after the rope is gone.
local function endLine(line: Line, reasonKey: string?, toastKind: string?)
	if lines[line.id] ~= line then
		return
	end
	local told: { Player } = { line.owner }
	for _, p in table.clone(line.reelers) do -- clone: removeReeler edits the list while we loop
		if not table.find(told, p) then
			table.insert(told, p)
		end
		removeReeler(line, p)
	end
	lines[line.id] = nil
	ShipService.setTow(line.ship, line.id, nil)
	if line.targetShip then
		ShipService.setTow(line.targetShip, line.id, nil)
	end
	if line.target.Parent and not stillHeld(line.target, line) then
		line.target:SetAttribute("Tethered", nil)
	end
	line.beam:Destroy()
	line.tip:Destroy()
	line.anchor:Destroy()
	if byOwner[line.owner] == line then
		byOwner[line.owner] = nil
		line.owner:SetAttribute("HarpoonOut", false)
		setReady(line.owner, now() + CFG.RELOAD)
	end
	if reasonKey then
		for _, p in told do
			if p.Parent == Players then -- skip anyone who already left
				toast(p, reasonKey, toastKind or "Info")
			end
		end
	end
	log.info(`tether {line.id} ({line.kind}) ended: {reasonKey or "silent"}`)
end

-- Making a rope

-- Builds the rope after a hit.
-- Each end is an Attachment parented to a part, so it rides along with that part for free (no per-frame moving).
-- PointToObjectSpace turns the world hit point into the part's local space, which is what Attachment.CFrame wants.
-- The anchor goes where the shooter stood (slightly raised), the tip exactly where the harpoon struck.
-- Starting length = current distance + a bit of slack, so the rope doesn't yank the instant it lands.
local function attach(owner: Player, ship: ShipService.Ship, kind: string, target: Model, part: BasePart, at: Vector3)
	local hrp = rootOf(owner)
	if not hrp or ship.sinking ~= nil or byOwner[owner] then
		return
	end
	local targetShip = if kind == "Ship" then ShipService.get(target) else nil
	nextId += 1
	local id = tostring(nextId)
	local anchor = Instance.new("Attachment")
	anchor.Name = "TetherAnchor"
	anchor.CFrame = CFrame.new(ship.root.CFrame:PointToObjectSpace(hrp.Position + Vector3.new(0, 0.5, 0)))
	anchor.Parent = ship.root
	anchor.WorldCFrame = CFrame.new(anchor.WorldPosition) * DOWN -- keep the position, swap the rotation for DOWN
	local tip = Instance.new("Attachment")
	tip.Name = "TetherTip"
	tip.CFrame = CFrame.new(part.CFrame:PointToObjectSpace(at))
	tip.Parent = part
	tip.WorldCFrame = CFrame.new(tip.WorldPosition) * DOWN
	local distance = (tip.WorldPosition - anchor.WorldPosition).Magnitude
	if distance > CFG.MAX_LENGTH then
		anchor:Destroy()
		tip:Destroy()
		return
	end
	-- The visible rope. FaceCamera keeps the flat beam from going paper-thin when seen edge-on.
	local beam = Instance.new("Beam")
	beam.Name = "TetherRope"
	beam.Attachment0 = anchor
	beam.Attachment1 = tip
	beam.Width0 = CFG.ROPE.WIDTH
	beam.Width1 = CFG.ROPE.WIDTH
	beam.Segments = CFG.ROPE.SEGMENTS
	beam.FaceCamera = true
	beam.LightInfluence = 1
	beam.Color = ColorSequence.new(Color3.fromRGB(CFG.ROPE.COLOR[1], CFG.ROPE.COLOR[2], CFG.ROPE.COLOR[3]))
	beam.Parent = ship.root
	local line: Line = {
		id = id,
		owner = owner,
		ship = ship,
		kind = kind,
		target = target,
		targetShip = targetShip,
		anchor = anchor,
		tip = tip,
		beam = beam,
		length = math.min(distance + CFG.SLACK, CFG.MAX_LENGTH),
		-- ships stop further apart so the hulls don't get reeled into each other
		minLength = if kind == "Ship" then CFG.SHIP_MIN_LENGTH else CFG.MIN_LENGTH,
		snapTimer = 0,
		reelers = {},
		input = {},
		strain = 0,
		strainOwed = 0,
		strainTimer = 0,
		publishTimer = 0,
	}
	-- State the client needs goes on the anchor as attributes (replicated); the tag lets clients find every rope.
	anchor:SetAttribute("TetherId", id)
	anchor:SetAttribute("Kind", kind)
	anchor:SetAttribute("Owner", owner.UserId)
	anchor:SetAttribute("Strain", 0)
	anchor:SetAttribute("Length", line.length)
	anchor:SetAttribute("Distance", distance)
	anchor:SetAttribute("Reelers", "")
	CollectionService:AddTag(anchor, TAG)
	-- turns the anchor into a prompt so a crewmate can join the reel
	InteractionService.attach(anchor, CFG.ACTION, 0, CFG.REELERS)
	target:SetAttribute("Tethered", true) -- monster AI reads this
	lines[id] = line
	byOwner[owner] = line
	owner:SetAttribute("HarpoonOut", true)
	addReeler(line, owner) -- the shooter starts on the reel
	toast(owner, "Tether.Hooked", "Success")
	log.info(`{owner.Name} harpooned a {kind} ({target.Name}) at {math.floor(distance)} studs`)
end

-- Public 

-- Firing. The client only sends an aim direction; everything else is checked here because the client can't be
-- trusted (right item, alive, not swimming, no rope already out, cooldown, standing on a ship).
-- How the shot is made: Ballistics.lob tilts the aim up a little so it arcs, then muzzleVelocity adds the
-- player's own velocity (shooting from a moving ship). ProjectileService flies it and ignores our own ship.
function TetherService.fire(player: Player, aim: Vector3?)
	if InventoryService.equippedItem(player) ~= CFG.ITEM then
		return
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local root = rootOf(player)
	if not character or not head or not head:IsA("BasePart") or not root or not alive(player) then
		return
	end
	if not aim or aim.Magnitude < 1e-3 or aim.Magnitude > CFG.MAX_AIM_MAGNITUDE then
		return
	end
	if OverboardService.isOverboard(player) then
		return
	end
	if byOwner[player] then
		toast(player, "Tether.StillOut", "Info")
		return
	end
	local ready = player:GetAttribute("HarpoonReadyAt")
	if typeof(ready) == "number" and ready > now() then
		return
	end
	local ship = ShipService.shipUnder(player)
	if not ship then
		toast(player, "Tether.NeedShip", "Info")
		return
	end
	if linesOn(ship) >= CFG.MAX_PER_SHIP then
		toast(player, "Tether.TooMany", "Info")
		return
	end
	if not Cooldowns.try(fireCooldowns, tostring(player.UserId), os.clock(), CFG.FIRE_COOLDOWN) then
		return
	end
	local unit = aim.Unit
	local dir = Ballistics.lob(Ballistics.vec(unit.X, unit.Y, unit.Z), CFG.UP)
	local inherited = root.AssemblyLinearVelocity
	local v = Ballistics.muzzleVelocity(dir, CFG.MUZZLE_SPEED, Ballistics.vec(inherited.X, inherited.Y, inherited.Z))
	ProjectileService.fire(CFG.AMMO, head.Position, Vector3.new(v.x, v.y, v.z), { character, ship.model }, player)
	setReady(player, now() + CFG.FIRE_COOLDOWN)
end

-- Called by the harpoon's ammo handler when the projectile hits something. Works out what was hit and
-- which kind of rope to make. Returns a word the client uses to pick the hit effect.
-- Drowned: hurt (and stunned) first, then tied only if it can still be towed.
-- Other enemies: hurt, and tied only if that hit didn't kill them.
function TetherService.onHarpoonHit(ctx: any): string
	local shooter: Player? = ctx.shooter
	local part: BasePart? = ctx.part
	if not shooter or not part then
		return "Solid"
	end
	local ownShip = ShipService.shipUnder(shooter)
	local hitShip = ShipService.shipOf(part)
	if hitShip then
		if ownShip and hitShip ~= ownShip and hitShip.sinking == nil then
			attach(shooter, ownShip, "Ship", hitShip.model, part, ctx.position)
		end
		return "Hull"
	end
	local enemy = EnemyService.enemyOf(part)
	if not enemy then
		return "Solid"
	end
	local model = enemy.model
	if model:GetAttribute("Friendly") == true then
		return "Solid" -- a drowned the crew already caught
	end
	EffectsService.play("Impact", ctx.position, 0.6)
	if model:GetAttribute("DrownedType") ~= nil then
		EnemyService.damage(model, HARPOON.DAMAGE, HARPOON.DAMAGE_TYPE, part, shooter, HARPOON.STUN or 0, 0)
		if ownShip and DrownedService.towable(model) then
			attach(shooter, ownShip, "Drowned", model, part, ctx.position)
		end
	else
		local _, _, defeated =
			EnemyService.damage(model, HARPOON.DAMAGE, HARPOON.DAMAGE_TYPE, part, shooter, 0, HARPOON.DAMAGE)
		if ownShip and not defeated then
			attach(shooter, ownShip, "Enemy", model, part, ctx.position)
		end
	end
	return "Solid"
end

-- lines is a dictionary, so # doesn't work on it; count by hand.
function TetherService.count(): number
	local n = 0
	for _ in lines do
		n += 1
	end
	return n
end

-- Per-frame step 

-- Is the other end still worth holding? Each kind has its own "gone" rule.
local function targetGone(line: Line): boolean
	if not line.target:IsDescendantOf(workspace) or not line.tip:IsDescendantOf(workspace) then
		return true
	end
	if line.kind == "Ship" then
		return line.targetShip == nil or line.targetShip.sinking ~= nil
	elseif line.kind == "Drowned" then
		return not DrownedService.towable(line.target)
	end
	local defeated = line.target:GetAttribute("Defeated")
	return typeof(defeated) == "string" and defeated ~= ""
end

-- A drowned reeled up to the rail: drop the rope, then DrownedService decides if it lands on deck or breaks free.
-- The rope is ended first so it isn't still pulling while the drowned is moved aboard.
local function arrive(line: Line)
	local hauler = line.reelers[1] or line.owner
	local target = line.target
	endLine(line, nil)
	local result = DrownedService.reelIn(hauler, target)
	if result == "Caught" then
		toast(hauler, "Tether.Landed", "Success")
	elseif result == "Corpse" then
		toast(hauler, "Tether.LandedCorpse", "Success")
	elseif result == "Awake" then
		toast(hauler, "Tether.TornFree", "Warning")
	end
end

-- Turns the rope force into movement at each end.
-- Tether.split gives each end a speed of force / mass (capped), so a light drowned flies in while two ships
-- creep together. dir points from our anchor to the tip, so our ship is pulled +dir and the target -dir.
-- Ships aren't moved here directly: setTow hands ShipService an extra velocity (keyed by rope id, so several
-- ropes can add up) and its own motion code applies it.
-- A drowned is moved by DrownedService.drag, never further than the stretch, so it can't overshoot the rope.
-- Monsters: if the thing is welded to our own hull (a tentacle), pulling our ship toward it would mean the
-- ship pulls itself, so our side gets 0. If it can't move at all, the force becomes damage instead, saved up
-- and paid out every STRAIN_TICK rather than every frame (fewer damage calls, same total).
local function pull(line: Line, force: number, dir: Vector3, dt: number, stretch: number)
	local massA = shipMass(line.ship)
	if line.kind == "Ship" and line.targetShip then
		local vA, vB = Tether.split(force, massA, shipMass(line.targetShip), LOGIC)
		ShipService.setTow(line.ship, line.id, dir * vA)
		ShipService.setTow(line.targetShip, line.id, -dir * vB)
	elseif line.kind == "Drowned" then
		local vA, vB = Tether.split(force, massA, CFG.DROWNED_MASS, LOGIC)
		ShipService.setTow(line.ship, line.id, dir * vA)
		if vB > 0 and stretch > 0 then
			DrownedService.drag(line.target, -dir * math.min(vB * dt, stretch))
		end
	else
		local mass = enemyMass(line.target)
		-- same assembly root = welded to our ship
		local onHull = line.tip.Parent ~= nil
			and (line.tip.Parent :: BasePart).AssemblyRootPart == line.ship.root.AssemblyRootPart
		local vA = 0
		if not onHull then
			vA = Tether.split(force, massA, mass, LOGIC)
		end
		ShipService.setTow(line.ship, line.id, dir * vA)
		if mass == math.huge then
			local strain = Tether.strain(force, LOGIC)
			line.strainOwed += strain * dt
			line.strainTimer += dt
			if line.strainTimer >= CFG.STRAIN_TICK then
				local owed = line.strainOwed
				line.strainTimer, line.strainOwed = 0, 0
				if owed > 0 then
					EnemyService.damage(
						line.target,
						CFG.STRAIN_DPS * owed,
						"Pierce",
						nil,
						line.owner,
						0,
						CFG.STRAIN_STAGGER * owed
					)
				end
			end
		end
	end
end

-- Sends rope state to clients a few times a second (not every frame) to save bandwidth; values are rounded
-- so tiny changes don't count as new attribute writes.
-- Sag: CurveSize0/1 bend the beam at each end; opposite signs on the two ends make one smooth dip in the middle.
-- The DOWN rotation is re-applied because the ends' parts rotate with the ship and would tilt the sag.
local function publish(line: Line, distance: number)
	local a = line.anchor
	a:SetAttribute("Strain", math.floor(line.strain * 100 + 0.5) / 100)
	a:SetAttribute("Length", math.floor(line.length * 10 + 0.5) / 10)
	a:SetAttribute("Distance", math.floor(distance * 10 + 0.5) / 10)
	local sag = Tether.sag(distance, line.length, LOGIC)
	line.beam.CurveSize0 = sag
	line.beam.CurveSize1 = -sag
	line.anchor.WorldCFrame = CFrame.new(line.anchor.WorldPosition) * DOWN
	line.tip.WorldCFrame = CFrame.new(line.tip.WorldPosition) * DOWN
end

-- One rope, one frame. Roughly:
--   1. end it if the owner left, our ship is sinking, or the target is gone
--   2. drop reelers who died, left, walked off or took another station
--   3. reel: the combined input changes the rope length (lengthStep stops it being reeled impossibly tight)
--   4. rope physics: stretch -> force -> strain; strain held at max for BREAK_TIME snaps the rope
--   5. pull both ends, check if a drowned reached the rail, and every UPDATE_INTERVAL publish to clients
-- Each early return is because the rope no longer exists after endLine / arrive.
local function stepLine(line: Line, dt: number)
	if line.owner.Parent ~= Players then
		endLine(line, nil)
		return
	end
	if not line.anchor:IsDescendantOf(workspace) or line.ship.sinking ~= nil then
		endLine(line, "Tether.Lost", "Warning")
		return
	end
	if targetGone(line) then
		endLine(line, if line.kind == "Enemy" then "Tether.Freed" else "Tether.Lost", "Info")
		return
	end
	for _, p in table.clone(line.reelers) do
		local r = rootOf(p)
		if
			p.Parent ~= Players
			or not alive(p)
			or not r
			or (r.Position - line.anchor.WorldPosition).Magnitude > CFG.REEL_RANGE
			or p:GetAttribute("Station") ~= STATION
		then
			removeReeler(line, p)
		end
	end
	local a, b = line.anchor.WorldPosition, line.tip.WorldPosition
	local distance = (b - a).Magnitude
	if distance > CFG.MAX_LENGTH then
		endLine(line, "Tether.Snapped", "Warning")
		return
	end
	local inputs = {}
	for _, p in line.reelers do
		table.insert(inputs, line.input[p] or 0)
	end
	local rate = Tether.reelRate(inputs, LOGIC)
	line.length = Tether.lengthStep(line.length, distance, rate, dt, line.minLength, LOGIC)
	local force = Tether.force(distance, line.length, LOGIC)
	line.strain = Tether.strain(force, LOGIC)
	local snapped
	line.snapTimer, snapped = Tether.breakStep(line.snapTimer, dt, line.strain, LOGIC)
	if snapped then
		EffectsService.play("Impact", b, 0.8)
		endLine(line, "Tether.Snapped", "Warning")
		return
	end
	local dir = flat(b - a)
	dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.zero -- .Unit of a zero vector is NaN
	pull(line, force, dir, dt, Tether.stretch(distance, line.length))
	if line.kind == "Drowned" and #line.reelers > 0 and distance <= CFG.ARRIVE_DISTANCE then
		arrive(line)
		return
	end
	line.publishTimer -= dt
	if line.publishTimer <= 0 then
		line.publishTimer = CFG.UPDATE_INTERVAL
		publish(line, distance)
	end
end

-- Runs every rope. pcall so one broken rope gets logged and removed instead of stopping all the others.
-- Removing from `lines` while looping over it is fine in Luau as long as nothing new is added.
local function step(dt: number)
	for _, line in lines do
		local ok, err = (pcall :: any)(stepLine, line, dt)
		if not ok then
			log.error(`tether {line.id} step failed: {err}`)
			pcall(endLine, line, nil)
		end
	end
end

-- Reel prompt (a crewmate joining) 

local function lineOfAnchor(inst: Instance): Line?
	local id = inst:GetAttribute("TetherId")
	return if typeof(id) == "string" then lines[id] else nil
end

-- InteractionService asks this before showing / running the prompt. The second return is a message key
-- explaining why not (nil = just hide the prompt).
local function canReel(player: Player, inst: Instance): (boolean, string?)
	local line = lineOfAnchor(inst)
	if not line then
		return false, nil
	end
	if lineOfReeler(player) then
		return false, nil
	end
	if #line.reelers >= CFG.REELERS then
		return false, "Tether.ReelFull"
	end
	return true, nil
end

local function manReel(player: Player, inst: Instance)
	local line = lineOfAnchor(inst)
	if line and addReeler(line, player) then
		toast(player, "Tether.OnReel", "Info")
	end
end

-- Debug commands (Studio dev panel only) 

DebugService.register("Tether.Kit", {
	description = "Give yourself a harpoon gun",
	args = Schema.tuple({}),
	run = function(player: Player?)
		if not player then
			return "needs a player"
		end
		InventoryService.give(player, CFG.ITEM, 1)
		return "harpoon gun given"
	end,
})

-- Skips aiming: finds the closest target of a kind and ties to it, for quick testing.
DebugService.register("Tether.HookNearest", {
	description = "Tie your harpoon line to the nearest floating drowned, other ship or enemy (no aiming)",
	args = Schema.tuple({ Schema.string({ oneOf = { "Drowned", "Ship", "Enemy" } }) }),
	presets = { { "Drowned" }, { "Ship" }, { "Enemy" } },
	run = function(player: Player?, kind: string)
		local hrp = player and rootOf(player)
		local ship = player and ShipService.shipUnder(player)
		if not player or not hrp or not ship then
			return "needs a player aboard a ship"
		end
		if byOwner[player] then
			return "your line is already out"
		end
		local best: Model?, bestPart: BasePart?, bestD = nil, nil, CFG.MAX_LENGTH
		local function consider(model: Model, part: BasePart)
			local d = (part.Position - hrp.Position).Magnitude
			if d < bestD then
				best, bestPart, bestD = model, part, d
			end
		end
		if kind == "Drowned" then
			for _, r in DrownedService.all() do
				if DrownedService.towable(r.model) then
					consider(r.model, r.body)
				end
			end
		elseif kind == "Ship" then
			for _, other in ShipService.all() do
				if other ~= ship and other.sinking == nil then
					consider(other.model, other.root)
				end
			end
		else
			for _, e in EnemyService.all() do
				if e.model:GetAttribute("DrownedType") == nil and e.model.PrimaryPart then
					consider(e.model, e.model.PrimaryPart :: BasePart)
				end
			end
		end
		if not best or not bestPart then
			return `no {kind} within {CFG.MAX_LENGTH} studs`
		end
		attach(player, ship, kind, best, bestPart, bestPart.Position)
		return `hooked {best.Name} at {math.floor(bestD)} studs`
	end,
})

DebugService.register("Tether.Status", {
	description = "List harpoon lines: kind, length, distance, strain, reelers",
	args = Schema.tuple({}),
	run = function()
		local list = {}
		for _, line in lines do
			local d = (line.tip.WorldPosition - line.anchor.WorldPosition).Magnitude
			table.insert(
				list,
				string.format(
					"%s %s->%s len=%.1f dist=%.1f strain=%.2f snap=%.1f reelers=%d",
					line.id,
					line.owner.Name,
					line.target.Name,
					line.length,
					d,
					line.strain,
					line.snapTimer,
					#line.reelers
				)
			)
		end
		return if #list > 0 then table.concat(list, "\n") else "no lines"
	end,
})

DebugService.register("Tether.CutAll", {
	description = "Cut every harpoon line",
	args = Schema.tuple({}),
	run = function()
		local n = 0
		for _, line in lines do
			endLine(line, "Tether.Cut")
			n += 1
		end
		return `cut {n}`
	end,
})

-- Lifecycle

-- Init only wires things up: the reel prompt, the two remotes, and cleanup when someone leaves.
-- The remotes only work for someone who is on a reel; NetService has already checked the argument types
-- and rate limit, and dir is clamped anyway in case someone sends 50.
-- Leaving the game cuts that player's own rope and clears their cooldown entry so the table doesn't grow forever.
function TetherService:Init()
	InteractionService.register(CFG.ACTION, {
		objectText = function()
			return "Tether.Object"
		end,
		canUse = canReel,
		maxDistance = CFG.REEL_RANGE,
		run = manReel,
	})
	NetService.connect("Tether/Reel", function(player: Player, dir: number)
		local line = lineOfReeler(player)
		if line then
			line.input[player] = math.clamp(dir, -1, 1)
		end
	end)
	NetService.connect("Tether/Cut", function(player: Player)
		local line = lineOfReeler(player)
		if line then
			endLine(line, "Tether.Cut", "Info")
		end
	end)
	ShipService.LeaveRequested:Connect(function(player)
		local line = lineOfReeler(player)
		if line then
			removeReeler(line, player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		local line = lineOfReeler(player)
		if line then
			removeReeler(line, player)
		end
		local owned = byOwner[player]
		if owned then
			endLine(owned, nil)
		end
		Cooldowns.clearPrefix(fireCooldowns, tostring(player.UserId))
	end)
end

-- Start begins the loop. Heartbeat runs after physics each frame, so positions read in stepLine are this frame's.
function TetherService:Start()
	RunService.Heartbeat:Connect(step)
end

return TetherService
