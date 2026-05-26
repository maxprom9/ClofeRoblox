--!strict
-- Discorde username is: clofes_37093, and roblox username is @Skidfly
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local SS = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
 
local Registry = require(SSS.Server.Lib.ServerRegistry)
local Net = require(RS.Shared.Net)
local Signal = require(RS.Shared.Signal)
local ZombieConfig = require(RS.Shared.Configs.ZombieConfig)
 
local PhysicsService = game:GetService("PhysicsService")
 
local ZOMBIE_COLLISION_GROUP = "Zombies"
local function ensureCollisionGroup()
	local ok = pcall(function() PhysicsService:RegisterCollisionGroup(ZOMBIE_COLLISION_GROUP) end)
	-- ok is false if already registered — fine, just ensure non-collide with Default.
	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(ZOMBIE_COLLISION_GROUP, "Default", false)
		PhysicsService:CollisionGroupSetCollidable(ZOMBIE_COLLISION_GROUP, ZOMBIE_COLLISION_GROUP, false)
	end)
end
ensureCollisionGroup()
 
local ZOMBIE_WALK_ANIM_IDS = {
	"rbxassetid://94359619900945",
	"rbxassetid://115370219086654",
	"rbxassetid://96690219235356",
	"rbxassetid://102951939195576",
	"rbxassetid://101174800866440",
	"rbxassetid://137209186333300",
}
 
export type ZombieInstance = {
	id: number,
	zombieId: string,
	model: Model,
	rootPart: BasePart,
	hp: number,
	maxHp: number,
	damage: number,
	speed: number,
	owner: Player,
	plot: Model,
	targetZ: number,
	row: number,
	groundY: number,
	baseThresholdX: number,
	reachedBase: boolean,
	alive: boolean,
	lastAttack: number,
	dotEndsAt: number,
	dotDps: number,
	dotNextTick: number,
	healthFill: Frame?,
}
 
local Service = {}
Service.__Order = 80
 
Service.ZombieSpawned = Signal.new()
Service.ZombieKilled = Signal.new()
 
local nextRuntimeId = 0
 
local function getZombiesTemplateFolder(): Folder?
	local templates = SS:FindFirstChild("Templates")
	if not templates then return nil end
	local zf = templates:FindFirstChild("Zombies")
	if zf and zf:IsA("Folder") then return zf end
	return nil
end
 
local function buildHealthbar(model: Model, maxHp: number): Frame?
	local head = model:FindFirstChild("Head")
	local anchor: BasePart? = nil
	if head and head:IsA("BasePart") then
		anchor = head
	else
		local hrp = model:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then anchor = hrp end
	end
	if not anchor then return nil end
 
	local gui = Instance.new("BillboardGui")
	gui.Name = "_Healthbar"
	gui.Size = UDim2.new(4, 0, 0.6, 0)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Adornee = anchor
	gui.Parent = anchor
 
	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	bg.BorderSizePixel = 0
	bg.Parent = gui
 
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
	fill.BorderSizePixel = 0
	fill.Parent = bg
 
	return fill
end
 
local function updateHealthbar(zombie: ZombieInstance)
	local fill = zombie.healthFill
	if not fill then return end
	local frac = math.max(0, zombie.hp) / math.max(1, zombie.maxHp)
	fill.Size = UDim2.fromScale(frac, 1)
end
 
local function getDifficultyMultiplier(profile): number
	local world = profile and profile.worldProgress and profile.worldProgress[profile.currentWorld]
	local diff = (world and world.difficulty) or 1
	return 1 + (diff - 1) * 0.5
end
 
local function getSpeed(player: Player): number
	local svc = Registry.TryGet("IngameControlService")
	if not svc then return 1 end
	local ok, v = pcall(function() return svc:GetSpeed(player) end)
	if ok and type(v) == "number" and v > 0 then return v end
	return 1
end
 
local function pickUnlockedRow(self, player: Player): number
	local Data = self.DataService
	local candidates: { number } = { 1 } -- row 1 is always unlocked
	if Data then
		for r = 2, 7 do
			if Data:IsRowUnlocked(player, r) then
				table.insert(candidates, r)
			end
		end
	end
	return candidates[self._rng:NextInteger(1, #candidates)]
end
 
function Service:Init()
	self.DataService = Registry.Get("DataService")
	self.SessionService = Registry.Get("SessionService")
	self.PlotService = Registry.Get("PlotService")
	self.EconomyService = Registry.Get("EconomyService")
	self._rng = Random.new()
 
	self._zombies = {} :: { [number]: ZombieInstance }
	self._byPlot = {} :: { [Model]: { [number]: ZombieInstance } }
	self._byPlayer = {} :: { [Player]: { [number]: ZombieInstance } }
 
	Net:Event("ZombieSpawned")
	Net:Event("ZombieDamaged")
	Net:Event("ZombieKilled")
end
 
local function registerZombie(self, z: ZombieInstance)
	self._zombies[z.id] = z
	local byPlot = self._byPlot[z.plot]
	if not byPlot then byPlot = {}; self._byPlot[z.plot] = byPlot end
	byPlot[z.id] = z
	local byPlayer = self._byPlayer[z.owner]
	if not byPlayer then byPlayer = {}; self._byPlayer[z.owner] = byPlayer end
	byPlayer[z.id] = z
end
 
local function unregisterZombie(self, z: ZombieInstance)
	self._zombies[z.id] = nil
	local byPlot = self._byPlot[z.plot]
	if byPlot then byPlot[z.id] = nil end
	local byPlayer = self._byPlayer[z.owner]
	if byPlayer then byPlayer[z.id] = nil end
end
 
function Service:Spawn(player: Player, zombieId: string): ZombieInstance?
	local def = ZombieConfig.get(zombieId)
	local templates = getZombiesTemplateFolder()
	if not templates then
		warn("[ZombieService] missing Zombies templates folder")
		return nil
	end
	local template = templates:FindFirstChild(zombieId)
	if not template or not template:IsA("Model") then
		warn("[ZombieService] missing zombie template: " .. tostring(zombieId))
		return nil
	end
 
	local plot = self.PlotService:GetPlot(player)
	if not plot then
		warn("[ZombieService] no plot for player " .. player.Name)
		return nil
	end
 
	local spawnPart = self.PlotService:GetEnemySpawnPart(plot)
	if not spawnPart then
		warn("[ZombieService] no EnemySpawnPart for plot")
		return nil
	end
 
	local basePos = self.PlotService:GetBasePosition(plot)
 
	local profile = self.DataService:Get(player)
	local mult = profile and getDifficultyMultiplier(profile) or 1
 
	local model = template:Clone()
	model.Name = string.format("Z_%s_%d", zombieId, nextRuntimeId + 1)
 
	local maxHp = math.floor(def.hp * mult + 0.5)
	local dmg = def.damage * mult
 
	nextRuntimeId += 1
	local runtimeId = nextRuntimeId
 
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		hrp = model.PrimaryPart
	end
	if not (hrp and hrp:IsA("BasePart")) then
		hrp = model:FindFirstChildWhichIsA("BasePart")
	end
	if not (hrp and hrp:IsA("BasePart")) then
		model:Destroy()
		return nil
	end
 
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = false
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CanTouch = false
			desc.Massless = true
			desc.CollisionGroup = ZOMBIE_COLLISION_GROUP
		end
	end
	hrp.Anchored = true
	hrp.CanCollide = false
	hrp.CanQuery = false
	hrp.CanTouch = false
	hrp.Massless = true
	hrp.CollisionGroup = ZOMBIE_COLLISION_GROUP
 
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.MaxHealth = maxHp
		hum.Health = maxHp
		hum.WalkSpeed = 0
		hum.AutoRotate = false
	end
 
	local rowIndex = pickUnlockedRow(self, player)
	local rowZ = self.PlotService:GetRowZ(plot, rowIndex)
	local targetZ
	if rowZ then
		targetZ = rowZ
	else
		local halfZ = spawnPart.Size.Z / 2
		targetZ = spawnPart.Position.Z + self._rng:NextNumber(-halfZ, halfZ)
	end
	local spawnX = spawnPart.Position.X
	local groundY = spawnPart.Position.Y + 3
	local spawnPos = Vector3.new(spawnX, groundY, targetZ)
	local spawnCFrame = CFrame.lookAt(spawnPos, spawnPos + Vector3.new(-1, 0, 0))
	local ok = pcall(function() model:PivotTo(spawnCFrame) end)
	if not ok then
		hrp.CFrame = spawnCFrame
	end
 
	model:SetAttribute("ZombieId", zombieId)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("RuntimeId", runtimeId)
	model:SetAttribute("HP", maxHp)
	model:SetAttribute("MaxHP", maxHp)
	model:SetAttribute("Row", rowIndex)
 
	model.Parent = Workspace
 
	if hum then
		local animator = hum:FindFirstChildOfClass("Animator")
		if not animator then
			animator = Instance.new("Animator")
			animator.Parent = hum
		end
		local animId = ZOMBIE_WALK_ANIM_IDS[self._rng:NextInteger(1, #ZOMBIE_WALK_ANIM_IDS)]
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
		if ok and track then
			track.Looped = true
			track:Play()
		end
	end
 
	local healthFill = buildHealthbar(model, maxHp)
 
	local zombie: ZombieInstance = {
		id = runtimeId,
		zombieId = zombieId,
		model = model,
		rootPart = hrp :: BasePart,
		hp = maxHp,
		maxHp = maxHp,
		damage = dmg,
		speed = def.speed,
		owner = player,
		plot = plot,
		targetZ = targetZ,
		row = rowIndex,
		groundY = groundY,
		baseThresholdX = basePos.X,
		reachedBase = false,
		alive = true,
		lastAttack = 0,
		dotEndsAt = 0,
		dotDps = 0,
		dotNextTick = 0,
		healthFill = healthFill,
	}
 
	registerZombie(self, zombie)
	Service.ZombieSpawned:Fire(player, zombie)
	Net:FireClient("ZombieSpawned", player, runtimeId, zombieId, hrp.Position)
	return zombie
end
 
function Service:GetZombiesForPlot(plot: Model): { ZombieInstance }
	local out: { ZombieInstance } = {}
	local byPlot = self._byPlot[plot]
	if not byPlot then return out end
	for _, z in pairs(byPlot) do
		if z.alive then table.insert(out, z) end
	end
	return out
end
 
function Service:GetZombiesForPlayer(player: Player): { ZombieInstance }
	local out: { ZombieInstance } = {}
	local byPlayer = self._byPlayer[player]
	if not byPlayer then return out end
	for _, z in pairs(byPlayer) do
		if z.alive then table.insert(out, z) end
	end
	return out
end
 
function Service:FindNearestZombie(plot: Model, position: Vector3, range: number, rowFilter: number?): ZombieInstance?
	local byPlot = self._byPlot[plot]
	if not byPlot then return nil end
	local best: ZombieInstance? = nil
	local bestDistSq = range * range
	for _, z in pairs(byPlot) do
		if z.alive and z.rootPart and z.rootPart.Parent then
			if rowFilter == nil or z.row == rowFilter then
				local d = z.rootPart.Position - position
				local distSq = d.X * d.X + d.Y * d.Y + d.Z * d.Z
				if distSq <= bestDistSq then
					best = z
					bestDistSq = distSq
				end
			end
		end
	end
	return best
end
 
local function killZombie(self, z: ZombieInstance, killer: Player?)
	if not z.alive then return end
	z.alive = false
 
	local deathPos = z.rootPart and z.rootPart.Position or Vector3.zero
 
	local def = ZombieConfig.get(z.zombieId)
	local coinCount = self._rng:NextInteger(def.coinDropMin, def.coinDropMax)
 
	local coinService = Registry.TryGet("CoinDropService")
	if coinService and coinCount > 0 then
		coinService:SpawnCoins(z.owner, deathPos, coinCount)
	end
 
	if z.owner and z.owner.Parent then
		self.DataService:Update(z.owner, function(profile)
			if not profile then return end
			profile.stats.totalZombiesKilled = (profile.stats.totalZombiesKilled or 0) + 1
		end)
	end
 
	Service.ZombieKilled:Fire(z.owner, z, killer)
	if z.owner and z.owner.Parent then
		Net:FireClient("ZombieKilled", z.owner, z.id)
	end
 
	unregisterZombie(self, z)
	if z.model then z.model:Destroy() end
end
 
local function applyDamageAoE(self, originPlot: Model, originZombie: ZombieInstance, amount: number, radius: number)
	local byPlot = self._byPlot[originPlot]
	if not byPlot then return end
	local radiusSq = radius * radius
	local origin = originZombie.rootPart and originZombie.rootPart.Position
	if not origin then return end
	for _, other in pairs(byPlot) do
		if other.alive and other ~= originZombie and other.rootPart then
			local d = other.rootPart.Position - origin
			if (d.X * d.X + d.Y * d.Y + d.Z * d.Z) <= radiusSq then
				self:_applyRaw(other, amount, nil)
			end
		end
	end
end
 
function Service:_applyRaw(zombie: ZombieInstance, amount: number, effect: string?)
	if not zombie.alive then return end
	if typeof(amount) ~= "number" or amount <= 0 then return end
	zombie.hp = zombie.hp - amount
	if zombie.model then
		zombie.model:SetAttribute("HP", math.max(0, zombie.hp))
	end
	updateHealthbar(zombie)
	local hum = zombie.model and zombie.model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Health = math.max(0, zombie.hp)
	end
	if zombie.owner and zombie.owner.Parent then
		Net:FireClient("ZombieDamaged", zombie.owner, zombie.id, math.max(0, zombie.hp), zombie.maxHp)
	end
	if zombie.hp <= 0 then
		killZombie(self, zombie, nil)
	end
end
 
-- Per-hit knockback (studs) in the direction opposite the zombie's walk.
-- Zombies always walk -X (see tickZombie), so +X pushes them back toward
-- their spawn. We mutate rootPart directly; tickZombie reads `pos.X` next
-- frame so the knockback effectively costs the zombie that much forward
-- progress before it can resume walking.
local KNOCKBACK_STUDS = 0.4
 
function Service:DamageZombie(zombie: ZombieInstance, amount: number, effect: string?)
	if typeof(zombie) ~= "table" then return end
	if not zombie.alive then return end
	local wasAlive = zombie.alive
	local plot = zombie.plot
	local mainAmount = amount
 
	-- Apply knockback BEFORE damage so even a fatal hit visually nudges the
	-- zombie back a frame. Only direct hits (projectile collision + melee) get
	-- knocked back — DoT and AoE splash call _applyRaw directly, which skips
	-- this, so persistent burn/poison ticks don't snowball zombies backwards.
	if zombie.rootPart and zombie.rootPart.Parent then
		local pos = zombie.rootPart.Position
		local newPos = Vector3.new(pos.X + KNOCKBACK_STUDS, pos.Y, pos.Z)
		zombie.rootPart.CFrame = CFrame.lookAt(newPos, newPos + Vector3.new(-1, 0, 0))
	end
 
	self:_applyRaw(zombie, mainAmount, effect)
 
	if effect == "Burn" and wasAlive then
		local MutationConfig = require(RS.Shared.Configs.MutationConfig)
		local eff = MutationConfig.getEffect("Burn")
		if eff and plot then
			applyDamageAoE(self, plot, zombie, mainAmount * eff.splashFraction, eff.aoeRadius)
		end
	end
end
 
function Service:ApplyAoE(plot: Model, originZombie: ZombieInstance, amount: number, radius: number)
	if not plot or not originZombie then return end
	applyDamageAoE(self, plot, originZombie, amount, radius)
end
 
function Service:ApplyDoT(zombie: ZombieInstance, dotDamagePerSec: number, durationSec: number)
	if typeof(zombie) ~= "table" then return end
	if not zombie.alive then return end
	local now = os.clock()
	zombie.dotEndsAt = math.max(zombie.dotEndsAt, now + durationSec)
	zombie.dotDps = math.max(zombie.dotDps, dotDamagePerSec)
	if zombie.dotNextTick == 0 or zombie.dotNextTick < now then
		zombie.dotNextTick = now + 1
	end
end
 
function Service:DespawnAll(player: Player)
	local byPlayer = self._byPlayer[player]
	if not byPlayer then return end
	local toKill = {}
	for _, z in pairs(byPlayer) do
		table.insert(toKill, z)
	end
	for _, z in ipairs(toKill) do
		if z.alive then
			z.alive = false
			unregisterZombie(self, z)
			if z.model then z.model:Destroy() end
			if z.owner and z.owner.Parent then
				Net:FireClient("ZombieKilled", z.owner, z.id)
			end
		end
	end
	self._byPlayer[player] = nil
end
 
local function tickZombie(self, zombie: ZombieInstance, now: number, dt: number, effectiveDt: number)
	if not zombie.alive then return end
	if not zombie.rootPart or not zombie.rootPart.Parent then
		killZombie(self, zombie, nil)
		return
	end
 
	if zombie.dotEndsAt > 0 and now <= zombie.dotEndsAt and zombie.dotDps > 0 then
		if now >= zombie.dotNextTick then
			zombie.dotNextTick = now + 1
			self:_applyRaw(zombie, zombie.dotDps, nil)
			if not zombie.alive then return end
		end
	elseif zombie.dotEndsAt > 0 and now > zombie.dotEndsAt then
		zombie.dotEndsAt = 0
		zombie.dotDps = 0
		zombie.dotNextTick = 0
	end
 
	local pos = zombie.rootPart.Position
	local newX = pos.X - zombie.speed * effectiveDt
	if newX <= zombie.baseThresholdX then
		if not zombie.reachedBase then
			zombie.reachedBase = true
			local BaseHealth = Registry.TryGet("BaseHealthService")
			if BaseHealth and zombie.owner and zombie.owner.Parent then
				BaseHealth:TakeDamage(zombie.owner, zombie.damage)
			end
		end
		-- Reach-base is also a death: drops cash, fires Signal (WaveService counts the kill),
		-- fires Net event, increments stats, destroys model.
		killZombie(self, zombie, nil)
		return
	end
 
	local newPos = Vector3.new(newX, zombie.groundY, zombie.targetZ)
	zombie.rootPart.CFrame = CFrame.lookAt(newPos, newPos + Vector3.new(-1, 0, 0))
end
 
function Service:Start()
	if self.PlotService.PlotReleased then
		self.PlotService.PlotReleased:Connect(function(player: Player)
			self:DespawnAll(player)
		end)
	end
 
	self.SessionService.PlayerLeft:Connect(function(player: Player)
		self:DespawnAll(player)
	end)
 
	self._heartbeat = RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		local playerSpeeds: { [Player]: number } = {}
		for _, zombie in pairs(self._zombies) do
			local owner = zombie.owner
			local speed = owner and playerSpeeds[owner]
			if speed == nil and owner then
				speed = getSpeed(owner)
				playerSpeeds[owner] = speed
			end
			local effectiveDt = dt * (speed or 1)
			tickZombie(self, zombie, now, dt, effectiveDt)
		end
	end)
end
 
return Service
 
