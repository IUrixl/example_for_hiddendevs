-- example module i used for a datastore service within a game

local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local run_service = game:GetService("RunService")
local datastore = game:GetService("DataStoreService")

local shared = replicated_storage:WaitForChild("shared")

local prof_class = require(shared:WaitForChild("Profile"))
local networking = require(shared:WaitForChild("Networking"))

return {
	config = {
		studiokey = "Dev2",
		releasekey = "EarlyAccess.safe1",
		mixdata = false, -- Prevent data loss when switching between studio and production
		default_profile = {
      ["cash"] = 0,
			["settings"] = {
				["music"] = true,
				["low_detail"] = false,
				["time"] = 0
			}
		}
	},
	
	storage = {},
	
	wait_for_profile = function(self, player: Player)
		local profile = self.storage[player.UserId]
		
		local attempts = 0

		-- Wait for profile
		while not profile or not profile._loaded do 
			task.wait() 
			profile = self.storage[player.UserId] 
			attempts += 1 

			if attempts == 100 then 
				warn(string.format("[DataService] Error while returning get_settings for %s, exceeded 100 attempts", player.Name))
				player:Kick("Has sido expulsado por un error inesperado con los datos. No se debe a un error tuyo, porfavor intentalo de nuevo mas tarde.")
				break
			end
		end
		
		return profile
	end,
	
	_init = function(self)
		print("[DataService] Booting...")
		
		local database
		if run_service:IsStudio() and not self.config.mixdata then
			database = datastore:GetDataStore(self.config.studiokey)
		else
			database = datastore:GetDataStore(self.config.releasekey)
		end
		
		-- Load on joining
		players.PlayerAdded:Connect(function(player: Player)
			print(string.format("[DataService] Fetching data for %s", player.Name))
			
			local profile = prof_class.new()
			
			local fetch = database:GetAsync(player.UserId)
			if fetch then
				profile:load(fetch)
			else
				profile:load({})
			end
			
			profile:patch(self.config.default_profile)
			
			self.storage[player.UserId] = profile
			
			print(profile.data)
		end)
		
		-- Save on leaving
		local function save_data(player: Player)
			print(string.format("[DataService] Saving data for %s", player.Name))
			
			local profile = self.storage[player.UserId]
			if not profile then return end
			
			profile._locked = true -- prevent further changes
			
			database:SetAsync(player.UserId, profile.data)
		end
	
		players.PlayerRemoving:Connect(function(player: Player)
			save_data(player)
		end)
		
		game:BindToClose(function()
			for _, player in players:GetPlayers() do
				save_data(player)
			end
		end)
		
		-- Client events
		networking:listen("get_data", function(player: Player)
			local profile = self:wait_for_profile(player)
			
			return profile.data
		end)
		
		networking:listen("get_settings", function(player: Player)
			local profile = self:wait_for_profile(player)

			return profile.data.settings
		end)
		
		networking:listen("set_setting", function(player: Player, key: string, value: any)
			local profile = self:wait_for_profile(player)
			local player_settings = profile.data.settings
			
			-- verify settings exists and type is the same
			if self.config.default_profile.settings[key] == nil or typeof(value) ~= typeof(self.config.default_profile.settings[key]) then
				player:Kick("Has sido expulsado por comportamientos extraños en tus datos. Referencia: Intentando modificar ajustes de forma incorrecta. Si se detecta multiples veces podrias acabar baneado.")
				return
			end
			
			player_settings[key] = value
		end)
	end,
}
