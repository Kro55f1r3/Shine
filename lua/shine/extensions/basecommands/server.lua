--[[
	Shine basecommands system.
]]

local Shine = Shine

local Notify = Shared.Message
local Encode, Decode = json.encode, json.decode

local Clamp = math.Clamp
local Floor = math.floor
local StringFormat = string.format
local TableShuffle = table.Shuffle
local TableSort = table.sort

local Plugin = Plugin
Plugin.Version = "1.1"

Plugin.HasConfig = true
Plugin.ConfigName = "BaseCommands.json"

Plugin.Commands = {}

Plugin.DefaultConfig = {
	AllTalk = false,
	AllTalkPreGame = false,
	EjectVotesNeeded = 0.5,
	DisableLuaRun = false
}

Plugin.CheckConfig = true

function Plugin:Initialise()
	self.Gagged = {}

	self:CreateCommands()

	self.SetEjectVotes = false

	self.Config.EjectVotesNeeded = Clamp( self.Config.EjectVotesNeeded, 0, 1 )

	self.Enabled = true

	return true
end

function Plugin:Think()
	self.dt.AllTalk = self.Config.AllTalkPreGame

	if self.SetEjectVotes then return end

	local Gamerules = GetGamerules()

	if not Gamerules then return end
	
	Gamerules.team1.ejectCommVoteManager:SetTeamPercentNeeded( self.Config.EjectVotesNeeded )
	Gamerules.team2.ejectCommVoteManager:SetTeamPercentNeeded( self.Config.EjectVotesNeeded )

	self.SetEjectVotes = true
end

function Plugin:SetGameState( Gamerules, NewState, OldState )
	self.dt.Gamestate = NewState
end

--[[
	Override voice chat to allow everyone to hear each other with alltalk on.
]]
function Plugin:CanPlayerHearPlayer( Gamerules, Listener, Speaker )
	if Listener:GetClientMuted( Speaker:GetClientIndex() ) then return false end
	
	if self.Config.AllTalkPreGame and GetGamerules():GetGameState() == kGameState.NotStarted then return true end
	if self.Config.AllTalk then return true end
end

function Plugin:CreateCommands()
	local function Help( Client, Command )
		local CommandObj = Shine.Commands[ Command ]

		if not CommandObj then
			Shine:AdminPrint( Client, StringFormat( "%s is not a valid command.", Command ) )
			return
		end

		if not Shine:GetPermission( Client, Command ) then
			Shine:AdminPrint( Client, StringFormat( "You do not have access to %s.", Command ) )
			return
		end

		Shine:AdminPrint( Client, StringFormat( "%s: %s", Command, CommandObj.Help or "No help available." ) )
	end
	local HelpCommand = self:BindCommand( "sh_help", nil, Help, true )
	HelpCommand:AddParam{ Type = "string", TakeRestofLine = true, Error = "Please specify a command." }
	HelpCommand:Help( "<command> Displays usage information for the given command." )

	local function CommandsList( Client )
		local Commands = Shine.Commands

		if Client then
			ServerAdminPrint( Client, "Available commands:" )

			for Command, Object in pairs( Commands ) do
				if Shine:GetPermission( Client, Command ) then
					ServerAdminPrint( Client, StringFormat( "%s: %s", Command, Object.Help or "No help available." ) )
				end
			end

			ServerAdminPrint( Client, "End command list." )

			return
		end

		Notify( "Available commands:" )

		for Command, Object in pairs( Commands ) do
			Notify( StringFormat( "%s: %s", Command, Object.Help or "No help available." ) )
		end

		Notify( "End command list." )
	end
	local CommandList = self:BindCommand( "sh_helplist", nil, CommandsList, true )
	CommandList:Help( "Displays every command you have access to and their usage." )

	local function RCon( Client, Command )
		Shared.ConsoleCommand( Command )
		Shine:Print( "%s ran console command: %s", true, Client and Client:GetControllingPlayer():GetName() or "Console", Command )
	end
	local RConCommand = self:BindCommand( "sh_rcon", "rcon", RCon )
	RConCommand:AddParam{ Type = "string", TakeRestOfLine = true }
	RConCommand:Help( "<command> Executes a command on the server console." )

	local function SetPassword( Client, Password )
		Server.SetPassword( Password )
		Shine:AdminPrint( Client, "Password %s", true, Password ~= "" and "set to "..Password or "reset" )
	end
	local SetPasswordCommand = self:BindCommand( "sh_password", "password", SetPassword )
	SetPasswordCommand:AddParam{ Type = "string", TakeRestOfLine = true, Optional = true, Default = "" }
	SetPasswordCommand:Help( "<password> Sets the server password." )

	if not self.Config.DisableLuaRun then
		local function RunLua( Client, Code )
			local Player = Client and Client:GetControllingPlayer()

			local Name = Player and Player:GetName() or "Console"

			local Func, Err = loadstring( Code )

			if Func then
				Func()
				Shine:Print( "%s ran: %s", true, Name, Code )
			else
				Shine:Print( "Lua run failed. Error: %s", true, Err )
			end
		end
		local RunLuaCommand = self:BindCommand( "sh_luarun", "luarun", RunLua, false, true )
		RunLuaCommand:AddParam{ Type = "string", TakeRestOfLine = true }
		RunLuaCommand:Help( "Runs a string of Lua code on the server. Be careful with this." )
	end

	local function AllTalk( Client, Enable )
		self.Config.AllTalk = Enable

		local Enabled = Enable and "enabled" or "disabled"

		Shine:NotifyDualColour( nil, Enable and 0 or 255, Enable and 255 or 0, 0, "[All Talk]", 
			255, 255, 255, "All talk has been %s.", true, Enabled )
	end
	local AllTalkCommand = self:BindCommand( "sh_alltalk", "alltalk", AllTalk )
	AllTalkCommand:AddParam{ Type = "boolean", Optional = true, Default = function() return not self.Config.AllTalk end }
	AllTalkCommand:Help( "<true/false> Enable or disable all talk, which allows everyone to hear each others voice chat regardless of team." )

	local function Kick( Client, Target, Reason )
		Shine:Print( "%s kicked %s.%s", true, 
			Client and Client:GetControllingPlayer():GetName() or "Console", 
			Target:GetControllingPlayer():GetName(),
			Reason ~= "" and " Reason: "..Reason or ""
		)
		Server.DisconnectClient( Target )
	end
	local KickCommand = self:BindCommand( "sh_kick", "kick", Kick )
	KickCommand:AddParam{ Type = "client", NotSelf = true }
	KickCommand:AddParam{ Type = "string", Optional = true, TakeRestOfLine = true, Default = "" }
	KickCommand:Help( "<player> Kicks the given player." )

	local function Status( Client )
		local CanSeeIPs = Shine:HasAccess( Client, "sh_status" )

		local PlayerList = Shared.GetEntitiesWithClassname( "Player" )
		local Size = PlayerList:GetSize()

		local GameIDs = Shine.GameIDs
		local SortTable = {}
		local Count = 1

		for Client, ID in pairs( GameIDs ) do
			SortTable[ Count ] = { ID, Client }
			Count = Count + 1
		end

		TableSort( SortTable, function( A, B )
			if A[ 1 ] < B[ 1 ] then return true end
			return false
		end )

		if Client then
			ServerAdminPrint( Client, StringFormat( "Showing %s:", Size == 1 and "1 connected player" or Size.." connected players" ) )
			ServerAdminPrint( Client, StringFormat( "ID\t\tName\t\t\t\tSteam ID\t\t\t\t\t\t\t\t\t\t\t\tTeam%s", CanSeeIPs and "\t\t\t\t\t\tIP" or "" ) )
			ServerAdminPrint( Client, "=============================================================================" )
		else
			Notify( StringFormat( "Showing %s:", Size == 1 and "1 connected player" or Size.." connected players" ) )
			Notify( "ID\t\tName\t\t\t\tSteam ID\t\t\t\t\t\t\t\t\t\t\t\tTeam\t\t\t\t\t\tIP" )
			Notify( "=============================================================================" )
		end

		for i = 1, #SortTable do
			local Data = SortTable[ i ]

			local GameID = Data[ 1 ]
			local PlayerClient = Data[ 2 ]

			local Player = PlayerClient:GetControllingPlayer()

			local ID = PlayerClient:GetUserId()

			if Client then
				ServerAdminPrint( Client, StringFormat( "'%s'\t\t'%s'\t\t'%s'\t'%s'\t\t'%s'%s",
				GameID,
				Player:GetName(),
				ID,
				Shine.NS2ToSteamID( ID ),
				Shine:GetTeamName( Player:GetTeamNumber(), true ),
				CanSeeIPs and "\t\t"..IPAddressToString( Server.GetClientAddress( PlayerClient ) ) or "" ) )
			else
				Notify( StringFormat( "'%s'\t\t'%s'\t\t'%s'\t'%s'\t\t'%s'\t\t%s",
				GameID,
				Player:GetName(),
				ID,
				Shine.NS2ToSteamID( ID ),
				Shine:GetTeamName( Player:GetTeamNumber(), true ),
				IPAddressToString( Server.GetClientAddress( PlayerClient ) ) ) )
			end
		end
	end
	local StatusCommand = self:BindCommand( "sh_status", nil, Status, true )
	StatusCommand:Help( "Prints a list of all connected players and their relevant information." )

	local function ChangeLevel( Client, MapName )
		MapCycle_ChangeMap( MapName )
	end
	local ChangeLevelCommand = self:BindCommand( "sh_changelevel", "map", ChangeLevel )
	ChangeLevelCommand:AddParam{ Type = "string", TakeRestOfLine = true, Error = "Please specify a map to change to." }
	ChangeLevelCommand:Help( "<map> Changes the map to the given level immediately." )

	local function ListMaps( Client )
		local Maps = {}
		Shared.GetMatchingFileNames( "maps/*.level", false, Maps )

		Shine:AdminPrint( Client, "Installed maps:" )
		for _, MapPath in pairs( Maps ) do
			local MapName = MapPath:match( "maps/(.-).level" )
			Shine:AdminPrint( Client, StringFormat( "- %s", MapName ) )
		end
	end
	local ListMapsCommand = self:BindCommand( "sh_listmaps", nil, ListMaps )
	ListMapsCommand:Help( "Lists all installed maps on the server." )

	local function ResetGame( Client )
		local Gamerules = GetGamerules()
		if Gamerules then
			Gamerules:ResetGame()
		end
	end
	local ResetGameCommand = self:BindCommand( "sh_reset", "reset", ResetGame )
	ResetGameCommand:Help( "Resets the game round." )

	local function LoadPlugin( Client, Name )
		if Name == "basecommands" then
			Shine:AdminPrint( Client, "You cannot reload the basecommands plugin." )
			return
		end

		local Success, Err = Shine:EnableExtension( Name )

		if Success then
			Shine:AdminPrint( Client, StringFormat( "Plugin %s loaded successfully.", Name ) )
			Shine:SendPluginData( nil, Shine:BuildPluginData() ) --Update all players with the plugins state.
		else
			Shine:AdminPrint( Client, StringFormat( "Plugin %s failed to load. Error: %s", Name, Err ) )
		end
	end
	local LoadPluginCommand = self:BindCommand( "sh_loadplugin", nil, LoadPlugin )
	LoadPluginCommand:AddParam{ Type = "string", TakeRestOfLine = true, Error = "Please specify a plugin to load." }
	LoadPluginCommand:Help( "<plugin> Loads a plugin." )

	local function UnloadPlugin( Client, Name )
		if Name == "basecommands" and Shine.Plugins[ Name ] and Shine.Plugins[ Name ].Enabled then
			Shine:AdminPrint( Client, "Unloading the basecommands plugin is ill-advised. If you wish to do so, remove it from the active plugins list in your config." )
			return
		end

		if not Shine.Plugins[ Name ] or not Shine.Plugins[ Name ].Enabled then
			Shine:AdminPrint( Client, StringFormat( "The plugin %s is not loaded.", Name ) )
			return
		end

		Shine:UnloadExtension( Name )

		Shine:AdminPrint( Client, StringFormat( "The plugin %s unloaded successfully.", Name ) )

		Shine:SendPluginData( nil, Shine:BuildPluginData() )
	end
	local UnloadPluginCommand = self:BindCommand( "sh_unloadplugin", nil, UnloadPlugin )
	UnloadPluginCommand:AddParam{ Type = "string", TakeRestOfLine = true, Error = "Please specify a plugin to unload." }
	UnloadPluginCommand:Help( "<plugin> Unloads a plugin." )

	local function ListPlugins( Client )
		Shine:AdminPrint( Client, "Loaded plugins:" )
		for Name, Table in pairs( Shine.Plugins ) do
			if Table.Enabled then
				Shine:AdminPrint( Client, StringFormat( "%s - version: %s", Name, Table.Version or "1.0" ) )
			end
		end
	end
	local ListPluginsCommand = self:BindCommand( "sh_listplugins", nil, ListPlugins )
	ListPluginsCommand:Help( "Lists all loaded plugins." )

	local function ReloadUsers( Client )
		Shine:AdminPrint( Client, "Reloading users..." )
		Shine:LoadUsers( Shine.Config.GetUsersFromWeb, true )
	end
	local ReloadUsersCommand = self:BindCommand( "sh_reloadusers", nil, ReloadUsers )
	ReloadUsersCommand:Help( "Reloads the user data, either from the web or locally depending on your config settings." )

	local function ReadyRoom( Client, Targets )
		local Gamerules = GetGamerules()
		if Gamerules then
			for i = 1, #Targets do
				Gamerules:JoinTeam( Targets[ i ]:GetControllingPlayer(), kTeamReadyRoom, nil, true )
			end
		end
	end
	local ReadyRoomCommand = self:BindCommand( "sh_rr", "rr", ReadyRoom )
	ReadyRoomCommand:AddParam{ Type = "clients" }
	ReadyRoomCommand:Help( "<players> Sends the given player(s) to the ready room." )

	local function ForceRandom( Client, Targets )
		local Gamerules = GetGamerules()
		
		if Gamerules then
			TableShuffle( Targets )

			local NumPlayers = #Targets

			local TeamSequence = math.GenerateSequence( NumPlayers, { 1, 2 } )
			local TeamMembers = {
				{},
				{}
			}

			local TargetList = {}

			for i = 1, NumPlayers do
				local Player = Targets[ i ]:GetControllingPlayer()

				TargetList[ Player ] = true 
				Targets[ i ] = Player
				--Gamerules:JoinTeam( Targets[ i ]:GetControllingPlayer(), TeamSequence[ i ], nil, true )
			end

			local Players = Shine.GetAllPlayers()

			for i = 1, #Players do
				local Player = Players[ i ]

				if not TargetList[ Player ] then
					local TeamTable = TeamMembers[ Player:GetTeamNumber() ]

					if TeamTable then
						TeamTable[ #TeamTable + 1 ] = Player
					end
				end
			end

			for i = 1, NumPlayers do
				local Player = Targets[ i ]

				local TeamTable = TeamMembers[ TeamSequence[ i ] ]

				TeamTable[ #TeamTable + 1 ] = Player
			end

			Shine.EvenlySpreadTeams( Gamerules, TeamMembers )
		end
	end
	local ForceRandomCommand = self:BindCommand( "sh_forcerandom", "forcerandom", ForceRandom )
	ForceRandomCommand:AddParam{ Type = "clients" }
	ForceRandomCommand:Help( "<players> Forces the given player(s) onto a random team." )

	local function ChangeTeam( Client, Targets, Team )
		local Gamerules = GetGamerules()
		if Gamerules then
			for i = 1, #Targets do
				Gamerules:JoinTeam( Targets[ i ]:GetControllingPlayer(), Team, nil, true )
			end
		end
	end
	local ChangeTeamCommand = self:BindCommand( "sh_setteam", { "team", "setteam" }, ChangeTeam )
	ChangeTeamCommand:AddParam{ Type = "clients" }
	ChangeTeamCommand:AddParam{ Type = "team", Error = "Please specify either marines or aliens." }
	ChangeTeamCommand:Help( "<players> <marine/alien> Sets the given player(s) onto the given team." )

	local function AutoBalance( Client, Enable, UnbalanceAmount, Delay )
		Server.SetConfigSetting( "auto_team_balance", Enable and { enabled_on_unbalance_amount = UnbalanceAmount, enabled_after_seconds = Delay } or nil )
		if Enable then
			Shine:AdminPrint( Client, "Auto balance enabled. Player unbalance amount: %s. Delay: %s.", true, UnbalanceAmount, Delay )
		else
			Shine:AdminPrint( Client, "Auto balance disabled." )
		end
	end
	local AutoBalanceCommand = self:BindCommand( "sh_autobalance", "autobalance", AutoBalance )
	AutoBalanceCommand:AddParam{ Type = "boolean", Error = "Please specify whether auto balance should be enabled." }
	AutoBalanceCommand:AddParam{ Type = "number", Min = 1, Round = true, Optional = true, Default = 2 }
	AutoBalanceCommand:AddParam{ Type = "number", Min = 0, Round = true, Optional = true, Default = 10 }
	AutoBalanceCommand:Help( "<true/false> <player amount> <seconds> Enables or disables auto balance. Player amount and seconds are optional." )

	local function Eject( Client, Target )
		local Player = Target:GetControllingPlayer()

		if Player then
			if Player:isa( "Commander" ) then
				Player:Eject()
			else
				if Client then
					Shine:Notify( Client:GetControllingPlayer(), "Error", Shine.Config.ChatName, "%s is not a commander.", true, Player:GetName() )
				else
					Shine:Print( "%s is not a commander.", true, Player:GetName() )
				end
			end
		end
	end
	local EjectCommand = self:BindCommand( "sh_eject", "eject", Eject )
	EjectCommand:AddParam{ Type = "client" }
	EjectCommand:Help( "<player> Ejects the given commander." )

	local function AdminSay( Client, Message )
		Shine:Notify( nil, "All", Shine.Config.ChatName, Message )
	end
	local AdminSayCommand = self:BindCommand( "sh_say", "say", AdminSay, false, true )
	AdminSayCommand:AddParam{ Type = "string", MaxLength = kMaxChatLength, TakeRestOfLine = true, Error = "Please specify a message." }
	AdminSayCommand:Help( "<message> Sends a message to everyone from 'Admin'." )

	local function AdminTeamSay( Client, Team, Message )
		local Players = GetEntitiesForTeam( "Player", Team )
		
		Shine:Notify( Players, "Team", Shine.Config.ChatName, Message )
	end
	local AdminTeamSayCommand = self:BindCommand( "sh_teamsay", "teamsay", AdminTeamSay, false, true )
	AdminTeamSayCommand:AddParam{ Type = "team", Error = "Please specify either marines or aliens." }
	AdminTeamSayCommand:AddParam{ Type = "string", TakeRestOfLine = true, MaxLength = kMaxChatLength, Error = "Please specify a message." }
	AdminTeamSayCommand:Help( "<marine/alien> <message> Sends a messages to everyone on the given team from 'Admin'." )

	local function PM( Client, Target, Message )
		local Player = Target:GetControllingPlayer()

		if Player then
			Shine:Notify( Player, "PM", Shine.Config.ChatName, Message )
		end
	end
	local PMCommand = self:BindCommand( "sh_pm", "pm", PM )
	PMCommand:AddParam{ Type = "client", IgnoreCanTarget = true }
	PMCommand:AddParam{ Type = "string", TakeRestOfLine = true, Error = "Please specify a message to send.", MaxLength = kMaxChatLength }
	PMCommand:Help( "<player> <message> Sends a private message to the given player." )

	local function CSay( Client, Message )
		local Player = Client and Client:GetControllingPlayer()
		local PlayerName = Player and Player:GetName() or "Console"
		local ID = Client:GetUserId() or 0

		Shine:SendText( nil, Shine.BuildScreenMessage( 3, 0.5, 0.25, Message, 6, 255, 255, 255, 1, 2, 1 ) )
		Shine:AdminPrint( nil, "CSay from %s[%s]: %s", true, PlayerName, ID, Message )
	end
	local CSayCommand = self:BindCommand( "sh_csay", "csay", CSay )
	CSayCommand:AddParam{ Type = "string", TakeRestOfLine = true, Error = "Please specify a message to send.", MaxLength = 128 }
	CSayCommand:Help( "Displays a message in the centre of all player's screens." )

	local function GagPlayer( Client, Target, Duration )
		self.Gagged[ Target ] = Duration == 0 and true or Shared.GetTime() + Duration

		local Player = Client and Client:GetControllingPlayer()
		local PlayerName = Player and Player:GetName() or "Console"
		local ID = Client:GetUserId() or 0

		local TargetPlayer = Target:GetControllingPlayer()
		local TargetName = TargetPlayer and TargetPlayer:GetName() or "<unknown>"
		local TargetID = Target:GetUserId() or 0

		Shine:AdminPrint( nil, "%s[%s] gagged %s[%s]%s", true, PlayerName, ID, TargetName, TargetID,
			Duration == 0 and "" or " for "..string.TimeToString( Duration ) )
	end
	local GagCommand = self:BindCommand( "sh_gag", "gag", GagPlayer )
	GagCommand:AddParam{ Type = "client" }
	GagCommand:AddParam{ Type = "number", Round = true, Min = 0, Max = 1800, Optional = true, Default = 0 }
	GagCommand:Help( "<player> <duration> Silences the given player's chat. If no duration is given, it will hold for the remainder of the map." )

	local function UngagPlayer( Client, Target )
		local TargetPlayer = Target:GetControllingPlayer()
		local TargetName = TargetPlayer and TargetPlayer:GetName() or "<unknown>"
		local TargetID = Target:GetUserId() or 0

		if not self.Gagged[ Target ] then
			Shine:Notify( Client, "Error", Shine.Config.ChatName, "%s is not gagged.", true, TargetName )

			return
		end

		self.Gagged[ Target ] = nil

		local Player = Client and Client:GetControllingPlayer()
		local PlayerName = Player and Player:GetName() or "Console"
		local ID = Client:GetUserId() or 0

		Shine:AdminPrint( nil, "%s[%s] ungagged %s[%s]", true, PlayerName, ID, TargetName, TargetID )
	end
	local UngagCommand = self:BindCommand( "sh_ungag", "ungag", UngagPlayer )
	UngagCommand:AddParam{ Type = "client" }
	UngagCommand:Help( "<player> Stops silencing the given player's chat." )
end

--[[
	Facilitates the gag command.
]]
function Plugin:PlayerSay( Client, Message )
	local GagData = self.Gagged[ Client ]

	if not GagData then return end

	if GagData == true then return "" end
	
	if GagData > Shared.GetTime() then return "" end

	self.Gagged[ Client ] = nil
end
