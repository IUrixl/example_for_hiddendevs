local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local shared = replicated_storage:WaitForChild("shared")
local assets = replicated_storage:WaitForChild("assets")
local metas = replicated_storage:WaitForChild("metadatas")

local pet_metas = require(metas:WaitForChild("Pets"))
local networking = require(shared:WaitForChild("Networking"))
local data = require("./DataService")
local utils = require(shared:WaitForChild("Utils"))

-- distances are separated into constants to make tuning easier without
-- hunting through logic. teleport threshold is generous to handle lag spikes.
local TELEPORT_THRESHOLD = 25
local PET_FOLLOW_SPEED = 1500

-- animation offsets are kept in one place because both amplitude and frequency
-- will likely need tuning together during gameplay feel iteration.
local WALK_ANIM_FREQ = 10
local WALK_ANIM_AMPLITUDE = 4
local WALK_ANIM_TILT = 3

-- the delay staggers all pets away from zero so they don't oscillate in sync,
-- which looks unnatural. a large prime like offset avoids aliasing with game time.
local WALK_ANIM_DELAY = 1000

-- lateral spacing per column. index maps directly to column (1 = center, 2 = left, 3 = right).
-- rows extend backward from the character, one row per 3 pets.
local POS_COLUMNS = { [1] = 0, [2] = -4, [3] = 4 }
local PETS_PER_ROW = 3
local ROW_DEPTH_OFFSET = 4
local ROW_BASE_DEPTH = 1.5


local PetService = {
	workspace_folder = game.Workspace:WaitForChild("PetFolder"),
}

-- centralise profile access so callers never repeat the wait_for_profile call.
-- any future caching or error handling only needs to happen here.
local function get_player_data(player: Player): {}
	local profile = data:wait_for_profile(player)
	return profile.data
end

-- walking the full inventory every time is O(n) but inventory sizes are small
-- enough that this is fine. returns slot indices, not pet objects, so callers
-- can use them as direct keys into data.inventory.
local function get_equipped_slots(player_data: {}): {number}
	local equipped = {}

	for slot_index, pet in player_data.inventory do
		if pet.equipped then
			table.insert(equipped, slot_index)
		end
	end

	return equipped
end

-- exposed publicly so networking handlers and other services can call it without
-- going through the full equipped slots lookup when they only need the count.
function PetService:get_equipped_amount(player: Player, player_data: {}): number
	return #get_equipped_slots(player_data)
end

-- deepcopying is critical here as pet_metas is shared module state and mutating
-- it directly would corrupt metadata for every player. we also tag each copy
-- with _slot so sort results can be traced back to their inventory position.
local function build_slot_meta_map(player_data: {}): {}
	local slot_metas = {}

	for slot_index, pet in player_data.inventory do
		local meta = pet_metas[pet.id]
		if not meta then continue end

		local copy = utils.deepcopy(meta)
		copy._slot = slot_index
		slot_metas[slot_index] = copy
	end

	return slot_metas
end

-- sorts by boost descending so the equip best feature always picks the
-- highest value pets. returns a flat array of slot indices ready for toggle_chunk.
local function sort_slots_by_boost(player_data: {}): {number}
	local slot_metas = build_slot_meta_map(player_data)

	-- Flatten the map into an array so table.sort can operate on it
	local meta_array = {}
	for _, meta in slot_metas do
		table.insert(meta_array, meta)
	end

	table.sort(meta_array, function(a, b)
		return a.boost > b.boost
	end)

	-- Discard metadata now that sorting is done; callers only need slot indices
	local sorted_slots = {}
	for _, meta in meta_array do
		table.insert(sorted_slots, meta._slot)
	end

	return sorted_slots
end

-- model names encode both the owner and the slot index so we can find them
-- without storing a separate reference map, even across server restarts.
local function build_model_name(player: Player, pet_slot_id: number): string
	return string.format("%s_%s", player.UserId, tostring(pet_slot_id))
end

-- generate physics constraints to ensure a smoothen pet movement
local function attach_physics_constraints(model: Model)
	local root = model.PrimaryPart

	-- AlignPosition smoothly drives the pet toward a world position each frame.
	-- MaxForce is set high so the pet tracks instantly, responsiveness is tuned
	-- via the position target update rate in _update_pets_model instead.
	local align_pos = Instance.new("AlignPosition")
	align_pos.MaxForce = math.huge
	align_pos.MaxVelocity = math.huge
	align_pos.Responsiveness = 200
	align_pos.Mode = Enum.PositionAlignmentMode.OneAttachment
	align_pos.Attachment0 = Instance.new("Attachment", root)
	align_pos.Parent = root

	-- AlignOrientation keeps the pet facing the same direction as the character.
	-- Without this the pet would spin freely based on physics collisions.
	local align_ori = Instance.new("AlignOrientation")
	align_ori.MaxTorque = math.huge
	align_ori.MaxAngularVelocity = math.huge
	align_ori.Responsiveness = 200
	align_ori.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align_ori.Attachment0 = align_pos.Attachment0
	align_ori.Parent = root
end

-- waits for a character before parenting because PrimaryPart based positioning
-- will error if the characters HumanoidRootPart does not exist yet.
function PetService:_generate_model(player: Player, meta_id: number, pet_slot_id: number)
	while not player.Character do
		task.wait()
	end

	local model = pet_metas[meta_id].model:Clone()
	model.Name = build_model_name(player, pet_slot_id)
	model.Parent = self.workspace_folder:FindFirstChild(player.UserId)

	attach_physics_constraints(model)
end

-- FindFirstChild avoids erroring when the model was already cleaned up by
-- another code path, such as a player leaving mid toggle.
function PetService:_destroy_model(player: Player, pet_slot_id: number)
	local player_folder = self.workspace_folder:FindFirstChild(player.UserId)
	if not player_folder then return end

	local model = player_folder:FindFirstChild(build_model_name(player, pet_slot_id))
	if not model then return end

	model:Destroy()
end

-- runs in a coroutine so the caller is never blocked waiting for the effect.
-- the brief transparency flicker sells the teleport without requiring a full
-- screen effect that could be disorienting.
function PetService:_teleport_pet_vfx(player: Player, pet_model: Model)
	task.spawn(function()
		local root = pet_model.PrimaryPart
		root.Transparency = 1

		task.wait(0.35)

		networking:fire(player, "play_audio", assets.sfx.pets.teleport_sfx)

		-- cloning the attachment rather than the whole VFX model keeps the
		-- particle anchor point local to the pet's root part automatically.
		local vfx = assets.vfx.TeleportVFX.TeleportVFX:Clone()
		vfx.Parent = root
		vfx.Teleport:Emit(60)

		task.wait(0.15)
		root.Transparency = 0

		-- debris is preferred over a manual task.delay destroy because it
		-- handles edge cases like the instance being reparented or destroyed early.
		game.Debris:AddItem(vfx, 0.4)
	end)
end

-- computes the target CFrame for a single pet given its column and row.
-- column drives lateral spread, row pushes pets further behind the character
-- so they arrange in a grid rather than stacking on top of each other.
local function compute_pet_target_cframe(character: Model, column: number, row: number): CFrame
	local lateral = POS_COLUMNS[column]
	local depth = (ROW_DEPTH_OFFSET * row) + ROW_BASE_DEPTH

	return character.PrimaryPart.CFrame * CFrame.new(lateral, 0, depth)
end

-- sine drives vertical bobbing while cosine tilts the pet forward/back.
-- applying both together mimics the hip oscillation seen in walk cycles.
local function apply_walk_animation(base_cframe: CFrame, character_cframe: CFrame): (CFrame, CFrame)
	local t = time() + WALK_ANIM_DELAY
	local vertical_bob = math.max(math.sin(t * WALK_ANIM_FREQ) / 2, -1) * WALK_ANIM_AMPLITUDE
	local forward_tilt = math.cos(t * WALK_ANIM_FREQ) / 7 * WALK_ANIM_TILT

	local animated_pos = base_cframe * CFrame.new(0, vertical_bob, 0)
	local animated_rot = character_cframe * CFrame.Angles(forward_tilt, 0, 0)

	return animated_pos, animated_rot
end

-- decides whether to smoothly follow or hard-teleport the pet.
-- teleporting prevents the pet from chasing the player across the map after
-- a respawn or teleport, which would look broken and could cause physics issues.
function PetService:_position_single_pet(player: Player, character: Model, pet_model: Model, column: number, row: number)
	local root = pet_model.PrimaryPart
	if not root then return end

	-- dont move pets if the character is dead to avoid them
	-- clustering on the respawn point when the humanoid transitions states.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local align_pos = root:FindFirstChildOfClass("AlignPosition")
	local align_ori = root:FindFirstChildOfClass("AlignOrientation")
	if not align_pos or not align_ori then return end

	local target_cframe = compute_pet_target_cframe(character, column, row)
	local character_facing = character.HumanoidRootPart.CFrame

	local is_moving = humanoid.MoveDirection.Magnitude > 0 and humanoid.WalkSpeed > 0
	if is_moving then
		target_cframe, character_facing = apply_walk_animation(target_cframe, character_facing)
	end

	local distance = (root.Position - character.PrimaryPart.Position).Magnitude

	if distance <= TELEPORT_THRESHOLD then
		align_pos.Position = target_cframe.Position
		align_ori.CFrame = character_facing
	else
		-- snap the root directly before updating the constraint targets so there
		-- is no oneframe lag where the constraints try to interpolate from far away.
		root.CFrame = CFrame.new(character.PrimaryPart.Position)
		align_pos.Position = target_cframe.Position
		align_ori.CFrame = character_facing

		self:_teleport_pet_vfx(player, pet_model)
	end
end

-- iterates all pets in a player folder and assigns each a column/row slot.
-- task.spawn is used so a slow pet model (example: one still loading) doesnt stall
-- the loop and delay positioning updates for the rest of the pets.
function PetService:_update_pets_model(player: Player, folder: Folder)
	local character = player.Character
	if not character or not character.PrimaryPart then return end

	local column = 1
	local row = 1

	for _, pet_model in folder:GetChildren() do
		local current_column = column
		local current_row = row

		task.spawn(function()
			self:_position_single_pet(player, character, pet_model, current_column, current_row)
		end)

		column += 1
		if column > PETS_PER_ROW then
			column = 1
			row += 1
		end
	end
end

-- handles a single pets equip or unequip. split from the chunk loop so the
-- equip guard logic (slot count vs maximum) is easy to read and test in isolation.
function PetService:_apply_equip(player: Player, player_data: {}, slot_index: number, mode: boolean, current_count: number): number
	local slot = player_data.inventory[slot_index]
	if not slot then return current_count end

	if mode then
		-- only equip if there is room. silently drop the request rather than
		-- erroring, since the client validates first and a mismatch is likely lag.
		if current_count >= player_data.equip_slots then return current_count end

		slot.equipped = true
		self:_generate_model(player, slot.id, slot_index)
		return current_count + 1
	else
		slot.equipped = false
		self:_destroy_model(player, slot_index)
		return current_count - 1
	end
end

-- processes a batch of slot indices in one call so callers dont need to loop
-- themselves. tracking the running total locally avoids repeated #get_equipped
-- calls inside the loop, which would recount on every iteration (O(n^2)).
function PetService:_toggle_chunk(player: Player, player_data: {}, chunk: {number}, mode: boolean)
	local equipped_count = self:get_equipped_amount(player, player_data)

	for _, slot_index in chunk do
		equipped_count = self:_apply_equip(player, player_data, slot_index, mode, equipped_count)
	end
end

-- creates the per-player folder in workspace and spawns models for any pets
-- that were already equipped when the session started (loaded from the profile).
local function on_player_added(self, player: Player)
	local player_data = get_player_data(player)

	local new_folder = Instance.new("Folder")
	new_folder.Name = player.UserId
	new_folder.Parent = self.workspace_folder

	local equipped_slots = get_equipped_slots(player_data)
	for _, slot_index in equipped_slots do
		local meta_id = player_data.inventory[slot_index].id
		self:_generate_model(player, meta_id, slot_index)
	end
end

-- destroys the folder and all pet models when the player leaves.
-- FindFirstChild guards against the rare case where the player disconnects
-- before PlayerAdded fully finishes setting up the folder.
local function on_player_removing(self, player: Player)
	local folder = self.workspace_folder:FindFirstChild(player.UserId)
	if folder then
		folder:Destroy()
	end
end

local function register_networking(self)
	networking:listen("toggle_pet", function(player: Player, inventory_id: number, mode: boolean)
		local player_data = get_player_data(player)
		self:_toggle_chunk(player, player_data, { inventory_id }, mode)
	end)

	networking:listen("get_equipped_amount", function(player: Player)
		local player_data = get_player_data(player)
		return self:get_equipped_amount(player, player_data)
	end)

	-- unequip all first so the max equip count is accurate before we start
	-- equipping the best pets. Without this step we would fill the remaining slots
	-- rather than replacing the whole equipped set.
	networking:listen("equip_best", function(player: Player)
		local player_data = get_player_data(player)
		local max_equip = player_data.equip_slots

		self:_toggle_chunk(player, player_data, get_equipped_slots(player_data), false)

		local sorted = sort_slots_by_boost(player_data)

		-- table.move copies only the first max_equip entries into a new table,
		-- so we never accidentally try to equip more than the cap allows.
		local best_chunk = {}
		table.move(sorted, 1, max_equip, 1, best_chunk)

		self:_toggle_chunk(player, player_data, best_chunk, true)
	end)

	-- deletion skips equipped pets intentionally, deleting an active pet would
	-- leave a floating model in the world with no inventory entry to clean it up.
	networking:listen("chunk_deletion_inventory", function(player: Player, chunk: {number})
		local profile = data:wait_for_profile(player)
		local inventory = profile.data.inventory

		for _, slot_id in chunk do
			local pet = inventory[slot_id]
			if not pet then continue end
			if pet.equipped then continue end

			table.remove(inventory, slot_id)
		end
	end)
end

-- registers the perframe update. runs on heartbeat (post physics) so pet
-- positions are set after roblox has already resolved character movement,
-- preventing oneframe jitter where the pet leads the character.
-- folders with no matching player are removed immediately to avoid accumulating
-- stale entries that would iterate every frame forever.
local function register_heartbeat(self)
	run_service.Heartbeat:Connect(function()
		for _, folder in self.workspace_folder:GetChildren() do
			local player = players:GetPlayerByUserId(tonumber(folder.Name))

			if not player then
				folder:Destroy()
				continue
			end

			task.spawn(function()
				self:_update_pets_model(player, folder)
			end)
		end
	end)
end

function PetService:_init()
	print("[PetService] Booting...")

	register_heartbeat(self)

	players.PlayerAdded:Connect(function(player: Player)
		on_player_added(self, player)
	end)

	players.PlayerRemoving:Connect(function(player: Player)
		on_player_removing(self, player)
	end)

	register_networking(self)
end

return PetService
