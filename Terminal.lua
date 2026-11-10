--[[
    Terminal.lua  -  a Linux-style terminal UI library for Roblox (client side)

    Opens over the screen with a blurred background and gives you a tiny shell:
    a virtual filesystem, pipes (|), redirects (> >>), &&, ||, ;, $VARS, quoting,
    tab completion, history, a Lua REPL, executable "scripts", and a command API.

        local Terminal = loadstring(readfile("Terminal.lua"))()
        local term = Terminal.new({ Theme = "default" })
        term:Show()

    See README.md for the full API. Quick reference:

        term:Show() / :Hide() / :Toggle() / :Destroy()
        term:Print(text, color) / :Error(text) / :Warn(text) / :Clear()
        term:Execute("ls -l")                       -- run a command line as if typed
        term:RegisterCommand(name, def)             -- def = function(ctx) or { description, usage, values, run }
        term:SetTheme("dracula" | { ...overrides })
        term.fs:WriteFile / :MkDir / :AddExecutable / :ReadFile / :Remove / :List
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local LogService = game:GetService("LogService")
local CoreGui = game:GetService("CoreGui")

local BASE_ENV = (getfenv and getfenv()) or _G
local unpack = table.unpack or unpack
local INTERRUPT = "__TERMINAL_INTERRUPT__"
local INT_TOKEN = {}

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end

local function hex(c)
	return string.format("#%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function esc(s)
	s = tostring(s)
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub("\t", "    ")
	return s
end

local function unrich(s)
	s = s:gsub("<[^>]*>", "")
	s = s:gsub("&lt;", "<")
	s = s:gsub("&gt;", ">")
	s = s:gsub("&amp;", "&")
	return s
end

local function splitLines(s)
	local t = {}
	for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
	if t[#t] == "" then t[#t] = nil end
	return t
end

local function tween(obj, time, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function commonPrefix(list)
	local p = list[1]
	for i = 2, #list do
		local s = list[i]
		local n = 0
		while n < #p and n < #s and p:sub(n + 1, n + 1) == s:sub(n + 1, n + 1) do n = n + 1 end
		p = p:sub(1, n)
	end
	return p
end

local function guiParent()
	if gethui then
		local ok, r = pcall(gethui)
		if ok and r then return r end
	end
	local ok = pcall(function()
		local t = Instance.new("Folder")
		t.Parent = CoreGui
		t:Destroy()
	end)
	if ok then return CoreGui end
	local lp = Players.LocalPlayer
	return lp:WaitForChild("PlayerGui")
end

local function randomName()
	local t = {}
	for i = 1, 14 do t[i] = string.char(math.random(97, 122)) end
	return table.concat(t)
end

------------------------------------------------------------------------------
-- Themes
------------------------------------------------------------------------------

local Themes = {
	default = {
		bg = rgb(22, 24, 32), header = rgb(30, 32, 43), stroke = rgb(52, 56, 74),
		text = rgb(208, 214, 228), dim = rgb(112, 120, 142),
		user = rgb(130, 220, 140), path = rgb(110, 170, 255), bgTransparency = 0.03,
		palette = {
			red = rgb(255, 105, 120), green = rgb(130, 220, 140), yellow = rgb(240, 200, 110),
			blue = rgb(110, 170, 255), magenta = rgb(200, 150, 250), cyan = rgb(110, 215, 230),
			white = rgb(240, 242, 248), gray = rgb(112, 120, 142),
		},
	},
	ubuntu = {
		bg = rgb(48, 10, 36), header = rgb(60, 56, 54), stroke = rgb(90, 40, 74),
		text = rgb(238, 238, 236), dim = rgb(170, 150, 165),
		user = rgb(138, 226, 52), path = rgb(114, 159, 207), bgTransparency = 0.02,
		palette = {
			red = rgb(239, 41, 41), green = rgb(138, 226, 52), yellow = rgb(252, 233, 79),
			blue = rgb(114, 159, 207), magenta = rgb(173, 127, 168), cyan = rgb(52, 226, 226),
			white = rgb(238, 238, 236), gray = rgb(170, 150, 165),
		},
	},
	dracula = {
		bg = rgb(40, 42, 54), header = rgb(33, 34, 44), stroke = rgb(68, 71, 90),
		text = rgb(248, 248, 242), dim = rgb(98, 114, 164),
		user = rgb(80, 250, 123), path = rgb(189, 147, 249), bgTransparency = 0.03,
		palette = {
			red = rgb(255, 85, 85), green = rgb(80, 250, 123), yellow = rgb(241, 250, 140),
			blue = rgb(130, 160, 255), magenta = rgb(255, 121, 198), cyan = rgb(139, 233, 253),
			white = rgb(248, 248, 242), gray = rgb(98, 114, 164),
		},
	},
	gruvbox = {
		bg = rgb(40, 40, 40), header = rgb(29, 32, 33), stroke = rgb(80, 73, 69),
		text = rgb(235, 219, 178), dim = rgb(146, 131, 116),
		user = rgb(184, 187, 38), path = rgb(131, 165, 152), bgTransparency = 0.03,
		palette = {
			red = rgb(251, 73, 52), green = rgb(184, 187, 38), yellow = rgb(250, 189, 47),
			blue = rgb(131, 165, 152), magenta = rgb(211, 134, 155), cyan = rgb(142, 192, 124),
			white = rgb(235, 219, 178), gray = rgb(146, 131, 116),
		},
	},
}

local function resolveTheme(t)
	local base = Themes.default
	local out = { palette = {} }
	for k, v in pairs(base) do if k ~= "palette" then out[k] = v end end
	for k, v in pairs(base.palette) do out.palette[k] = v end
	if type(t) == "string" then t = Themes[t] or Themes.default end
	if type(t) == "table" then
		for k, v in pairs(t) do
			if k == "palette" then
				for pk, pv in pairs(v) do out.palette[pk] = pv end
			else
				out[k] = v
			end
		end
	end
	return out
end

------------------------------------------------------------------------------
-- Virtual filesystem
------------------------------------------------------------------------------

local FS = {}
FS.__index = FS

local function newDir()
	return { type = "dir", children = {}, mtime = os.time() }
end

function FS.new(home)
	local self = setmetatable({}, FS)
	self.root = newDir()
	self.home = home or "/"
	return self
end

function FS:Resolve(path, cwd, home)
	path = path or ""
	home = home or self.home
	if path == "~" then
		path = home
	elseif path:sub(1, 2) == "~/" then
		path = home .. path:sub(2)
	end
	if path:sub(1, 1) ~= "/" then path = (cwd or "/") .. "/" .. path end
	local stack = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then
			stack[#stack] = nil
		elseif part ~= "." then
			stack[#stack + 1] = part
		end
	end
	return "/" .. table.concat(stack, "/")
end

function FS:Get(path)
	local node = self.root
	for part in self:Resolve(path, "/"):gmatch("[^/]+") do
		if node.type ~= "dir" then return nil end
		node = node.children[part]
		if not node then return nil end
	end
	return node
end

function FS:Exists(path) return self:Get(path) ~= nil end
function FS:IsDir(path) local n = self:Get(path) return n ~= nil and n.type == "dir" end

function FS:_split(path)
	local abs = self:Resolve(path, "/")
	local dir, name = abs:match("^(.*)/([^/]+)$")
	if not name then return nil, nil end
	if dir == "" then dir = "/" end
	return dir, name
end

function FS:MkDir(path, parents)
	local abs = self:Resolve(path, "/")
	local node = self.root
	local parts = {}
	for part in abs:gmatch("[^/]+") do parts[#parts + 1] = part end
	for i, part in ipairs(parts) do
		local child = node.children[part]
		if not child then
			if i < #parts and not parents then return nil, "No such file or directory" end
			child = newDir()
			node.children[part] = child
		elseif child.type ~= "dir" then
			return nil, "Not a directory"
		elseif i == #parts and not parents then
			return nil, "File exists"
		end
		node = child
	end
	return node
end

-- opts: { append = bool, executable = bool, parents = bool (default true) }
function FS:WriteFile(path, content, opts)
	opts = opts or {}
	local dir, name = self:_split(path)
	if not name then return nil, "Is a directory" end
	local parent = self:Get(dir)
	if not parent then
		if opts.parents == false then return nil, "No such file or directory" end
		parent = self:MkDir(dir, true)
		if not parent then return nil, "Not a directory" end
	end
	if parent.type ~= "dir" then return nil, "Not a directory" end
	local node = parent.children[name]
	if node and node.type == "dir" then return nil, "Is a directory" end
	if not node then
		node = { type = "file", content = "", mtime = os.time() }
		parent.children[name] = node
	end
	content = tostring(content or "")
	node.content = opts.append and ((node.content or "") .. content) or content
	node.mtime = os.time()
	if opts.executable then node.executable = true end
	return node
end

function FS:ReadFile(path)
	local node = self:Get(path)
	if not node then return nil, "No such file or directory" end
	if node.type == "dir" then return nil, "Is a directory" end
	return node.content or ""
end

-- def: function(ctx) or { run = function(ctx), description, usage, values }
function FS:AddExecutable(path, def)
	if type(def) == "function" then def = { run = def } end
	local node, err = self:WriteFile(path, "", { executable = true })
	if not node then return nil, err end
	node.run = def.run
	node.description = def.description
	node.usage = def.usage
	node.values = def.values
	return node
end

function FS:Remove(path, recursive)
	local dir, name = self:_split(path)
	if not name then return false, "Permission denied" end
	local parent = self:Get(dir)
	local node = parent and parent.children and parent.children[name]
	if not node then return false, "No such file or directory" end
	if node.type == "dir" and next(node.children) and not recursive then return false, "Is a directory" end
	parent.children[name] = nil
	return true
end

function FS:List(path, hidden)
	local node = self:Get(path)
	if not node then return nil, "No such file or directory" end
	if node.type ~= "dir" then return nil, "Not a directory" end
	local out = {}
	for name, child in pairs(node.children) do
		if hidden or name:sub(1, 1) ~= "." then out[#out + 1] = { name = name, node = child } end
	end
	table.sort(out, function(a, b)
		local la, lb = a.name:lower(), b.name:lower()
		if la == lb then return a.name < b.name end
		return la < lb
	end)
	return out
end

local function isExec(node)
	return node.type == "file" and (node.run ~= nil or node.command ~= nil or node.executable == true
		or (node.content ~= nil and node.content:sub(1, 2) == "#!"))
end

------------------------------------------------------------------------------
-- Shell parsing (tokenizer + parser)
------------------------------------------------------------------------------

local function tokenize(line)
	local tokens, parts, lit = {}, {}, {}
	local started = false
	local function flushLit()
		if #lit > 0 then parts[#parts + 1] = table.concat(lit); lit = {} end
	end
	local function endWord()
		flushLit()
		if started then
			tokens[#tokens + 1] = { t = "w", parts = parts }
			parts = {}
			started = false
		end
	end
	local function push(v)
		if type(v) == "table" then flushLit(); parts[#parts + 1] = v else lit[#lit + 1] = v end
		started = true
	end
	local function varAt(i)
		local nxt = line:sub(i + 1, i + 1)
		if nxt == "?" then return { var = "?" }, i + 2 end
		if nxt == "{" then
			local j = line:find("}", i + 2, true)
			if j then return { var = line:sub(i + 2, j - 1) }, j + 1 end
		end
		local name = line:match("^[%a_][%w_]*", i + 1)
		if name then return { var = name }, i + 1 + #name end
		return "$", i + 1
	end

	local i, n = 1, #line
	while i <= n do
		local c = line:sub(i, i)
		local nx = line:sub(i + 1, i + 1)
		if c == "'" then
			local j = line:find("'", i + 1, true)
			if not j then return nil, "unexpected EOF while looking for matching `''" end
			push(line:sub(i + 1, j - 1))
			i = j + 1
		elseif c == '"' then
			started = true
			i = i + 1
			while true do
				if i > n then return nil, 'unexpected EOF while looking for matching `"\'' end
				local d = line:sub(i, i)
				if d == '"' then
					i = i + 1
					break
				elseif d == "\\" and line:sub(i + 1, i + 1):match('[\\"$`]') then
					push(line:sub(i + 1, i + 1))
					i = i + 2
				elseif d == "$" then
					local v, ni = varAt(i)
					push(v)
					i = ni
				else
					push(d)
					i = i + 1
				end
			end
		elseif c == "\\" then
			push(nx)
			i = i + 2
		elseif c == "$" then
			local v, ni = varAt(i)
			push(v)
			i = ni
		elseif c == "~" and not started and #lit == 0 and (nx == "" or nx == "/" or nx:match("%s")) then
			push({ var = "HOME" })
			i = i + 1
		elseif c:match("%s") then
			endWord()
			i = i + 1
		elseif c == "#" and not started and #lit == 0 then
			break
		elseif c == "|" then
			endWord()
			if nx == "|" then tokens[#tokens + 1] = { t = "op", v = "||" }; i = i + 2
			else tokens[#tokens + 1] = { t = "op", v = "|" }; i = i + 1 end
		elseif c == ">" then
			endWord()
			if nx == ">" then tokens[#tokens + 1] = { t = "op", v = ">>" }; i = i + 2
			else tokens[#tokens + 1] = { t = "op", v = ">" }; i = i + 1 end
		elseif c == ";" then
			endWord()
			tokens[#tokens + 1] = { t = "op", v = ";" }
			i = i + 1
		elseif c == "&" and nx == "&" then
			endWord()
			tokens[#tokens + 1] = { t = "op", v = "&&" }
			i = i + 2
		else
			push(c)
			i = i + 1
		end
	end
	endWord()
	return tokens
end

local function parse(tokens)
	local stmts, pipeline = {}, {}
	local conn = ";"
	local cmd = { words = {} }
	local function finishCmd()
		if #cmd.words == 0 then return false end
		pipeline[#pipeline + 1] = cmd
		cmd = { words = {} }
		return true
	end
	local i = 1
	while i <= #tokens do
		local tk = tokens[i]
		if tk.t == "w" then
			cmd.words[#cmd.words + 1] = tk
		else
			local op = tk.v
			if op == ">" or op == ">>" then
				local nx = tokens[i + 1]
				if not nx or nx.t ~= "w" then return nil, "syntax error near unexpected token `newline'" end
				cmd.redirect = { op = op, target = nx }
				i = i + 1
			elseif op == "|" then
				if not finishCmd() then return nil, "syntax error near unexpected token `|'" end
			else
				local had = finishCmd()
				if not had and #pipeline == 0 and op ~= ";" then
					return nil, "syntax error near unexpected token `" .. op .. "'"
				end
				if #pipeline > 0 then
					stmts[#stmts + 1] = { conn = conn, pipeline = pipeline }
					pipeline = {}
				end
				conn = op
			end
		end
		i = i + 1
	end
	finishCmd()
	if #pipeline > 0 then stmts[#stmts + 1] = { conn = conn, pipeline = pipeline } end
	return stmts
end

local function parseArgs(argv, values)
	local vset = {}
	if values then for _, v in ipairs(values) do vset[v] = true end end
	local args, flags = {}, {}
	local i, endFlags = 2, false
	while i <= #argv do
		local a = argv[i]
		if endFlags or a == "-" or not a:match("^%-") or a:match("^%-%d") then
			args[#args + 1] = a
		elseif a == "--" then
			endFlags = true
		elseif a:sub(1, 2) == "--" then
			local k, v = a:match("^%-%-([^=]+)=(.*)$")
			if k then
				flags[k] = v
			else
				local k2 = a:sub(3)
				if vset[k2] and argv[i + 1] then flags[k2] = argv[i + 1]; i = i + 1 else flags[k2] = true end
			end
		else
			for ci = 2, #a do
				local ch = a:sub(ci, ci)
				if vset[ch] and ci == #a and argv[i + 1] then flags[ch] = argv[i + 1]; i = i + 1 else flags[ch] = true end
			end
		end
		i = i + 1
	end
	return args, flags
end

------------------------------------------------------------------------------
-- Terminal
------------------------------------------------------------------------------

local Terminal = {}
Terminal.__index = Terminal
Terminal.Themes = Themes
Terminal.FS = FS
Terminal.Escape = esc
Terminal.Version = "1.0"

local DEFAULTS = {
	Title = nil,              -- nil = auto "user@host: ~/path"
	User = nil,               -- default: your Roblox username (lowercase)
	Host = "roblox",
	Theme = "default",        -- name from Terminal.Themes, or a table of overrides
	Font = Enum.Font.RobotoMono,
	TextSize = 15,
	Size = Vector2.new(780, 470),
	Blur = true,
	BlurSize = 22,
	Dim = 0.35,               -- background dim amount (0-1)
	ToggleKey = Enum.KeyCode.RightControl,
	MaxLines = 600,
	Motd = true,
	Draggable = true,
	Resizable = true,
	DisplayOrder = 10000,
}

function Terminal.new(config)
	local cfg = {}
	for k, v in pairs(DEFAULTS) do cfg[k] = v end
	for k, v in pairs(config or {}) do cfg[k] = v end

	local self = setmetatable({}, Terminal)
	self.Config = cfg
	self.Theme = resolveTheme(cfg.Theme)
	self.ThemeName = type(cfg.Theme) == "string" and cfg.Theme or "custom"
	self.Visible = false
	self.Destroyed = false

	local lp = Players.LocalPlayer
	self.user = cfg.User or (lp and lp.Name:lower():gsub("%s", "") or "user")
	self.host = cfg.Host
	self.home = "/home/" .. self.user
	self.cwd = self.home
	self.fs = FS.new(self.home)
	self.env = {
		USER = self.user, HOME = self.home, PWD = self.home, HOSTNAME = self.host,
		SHELL = "/bin/rbxsh", PATH = "/bin:/usr/local/bin", TERM = "xterm-256color",
		LANG = "en_US.UTF-8",
	}
	self.commands = {}
	self.history = {}
	self.lastStatus = 0
	self.startTime = os.clock()

	self._lines = {}
	self._order = 0
	self._conns = {}
	self._hIdx = 1

	self:_buildFS()
	self:_buildUI()
	self:_installBuiltins()
	self:_refreshPrompt()

	if cfg.Motd then
		self:Print("RbxTerm " .. Terminal.Version .. "  -  a tiny Linux-style shell for Roblox", "cyan")
		self:Print("Type 'help' for commands. Tab = complete, Up/Down = history, Ctrl+C = interrupt.", "gray")
		self:Print("")
	end
	return self
end

---------------------------------------------------------------- filesystem --

function Terminal:_buildFS()
	local fs, u = self.fs, self.user
	for _, d in ipairs({ "/bin", "/usr/local/bin", "/etc", "/tmp", "/home/" .. u, "/home/" .. u .. "/docs" }) do
		fs:MkDir(d, true)
	end
	fs:WriteFile("/etc/hostname", self.host .. "\n")
	fs:WriteFile("/etc/os-release", 'NAME="Roblox Linux"\nVERSION="1.0 (Luau)"\nID=roblox\nPRETTY_NAME="Roblox Linux 1.0"\n')
	fs:WriteFile("/home/" .. u .. "/.bashrc", "# ~/.bashrc\nexport EDITOR=none\n")
	fs:WriteFile("/home/" .. u .. "/docs/readme.txt",
		"Welcome to RbxTerm.\n\n" ..
		"  ls, cd, cat, mkdir, touch, rm, tree  - poke around the virtual filesystem\n" ..
		"  echo hi > file.txt                   - redirect output into a file\n" ..
		"  ls | grep scr                        - pipes work too\n" ..
		"  lua print('hello')                   - run Lua, output lands here\n" ..
		"  theme dracula                        - change the look\n")
end

------------------------------------------------------------------------------- UI --

function Terminal:_buildUI()
	local cfg, theme = self.Config, self.Theme
	local conns = self._conns
	local function conn(c) conns[#conns + 1] = c return c end

	local gui = Instance.new("ScreenGui")
	gui.Name = randomName()
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = cfg.DisplayOrder
	gui.Enabled = false
	if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
	gui.Parent = guiParent()
	self._gui = gui

	if cfg.Blur then
		local blur = Instance.new("BlurEffect")
		blur.Name = randomName()
		blur.Size = 0
		blur.Enabled = false
		blur.Parent = Lighting
		self._blur = blur
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Active = true
	overlay.Parent = gui

	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local w = math.min(cfg.Size.X, vp.X - 40)
	local h = math.min(cfg.Size.Y, vp.Y - 60)

	local window = Instance.new("CanvasGroup")
	window.Name = "Window"
	window.Size = UDim2.fromOffset(w, h)
	window.Position = UDim2.new(0.5, -w / 2, 0.5, -h / 2)
	window.BackgroundColor3 = theme.bg
	window.BackgroundTransparency = theme.bgTransparency
	window.BorderSizePixel = 0
	window.GroupTransparency = 1
	window.Parent = gui
	self._basePos = window.Position
	Instance.new("UICorner", window).CornerRadius = UDim.new(0, 10)
	local stroke = Instance.new("UIStroke", window)
	stroke.Color = theme.stroke
	stroke.Thickness = 1

	local HEADER = 34
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER)
	header.BackgroundColor3 = theme.header
	header.BorderSizePixel = 0
	header.Active = true
	header.Parent = window

	local divider = Instance.new("Frame")
	divider.Size = UDim2.new(1, 0, 0, 1)
	divider.Position = UDim2.new(0, 0, 1, -1)
	divider.BackgroundColor3 = theme.stroke
	divider.BorderSizePixel = 0
	divider.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -140, 1, 0)
	title.Position = UDim2.fromOffset(70, 0)
	title.Font = Enum.Font.GothamMedium
	title.TextSize = 13
	title.TextColor3 = theme.dim
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.Text = cfg.Title or "terminal"
	title.Parent = header

	local dotColors = { rgb(255, 95, 86), rgb(255, 189, 46), rgb(39, 201, 63) }
	local dots = {}
	for i = 1, 3 do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(12, 12)
		b.Position = UDim2.new(0, 14 + (i - 1) * 20, 0.5, -6)
		b.BackgroundColor3 = dotColors[i]
		b.Text = ""
		b.AutoButtonColor = false
		b.BorderSizePixel = 0
		b.Parent = header
		Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
		dots[i] = b
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Output"
	scroll.Position = UDim2.fromOffset(0, HEADER)
	scroll.Size = UDim2.new(1, 0, 1, -HEADER)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 5
	scroll.ScrollBarImageColor3 = theme.dim
	scroll.ScrollBarImageTransparency = 0.4
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = window
	local pad = Instance.new("UIPadding", scroll)
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 12)
	local layout = Instance.new("UIListLayout", scroll)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	-- input row (always the last element in the list)
	local rowH = cfg.TextSize + 4
	local row = Instance.new("Frame")
	row.Name = "InputRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, rowH)
	row.LayoutOrder = 1000000000
	row.Parent = scroll

	local prompt = Instance.new("TextLabel")
	prompt.BackgroundTransparency = 1
	prompt.Size = UDim2.new(1, 0, 1, 0)
	prompt.RichText = true
	prompt.Font = cfg.Font
	prompt.TextSize = cfg.TextSize
	prompt.TextColor3 = theme.text
	prompt.TextXAlignment = Enum.TextXAlignment.Left
	prompt.TextWrapped = false
	prompt.Text = ""
	prompt.Parent = row

	local input = Instance.new("TextBox")
	input.Name = "Input"
	input.BackgroundTransparency = 1
	input.ClearTextOnFocus = false
	input.MultiLine = false
	input.Font = cfg.Font
	input.TextSize = cfg.TextSize
	input.TextColor3 = theme.text
	input.TextXAlignment = Enum.TextXAlignment.Left
	input.PlaceholderText = ""
	input.Text = ""
	input.Position = UDim2.fromOffset(0, 0)
	input.Size = UDim2.new(1, 0, 1, 0)
	input.Parent = row

	local grip = Instance.new("TextLabel")
	grip.BackgroundTransparency = 1
	grip.Size = UDim2.fromOffset(16, 16)
	grip.Position = UDim2.new(1, -16, 1, -16)
	grip.Text = "◢"
	grip.Font = Enum.Font.Gotham
	grip.TextSize = 12
	grip.TextColor3 = theme.dim
	grip.TextTransparency = 0.5
	grip.Active = true
	grip.ZIndex = 5
	grip.Visible = cfg.Resizable
	grip.Parent = window

	self._ui = {
		overlay = overlay, window = window, stroke = stroke, header = header, divider = divider,
		title = title, scroll = scroll, prompt = prompt, input = input, grip = grip, row = row,
	}
	self._scroll, self._prompt, self._input, self._row, self._title = scroll, prompt, input, row, title
	self._window, self._overlay = window, overlay
	self._HEADER = HEADER

	-- keep the view pinned to the bottom as output arrives
	conn(scroll:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.AbsoluteCanvasSize.Y - scroll.AbsoluteSize.Y))
	end))

	-- position the input box after the prompt text
	local function layoutInput()
		local px = prompt.TextBounds.X + 4
		input.Position = UDim2.fromOffset(px, 0)
		input.Size = UDim2.new(1, -px, 1, 0)
	end
	self._layoutInput = layoutInput
	conn(prompt:GetPropertyChangedSignal("TextBounds"):Connect(layoutInput))

	-- click anywhere in the output to focus the input
	conn(scroll.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			task.defer(function() if self.Visible and row.Visible then input:CaptureFocus() end end)
		end
	end))

	conn(input.FocusLost:Connect(function(enter)
		if enter then self:_submit() end
		task.defer(function()
			if self.Visible and not self.Destroyed and row.Visible and not self._shaded then input:CaptureFocus() end
		end)
	end))

	conn(input:GetPropertyChangedSignal("Text"):Connect(function()
		local t = input.Text
		if t:find("[\t\n\r]") then
			local clean = t:gsub("[\t\n\r]", "")
			input.Text = clean
			if t:find("\t") and os.clock() - (self._tabAt or 0) > 0.15 then self:_complete() end
		end
	end))

	conn(UserInputService.InputBegan:Connect(function(inp, processed)
		local kc = inp.KeyCode
		if kc == cfg.ToggleKey and (self.Visible or not processed) then
			self:Toggle()
			return
		end
		if not self.Visible then return end
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		if self._busy and ctrl and kc == Enum.KeyCode.C then
			self:Interrupt()
			return
		end
		if not input:IsFocused() then return end
		if kc == Enum.KeyCode.Up then
			if self._hIdx > 1 then
				if self._hIdx == #self.history + 1 then self._draft = input.Text end
				self._hIdx = self._hIdx - 1
				self:_setInput(self.history[self._hIdx])
			end
		elseif kc == Enum.KeyCode.Down then
			if self._hIdx <= #self.history then
				self._hIdx = self._hIdx + 1
				self:_setInput(self.history[self._hIdx] or self._draft or "")
			end
		elseif kc == Enum.KeyCode.Tab then
			self._tabAt = os.clock()
			self:_complete()
		elseif ctrl and kc == Enum.KeyCode.L then
			self:Clear()
		elseif ctrl and kc == Enum.KeyCode.U then
			self:_setInput("")
		elseif ctrl and kc == Enum.KeyCode.C and not self._reader then
			local sel = input.SelectionStart
			if sel == -1 or sel == input.CursorPosition then
				self:_write(self:_promptMarkup() .. esc(input.Text) .. "^C\n")
				self:_setInput("")
			end
		end
	end))

	-- dragging
	if cfg.Draggable then
		local dragging, startMouse, startPos
		conn(header.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				startMouse = Vector2.new(i.Position.X, i.Position.Y)
				startPos = window.Position
			end
		end))
		conn(UserInputService.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				local d = Vector2.new(i.Position.X, i.Position.Y) - startMouse
				window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end))
		conn(UserInputService.InputEnded:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
				dragging = false
				self._basePos = window.Position
			end
		end))
	end

	-- resizing
	if cfg.Resizable then
		local resizing, startMouse, startSize
		conn(grip.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				resizing = true
				startMouse = Vector2.new(i.Position.X, i.Position.Y)
				startSize = window.AbsoluteSize
			end
		end))
		conn(UserInputService.InputChanged:Connect(function(i)
			if resizing and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				local d = Vector2.new(i.Position.X, i.Position.Y) - startMouse
				window.Size = UDim2.fromOffset(math.max(380, startSize.X + d.X), math.max(220, startSize.Y + d.Y))
			end
		end))
		conn(UserInputService.InputEnded:Connect(function(i)
			if resizing and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
				resizing = false
			end
		end))
	end

	-- window buttons: close / shade / maximize
	conn(dots[1].MouseButton1Click:Connect(function() self:Hide() end))
	conn(dots[2].MouseButton1Click:Connect(function() self:ToggleShade() end))
	conn(dots[3].MouseButton1Click:Connect(function() self:ToggleMaximize() end))
end

function Terminal:_setInput(text)
	self._input.Text = text
	task.defer(function()
		if not self.Destroyed then self._input.CursorPosition = #text + 1 end
	end)
end

function Terminal:ToggleMaximize()
	local w = self._window
	if self._maximized then
		self._maximized = false
		local s = self._restore
		tween(w, 0.2, { Size = s.size, Position = s.pos })
		self._basePos = s.pos
	else
		self._maximized = true
		self._restore = { size = w.Size, pos = w.Position }
		local pos = UDim2.fromOffset(20, 20)
		tween(w, 0.2, { Size = UDim2.new(1, -40, 1, -40), Position = pos })
		self._basePos = pos
	end
end

function Terminal:ToggleShade()
	local w = self._window
	if self._shaded then
		self._shaded = false
		tween(w, 0.2, { Size = self._shadeSize })
		self._input:CaptureFocus()
	else
		self._shaded = true
		self._shadeSize = w.Size
		self._input:ReleaseFocus()
		tween(w, 0.2, { Size = UDim2.new(w.Size.X.Scale, w.Size.X.Offset, 0, self._HEADER) })
	end
end

------------------------------------------------------------------ theming --

function Terminal:SetTheme(t)
	self.Theme = resolveTheme(t)
	self.ThemeName = type(t) == "string" and t or "custom"
	local th, ui = self.Theme, self._ui
	ui.window.BackgroundColor3 = th.bg
	ui.window.BackgroundTransparency = th.bgTransparency
	ui.stroke.Color = th.stroke
	ui.header.BackgroundColor3 = th.header
	ui.divider.BackgroundColor3 = th.stroke
	ui.title.TextColor3 = th.dim
	ui.scroll.ScrollBarImageColor3 = th.dim
	ui.prompt.TextColor3 = th.text
	ui.input.TextColor3 = th.text
	ui.grip.TextColor3 = th.dim
	for _, l in ipairs(self._lines) do l.label.TextColor3 = th.text end
	self:_refreshPrompt()
end

function Terminal:_color(color)
	if typeof(color) == "Color3" then return color end
	if type(color) == "string" then
		return self.Theme.palette[color] or self.Theme[color] or self.Theme.text
	end
	return self.Theme.text
end

-- plain text -> rich-text markup (escaped, optionally colored/bold)
function Terminal:Colorize(text, color, bold)
	local m = esc(text)
	if color or bold then
		local open, close = "", ""
		if color then
			open = '<font color="' .. hex(self:_color(color)) .. '">'
			close = "</font>"
		end
		if bold then open = open .. "<b>"; close = "</b>" .. close end
		m = m:gsub("[^\n]+", function(s) return open .. s .. close end)
	end
	return m
end

---------------------------------------------------------------- output ------

function Terminal:_newLine()
	self._order = self._order + 1
	local cfg = self.Config
	local l = Instance.new("TextLabel")
	l.Name = "Line"
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.RichText = true
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Font = cfg.Font
	l.TextSize = cfg.TextSize
	l.TextColor3 = self.Theme.text
	l.LayoutOrder = self._order
	l.Text = " "
	l.Parent = self._scroll
	local entry = { label = l, markup = "" }
	self._lines[#self._lines + 1] = entry
	if #self._lines > cfg.MaxLines then
		local old = table.remove(self._lines, 1)
		if self._open == old then self._open = nil end
		old.label:Destroy()
	end
	return entry
end

-- write rich-text markup; a trailing "\n" closes the current line
function Terminal:_write(markup)
	if self.Destroyed then return end
	local pos = 1
	while true do
		local nl = markup:find("\n", pos, true)
		local piece = nl and markup:sub(pos, nl - 1) or markup:sub(pos)
		if piece ~= "" or nl then
			local e = self._open or self:_newLine()
			self._open = e
			e.markup = e.markup .. piece
			e.label.Text = e.markup == "" and " " or e.markup
		end
		if nl then
			self._open = nil
			pos = nl + 1
			if pos > #markup then break end
		else
			break
		end
	end
end

function Terminal:Print(text, color, bold)
	self:_write(self:Colorize(tostring(text == nil and "" or text), color, bold) .. "\n")
end
function Terminal:Error(text) self:Print(text, "red") end
function Terminal:Warn(text) self:Print(text, "yellow") end
function Terminal:Success(text) self:Print(text, "green") end
function Terminal:PrintRich(markup) self:_write(markup .. "\n") end

function Terminal:Clear()
	for _, l in ipairs(self._lines) do l.label:Destroy() end
	self._lines = {}
	self._open = nil
end

-- mirror the Roblox developer console into the terminal
function Terminal:MirrorConsole(on)
	if self._logConn then self._logConn:Disconnect(); self._logConn = nil end
	if on then
		self._logConn = LogService.MessageOut:Connect(function(msg, mtype)
			local color = "gray"
			if mtype == Enum.MessageType.MessageError then color = "red"
			elseif mtype == Enum.MessageType.MessageWarning then color = "yellow" end
			self:Print("[log] " .. msg, color)
		end)
	end
end

-------------------------------------------------------------------- prompt --

function Terminal:_displayPath(p)
	if p == self.home then return "~" end
	if p:sub(1, #self.home + 1) == self.home .. "/" then return "~" .. p:sub(#self.home + 1) end
	return p
end

function Terminal:_promptMarkup()
	local t = self.Theme
	return string.format('<font color="%s"><b>%s@%s</b></font>:<font color="%s"><b>%s</b></font>$ ',
		hex(t.user), esc(self.user), esc(self.host), hex(t.path), esc(self:_displayPath(self.cwd)))
end

function Terminal:_refreshPrompt()
	if self.Destroyed then return end
	self._prompt.Text = self._promptOverride or self:_promptMarkup()
	self._layoutInput()
	if not self.Config.Title then
		self._title.Text = string.format("%s@%s: %s", self.user, self.host, self:_displayPath(self.cwd))
	end
end

function Terminal:SetTitle(t)
	self.Config.Title = t
	self._title.Text = t or ""
	self:_refreshPrompt()
end

------------------------------------------------------------- show / hide ----

function Terminal:Show()
	if self.Visible or self.Destroyed then return end
	self.Visible = true
	local th = self.Theme
	self._gui.Enabled = true
	if self._blur then
		self._blur.Enabled = true
		tween(self._blur, 0.35, { Size = self.Config.BlurSize })
	end
	tween(self._overlay, 0.3, { BackgroundTransparency = 1 - self.Config.Dim })
	self._window.Position = self._basePos + UDim2.fromOffset(0, 16)
	tween(self._window, 0.3, { GroupTransparency = 0, Position = self._basePos })
	task.delay(0.05, function()
		if self.Visible and self._row.Visible then self._input:CaptureFocus() end
	end)
end

function Terminal:Hide()
	if not self.Visible or self.Destroyed then return end
	self.Visible = false
	self._input:ReleaseFocus()
	if self._blur then tween(self._blur, 0.25, { Size = 0 }) end
	tween(self._overlay, 0.25, { BackgroundTransparency = 1 })
	tween(self._window, 0.25, { GroupTransparency = 1, Position = self._basePos + UDim2.fromOffset(0, 16) })
	task.delay(0.28, function()
		if not self.Visible and not self.Destroyed then
			self._gui.Enabled = false
			if self._blur then self._blur.Enabled = false end
		end
	end)
end

function Terminal:Toggle()
	if self.Visible then self:Hide() else self:Show() end
end

function Terminal:Destroy()
	if self.Destroyed then return end
	self.Destroyed = true
	self.Visible = false
	self:MirrorConsole(false)
	for _, c in ipairs(self._conns) do c:Disconnect() end
	if self._reader then
		local r = self._reader
		self._reader = nil
		r(INT_TOKEN)
	end
	self._gui:Destroy()
	if self._blur then self._blur:Destroy() end
end

------------------------------------------------------------- input / exec ---

function Terminal:_submit()
	local line = self._input.Text
	self._input.Text = ""
	if self._reader then
		local r = self._reader
		self._reader = nil
		self:_write((self._promptOverride or "") .. esc(line) .. "\n")
		self._promptOverride = nil
		self._row.Visible = false
		r(line)
		return
	end
	if self._busy then return end
	self:_write(self:_promptMarkup() .. esc(line) .. "\n")
	if line:match("%S") then
		if self.history[#self.history] ~= line then self.history[#self.history + 1] = line end
		self._hIdx = #self.history + 1
		self._draft = nil
		self:Run(line)
	end
end

-- run a command line (no echo)
function Terminal:Run(line)
	if self._busy or self.Destroyed then return false end
	self._busy = true
	self._interrupt = false
	self._row.Visible = false
	task.spawn(function()
		local ok, err = pcall(self._execLine, self, line)
		if not ok and not tostring(err):find(INTERRUPT, 1, true) then
			self:Error("bash: " .. tostring(err))
			self.lastStatus = 1
		end
		self._busy = false
		self._reader = nil
		self._promptOverride = nil
		if self.Destroyed then return end
		self._row.Visible = true
		self:_refreshPrompt()
		if self.Visible then self._input:CaptureFocus() end
	end)
	return true
end

-- run a command line as if the user typed it (echoes the prompt + line)
function Terminal:Execute(line)
	if self._busy then return false end
	self:_write(self:_promptMarkup() .. esc(line) .. "\n")
	return self:Run(line)
end

function Terminal:Interrupt()
	if not self._busy then return end
	self._interrupt = true
	self:_write("^C\n")
	if self._reader then
		local r = self._reader
		self._reader = nil
		self._promptOverride = nil
		r(INT_TOKEN)
	end
end

function Terminal:_expandWord(tok)
	local out = {}
	for _, p in ipairs(tok.parts) do
		if type(p) == "string" then
			out[#out + 1] = p
		elseif p.var == "?" then
			out[#out + 1] = tostring(self.lastStatus)
		else
			out[#out + 1] = self.env[p.var] or ""
		end
	end
	return table.concat(out)
end

function Terminal:_execLine(line)
	local first, rest = line:match("^%s*(%S+)%s*(.*)$")
	if not first then return end

	-- "raw" commands (lua) receive the rest of the line verbatim
	local def = self.commands[first]
	if def and def.raw then
		self.lastStatus = self:_runCommand({ first, rest }, nil, nil, rest)
		return
	end

	local tokens, terr = tokenize(line)
	if not tokens then self:Error("bash: " .. terr); self.lastStatus = 2; return end
	local stmts, perr = parse(tokens)
	if not stmts then self:Error("bash: " .. perr); self.lastStatus = 2; return end

	for _, st in ipairs(stmts) do
		if self._interrupt then break end
		local skip = (st.conn == "&&" and self.lastStatus ~= 0) or (st.conn == "||" and self.lastStatus == 0)
		if not skip then self.lastStatus = self:_runPipeline(st.pipeline) end
	end
end

function Terminal:_runPipeline(pipeline)
	local stdin, status = nil, 0
	for idx, cmd in ipairs(pipeline) do
		local last = idx == #pipeline
		local argv = {}
		for _, w in ipairs(cmd.words) do argv[#argv + 1] = self:_expandWord(w) end
		local capture = (not last) or cmd.redirect ~= nil
		local buf = {}
		local out = capture and function(s) buf[#buf + 1] = s end or nil
		status = self:_runCommand(argv, stdin, out)
		if capture then
			local text = table.concat(buf)
			if last then
				local path = self:_expandWord(cmd.redirect.target)
				local abs = self.fs:Resolve(path, self.cwd, self.home)
				local node, err = self.fs:WriteFile(abs, text, { append = cmd.redirect.op == ">>", parents = false })
				if not node then self:Error("bash: " .. path .. ": " .. err); status = 1 end
			else
				stdin = text
			end
		end
		if self._interrupt then break end
	end
	return status
end

function Terminal:_resolveCommand(name)
	if name:find("/") then
		local abs = self.fs:Resolve(name, self.cwd, self.home)
		local node = self.fs:Get(abs)
		if not node then return nil, name .. ": No such file or directory", 127 end
		if node.type == "dir" then return nil, name .. ": Is a directory", 126 end
		if not isExec(node) then return nil, name .. ": Permission denied", 126 end
		if node.command then
			local d = self.commands[node.command]
			if d then return d end
		end
		return node
	end
	local def = self.commands[name]
	if def then return def end
	for dir in (self.env.PATH or ""):gmatch("[^:]+") do
		local node = self.fs:Get(dir .. "/" .. name)
		if node and node.type == "file" and isExec(node) then
			if node.command and self.commands[node.command] then return self.commands[node.command] end
			return node
		end
	end
	return nil, name .. ": command not found", 127
end

function Terminal:_runCommand(argv, stdin, out, raw)
	local name = argv[1]
	local target, err, code = self:_resolveCommand(name)
	if not target then
		self:Error("bash: " .. err)
		return code
	end
	local ctx = self:_makeCtx(argv, stdin, out, target, raw)
	if ctx.flags.help and target.usage then
		ctx.print("Usage: " .. target.usage)
		if target.description then ctx.print(target.description) end
		return 0
	end
	local ok, res = pcall(function()
		if target.run then return target.run(ctx) end
		if target.content then return self:_runLua(target.content:gsub("^#![^\n]*", ""), name, ctx) end
		return 0
	end)
	if not ok then
		if tostring(res):find(INTERRUPT, 1, true) then return 130 end
		ctx.error(name .. ": " .. tostring(res))
		return 1
	end
	return tonumber(res) or 0
end

function Terminal:_makeCtx(argv, stdin, out, target, raw)
	local term = self
	local args, flags = parseArgs(argv, target.values)
	local ctx = {
		term = term, fs = term.fs, env = term.env, name = argv[1], argv = argv,
		args = args, flags = flags, stdin = stdin, raw = raw, tty = out == nil, cwd = term.cwd,
	}

	local function tostrings(...)
		local t = {}
		for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
		return t
	end

	function ctx.write(text, color, bold)
		text = tostring(text)
		if out then out(text) else term:_write(term:Colorize(text, color, bold)) end
	end
	function ctx.writeRich(markup)
		if out then out(unrich(markup)) else term:_write(markup) end
	end
	function ctx.print(...)
		ctx.write(table.concat(tostrings(...), "\t") .. "\n")
	end
	function ctx.printc(color, ...)
		ctx.write(table.concat(tostrings(...), "\t") .. "\n", color)
	end
	function ctx.printRich(markup) ctx.writeRich(markup .. "\n") end
	function ctx.error(msg) term:_write(term:Colorize(tostring(msg), "red") .. "\n") end
	function ctx.warn(msg) term:_write(term:Colorize(tostring(msg), "yellow") .. "\n") end
	function ctx.color(color, text, bold) return term:Colorize(text, color, bold) end
	function ctx.resolve(path) return term.fs:Resolve(path, term.cwd, term.home) end
	function ctx.cancelled() return term._interrupt == true end
	function ctx.sleep(n)
		local t = os.clock()
		repeat
			task.wait(0.03)
			if term._interrupt then error(INTERRUPT, 0) end
		until os.clock() - t >= (n or 0)
	end
	function ctx.read(promptText)
		if term._interrupt then error(INTERRUPT, 0) end
		local co = coroutine.running()
		term._promptOverride = esc(promptText or "")
		term._reader = function(v) task.spawn(co, v) end
		term._row.Visible = true
		term:_refreshPrompt()
		if term.Visible then term._input:CaptureFocus() end
		local v = coroutine.yield()
		if v == INT_TOKEN then error(INTERRUPT, 0) end
		return v
	end
	return ctx
end

----------------------------------------------------------------- Lua runner --

function Terminal:_makeLuaEnv(ctx)
	local function tostrings(...)
		local t = {}
		for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
		return t
	end
	return setmetatable({
		print = ctx.print,
		warn = function(...) ctx.warn(table.concat(tostrings(...), "\t")) end,
		args = ctx.args, flags = ctx.flags, argv = ctx.argv, stdin = ctx.stdin,
		term = self, ctx = ctx, fs = self.fs,
		read = ctx.read, sleep = ctx.sleep,
		io = {
			write = function(...) ctx.write(table.concat(tostrings(...))) end,
			read = ctx.read,
		},
		exit = function(code) error({ __exit = code or 0 }, 0) end,
	}, { __index = BASE_ENV })
end

function Terminal:_runLua(src, chunk, ctx, env)
	local loader = loadstring or load
	if not loader then
		ctx.error("lua: loadstring is not available in this environment")
		return 1
	end
	local fn, err = loader(src, "=" .. chunk)
	if not fn then
		ctx.error(tostring(err))
		return 1
	end
	env = env or self:_makeLuaEnv(ctx)
	if setfenv then pcall(setfenv, fn, env) end
	local ok, e = pcall(fn, unpack(ctx.args))
	if ok then return 0 end
	if type(e) == "table" and e.__exit then return e.__exit end
	if tostring(e):find(INTERRUPT, 1, true) then error(INTERRUPT, 0) end
	ctx.error(tostring(e))
	return 1
end

function Terminal:_repl(ctx)
	local loader = loadstring or load
	if not loader then ctx.error("lua: loadstring is not available") return 1 end
	local env = self:_makeLuaEnv(ctx)
	ctx.printc("gray", "Luau REPL - type 'exit' to leave. print() goes to this terminal.")
	while true do
		local line = ctx.read("lua> ")
		if line == nil or line == "exit" or line == "quit" then break end
		if line:match("%S") then
			local fn = loader("return " .. line, "=repl")
			if fn then
				if setfenv then pcall(setfenv, fn, env) end
				local res = table.pack(pcall(fn))
				if res[1] then
					if res.n > 1 then
						local parts = {}
						for i = 2, res.n do parts[#parts + 1] = tostring(res[i]) end
						ctx.printc("cyan", table.concat(parts, "\t"))
					end
				else
					if tostring(res[2]):find(INTERRUPT, 1, true) then error(INTERRUPT, 0) end
					ctx.error(tostring(res[2]))
				end
			else
				self:_runLua(line, "repl", ctx, env)
			end
		end
	end
	return 0
end

-------------------------------------------------------------- tab complete --

function Terminal:_complete()
	local input = self._input
	local text = input.Text
	local before, word = text:match("^(.*%s)(%S*)$")
	if not before then before, word = "", text end
	local isCmd = before:match("^%s*$") ~= nil
	local cands, seen = {}, {}
	local function add(s) if not seen[s] then seen[s] = true; cands[#cands + 1] = s end end

	if isCmd and not word:find("/") then
		for name in pairs(self.commands) do
			if name:sub(1, #word) == word then add(name) end
		end
		for dir in (self.env.PATH or ""):gmatch("[^:]+") do
			for _, e in ipairs(self.fs:List(dir, false) or {}) do
				if e.name:sub(1, #word) == word and isExec(e.node) then add(e.name) end
			end
		end
	else
		local dirPart, base = word:match("^(.*/)([^/]*)$")
		if not dirPart then dirPart, base = "", word end
		local absDir = self.fs:Resolve(dirPart == "" and "." or dirPart, self.cwd, self.home)
		for _, e in ipairs(self.fs:List(absDir, base:sub(1, 1) == ".") or {}) do
			if e.name:sub(1, #base) == base then
				add(dirPart .. e.name .. (e.node.type == "dir" and "/" or ""))
			end
		end
	end
	table.sort(cands)
	if #cands == 0 then return end

	local newWord
	if #cands == 1 then
		newWord = cands[1]
		if newWord:sub(-1) ~= "/" then newWord = newWord .. " " end
	else
		local lcp = commonPrefix(cands)
		if #lcp > #word then
			newWord = lcp
		else
			self:_write(self:_promptMarkup() .. esc(text) .. "\n")
			local names = {}
			for _, c in ipairs(cands) do names[#names + 1] = c:match("([^/]*/?)$") end
			self:Print(table.concat(names, "  "))
			return
		end
	end
	self:_setInput(before .. newWord)
end

------------------------------------------------------------ command registry --

-- def: function(ctx) or { run = function(ctx), description, usage, values = {"size"}, raw = bool }
function Terminal:RegisterCommand(name, def)
	if type(def) == "function" then def = { run = def } end
	def.name = name
	self.commands[name] = def
	self.fs:WriteFile("/bin/" .. name, "", { executable = true }).command = name
	return def
end

function Terminal:UnregisterCommand(name)
	self.commands[name] = nil
	self.fs:Remove("/bin/" .. name)
end

---------------------------------------------------------------- builtins ------

function Terminal:_installBuiltins()
	local term = self
	local function reg(name, def) term:RegisterCommand(name, def) end

	local function readInputs(ctx, cmdName)
		-- returns list of {name, text}; reads stdin when no file args
		local items = {}
		if #ctx.args == 0 then
			if ctx.stdin then items[1] = { name = "-", text = ctx.stdin } end
			return items
		end
		for _, a in ipairs(ctx.args) do
			local text, err = ctx.fs:ReadFile(ctx.resolve(a))
			if text then
				items[#items + 1] = { name = a, text = text }
			else
				ctx.error(cmdName .. ": " .. a .. ": " .. err)
			end
		end
		return items
	end

	reg("help", { description = "list commands", usage = "help [command]", run = function(ctx)
		local name = ctx.args[1]
		if name then
			local def = term.commands[name]
			if not def then ctx.error("help: no help topics match '" .. name .. "'") return 1 end
			ctx.print(def.usage or name)
			if def.description then ctx.printc("gray", def.description) end
			return 0
		end
		local names = {}
		for n in pairs(term.commands) do names[#names + 1] = n end
		table.sort(names)
		ctx.write("Available commands:\n", "cyan", true)
		for _, n in ipairs(names) do
			local d = term.commands[n]
			ctx.writeRich("  " .. ctx.color("green", string.format("%-14s", n)) .. ctx.color("gray", d.description or "") .. "\n")
		end
		ctx.printc("gray", "\nTry:  ls | grep s    echo hi > a.txt    lua print(1+1)    <cmd> --help")
		return 0
	end })

	reg("ls", { description = "list directory contents", usage = "ls [-a] [-l] [-1] [path...]", run = function(ctx)
		local paths = #ctx.args > 0 and ctx.args or { "." }
		local status = 0
		for i, p in ipairs(paths) do
			local abs = ctx.resolve(p)
			local node = ctx.fs:Get(abs)
			if not node then
				ctx.error(string.format("ls: cannot access '%s': No such file or directory", p))
				status = 2
			else
				local entries
				if node.type == "dir" then
					entries = ctx.fs:List(abs, ctx.flags.a)
					if #paths > 1 then
						if i > 1 then ctx.write("\n") end
						ctx.print(p .. ":")
					end
				else
					entries = { { name = p, node = node } }
				end
				local function fmt(e)
					if e.node.type == "dir" then return ctx.color("blue", e.name .. "/", true), e.name .. "/" end
					if isExec(e.node) then return ctx.color("green", e.name, true), e.name end
					return ctx.color(nil, e.name), e.name
				end
				if ctx.flags.l then
					for _, e in ipairs(entries) do
						local perms = e.node.type == "dir" and "drwxr-xr-x" or (isExec(e.node) and "-rwxr-xr-x" or "-rw-r--r--")
						local size = e.node.type == "dir" and 4096 or #(e.node.content or "")
						local rich = fmt(e)
						ctx.writeRich(string.format("%s 1 %s %s %6d %s %s\n", perms, term.user, term.user, size,
							os.date("%b %d %H:%M", e.node.mtime or os.time()), rich))
					end
				elseif not ctx.tty or ctx.flags["1"] then
					for _, e in ipairs(entries) do local _, plain = fmt(e); ctx.print((ctx.tty and plain or e.name)) end
				else
					local parts = {}
					for _, e in ipairs(entries) do parts[#parts + 1] = (fmt(e)) end
					if #parts > 0 then ctx.writeRich(table.concat(parts, "  ") .. "\n") end
				end
			end
		end
		return status
	end })

	reg("cd", { description = "change directory", usage = "cd [dir]", run = function(ctx)
		local target = ctx.args[1]
		if target == "-" then
			target = ctx.env.OLDPWD or term.cwd
			ctx.print(target)
		end
		local abs = target and ctx.resolve(target) or term.home
		local node = ctx.fs:Get(abs)
		if not node then ctx.error("bash: cd: " .. tostring(target) .. ": No such file or directory") return 1 end
		if node.type ~= "dir" then ctx.error("bash: cd: " .. tostring(target) .. ": Not a directory") return 1 end
		ctx.env.OLDPWD = term.cwd
		term.cwd = abs
		ctx.env.PWD = abs
		return 0
	end })

	reg("pwd", { description = "print working directory", run = function(ctx) ctx.print(term.cwd) end })

	reg("cat", { description = "print files", usage = "cat [file...]", run = function(ctx)
		local items = readInputs(ctx, "cat")
		for _, it in ipairs(items) do
			ctx.write(it.text)
			if it.text ~= "" and it.text:sub(-1) ~= "\n" then ctx.write("\n") end
		end
		return (#ctx.args > #items) and 1 or 0
	end })

	reg("echo", { description = "print text", usage = "echo [-n] [text...]", run = function(ctx)
		local argv = ctx.argv
		local i, nonl, interp = 2, false, false
		while argv[i] == "-n" or argv[i] == "-e" do
			if argv[i] == "-n" then nonl = true else interp = true end
			i = i + 1
		end
		local words = {}
		for j = i, #argv do words[#words + 1] = argv[j] end
		local s = table.concat(words, " ")
		if interp then s = s:gsub("\\n", "\n"):gsub("\\t", "\t") end
		ctx.write(s .. (nonl and "" or "\n"))
	end })

	reg("clear", { description = "clear the screen", run = function() term:Clear() end })

	reg("mkdir", { description = "make directories", usage = "mkdir [-p] dir...", run = function(ctx)
		local status = 0
		for _, a in ipairs(ctx.args) do
			local _, err = ctx.fs:MkDir(ctx.resolve(a), ctx.flags.p)
			if err then ctx.error("mkdir: cannot create directory '" .. a .. "': " .. err); status = 1 end
		end
		return status
	end })

	reg("touch", { description = "create empty files", usage = "touch file...", run = function(ctx)
		for _, a in ipairs(ctx.args) do
			local abs = ctx.resolve(a)
			local node = ctx.fs:Get(abs)
			if node then node.mtime = os.time() else ctx.fs:WriteFile(abs, "", { parents = false }) end
		end
	end })

	reg("rm", { description = "remove files", usage = "rm [-r] [-f] file...", run = function(ctx)
		local status = 0
		for _, a in ipairs(ctx.args) do
			local ok, err = ctx.fs:Remove(ctx.resolve(a), ctx.flags.r or ctx.flags.R)
			if not ok and not ctx.flags.f then
				if err == "Is a directory" then err = "Is a directory (use -r)" end
				ctx.error("rm: cannot remove '" .. a .. "': " .. err)
				status = 1
			end
		end
		return status
	end })

	reg("tree", { description = "list directory tree", usage = "tree [dir]", run = function(ctx)
		local abs = ctx.resolve(ctx.args[1] or ".")
		local root = ctx.fs:Get(abs)
		if not root or root.type ~= "dir" then ctx.error("tree: " .. (ctx.args[1] or ".") .. ": No such directory") return 1 end
		ctx.write((ctx.args[1] or ".") .. "\n", "blue", true)
		local dirs, files = 0, 0
		local function walk(path, prefix)
			local list = ctx.fs:List(path, ctx.flags.a)
			for i, e in ipairs(list) do
				local last = i == #list
				local name
				if e.node.type == "dir" then name = ctx.color("blue", e.name, true)
				elseif isExec(e.node) then name = ctx.color("green", e.name)
				else name = ctx.color(nil, e.name) end
				ctx.writeRich(prefix .. (last and "└── " or "├── ") .. name .. "\n")
				if e.node.type == "dir" then
					dirs = dirs + 1
					walk(path .. "/" .. e.name, prefix .. (last and "    " or "│   "))
				else
					files = files + 1
				end
			end
		end
		walk(abs, "")
		ctx.print(string.format("\n%d directories, %d files", dirs, files))
	end })

	reg("grep", { description = "filter lines matching text", usage = "grep [-i] [-v] [-n] pattern [file...]", run = function(ctx)
		local pat = table.remove(ctx.args, 1)
		if not pat then ctx.error("Usage: grep [-i] [-v] pattern [file...]") return 2 end
		if ctx.flags.i then pat = pat:lower() end
		local found = false
		for _, it in ipairs(readInputs(ctx, "grep")) do
			for n, l in ipairs(splitLines(it.text)) do
				local hay = ctx.flags.i and l:lower() or l
				local hit = hay:find(pat, 1, true) ~= nil
				if ctx.flags.v then hit = not hit end
				if hit then
					found = true
					local prefix = ""
					if #ctx.args > 1 then prefix = it.name .. ":" end
					if ctx.flags.n then prefix = prefix .. n .. ":" end
					ctx.print(prefix .. l)
				end
			end
		end
		return found and 0 or 1
	end })

	reg("head", { description = "first lines of input", usage = "head [-n N] [file...]", values = { "n" }, run = function(ctx)
		local n = tonumber(ctx.flags.n) or 10
		for _, it in ipairs(readInputs(ctx, "head")) do
			for i, l in ipairs(splitLines(it.text)) do if i <= n then ctx.print(l) end end
		end
	end })

	reg("tail", { description = "last lines of input", usage = "tail [-n N] [file...]", values = { "n" }, run = function(ctx)
		local n = tonumber(ctx.flags.n) or 10
		for _, it in ipairs(readInputs(ctx, "tail")) do
			local ls = splitLines(it.text)
			for i = math.max(1, #ls - n + 1), #ls do ctx.print(ls[i]) end
		end
	end })

	reg("wc", { description = "count lines, words, chars", usage = "wc [-l] [file...]", run = function(ctx)
		for _, it in ipairs(readInputs(ctx, "wc")) do
			local lines = select(2, it.text:gsub("\n", ""))
			local words = select(2, it.text:gsub("%S+", ""))
			local name = it.name ~= "-" and (" " .. it.name) or ""
			if ctx.flags.l then ctx.print(lines .. name)
			else ctx.print(string.format("%d %d %d%s", lines, words, #it.text, name)) end
		end
	end })

	reg("whoami", { description = "print user name", run = function(ctx) ctx.print(term.user) end })
	reg("hostname", { description = "print host name", run = function(ctx) ctx.print(term.host) end })
	reg("uname", { description = "system information", usage = "uname [-a]", run = function(ctx)
		if ctx.flags.a then ctx.print(string.format("Linux %s 5.15.0-roblox #1 SMP Luau x86_64 GNU/Linux", term.host))
		else ctx.print("Linux") end
	end })
	reg("date", { description = "print the date", run = function(ctx) ctx.print(os.date("%a %b %d %H:%M:%S %Y")) end })

	reg("history", { description = "show command history", run = function(ctx)
		for i, l in ipairs(term.history) do ctx.print(string.format("%4d  %s", i, l)) end
	end })

	reg("env", { description = "print environment variables", run = function(ctx)
		local keys = {}
		for k in pairs(ctx.env) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do ctx.print(k .. "=" .. tostring(ctx.env[k])) end
	end })

	reg("export", { description = "set environment variables", usage = "export NAME=value ...", run = function(ctx)
		for i = 2, #ctx.argv do
			local k, v = ctx.argv[i]:match("^([%a_][%w_]*)=(.*)$")
			if k then ctx.env[k] = v else ctx.error("bash: export: `" .. ctx.argv[i] .. "': not a valid identifier") end
		end
	end })

	reg("unset", { description = "remove environment variables", usage = "unset NAME ...", run = function(ctx)
		for _, a in ipairs(ctx.args) do ctx.env[a] = nil end
	end })

	reg("which", { description = "locate a command", usage = "which command...", run = function(ctx)
		local status = 0
		for _, a in ipairs(ctx.args) do
			local found
			for dir in (ctx.env.PATH or ""):gmatch("[^:]+") do
				local node = ctx.fs:Get(dir .. "/" .. a)
				if node and node.type == "file" then found = dir .. "/" .. a; break end
			end
			if found then ctx.print(found) else status = 1 end
		end
		return status
	end })

	reg("sleep", { description = "delay for N seconds", usage = "sleep N", run = function(ctx)
		ctx.sleep(tonumber(ctx.args[1]) or 1)
	end })

	reg("exit", { description = "close the terminal", run = function() term:Hide() end })

	reg("theme", { description = "list or change the color theme", usage = "theme [name]", run = function(ctx)
		local name = ctx.args[1]
		if not name then
			local names = {}
			for n in pairs(Themes) do names[#names + 1] = n end
			table.sort(names)
			for _, n in ipairs(names) do
				ctx.print((n == term.ThemeName and "* " or "  ") .. n)
			end
			return 0
		end
		if not Themes[name] then ctx.error("theme: unknown theme '" .. name .. "'") return 1 end
		term:SetTheme(name)
		return 0
	end })

	reg("lua", { description = "run Lua code, a .lua file, or open a REPL", usage = "lua [code | file]", raw = true, run = function(ctx)
		local code = ctx.raw or ""
		if code:match("^%s*$") then return term:_repl(ctx) end
		local single = code:match("^%s*(%S+)%s*$")
		if single then
			local node = ctx.fs:Get(ctx.resolve(single))
			if node and node.type == "file" and node.content then
				return term:_runLua((node.content:gsub("^#![^\n]*", "")), single, ctx)
			end
		end
		return term:_runLua(code, "lua", ctx)
	end })

	reg("neofetch", { description = "show system info", run = function(ctx)
		local logo = {
			"    .--.        ",
			"   |o_o |       ",
			"   |:_/ |       ",
			"  //   \\ \\      ",
			" (|     | )     ",
			"/'\\_   _/`\\     ",
			"\\___)=(___/     ",
		}
		local lp = Players.LocalPlayer
		local exec = "unknown"
		if identifyexecutor then local ok, n = pcall(identifyexecutor); if ok and n then exec = tostring(n) end end
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(0, 0)
		local up = math.floor(os.clock() - term.startTime)
		local info = {}
		info[#info + 1] = ctx.color("green", term.user .. "@" .. term.host, true)
		info[#info + 1] = ctx.color("gray", string.rep("-", #term.user + #term.host + 1))
		local function kv(k, v) info[#info + 1] = ctx.color("blue", k, true) .. ": " .. esc(v) end
		kv("OS", "Roblox Linux 1.0 (Luau)")
		kv("Kernel", "5.15.0-roblox")
		kv("Uptime", string.format("%dm %ds", math.floor(up / 60), up % 60))
		kv("Shell", "rbxsh")
		kv("Executor", exec)
		kv("Resolution", string.format("%dx%d", vp.X, vp.Y))
		kv("Theme", term.ThemeName)
		kv("Players", #Players:GetPlayers() .. "/" .. Players.MaxPlayers)
		kv("Place", tostring(game.PlaceId))
		for i = 1, math.max(#logo, #info) do
			ctx.writeRich(ctx.color("cyan", logo[i] or string.rep(" ", 16)) .. (info[i] or "") .. "\n")
		end
		local bar = {}
		for _, c in ipairs({ "red", "yellow", "green", "cyan", "blue", "magenta", "white", "gray" }) do
			bar[#bar + 1] = ctx.color(c, "███")
		end
		ctx.writeRich("\n" .. string.rep(" ", 16) .. table.concat(bar) .. "\n")
	end })
end

return Terminal
