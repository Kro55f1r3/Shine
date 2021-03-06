--[[
	Shine extension system.

	Supports server side, client side and shared plugins.
]]

local include = Script.Load
local next = next
local pairs = pairs
local Notify = Shared.Message
local setmetatable = setmetatable
local StringExplode = string.Explode
local StringFormat = string.format

local function Print( ... )
	return Notify( StringFormat( ... ) )
end

local Hook = Shine.Hook

Shine.Plugins = {}

local AutoLoadPath = "config://shine/AutoLoad.json"
local ClientConfigPath = "config://shine/cl_plugins/"
local ExtensionPath = "lua/shine/extensions/"

--Here we collect every extension file so we can be sure it exists before attempting to load it.
local Files = {}
Shared.GetMatchingFileNames( ExtensionPath.."*.lua", true, Files )
local PluginFiles = {}

--Convert to faster table.
for i = 1, #Files do
	PluginFiles[ Files[ i ] ] = true
end

local PluginMeta = {}
PluginMeta.__index = PluginMeta

function PluginMeta:AddDTVar( Type, Name, Default, Access )
	self.DTVars = self.DTVars or {}
	self.DTVars.Keys = self.DTVars.Keys or {}
	self.DTVars.Defaults = self.DTVars.Defaults or {}
	self.DTVars.Access = self.DTVars.Access or {}

	self.DTVars.Keys[ Name ] = Type
	self.DTVars.Defaults[ Name ] = Default
	self.DTVars.Access[ Name ] = Access
end

function PluginMeta:InitDataTable( Name )
	self.dt = Shine:CreateDataTable( "Shine_DT_"..Name, self.DTVars.Keys, self.DTVars.Defaults, self.DTVars.Access )

	if self.NetworkUpdate then
		self.dt:__SetChangeCallback( self, self.NetworkUpdate )
	end

	self.DTVars = nil
end

function PluginMeta:GenerateDefaultConfig( Save )
	self.Config = self.DefaultConfig

	if Save then
		local Path = Server and Shine.Config.ExtensionDir..self.ConfigName or ClientConfigPath..self.ConfigName

		local Success, Err = Shine.SaveJSONFile( self.Config, Path )

		if not Success then
			Print( "Error writing %s config file: %s", self.__Name, Err )	

			return	
		end

		Print( "Shine %s config file created.", self.__Name )
	end
end

function PluginMeta:SaveConfig()
	local Path = Server and Shine.Config.ExtensionDir..self.ConfigName or ClientConfigPath..self.ConfigName

	local Success, Err = Shine.SaveJSONFile( self.Config, Path )

	if not Success then
		Print( "Error writing %s config file: %s", self.__Name, Err )	

		return	
	end

	if not self.SilentConfigSave then
		Print( "Shine %s config file updated.", self.__Name )
	end
end

function PluginMeta:LoadConfig()
	local Path = Server and Shine.Config.ExtensionDir..self.ConfigName or ClientConfigPath..self.ConfigName

	local PluginConfig = Shine.LoadJSONFile( Path )

	if not PluginConfig then
		self:GenerateDefaultConfig( true )

		return
	end

	self.Config = PluginConfig

	if self.CheckConfig and Shine.CheckConfig( self.Config, self.DefaultConfig ) then 
		self:SaveConfig() 
	end
end

if Server then
	--[[
		Bind a command to the plugin.
		If you call the base class Cleanup, the command will be removed on plugin unload.
	]]
	function PluginMeta:BindCommand( ConCommand, ChatCommand, Func, NoPerm, Silent )
		self.Commands = self.Commands or {}

		local Command  = Shine:RegisterCommand( ConCommand, ChatCommand, Func, NoPerm, Silent )

		self.Commands[ ConCommand ] = Command

		return Command
	end

	--[[
		Default cleanup will remove any bound commands.
		Override to add/change behaviour, call it with self.BaseClass.Cleanup( self ).
	]]
	function PluginMeta:Cleanup()
		if self.Commands then
			for k, Command in pairs( self.Commands ) do
				Shine:RemoveCommand( Command.ConCmd, Command.ChatCmd )
				self.Commands[ k ] = nil
			end
		end
	end
elseif Client then
	function PluginMeta:BindCommand( ConCommand, Func )
		self.Commands = self.Commands or {}

		local Command = Shine:RegisterClientCommand( ConCommand, Func )

		self.Commands[ ConCommand ] = Command

		return Command
	end

	function PluginMeta:Cleanup()
		if self.Commands then
			for k, Command in pairs( self.Commands ) do
				Shine:RemoveClientCommand( Command.ConCmd, Command.ChatCmd )
				self.Commands[ k ] = nil
			end
		end
	end
end

function Shine:RegisterExtension( Name, Table )
	self.Plugins[ Name ] = setmetatable( Table, PluginMeta )

	Table.BaseClass = PluginMeta
	Table.__Name = Name
end

function Shine:LoadExtension( Name, DontEnable )
	Name = Name:lower()

	if self.Plugins[ Name ] then return end

	local ClientFile = StringFormat( "%s%s/client.lua", ExtensionPath, Name )
	local ServerFile = StringFormat( "%s%s/server.lua", ExtensionPath, Name )
	local SharedFile = StringFormat( "%s%s/shared.lua", ExtensionPath, Name )
	
	local IsShared = PluginFiles[ ClientFile ] and PluginFiles[ SharedFile ] or PluginFiles[ ServerFile ]

	if PluginFiles[ SharedFile ] then
		include( SharedFile )

		local Plugin = self.Plugins[ Name ]

		if not Plugin then
			return false, "plugin did not register itself"
		end

		if Plugin.SetupDataTable then --Networked variables.
			Plugin:SetupDataTable()
			Plugin:InitDataTable( Name )
		end
	end

	--Client plugins load automatically, but enable themselves later when told to.
	if Client then
		local OldValue = Plugin
		Plugin = self.Plugins[ Name ]

		if PluginFiles[ ClientFile ] then
			include( ClientFile )
		end

		Plugin = OldValue --Just in case someone else uses Plugin as a global...

		return true
	end

	if not PluginFiles[ ServerFile ] then
		ServerFile = StringFormat( "%s%s.lua", ExtensionPath, Name )

		if not PluginFiles[ ServerFile ] then
			local Found

			local SearchTerm = StringFormat( "/%s.lua", Name )

			--In case someone uses a different case file name to the plugin name...
			for File in pairs( PluginFiles ) do
				local LowerF = File:lower()

				if LowerF:find( SearchTerm, 1, true ) then
					Found = true
					ServerFile = File

					break
				end
			end

			if not Found then
				return false, "plugin does not exist."
			end
		end
	end

	--Global value so that the server file has access to the same table the shared one created.
	local OldValue = Plugin

	if IsShared then
		Plugin = self.Plugins[ Name ]
	end

	include( ServerFile )

	--Clean it up afterwards ready for the next extension.
	if IsShared then
		Plugin = OldValue
	end

	local Plugin = self.Plugins[ Name ]

	if not Plugin then
		return false, "plugin did not register itself."
	end

	Plugin.IsShared = IsShared and true or nil

	if DontEnable then return true end
	
	return self:EnableExtension( Name )
end

--Shared extensions need to be enabled once the server tells it to.
function Shine:EnableExtension( Name )
	local Plugin = self.Plugins[ Name ]

	if not Plugin then
		return false, "plugin does not exist"
	end

	if Plugin.Enabled then
		self:UnloadExtension( Name )
	end

	if Plugin.HasConfig then
		Plugin:LoadConfig()
	end

	if Server and Plugin.IsShared and next( self.GameIDs ) then --We need to inform clients to enable the client portion.
		Server.SendNetworkMessage( "Shine_PluginEnable", { Plugin = Name, Enabled = true }, true )
	end

	return Plugin:Initialise()
end

function Shine:UnloadExtension( Name )
	local Plugin = self.Plugins[ Name ]

	if not Plugin then return end

	Plugin:Cleanup()

	Plugin.Enabled = false

	if Server and Plugin.IsShared and next( self.GameIDs ) then
		Server.SendNetworkMessage( "Shine_PluginEnable", { Plugin = Name, Enabled = false }, true )
	end

	Hook.Call( "OnPluginUnload", Name )
end

local ClientPlugins = {}

--[[
	Prepare shared plugins.

	Important to note: Shine does not support hot loading plugin files. 
	That is, it will only know about plugin files that were present when it started.
]]
for Path in pairs( PluginFiles ) do
	local Folders = StringExplode( Path, "/" )
	local Name = Folders[ 4 ]
	local File = Folders[ 5 ]

	if File and not ClientPlugins[ Name ] then
		if File:lower() == "shared.lua" then
			ClientPlugins[ Name ] = "boolean" --Generate the network message.
		end
		Shine:LoadExtension( Name, true ) --Shared plugins should load into memory for network messages.
	end
end

Shared.RegisterNetworkMessage( "Shine_PluginSync", ClientPlugins )
Shared.RegisterNetworkMessage( "Shine_PluginEnable", {
	Plugin = "string (25)",
	Enabled = "boolean"
} )

if Server then
	Shine.Hook.Add( "ClientConfirmConnect", "PluginSync", function( Client )
		local Message = {}

		for Name in pairs( ClientPlugins ) do
			if Shine.Plugins[ Name ] and Shine.Plugins[ Name ].Enabled then
				Message[ Name ] = true
			else
				Message[ Name ] = false
			end
		end

		Server.SendNetworkMessage( Client, "Shine_PluginSync", Message, true )
	end )
elseif Client then
	Client.HookNetworkMessage( "Shine_PluginSync", function( Data )
		for Name, Enabled in pairs( Data ) do
			if Enabled then
				Shine:EnableExtension( Name )
			end
		end
	end )

	Client.HookNetworkMessage( "Shine_PluginEnable", function( Data )
		local Name = Data.Plugin
		local Enabled = Data.Enabled

		if Enabled then
			Shine:EnableExtension( Name )
		else
			Shine:UnloadExtension( Name )
		end
	end )

	--[[
		Adds a plugin to be auto loaded on the client.
		This should only be used for client side plugins, not shared.

		Inputs: Plugin name, boolean AutoLoad.
	]]
	function Shine:SetPluginAutoLoad( Name, AutoLoad )
		if not self.AutoLoadPlugins then return end
		
		self.AutoLoadPlugins[ Name ] = AutoLoad and true or nil

		self.SaveJSONFile( self.AutoLoadPlugins, AutoLoadPath )
	end

	Hook.Add( "OnMapLoad", "AutoLoadExtensions", function()
		local AutoLoad = Shine.LoadJSONFile( AutoLoadPath )

		if not AutoLoad or not next( AutoLoad ) then
			Shine.AutoLoadPlugins = Shine.AutoLoadPlugins or {}

			return 
		end

		Shine.AutoLoadPlugins = AutoLoad

		for Plugin, Load in pairs( AutoLoad ) do
			if Load then
				Shine:EnableExtension( Plugin )
			end
		end
	end )
end
