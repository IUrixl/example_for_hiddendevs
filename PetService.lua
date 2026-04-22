local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")

local shared = replicated_storage:WaitForChild("shared")
local assets = replicated_storage:WaitForChild("assets")

local metas = replicated_storage:WaitForChild("metadatas")

local pet_metas = require(metas:WaitForChild("Pets"))

local networking = require(shared:WaitForChild("Networking"))
local data = require("./Data")
local utils = require(shared:WaitForChild("Utils"))

return {
	-- everything underscored should be considered as a private method
	workspace_folder = game.Workspace:WaitForChild("PetFolder"),
	
	pos_array = {
		[1] = 0,
		[2] = -4,
		[3] = 4
	},
	
	-- return an array with the equipped slots
	_get_equipped = function(self, player: Player, data: {}): {number}
		local r = {}
		
		for _, pet in data.inventory do
			if pet.equipped then
				table.insert(r, _)
			end
		end
		
		return r
	end,
	
	-- return the amount of equipped pets, useful for client checking and equip checking
	get_equipped_amount = function(self, player: Player, data: {}): number
		return #self:_get_equipped(player, data)
	end,
	
	-- equip/unequip pets provided within a chunk
	_toggle_chunk = function(self, player: Player, data: {}, chunk: {number}, mode: boolean)
		local total_equipped = self:get_equipped_amount(player, data)
		local maximum_equips = data.equip_slots
		
		-- to prevent users from equipping more than 1 pet we are going to check for the total equipped amount
		-- and make sure to only equip a pet if theres enough space.
		
		-- when not enough space the request will be dropped and that specific pet out of scope wont be equipped.
		for _, id in chunk do
			local slot = data.inventory[id]
			
			-- make sure it can only be equipped when theres space for it
			if mode and total_equipped < maximum_equips then
				slot.equipped = true
				total_equipped += 1
				
				self:_generate_model(player, slot.id, id)
			elseif not mode then
				slot.equipped = false
				total_equipped -= 1
				
				self:_destroy_model(player, id)
			end
		end
	end,
	
	-- avoid double lining
	_get_data = function(self, player: Player): {}
		local profile = data:wait_for_profile(player)
		return profile.data
	end,
	
	-- transform chunk of inventory slots to a chunk of metadatas
	_prepare_chunk_meta = function(self, player: Player, chunk: {number}): {}
		local r = {}
		
		for _, slot in chunk do
			local p = utils.deepcopy(pet_metas[slot.id]) -- copy the table to avoid sharing it
			
			if p then
				r[_] = p
				r[_]._slot = _
			end
		end
		
		return r
	end,
	
	-- sort best
	_sort_best = function(self, player: Player, data: {}): {}
		local inventory_meta = self:_prepare_chunk_meta(player, data.inventory)
		
		table.sort(inventory_meta, function(a, b)
			return a.boost > b.boost
		end)
		
		-- return chunk of slot ids
		local chunk = {}
		for _, pet in inventory_meta do
			table.insert(chunk, pet._slot)
		end
		
		return chunk
	end,
	
	-- teleport pet effects
	_teleport_pet_vfx = function(self, player: player, pet_model: Model)
		coroutine.wrap(function()
			pet_model.PrimaryPart.Transparency = 1
			
			task.wait(.35)
			
			-- sfx
			networking:fire(player, "play_audio", assets.sfx.pets.teleport_sfx)
			
			-- vfx
			local vfx_instance = assets.vfx.TeleportVFX.TeleportVFX:Clone() -- copy the attachment that contains the particles
			vfx_instance.Parent = pet_model.PrimaryPart
			vfx_instance.Teleport:Emit(60)
			
			task.wait(.15)
			pet_model.PrimaryPart.Transparency = 0
			
			game.Debris:AddItem(vfx_instance, 0.4) -- remove after a small time given
		end)()
	end,
	
	-- destroy pet model
	_destroy_model = function(self, player: Player, id: number)
		local model = self.workspace_folder:FindFirstChild(player.UserId):FindFirstChild(string.format("%s_%s", player.UserId, tostring(id)))
		
		if model then model:Destroy() end
	end,
	
	-- generate model
	_generate_model = function(self, player: Player, meta_id: number, pet_id: number)
		-- prevent generating pets without a character
		while not player.Character do task.wait() end
		
		local model = pet_metas[meta_id].model:Clone()
		model.Parent = self.workspace_folder:FindFirstChild(player.UserId)
		
		local body_gyro: BodyGyro = Instance.new("BodyGyro", model.PrimaryPart)
		body_gyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		
		local body_position: BodyPosition = Instance.new("BodyPosition", model.PrimaryPart)
		body_position.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		
		model.Name = string.format("%s_%s", player.UserId, tostring(pet_id))
	end,
	
	_update_pets_model = function(self, player: Player, folder)
		local character = player.Character
		
		local pos_index = 1
		local pos_row = 1
		for _, pet_model in folder:GetChildren() do
			task.spawn(function()
				if pos_index > 3 then
					pos_index = 1
					pos_row += 1
				end

				if not pet_model or not pet_model.PrimaryPart then return end
				
				local body_gyro = pet_model.PrimaryPart:WaitForChild("BodyGyro")
				local body_position = pet_model.PrimaryPart:WaitForChild("BodyPosition")
				
				local focus_cframe = character.PrimaryPart.CFrame * CFrame.new(self.pos_array[pos_index], 0, (4*pos_row)+1.5)
				local focus_angle = character.HumanoidRootPart.CFrame 

				-- walk animation
				local anim_delay = 1000
				local sine = math.max(math.sin((time() + anim_delay) * 10) / 2, -1) * 4
				local cosine = math.cos((time() + anim_delay) * 10)/7 * 3

				-- apply walk animation if player is moving
				if character.Humanoid.MoveDirection.Magnitude > 0 and character.Humanoid.WalkSpeed > 0 then
					focus_cframe *= CFrame.new(0, sine, 0)
					focus_angle *= CFrame.Angles(cosine, 0, 0)
				end

				-- update position
				local position_difference = (pet_model.PrimaryPart.Position - character.PrimaryPart.Position).Magnitude
				
				if character.Humanoid.Health > 0  then
					if position_difference < 25 then
						body_position.Position = focus_cframe.Position
						body_gyro.CFrame = focus_angle
					elseif position_difference > 25 then -- if the player is suddenly teleported or respawned and is far away from the pets, then teleport them to avoid weird movements
						pet_model.PrimaryPart.Position = character.PrimaryPart.Position
						
						-- vfx
						self:_teleport_pet_vfx(player, pet_model)
					end
				end

				pos_index += 1
			end)
		end
	end,
	
	-- innit module
	_init = function(self)
		print("[PetService] Booting...")
		
		-- update pets
		run_service.Heartbeat:Connect(function(dt)
			for _, folder in self.workspace_folder:GetChildren() do
				local player = players:GetPlayerByUserId(tonumber(folder.Name))
				
				if player then
					coroutine.wrap(function()
						self:_update_pets_model(player, folder)
					end)()
				else 
					folder:Destroy() -- avoid iterating for a nil player
				end
			end
		end)
		
		-- handle player events
		players.PlayerAdded:Connect(function(player: Player)
			local data = self:_get_data(player)
			
			local new_folder = Instance.new("Folder", self.workspace_folder)
			new_folder.Name = player.UserId
			
			local equipped_chunk = self:_get_equipped(player, data)
			
			for _, id in equipped_chunk do
				local meta_id = data.inventory[id].id
				self:_generate_model(player, meta_id, id)
			end
		end)
		
		players.PlayerRemoving:Connect(function(player: Player)
			self.workspace_folder:FindFirstChild(player.UserId):Destroy()
		end)
		
		-- networking
		networking:listen("toggle_pet", function(player: Player, inventory_id: number, mode: boolean)
			local data = self:_get_data(player)
			
			-- toggle pet
			self:_toggle_chunk(player, data, {inventory_id}, mode)
		end)
		
		networking:listen("get_equipped_amount", function(player: Player)
			local data = self:_get_data(player)
			
			return self:get_equipped_amount(player, data)
		end)

		networking:listen("equip_best", function(player: Player)
			local data = self:_get_data(player)
			local max_equip = data.equip_slots
			
			-- unequip everything first
			self:_toggle_chunk(player, data, self:_get_equipped(player, data), false)			
			
			-- get best pets			
			local sorted_inventory = self:_sort_best(player, data)		
			
			-- get max amount of pets
			local equipping_chunk = {}
			table.move(sorted_inventory, 1, max_equip, 1, equipping_chunk)
			
			-- equip chunk
			self:_toggle_chunk(player, data, equipping_chunk, true)
		end)
		
		networking:listen("chunk_deletion_inventory", function(player: Player, chunk: {number})
			local profile = data:wait_for_profile(player)
			local inventory = profile.data.inventory

			-- validate and remove
			for _, id in chunk do
				local pet = inventory[id]

				if pet and not pet.equipped then -- prevent removing equipped pet
					table.remove(inventory, id)
				end
			end
		end)
	end,
}
