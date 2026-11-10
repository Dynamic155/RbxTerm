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
local TextService = game:GetService("TextService")

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

local function cloneNode(node)
	if node.type == "dir" then
		local d = newDir()
		for n, c in pairs(node.children) do d.children[n] = cloneNode(c) end
		return d
	end
	local f = {}
	for k, v in pairs(node) do f[k] = v end
	f.mtime = os.time()
	return f
end

function FS:Copy(src, dst)
	local node = self:Get(src)
	if not node then return false, "No such file or directory" end
	local s, d = self:Resolve(src, "/"), self:Resolve(dst, "/")
	if d == s or d:sub(1, #s + 1) == s .. "/" then return false, "cannot copy a file into itself" end
	local dir, name = self:_split(dst)
	if not name then return false, "Invalid destination" end
	local parent = self:Get(dir)
	if not parent or parent.type ~= "dir" then return false, "No such file or directory" end
	parent.children[name] = cloneNode(node)
	return true
end

function FS:Move(src, dst)
	local ok, err = self:Copy(src, dst)
	if not ok then return false, err end
	self:Remove(src, true)
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
	if node.type ~= "file" or node.executable == false then return false end
	return node.run ~= nil or node.command ~= nil or node.executable == true
		or (node.content ~= nil and node.content:sub(1, 2) == "#!")
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
	self.aliases = { ll = "ls -l", la = "ls -a", l = "ls" }
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
	self:_installTools()
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
		local isCtrlKey = kc == Enum.KeyCode.LeftControl or kc == Enum.KeyCode.RightControl
		if kc == cfg.ToggleKey and (self.Visible or not processed) and not (self._screen and isCtrlKey) then
			self:Toggle()
			return
		end
		if not self.Visible or self._screen then return end
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
		if not self.Visible then return end
		if self._screen then
			self._screen.box:CaptureFocus()
		elseif self._row.Visible then
			self._input:CaptureFocus()
		end
	end)
end

function Terminal:Hide()
	if not self.Visible or self.Destroyed then return end
	self.Visible = false
	self._input:ReleaseFocus()
	if self._screen then self._screen.box:ReleaseFocus() end
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
	if self._screen then self._screen:Close() end
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
	if self._screen then self._screen:Close() end
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
	local first, rest
	for _ = 1, 5 do
		first, rest = line:match("^%s*(%S+)%s*(.*)$")
		if first and self.aliases[first] then
			line = self.aliases[first] .. (rest ~= "" and (" " .. rest) or "")
		else
			break
		end
	end
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
		if target.content then
			local shebang = target.content:match("^#![^\n]*")
			if shebang and shebang:match("sh%s*$") then return self:_runShell(target.content, ctx) end
			return self:_runLua((target.content:gsub("^#![^\n]*", "")), name, ctx)
		end
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

------------------------------------------------------- full-screen apps ----

local KEYNAMES = {
	[Enum.KeyCode.Up] = "Up", [Enum.KeyCode.Down] = "Down", [Enum.KeyCode.Left] = "Left", [Enum.KeyCode.Right] = "Right",
	[Enum.KeyCode.Return] = "Enter", [Enum.KeyCode.KeypadEnter] = "Enter", [Enum.KeyCode.Backspace] = "Backspace",
	[Enum.KeyCode.Delete] = "Delete", [Enum.KeyCode.Tab] = "Tab", [Enum.KeyCode.Escape] = "Escape",
	[Enum.KeyCode.Home] = "Home", [Enum.KeyCode.End] = "End", [Enum.KeyCode.PageUp] = "PageUp",
	[Enum.KeyCode.PageDown] = "PageDown",
}
local REPEATABLE = { Up = true, Down = true, Left = true, Right = true, Backspace = true, Delete = true,
	PageUp = true, PageDown = true, Enter = true }

--[[
    term:OpenScreen({ onKey, onChar, onResize, onClose }) -> screen

    Takes over the window body with a character grid (used by vim, nano, less).
      onKey(key)   key = { name = "Up"|"Enter"|"Escape"|"a"..., ctrl = bool, alt = bool, shift = bool }
                   (letters only arrive here when Ctrl or Alt is held; plain typing goes to onChar)
      onChar(text) typed or pasted text
    screen.rows / screen.cols    size of the grid
    screen:Render(rows, cursor)  rows[i] = markup string or { t = markup, style = "bar" }
                                 cursor = { row, col, style = "block"|"bar" } or nil
    screen:Wait()                yield the calling command until the screen closes
    screen:Close()
]]
function Terminal:OpenScreen(opts)
	assert(not self._screen, "a full-screen app is already open")
	local term, cfg = self, self.Config
	local screen = { term = self, closed = false, rows = 1, cols = 1 }
	local conns = {}
	local function conn(c) conns[#conns + 1] = c end

	local frame = Instance.new("Frame")
	frame.Name = "Screen"
	frame.Position = UDim2.fromOffset(0, self._HEADER)
	frame.Size = UDim2.new(1, 0, 1, -self._HEADER)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Active = true
	frame.ZIndex = 3
	frame.Parent = self._window
	self._ui.scroll.Visible = false

	local lineH = cfg.TextSize + 4
	local charW = TextService:GetTextSize(string.rep("M", 32), cfg.TextSize, cfg.Font, Vector2.new(10000, 10000)).X / 32
	local padX, padY = 12, 6
	screen.lineH, screen.charW = lineH, charW

	local box = Instance.new("TextBox")
	box.Name = "Capture"
	box.Size = UDim2.fromOffset(4, 4)
	box.BackgroundTransparency = 1
	box.TextTransparency = 1
	box.ClearTextOnFocus = false
	box.MultiLine = false
	box.Text = ""
	box.ZIndex = 1
	box.Parent = frame
	screen.box = box

	local cursor = Instance.new("Frame")
	cursor.BorderSizePixel = 0
	cursor.BackgroundColor3 = self.Theme.text
	cursor.BackgroundTransparency = 0.55
	cursor.ZIndex = 5
	cursor.Visible = false
	cursor.Parent = frame

	local labels, cache = {}, {}
	local function relayout()
		local sz = self._window.AbsoluteSize
		screen.rows = math.max(1, math.floor((sz.Y - self._HEADER - padY * 2) / lineH))
		screen.cols = math.max(1, math.floor((sz.X - padX * 2) / charW))
		for i = #labels + 1, screen.rows do
			local l = Instance.new("TextLabel")
			l.BackgroundTransparency = 1
			l.Size = UDim2.new(1, 0, 0, lineH)
			l.Position = UDim2.fromOffset(0, padY + (i - 1) * lineH)
			l.RichText = true
			l.TextWrapped = false
			l.TextXAlignment = Enum.TextXAlignment.Left
			l.Font = cfg.Font
			l.TextSize = cfg.TextSize
			l.TextColor3 = self.Theme.text
			l.ClipsDescendants = true
			l.ZIndex = 2
			l.Text = ""
			Instance.new("UIPadding", l).PaddingLeft = UDim.new(0, padX)
			l.Parent = frame
			labels[i] = l
		end
		for i, l in ipairs(labels) do l.Visible = i <= screen.rows end
	end
	relayout()

	function screen:Render(rows, cur)
		if self.closed then return end
		for i = 1, self.rows do
			local r = rows[i]
			local text, style = "", nil
			if type(r) == "table" then text, style = r.t or "", r.style elseif r then text = r end
			local key = (style or "") .. "|" .. text
			if cache[i] ~= key then
				cache[i] = key
				local l = labels[i]
				l.Text = text
				if style == "bar" then
					l.BackgroundTransparency = 0
					l.BackgroundColor3 = term.Theme.header
				else
					l.BackgroundTransparency = 1
				end
			end
		end
		if cur then
			cursor.Visible = true
			cursor.BackgroundColor3 = term.Theme.text
			cursor.Size = UDim2.fromOffset(cur.style == "bar" and 2 or charW, lineH - 2)
			cursor.Position = UDim2.fromOffset(padX + (cur.col - 1) * charW, padY + (cur.row - 1) * lineH + 1)
		else
			cursor.Visible = false
		end
	end

	local function ctrlDown() return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) end
	local function altDown() return UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt) end
	local function shiftDown() return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) end
	local function fireKey(key)
		if not screen.closed and opts.onKey then opts.onKey(key) end
	end

	conn(UserInputService.InputBegan:Connect(function(inp)
		if screen.closed or not term.Visible then return end
		if inp.UserInputType ~= Enum.UserInputType.Keyboard then return end
		local kc = inp.KeyCode
		local name = KEYNAMES[kc]
		local ctrl, alt = ctrlDown(), altDown()
		if not name and (ctrl or alt) then
			if kc == Enum.KeyCode.LeftBracket and ctrl then
				name, ctrl = "Escape", false
			elseif kc == Enum.KeyCode.Minus and ctrl then
				name = "_"
			elseif #kc.Name == 1 then
				name = kc.Name:lower()
			end
		end
		if not name then return end
		local key = { name = name, ctrl = ctrl, alt = alt, shift = shiftDown() }
		fireKey(key)
		if REPEATABLE[name] and not ctrl then
			local token = {}
			screen._rep = token
			task.spawn(function()
				task.wait(0.4)
				while screen._rep == token and not screen.closed and UserInputService:IsKeyDown(kc) do
					fireKey(key)
					task.wait(0.04)
				end
			end)
		end
	end))
	conn(UserInputService.InputEnded:Connect(function(inp)
		if inp.UserInputType == Enum.UserInputType.Keyboard then screen._rep = nil end
	end))

	conn(box:GetPropertyChangedSignal("Text"):Connect(function()
		local t = box.Text
		if t == "" then return end
		box.Text = ""
		if screen.closed then return end
		if #t == 1 and ctrlDown() then return end
		t = t:gsub("\t", "")
		local buf = {}
		local function flush()
			if #buf > 0 then
				local s = table.concat(buf)
				buf = {}
				if not screen.closed and opts.onChar then opts.onChar(s) end
			end
		end
		local i = 1
		while i <= #t do
			local c = t:sub(i, i)
			if c == "\r" or c == "\n" then
				flush()
				if c == "\r" and t:sub(i + 1, i + 1) == "\n" then i = i + 1 end
				fireKey({ name = "Enter" })
			else
				buf[#buf + 1] = c
			end
			i = i + 1
		end
		flush()
	end))
	conn(box.FocusLost:Connect(function()
		task.defer(function()
			if not screen.closed and term.Visible and not term.Destroyed then box:CaptureFocus() end
		end)
	end))
	conn(frame.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			task.defer(function() if not screen.closed and term.Visible then box:CaptureFocus() end end)
		end
	end))
	conn(self._window:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		relayout()
		if opts.onResize then opts.onResize(screen) end
	end))

	function screen:Close()
		if self.closed then return end
		self.closed = true
		for _, c in ipairs(conns) do c:Disconnect() end
		frame:Destroy()
		if term._screen == self then term._screen = nil end
		if not term.Destroyed then term._ui.scroll.Visible = true end
		if opts.onClose then pcall(opts.onClose) end
		if self._co then
			local co = self._co
			self._co = nil
			task.spawn(co)
		end
	end
	function screen:Wait()
		if self.closed then return end
		self._co = coroutine.running()
		coroutine.yield()
	end

	self._screen = screen
	if self.Visible then box:CaptureFocus() end
	return screen
end

------------------------------------------------------------------ editors ----

local function copyLines(t)
	local c = {}
	for i, v in ipairs(t) do c[i] = v end
	return c
end

local function charClass(c)
	if c == "" or c:match("%s") then return 0 end
	if c:match("[%w_]") then return 1 end
	return 2
end

local function nextWord(lines, y, x)
	local line = lines[y]
	local cls = charClass(line:sub(x, x))
	if cls ~= 0 then
		while x <= #line and charClass(line:sub(x, x)) == cls do x = x + 1 end
	end
	while true do
		while x <= #line and charClass(line:sub(x, x)) == 0 do x = x + 1 end
		if x <= #line then return y, x end
		if y >= #lines then return y, #line + 1 end
		y = y + 1
		line = lines[y]
		x = 1
		if line == "" then return y, 1 end
	end
end

local function prevWord(lines, y, x)
	x = x - 1
	while true do
		local line = lines[y]
		while x >= 1 and charClass(line:sub(x, x)) == 0 do x = x - 1 end
		if x >= 1 then
			local cls = charClass(line:sub(x, x))
			while x > 1 and charClass(line:sub(x - 1, x - 1)) == cls do x = x - 1 end
			return y, x
		end
		if y == 1 then return 1, 1 end
		y = y - 1
		x = #lines[y]
		if x == 0 then return y, 1 end
	end
end

local function wordEnd(lines, y, x)
	x = x + 1
	while true do
		local line = lines[y]
		while x <= #line and charClass(line:sub(x, x)) == 0 do x = x + 1 end
		if x <= #line then
			local cls = charClass(line:sub(x, x))
			while x < #line and charClass(line:sub(x + 1, x + 1)) == cls do x = x + 1 end
			return y, x
		end
		if y >= #lines then return y, math.max(#line, 1) end
		y = y + 1
		x = 1
	end
end

local LUA_KW = {}
for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while continue"):gmatch("%a+") do
	LUA_KW[w] = true
end

-- returns a table mapping column -> palette color name for a line of Lua
local function luaColors(line)
	local cols = {}
	local i, n = 1, #line
	while i <= n do
		local c = line:sub(i, i)
		if c == "-" and line:sub(i, i + 1) == "--" then
			for j = i, n do cols[j] = "gray" end
			break
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = line:sub(j, j)
				if d == "\\" then j = j + 2 elseif d == c then break else j = j + 1 end
			end
			for k = i, math.min(j, n) do cols[k] = "green" end
			i = j + 1
		elseif c:match("%d") and not line:sub(i - 1, i - 1):match("[%w_]") then
			local j = i
			while line:sub(j, j):match("[%w%.]") do j = j + 1 end
			for k = i, j - 1 do cols[k] = "yellow" end
			i = j
		elseif c:match("[%a_]") then
			local w = line:match("^[%a_][%w_]*", i)
			if LUA_KW[w] then
				for k = i, i + #w - 1 do cols[k] = "magenta" end
			end
			i = i + #w
		else
			i = i + 1
		end
	end
	return cols
end

-- markup for characters [from, to] of a line, with optional syntax colors and selection [s1, s2]
local function lineMarkup(term, line, from, to, colors, s1, s2)
	to = math.min(to, #line)
	if to < from then return "" end
	local out, runText = {}, {}
	local runCol, runSel = nil, false
	local function flush()
		if #runText == 0 then return end
		local s = esc(table.concat(runText))
		if runCol then s = '<font color="' .. hex(term:_color(runCol)) .. '">' .. s .. "</font>" end
		if runSel then s = '<mark color="' .. hex(term.Theme.dim) .. '" transparency="0.45">' .. s .. "</mark>" end
		out[#out + 1] = s
		runText = {}
	end
	for i = from, to do
		local col = colors and colors[i] or nil
		local sel = s1 ~= nil and i >= s1 and i <= s2
		if col ~= runCol or sel ~= runSel then
			flush()
			runCol, runSel = col, sel
		end
		runText[#runText + 1] = line:sub(i, i)
	end
	flush()
	return table.concat(out)
end

local function inv(term, text)
	local th = term.Theme
	return '<mark color="' .. hex(th.text) .. '" transparency="0"><font color="' .. hex(th.bg) .. '">' .. esc(text) .. "</font></mark>"
end

local Editor = {}
Editor.__index = Editor

function Editor.new(term, ctx, path)
	local self = setmetatable({}, Editor)
	self.term, self.ctx, self.path = term, ctx, path
	self.abs = path and ctx.resolve(path) or nil
	self.lines = { "" }
	self.cy, self.cx = 1, 1
	self.top, self.left = 1, 0
	self.modified, self.isNew = false, true
	self.undo, self.redo = {}, {}
	self.lua = path ~= nil and path:match("%.lua$") ~= nil
	if self.abs then
		local node = ctx.fs:Get(self.abs)
		if node and node.type == "dir" then
			self.err = "Is a directory"
		elseif node then
			local content = (node.content or ""):gsub("\r", ""):gsub("\t", "    ")
			local ls = splitLines(content)
			if #ls == 0 then ls = { "" } end
			self.lines, self.isNew, self.bytes = ls, false, #content
		end
	end
	return self
end

function Editor:snap()
	self.undo[#self.undo + 1] = { lines = copyLines(self.lines), cy = self.cy, cx = self.cx }
	if #self.undo > 200 then table.remove(self.undo, 1) end
	self.redo = {}
end

function Editor:doUndo()
	local s = table.remove(self.undo)
	if not s then return false end
	self.redo[#self.redo + 1] = { lines = copyLines(self.lines), cy = self.cy, cx = self.cx }
	self.lines, self.cy, self.cx = s.lines, s.cy, s.cx
	self.modified = true
	return true
end

function Editor:doRedo()
	local s = table.remove(self.redo)
	if not s then return false end
	self.undo[#self.undo + 1] = { lines = copyLines(self.lines), cy = self.cy, cx = self.cx }
	self.lines, self.cy, self.cx = s.lines, s.cy, s.cx
	self.modified = true
	return true
end

function Editor:curLine() return self.lines[self.cy] end

function Editor:clamp(insert)
	self.cy = math.max(1, math.min(self.cy, #self.lines))
	local n = #self.lines[self.cy]
	self.cx = math.max(1, math.min(self.cx, insert and (n + 1) or math.max(1, n)))
end

function Editor:insertText(text)
	local line = self.lines[self.cy]
	self.lines[self.cy] = line:sub(1, self.cx - 1) .. text .. line:sub(self.cx)
	self.cx = self.cx + #text
	self.modified = true
end

function Editor:newline()
	local line = self.lines[self.cy]
	self.lines[self.cy] = line:sub(1, self.cx - 1)
	table.insert(self.lines, self.cy + 1, line:sub(self.cx))
	self.cy, self.cx = self.cy + 1, 1
	self.modified = true
end

function Editor:backspace()
	local line = self.lines[self.cy]
	if self.cx > 1 then
		self.lines[self.cy] = line:sub(1, self.cx - 2) .. line:sub(self.cx)
		self.cx = self.cx - 1
	elseif self.cy > 1 then
		local prev = self.lines[self.cy - 1]
		self.cx = #prev + 1
		self.lines[self.cy - 1] = prev .. line
		table.remove(self.lines, self.cy)
		self.cy = self.cy - 1
	end
	self.modified = true
end

function Editor:delete()
	local line = self.lines[self.cy]
	if self.cx <= #line then
		self.lines[self.cy] = line:sub(1, self.cx - 1) .. line:sub(self.cx + 1)
	elseif self.cy < #self.lines then
		self.lines[self.cy] = line .. self.lines[self.cy + 1]
		table.remove(self.lines, self.cy + 1)
	end
	self.modified = true
end

-- text from (y1,x1) inclusive to (y2,x2) exclusive
function Editor:getRange(y1, x1, y2, x2)
	if y1 == y2 then return self.lines[y1]:sub(x1, x2 - 1) end
	local out = { self.lines[y1]:sub(x1) }
	for y = y1 + 1, y2 - 1 do out[#out + 1] = self.lines[y] end
	out[#out + 1] = self.lines[y2]:sub(1, x2 - 1)
	return table.concat(out, "\n")
end

function Editor:deleteRange(y1, x1, y2, x2)
	local text = self:getRange(y1, x1, y2, x2)
	self.lines[y1] = self.lines[y1]:sub(1, x1 - 1) .. self.lines[y2]:sub(x2)
	for _ = y1 + 1, y2 do table.remove(self.lines, y1 + 1) end
	self.cy, self.cx = y1, x1
	self.modified = true
	return text
end

-- insert possibly multi-line text at (y,x); returns the position just after it
function Editor:insertBlock(text, y, x)
	local parts = {}
	for p in (text .. "\n"):gmatch("(.-)\n") do parts[#parts + 1] = p end
	local line = self.lines[y]
	local head, tail = line:sub(1, x - 1), line:sub(x)
	self.modified = true
	if #parts == 1 then
		self.lines[y] = head .. parts[1] .. tail
		return y, x + #parts[1]
	end
	self.lines[y] = head .. parts[1]
	for i = 2, #parts - 1 do table.insert(self.lines, y + i - 1, parts[i]) end
	table.insert(self.lines, y + #parts - 1, parts[#parts] .. tail)
	return y + #parts - 1, #parts[#parts] + 1
end

function Editor:save(path)
	local target = path and self.ctx.resolve(path) or self.abs
	if not target then return false, "No file name" end
	local text = (#self.lines == 1 and self.lines[1] == "") and "" or (table.concat(self.lines, "\n") .. "\n")
	local node, err = self.ctx.fs:WriteFile(target, text, { parents = false })
	if not node then return false, err end
	self.abs = target
	self.path = path or self.path
	self.modified, self.isNew = false, false
	if self.path then self.lua = self.path:match("%.lua$") ~= nil end
	return true, #self.lines, #text
end

function Editor:scrollTo(rows, cols)
	if self.cy < self.top then self.top = self.cy end
	if self.cy > self.top + rows - 1 then self.top = self.cy - rows + 1 end
	if self.cx - 1 < self.left then self.left = self.cx - 1 end
	if self.cx - 1 > self.left + cols - 1 then self.left = self.cx - cols end
	if self.left < 0 then self.left = 0 end
	if self.top < 1 then self.top = 1 end
end

-- fills out[first .. first+count-1] with markup; returns the gutter width
function Editor:renderBody(out, first, count, o)
	local term = self.term
	local gw = o.number and (#tostring(#self.lines) + 1) or 0
	local cols = math.max(1, o.cols - gw)
	self:scrollTo(count, cols)
	for i = 1, count do
		local y = self.top + i - 1
		local line = self.lines[y]
		local txt
		if line then
			local s1, s2
			if o.sel then s1, s2 = o.sel(y, line) end
			txt = lineMarkup(term, line, self.left + 1, self.left + cols, self.lua and luaColors(line) or nil, s1, s2)
			if gw > 0 then
				txt = '<font color="' .. hex(term.Theme.dim) .. '">' .. string.format("%" .. (gw - 1) .. "d ", y) .. "</font>" .. txt
			end
		else
			txt = o.tilde and ('<font color="' .. hex(term.Theme.palette.blue) .. '">~</font>') or ""
		end
		out[first + i - 1] = txt
	end
	return gw
end

------------------------------------------------------------------------ vim --

local Vim = {}
Vim.__index = Vim

function Vim.new(term, ctx, path)
	local self = setmetatable({}, Vim)
	self.term, self.ctx = term, ctx
	self.ed = Editor.new(term, ctx, path)
	self.mode, self.count, self.cmd, self.msg = "normal", "", "", ""
	self.promptChar = ":"
	self.number = false
	local ed = self.ed
	if path then
		if ed.isNew then
			self.msg = string.format('"%s" [New]', path)
		else
			self.msg = string.format('"%s" %dL, %dB', path, #ed.lines, ed.bytes or 0)
		end
	end
	return self
end

function Vim:run()
	local screen = self.term:OpenScreen({
		onKey = function(k) self:onKey(k) end,
		onChar = function(c) self:onChar(c) end,
		onResize = function() self:render() end,
	})
	self.screen = screen
	self:render()
	screen:Wait()
end

function Vim:render()
	local s = self.screen
	if not s or s.closed then return end
	local ed = self.ed
	local rows = {}
	local textRows = math.max(1, s.rows - 2)
	local visual = self.mode == "visual" or self.mode == "vline"
	local sel
	if visual then
		local ay, ax, by, bx = self.vy, self.vx, ed.cy, ed.cx
		if ay > by or (ay == by and ax > bx) then ay, ax, by, bx = by, bx, ay, ax end
		sel = function(y, line)
			if y < ay or y > by then return nil end
			if self.mode == "vline" then return 1, math.max(#line, 1) end
			return (y == ay) and ax or 1, (y == by) and bx or math.max(#line, 1)
		end
	end
	local gw = ed:renderBody(rows, 1, textRows, { number = self.number, sel = sel, tilde = true, cols = s.cols })

	local total = #ed.lines
	local pct
	if total <= textRows then pct = "All"
	elseif ed.top == 1 then pct = "Top"
	elseif ed.top + textRows - 1 >= total then pct = "Bot"
	else pct = math.floor((ed.top - 1) / (total - textRows) * 100) .. "%" end
	local left = (ed.path or "[No Name]") .. (ed.modified and " [+]" or "")
	local right = string.format("%d,%d   %s", ed.cy, ed.cx, pct)
	rows[textRows + 1] = { t = esc(left) .. string.rep(" ", math.max(1, s.cols - #left - #right)) .. esc(right), style = "bar" }

	local last = ""
	if self.mode == "cmd" then last = esc(self.promptChar .. self.cmd)
	elseif self.msg ~= "" then last = esc(self.msg)
	elseif self.mode == "insert" then last = "<b>-- INSERT --</b>"
	elseif self.mode == "visual" then last = "<b>-- VISUAL --</b>"
	elseif self.mode == "vline" then last = "<b>-- VISUAL LINE --</b>" end
	rows[textRows + 2] = last

	local cur
	if self.mode == "cmd" then
		cur = { row = textRows + 2, col = #self.promptChar + #self.cmd + 1, style = "bar" }
	else
		cur = { row = ed.cy - ed.top + 1, col = gw + ed.cx - ed.left, style = self.mode == "insert" and "bar" or "block" }
	end
	s:Render(rows, cur)
end

function Vim:resetPending()
	self.count, self.op, self.opCount, self.pending = "", nil, nil, nil
end

function Vim:startInsert()
	self:resetPending()
	self.mode = "insert"
end

function Vim:toNormal()
	local ed = self.ed
	if self.mode == "insert" then ed.cx = math.max(1, ed.cx - 1) end
	self.mode = "normal"
	self:resetPending()
	ed:clamp(false)
end

function Vim:enterCmd(pc)
	self:resetPending()
	self.mode, self.promptChar, self.cmd = "cmd", pc, ""
end

function Vim:page(dir, frac)
	local ed = self.ed
	local step = math.max(1, math.floor(math.max(1, self.screen.rows - 2) * frac))
	ed.cy = ed.cy + dir * step
	ed.top = math.max(1, ed.top + dir * step)
	ed:clamp(false)
end

function Vim:onKey(k)
	local ed, name = self.ed, k.name
	self.msg = ""
	if self.mode == "cmd" then return self:cmdKey(k) end
	if name == "Escape" or (k.ctrl and name == "c") then
		self:toNormal()
	elseif self.mode == "insert" then
		local line = ed:curLine()
		if name == "Enter" then ed:newline()
		elseif name == "Backspace" then ed:backspace()
		elseif name == "Delete" then ed:delete()
		elseif name == "Tab" then ed:insertText("    ")
		elseif name == "Left" then ed.cx = math.max(1, ed.cx - 1)
		elseif name == "Right" then ed.cx = math.min(#line + 1, ed.cx + 1)
		elseif name == "Up" then ed.cy = ed.cy - 1; ed:clamp(true)
		elseif name == "Down" then ed.cy = ed.cy + 1; ed:clamp(true)
		elseif name == "Home" then ed.cx = 1
		elseif name == "End" then ed.cx = #line + 1
		elseif name == "PageUp" then self:page(-1, 1); ed:clamp(true)
		elseif name == "PageDown" then self:page(1, 1); ed:clamp(true)
		end
	else
		local visual = self.mode ~= "normal"
		if k.ctrl then
			if name == "r" then
				if not ed:doRedo() then self.msg = "Already at newest change" end
				ed:clamp(false)
			elseif name == "f" then self:page(1, 1)
			elseif name == "b" then self:page(-1, 1)
			elseif name == "d" then self:page(1, 0.5)
			elseif name == "u" then self:page(-1, 0.5)
			end
		elseif name == "Left" or name == "Backspace" then self:normalChar("h")
		elseif name == "Right" then self:normalChar("l")
		elseif name == "Up" then self:normalChar("k")
		elseif name == "Down" or name == "Enter" then self:normalChar("j")
		elseif name == "Home" then self:normalChar("0")
		elseif name == "End" then self:normalChar("$")
		elseif name == "Delete" then self:normalChar("x")
		elseif name == "PageUp" then self:page(-1, 1)
		elseif name == "PageDown" then self:page(1, 1)
		end
		if visual and self.mode == "normal" then ed:clamp(false) end
	end
	self:render()
end

function Vim:onChar(text)
	if not self.screen or self.screen.closed then return end
	self.msg = ""
	if self.mode == "cmd" then
		self.cmd = self.cmd .. text
	elseif self.mode == "insert" then
		self.ed:insertText(text)
	else
		for i = 1, #text do
			if self.screen.closed then return end
			self:normalChar(text:sub(i, i))
		end
	end
	self:render()
end

-- returns { y, x, linewise, inclusive, word } or nil
function Vim:motion(key, n, hasCount, arg, op)
	local ed = self.ed
	local lines = ed.lines
	local y, x = ed.cy, ed.cx
	local line = lines[y]
	if key == "h" then
		return { y = y, x = math.max(1, x - n) }
	elseif key == "l" then
		return { y = y, x = math.min(x + n, op and (#line + 1) or math.max(#line, 1)) }
	elseif key == "0" then
		return { y = y, x = 1 }
	elseif key == "^" then
		return { y = y, x = line:find("%S") or 1 }
	elseif key == "$" then
		local ty = math.min(#lines, y + n - 1)
		return { y = ty, x = math.max(#lines[ty], 1), inclusive = true }
	elseif key == "j" then
		return { y = math.min(#lines, y + n), x = x, linewise = true }
	elseif key == "k" then
		return { y = math.max(1, y - n), x = x, linewise = true }
	elseif key == "G" then
		local ty = hasCount and math.min(n, #lines) or #lines
		return { y = ty, x = lines[ty]:find("%S") or 1, linewise = true }
	elseif key == "gg" then
		local ty = hasCount and math.min(n, #lines) or 1
		return { y = ty, x = lines[ty]:find("%S") or 1, linewise = true }
	elseif key == "w" then
		if op == "c" and charClass(line:sub(x, x)) ~= 0 then
			local ey, ex = y, x - 1
			for _ = 1, n do ey, ex = wordEnd(lines, ey, ex) end
			return { y = ey, x = ex, inclusive = true }
		end
		for _ = 1, n do y, x = nextWord(lines, y, x) end
		return { y = y, x = x, word = true }
	elseif key == "b" then
		for _ = 1, n do y, x = prevWord(lines, y, x) end
		return { y = y, x = x }
	elseif key == "e" then
		for _ = 1, n do y, x = wordEnd(lines, y, x) end
		return { y = y, x = x, inclusive = true }
	elseif key == "f" or key == "t" then
		local idx = x
		for _ = 1, n do
			idx = line:find(arg, idx + 1, true)
			if not idx then return nil end
		end
		return { y = y, x = key == "t" and idx - 1 or idx, inclusive = true }
	elseif key == "F" or key == "T" then
		local idx = x
		for _ = 1, n do
			local found
			for i = idx - 1, 1, -1 do
				if line:sub(i, i) == arg then found = i; break end
			end
			if not found then return nil end
			idx = found
		end
		return { y = y, x = key == "T" and idx + 1 or idx }
	elseif key == "}" then
		local ty = y + 1
		while ty < #lines and lines[ty] ~= "" do ty = ty + 1 end
		return { y = math.min(ty, #lines), x = 1 }
	elseif key == "{" then
		local ty = y - 1
		while ty > 1 and lines[ty] ~= "" do ty = ty - 1 end
		return { y = math.max(ty, 1), x = 1 }
	end
	return nil
end

function Vim:applyRange(op, y1, x1, y2, x2)
	local ed = self.ed
	if y1 == y2 and x2 <= x1 then
		if op == "c" then ed:snap(); self:startInsert() end
		return
	end
	self.term._reg = { text = ed:getRange(y1, x1, y2, x2), linewise = false }
	if op == "y" then
		ed.cy, ed.cx = y1, x1
		return
	end
	ed:snap()
	ed:deleteRange(y1, x1, y2, x2)
	if op == "c" then self:startInsert() else ed:clamp(false) end
end

function Vim:applyLinewise(op, y1, y2)
	local ed = self.ed
	local chunk = {}
	for y = y1, y2 do chunk[#chunk + 1] = ed.lines[y] end
	self.term._reg = { text = table.concat(chunk, "\n"), linewise = true }
	if op == "y" then
		ed.cy = y1
		if #chunk > 2 then self.msg = #chunk .. " lines yanked" end
		return
	end
	ed:snap()
	for _ = y1, y2 do table.remove(ed.lines, y1) end
	ed.modified = true
	if op == "d" then
		if #ed.lines == 0 then ed.lines = { "" } end
		ed.cy = math.min(y1, #ed.lines)
		ed.cx = ed.lines[ed.cy]:find("%S") or 1
		if #chunk > 2 then self.msg = #chunk .. " fewer lines" end
	else
		table.insert(ed.lines, y1, "")
		ed.cy, ed.cx = y1, 1
		self:startInsert()
	end
end

function Vim:applyOp(op, spec)
	local ed = self.ed
	if spec.linewise then
		return self:applyLinewise(op, math.min(ed.cy, spec.y), math.max(ed.cy, spec.y))
	end
	local y1, x1, y2, x2 = ed.cy, ed.cx, spec.y, spec.x
	if spec.word and y2 > y1 then y2, x2 = y1, #ed.lines[y1] + 1 end
	if y2 < y1 or (y2 == y1 and x2 < x1) then y1, x1, y2, x2 = y2, x2, y1, x1 end
	if spec.inclusive then x2 = x2 + 1 end
	self:applyRange(op, y1, x1, y2, x2)
end

function Vim:visualOp(op)
	local ed = self.ed
	local y1, x1, y2, x2 = self.vy, self.vx, ed.cy, ed.cx
	if y1 > y2 or (y1 == y2 and x1 > x2) then y1, x1, y2, x2 = y2, x2, y1, x1 end
	local mode = self.mode
	self.mode = "normal"
	self:resetPending()
	if mode == "vline" then
		self:applyLinewise(op, y1, y2)
	else
		self:applyRange(op, y1, x1, y2, x2 + 1)
	end
end

function Vim:paste(before, n)
	local ed = self.ed
	local reg = self.term._reg
	if not reg or (reg.text == "" and not reg.linewise) then
		self.msg = 'E353: Nothing in register "'
		return
	end
	ed:snap()
	for _ = 1, n do
		if reg.linewise then
			local at = before and ed.cy or ed.cy + 1
			local i = 0
			for p in (reg.text .. "\n"):gmatch("(.-)\n") do
				table.insert(ed.lines, at + i, p)
				i = i + 1
			end
			ed.cy = at
			ed.cx = ed.lines[ed.cy]:find("%S") or 1
			ed.modified = true
		else
			local x = before and ed.cx or ed.cx + 1
			x = math.min(x, #ed:curLine() + 1)
			local ey, ex = ed:insertBlock(reg.text, ed.cy, x)
			ed.cy, ed.cx = ey, ex - 1
		end
	end
	ed:clamp(false)
end

function Vim:search(pat, dir, keepDir)
	local ed = self.ed
	if pat == "" then return false end
	self.searchPat = pat
	if not keepDir then self.searchDir = dir end
	local lines, total = ed.lines, #ed.lines
	for i = 0, total do
		local y = ((ed.cy - 1 + dir * i) % total) + 1
		local line = lines[y]
		if dir == 1 then
			local idx = line:find(pat, (i == 0) and (ed.cx + 1) or 1, true)
			if idx then ed.cy, ed.cx = y, idx; return true end
		else
			local limit = (i == 0) and (ed.cx - 1) or #line
			local last, init = nil, 1
			while true do
				local idx = line:find(pat, init, true)
				if not idx or idx > limit then break end
				last, init = idx, idx + 1
			end
			if last then ed.cy, ed.cx = y, last; return true end
		end
	end
	self.msg = "E486: Pattern not found: " .. pat
	return false
end

function Vim:normalChar(ch)
	local ed = self.ed
	if self.screen.closed then return end
	local visual = self.mode == "visual" or self.mode == "vline"
	local p = self.pending
	local key, arg = ch, nil
	if p then
		self.pending = nil
		if p == "r" then
			self.count = ""
			local line = ed:curLine()
			if not visual and ed.cx <= #line then
				ed:snap()
				ed.lines[ed.cy] = line:sub(1, ed.cx - 1) .. ch .. line:sub(ed.cx + 1)
				ed.modified = true
			end
			return
		elseif p == "g" then
			key = "g" .. ch
		else
			key, arg = p, ch
		end
	else
		if ch:match("%d") and (ch ~= "0" or self.count ~= "") then
			self.count = self.count .. ch
			return
		end
		if ch == "g" or ch == "f" or ch == "t" or ch == "F" or ch == "T" or (ch == "r" and not self.op) then
			self.pending = ch
			return
		end
	end
	local n = tonumber(self.count)
	local hasCount = n ~= nil
	n = n or 1

	if self.op and not visual then
		local op = self.op
		local total = (self.opCount or 1) * n
		local opHas = hasCount or self.opCount ~= nil
		self:resetPending()
		if key == op then
			self:applyLinewise(op, ed.cy, math.min(#ed.lines, ed.cy + total - 1))
		else
			local spec = self:motion(key, total, opHas, arg, op)
			if spec then self:applyOp(op, spec) end
		end
		return
	end

	if key == "d" or key == "y" or key == "c" then
		if visual then
			self:visualOp(key)
			return
		end
		self.op, self.opCount, self.count = key, (hasCount and n or nil), ""
		return
	end

	local spec = self:motion(key, n, hasCount, arg, nil)
	if spec then
		self.count = ""
		ed.cy, ed.cx = spec.y, spec.x
		ed:clamp(false)
		return
	end
	self.count = ""

	if visual then
		if key == "v" then
			if self.mode == "visual" then self:toNormal() else self.mode = "visual" end
		elseif key == "V" then
			if self.mode == "vline" then self:toNormal() else self.mode = "vline" end
		elseif key == "x" or key == "X" then
			self:visualOp("d")
		elseif key == "o" then
			self.vy, ed.cy = ed.cy, self.vy
			self.vx, ed.cx = ed.cx, self.vx
		elseif key == ":" then
			self:toNormal()
			self:enterCmd(":")
		end
		return
	end
	self:normalCommand(key, n, hasCount)
end

function Vim:normalCommand(key, n, hasCount)
	local ed = self.ed
	local line = ed:curLine()
	if key == "i" then
		ed:snap(); self:startInsert()
	elseif key == "a" then
		ed:snap()
		if #line > 0 then ed.cx = ed.cx + 1 end
		self:startInsert()
	elseif key == "I" then
		ed:snap(); ed.cx = line:find("%S") or 1; self:startInsert()
	elseif key == "A" then
		ed:snap(); ed.cx = #line + 1; self:startInsert()
	elseif key == "o" then
		ed:snap()
		table.insert(ed.lines, ed.cy + 1, "")
		ed.cy, ed.cx, ed.modified = ed.cy + 1, 1, true
		self:startInsert()
	elseif key == "O" then
		ed:snap()
		table.insert(ed.lines, ed.cy, "")
		ed.cx, ed.modified = 1, true
		self:startInsert()
	elseif key == "x" then
		self:applyRange("d", ed.cy, ed.cx, ed.cy, math.min(ed.cx + n, #line + 1))
	elseif key == "X" then
		if ed.cx > 1 then self:applyRange("d", ed.cy, math.max(1, ed.cx - n), ed.cy, ed.cx) end
	elseif key == "D" then
		self:applyRange("d", ed.cy, ed.cx, ed.cy, #line + 1)
	elseif key == "C" then
		self:applyRange("c", ed.cy, ed.cx, ed.cy, #line + 1)
	elseif key == "s" then
		self:applyRange("c", ed.cy, ed.cx, ed.cy, math.min(ed.cx + n, #line + 1))
	elseif key == "S" then
		self:applyLinewise("c", ed.cy, math.min(#ed.lines, ed.cy + n - 1))
	elseif key == "p" then
		self:paste(false, n)
	elseif key == "P" then
		self:paste(true, n)
	elseif key == "u" then
		if ed:doUndo() then ed:clamp(false) else self.msg = "Already at oldest change" end
	elseif key == "J" then
		for _ = 1, math.max(1, hasCount and (n - 1) or 1) do
			if ed.cy < #ed.lines then
				ed:snap()
				local a = ed.lines[ed.cy]
				local b = ed.lines[ed.cy + 1]:gsub("^%s+", "")
				ed.cx = #a + 1
				ed.lines[ed.cy] = a .. ((#a > 0 and #b > 0) and " " or "") .. b
				table.remove(ed.lines, ed.cy + 1)
				ed.modified = true
			end
		end
		ed:clamp(false)
	elseif key == "~" then
		if #line >= ed.cx then
			ed:snap()
			local c = line:sub(ed.cx, ed.cx)
			local sw = (c:lower() == c) and c:upper() or c:lower()
			ed.lines[ed.cy] = line:sub(1, ed.cx - 1) .. sw .. line:sub(ed.cx + 1)
			ed.cx = math.min(ed.cx + 1, #line)
			ed.modified = true
		end
	elseif key == "v" then
		self.mode, self.vy, self.vx = "visual", ed.cy, ed.cx
	elseif key == "V" then
		self.mode, self.vy, self.vx = "vline", ed.cy, ed.cx
	elseif key == ":" or key == "/" or key == "?" then
		self:enterCmd(key)
	elseif key == "n" then
		if self.searchPat then self:search(self.searchPat, self.searchDir, true) else self.msg = "E35: No previous regular expression" end
	elseif key == "N" then
		if self.searchPat then self:search(self.searchPat, -self.searchDir, true) else self.msg = "E35: No previous regular expression" end
	end
end

function Vim:cmdKey(k)
	local name = k.name
	if name == "Escape" or (k.ctrl and name == "c") then
		self.mode, self.cmd = "normal", ""
	elseif name == "Enter" then
		local c, pc = self.cmd, self.promptChar
		self.mode, self.cmd = "normal", ""
		if pc == ":" then self:exCommand(c) else self:search(c, pc == "/" and 1 or -1) end
	elseif name == "Backspace" then
		if self.cmd == "" then self.mode = "normal" else self.cmd = self.cmd:sub(1, -2) end
	end
	self:render()
end

function Vim:write(path)
	local ed = self.ed
	local ok, a, b = ed:save(path)
	if ok then
		self.msg = string.format('"%s" %dL, %dB written', ed.path, a, b)
	elseif a == "No file name" then
		self.msg = "E32: No file name"
	else
		self.msg = "E212: Can't open file for writing"
	end
	return ok
end

function Vim:exCommand(c)
	local ed = self.ed
	c = c:gsub("^%s+", ""):gsub("%s+$", "")
	if c == "" then return end
	local num = tonumber(c)
	if num then
		ed.cy, ed.cx = math.max(1, math.min(num, #ed.lines)), 1
		ed:clamp(false)
		return
	end
	if c == "$" then
		ed.cy, ed.cx = #ed.lines, 1
		ed:clamp(false)
		return
	end

	local range, rest = c:match("^(%%?)s/(.*)$")
	if rest then
		local pat, rep, flags = rest:match("^([^/]*)/([^/]*)/?(.*)$")
		if not pat or pat == "" then self.msg = "E486: Pattern not found" return end
		local y1, y2 = ed.cy, ed.cy
		if range == "%" then y1, y2 = 1, #ed.lines end
		ed:snap()
		local count = 0
		for y = y1, y2 do
			local line = ed.lines[y]
			local out, pos = {}, 1
			while true do
				local s, e = line:find(pat, pos, true)
				if not s then break end
				out[#out + 1] = line:sub(pos, s - 1) .. rep
				pos = e + 1
				count = count + 1
				if not flags:find("g") then break end
			end
			out[#out + 1] = line:sub(pos)
			ed.lines[y] = table.concat(out)
		end
		if count == 0 then
			table.remove(ed.undo)
			self.msg = "E486: Pattern not found: " .. pat
		else
			ed.modified = true
			self.msg = count .. " substitutions"
		end
		return
	end

	local cmd, bang, arg = c:match("^(%a+)(!?)%s*(.*)$")
	bang = bang == "!"
	if cmd == "w" then
		self:write(arg ~= "" and arg or nil)
	elseif cmd == "wq" or cmd == "x" or cmd == "xit" then
		if cmd == "wq" or ed.modified then
			if not self:write(arg ~= "" and arg or nil) then return end
		end
		self.screen:Close()
	elseif cmd == "q" or cmd == "quit" or cmd == "qa" or cmd == "qall" then
		if ed.modified and not bang then
			self.msg = "E37: No write since last change (add ! to override)"
		else
			self.screen:Close()
		end
	elseif cmd == "e" or cmd == "edit" then
		if ed.modified and not bang then
			self.msg = "E37: No write since last change (add ! to override)"
		else
			local target = arg ~= "" and arg or ed.path
			if not target then self.msg = "E32: No file name" return end
			local new = Editor.new(self.term, self.ctx, target)
			if new.err then self.msg = "E502: \"" .. target .. "\" is a directory" return end
			self.ed = new
			self.msg = new.isNew and string.format('"%s" [New]', target) or string.format('"%s" %dL, %dB', target, #new.lines, new.bytes or 0)
		end
	elseif cmd == "set" then
		for opt in arg:gmatch("%S+") do
			if opt == "nu" or opt == "number" then self.number = true
			elseif opt == "nonu" or opt == "nonumber" then self.number = false
			elseif opt:match("^ts=") or opt:match("^sw=") or opt == "hlsearch" or opt == "ignorecase" then
				-- accepted, no effect
			else
				self.msg = "E518: Unknown option: " .. opt
			end
		end
	elseif cmd == "noh" or cmd == "nohlsearch" or cmd == "syntax" then
		-- no-op
	elseif cmd == "help" or cmd == "h" then
		self.msg = "RbxTerm vim: :w save  :q quit  :wq save+quit  :set nu  :%s/a/b/g  /search  Esc or Ctrl+[ for normal mode"
	else
		self.msg = "E492: Not an editor command: " .. c
	end
end

----------------------------------------------------------------------- nano --

local Nano = {}
Nano.__index = Nano

function Nano.new(term, ctx, path)
	local self = setmetatable({}, Nano)
	self.term, self.ctx = term, ctx
	self.ed = Editor.new(term, ctx, path)
	self.msg = ""
	if path then
		if self.ed.isNew then self.msg = "[ New File ]" else self.msg = string.format("[ Read %d lines ]", #self.ed.lines) end
	end
	return self
end

function Nano:run()
	local screen = self.term:OpenScreen({
		onKey = function(k) self:onKey(k) end,
		onChar = function(c) self:onChar(c) end,
		onResize = function() self:render() end,
	})
	self.screen = screen
	self:render()
	screen:Wait()
end

local NANO_HELP1 = { { "^G", "Help" }, { "^O", "Write Out" }, { "^W", "Where Is" }, { "^K", "Cut" }, { "^C", "Location" } }
local NANO_HELP2 = { { "^X", "Exit" }, { "^_", "Go To Line" }, { "^U", "Paste" }, { "M-U", "Undo" }, { "M-E", "Redo" } }

function Nano:render()
	local s = self.screen
	if not s or s.closed then return end
	local ed, term = self.ed, self.term
	local rows = {}
	local textRows = math.max(1, s.rows - 4)

	local left = "  RbxTerm nano"
	local center = ed.path or "New Buffer"
	local right = ed.modified and "Modified  " or ""
	local pad1 = math.max(1, math.floor((s.cols - #center) / 2) - #left)
	local pad2 = math.max(1, s.cols - #left - pad1 - #center - #right)
	rows[1] = { t = esc(left) .. string.rep(" ", pad1) .. esc(center) .. string.rep(" ", pad2) .. esc(right), style = "bar" }

	ed:renderBody(rows, 2, textRows, { cols = s.cols })

	local msgRow = textRows + 2
	if self.prompt then
		rows[msgRow] = "<b>" .. esc(self.prompt.label .. self.prompt.text) .. "</b>"
	elseif self.msg ~= "" then
		rows[msgRow] = string.rep(" ", math.max(0, math.floor((s.cols - #self.msg) / 2))) .. esc(self.msg)
	else
		rows[msgRow] = ""
	end

	local function helpRow(items)
		local colw = math.max(10, math.floor(s.cols / #items))
		local parts = {}
		for _, it in ipairs(items) do
			local used = #it[1] + 1 + #it[2]
			parts[#parts + 1] = inv(term, it[1]) .. " " .. esc(it[2]) .. string.rep(" ", math.max(1, colw - used))
		end
		return table.concat(parts)
	end
	rows[textRows + 3] = helpRow(NANO_HELP1)
	rows[textRows + 4] = helpRow(NANO_HELP2)

	local cur
	if self.prompt then
		cur = { row = msgRow, col = #self.prompt.label + #self.prompt.text + 1, style = "bar" }
	else
		cur = { row = ed.cy - ed.top + 2, col = ed.cx - ed.left, style = "bar" }
	end
	s:Render(rows, cur)
end

function Nano:promptStart(label, text, onEnter, yn)
	self.prompt = { label = label, text = text or "", onEnter = onEnter, yn = yn }
end

function Nano:writeOut(thenExit)
	local ed = self.ed
	self:promptStart("File Name to Write: ", ed.path or "", function(t)
		if t == "" then self.msg = "[ Cancelled ]" return end
		local ok, l = ed:save(t)
		if ok then
			self.msg = string.format("[ Wrote %d lines ]", l)
			if thenExit then self.screen:Close() end
		else
			self.msg = "[ Error writing " .. t .. ": " .. tostring(l) .. " ]"
		end
	end)
end

function Nano:exit()
	if not self.ed.modified then
		self.screen:Close()
		return
	end
	self:promptStart("Save modified buffer?  (Y/N, Esc to cancel)", "", function(c)
		if c == "n" then self.screen:Close() else self:writeOut(true) end
	end, true)
end

function Nano:search()
	local ed = self.ed
	self:promptStart("Search: ", self.lastSearch or "", function(pat)
		if pat == "" then return end
		self.lastSearch = pat
		local total = #ed.lines
		for i = 0, total do
			local y = ((ed.cy - 1 + i) % total) + 1
			local idx = ed.lines[y]:find(pat, (i == 0) and (ed.cx + 1) or 1, true)
			if idx then ed.cy, ed.cx = y, idx; return end
		end
		self.msg = '[ "' .. pat .. '" not found ]'
	end)
end

function Nano:onKey(k)
	local ed, name = self.ed, k.name
	if self.prompt then
		local p = self.prompt
		if name == "Escape" or (k.ctrl and name == "c") then
			self.prompt = nil
			self.msg = "[ Cancelled ]"
		elseif not p.yn then
			if name == "Enter" then
				self.prompt = nil
				p.onEnter(p.text)
			elseif name == "Backspace" then
				p.text = p.text:sub(1, -2)
			end
		end
		self:render()
		return
	end
	self.msg = ""
	local line = ed:curLine()
	local textRows = math.max(1, self.screen.rows - 4)
	local isEdit = name == "Backspace" or name == "Enter" or name == "Delete" or name == "Tab"
	if not isEdit then self.typing = false end
	if isEdit and not self.typing and not k.ctrl then ed:snap(); self.typing = true end

	if k.ctrl then
		if name == "x" then self:exit()
		elseif name == "o" then self:writeOut(false)
		elseif name == "w" then self:search()
		elseif name == "_" or name == "t" then
			self:promptStart("Enter line number: ", "", function(t)
				local n = tonumber(t)
				if n then ed.cy, ed.cx = math.max(1, math.min(n, #ed.lines)), 1 else self.msg = "[ Invalid line number ]" end
			end)
		elseif name == "k" then
			ed:snap()
			if self.lastCut and self.cutBuf then self.cutBuf[#self.cutBuf + 1] = line else self.cutBuf = { line } end
			if #ed.lines == 1 then ed.lines[1] = "" else table.remove(ed.lines, ed.cy) end
			ed:clamp(true)
			ed.cx, ed.modified = 1, true
			self.lastCut = true
			self:render()
			return
		elseif name == "u" then
			if self.cutBuf then
				ed:snap()
				for i, l in ipairs(self.cutBuf) do table.insert(ed.lines, ed.cy + i - 1, l) end
				ed.cy, ed.cx, ed.modified = ed.cy + #self.cutBuf, 1, true
				ed:clamp(true)
			end
		elseif name == "c" then
			local total = 0
			for _, l in ipairs(ed.lines) do total = total + #l + 1 end
			self.msg = string.format("[ line %d/%d (%d%%), col %d/%d ]", ed.cy, #ed.lines,
				math.floor(ed.cy / #ed.lines * 100), ed.cx, #line + 1)
		elseif name == "g" then
			self.msg = "[ ^O save, ^X exit, ^K cut line, ^U paste, ^W search, ^_ go to line, M-U undo ]"
		elseif name == "a" then ed.cx = 1
		elseif name == "e" then ed.cx = #line + 1
		elseif name == "y" then ed.cy = ed.cy - textRows; ed.top = ed.top - textRows; ed:clamp(true)
		elseif name == "z" then
			if ed:doUndo() then ed:clamp(true) else self.msg = "[ Nothing to undo ]" end
		end
	elseif k.alt then
		if name == "u" then
			if ed:doUndo() then ed:clamp(true) else self.msg = "[ Nothing to undo ]" end
		elseif name == "e" then
			if ed:doRedo() then ed:clamp(true) else self.msg = "[ Nothing to redo ]" end
		end
	else
		if name == "Enter" then ed:newline()
		elseif name == "Backspace" then ed:backspace()
		elseif name == "Delete" then ed:delete()
		elseif name == "Tab" then ed:insertText("    ")
		elseif name == "Left" then
			if ed.cx > 1 then ed.cx = ed.cx - 1
			elseif ed.cy > 1 then ed.cy = ed.cy - 1; ed.cx = #ed.lines[ed.cy] + 1 end
		elseif name == "Right" then
			if ed.cx <= #line then ed.cx = ed.cx + 1
			elseif ed.cy < #ed.lines then ed.cy = ed.cy + 1; ed.cx = 1 end
		elseif name == "Up" then ed.cy = ed.cy - 1; ed:clamp(true)
		elseif name == "Down" then ed.cy = ed.cy + 1; ed:clamp(true)
		elseif name == "Home" then ed.cx = 1
		elseif name == "End" then ed.cx = #line + 1
		elseif name == "PageUp" then ed.cy = ed.cy - textRows; ed.top = ed.top - textRows; ed:clamp(true)
		elseif name == "PageDown" then ed.cy = ed.cy + textRows; ed.top = ed.top + textRows; ed:clamp(true)
		end
	end
	self.lastCut = false
	self:render()
end

function Nano:onChar(text)
	if not self.screen or self.screen.closed then return end
	if self.prompt then
		local p = self.prompt
		if p.yn then
			local c = text:lower():sub(1, 1)
			if c == "y" or c == "n" then
				self.prompt = nil
				p.onEnter(c)
			end
		else
			p.text = p.text .. text
		end
		self:render()
		return
	end
	if not self.typing then
		self.ed:snap()
		self.typing = true
	end
	self.msg = ""
	self.lastCut = false
	self.ed:insertText(text)
	self:render()
end

---------------------------------------------------------------------- pager --

-- lines: array of plain strings. Used by less, more and man.
function Terminal:_pager(lines, title)
	local top, searchPat, mode, cmd = 1, nil, "view", ""
	local screen
	local function maxTop() return math.max(1, #lines - (screen.rows - 1) + 1) end
	local function render()
		if screen.closed then return end
		local rows = {}
		for i = 1, screen.rows - 1 do
			local l = lines[top + i - 1]
			rows[i] = l and esc(l:gsub("\t", "    "):sub(1, screen.cols)) or ('<font color="' .. hex(self.Theme.palette.blue) .. '">~</font>')
		end
		local status
		if mode == "search" then
			status = "/" .. cmd
		else
			local bottom = top + screen.rows - 2
			local where = bottom >= #lines and "(END)" or string.format("%d%%", math.floor(bottom / #lines * 100))
			status = string.format("%s  lines %d-%d/%d  %s   (q quit, / search, space/b page)", title or "", top, math.min(bottom, #lines), #lines, where)
		end
		rows[screen.rows] = { t = esc(status:sub(1, screen.cols)), style = "bar" }
		screen:Render(rows, mode == "search" and { row = screen.rows, col = #cmd + 2, style = "bar" } or nil)
	end
	local function clamp() top = math.max(1, math.min(top, maxTop())) end
	local function find(dir)
		if not searchPat then return end
		for i = 1, #lines do
			local y = ((top - 1 + dir * i) % #lines) + 1
			if lines[y]:find(searchPat, 1, true) then top = y; clamp(); return end
		end
	end
	local function act(key)
		local page = math.max(1, screen.rows - 2)
		if key == "j" or key == "Down" or key == "Enter" then top = top + 1
		elseif key == "k" or key == "Up" then top = top - 1
		elseif key == " " or key == "f" or key == "PageDown" then top = top + page
		elseif key == "b" or key == "PageUp" then top = top - page
		elseif key == "d" then top = top + math.floor(page / 2)
		elseif key == "u" then top = top - math.floor(page / 2)
		elseif key == "g" or key == "Home" then top = 1
		elseif key == "G" or key == "End" then top = maxTop()
		elseif key == "n" then find(1)
		elseif key == "N" then find(-1)
		elseif key == "/" then mode, cmd = "search", ""
		elseif key == "q" or key == "Escape" then screen:Close() return end
		clamp()
	end
	screen = self:OpenScreen({
		onKey = function(k)
			if k.ctrl and k.name == "c" then screen:Close() return end
			if mode == "search" then
				if k.name == "Enter" then
					mode = "view"
					if cmd ~= "" then searchPat = cmd; find(1) end
				elseif k.name == "Escape" then mode = "view"
				elseif k.name == "Backspace" then
					if cmd == "" then mode = "view" else cmd = cmd:sub(1, -2) end
				end
			else
				act(k.name)
			end
			render()
		end,
		onChar = function(c)
			if mode == "search" then cmd = cmd .. c else for i = 1, #c do act(c:sub(i, i)) end end
			render()
		end,
		onResize = function() clamp(); render() end,
	})
	render()
	screen:Wait()
end

--------------------------------------------------------------------- tools ----

local function globToPattern(g)
	local p = g:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
	p = p:gsub("%*", ".*")
	p = p:gsub("%?", ".")
	return "^" .. p .. "$"
end

local function gatherInputs(ctx, name)
	local items = {}
	if #ctx.args == 0 then
		if ctx.stdin then items[1] = { name = "-", text = ctx.stdin } end
		return items
	end
	for _, a in ipairs(ctx.args) do
		local text, err = ctx.fs:ReadFile(ctx.resolve(a))
		if text then items[#items + 1] = { name = a, text = text } else ctx.error(name .. ": " .. a .. ": " .. err) end
	end
	return items
end

local function expandSet(s)
	local out = {}
	local i = 1
	while i <= #s do
		local a, dash, b = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2)
		if dash == "-" and b ~= "" then
			for c = a:byte(), b:byte() do out[#out + 1] = string.char(c) end
			i = i + 3
		else
			out[#out + 1] = a
			i = i + 1
		end
	end
	return out
end

local function parseFields(spec)
	local set = {}
	for part in spec:gmatch("[^,]+") do
		local a, b = part:match("^(%d+)-(%d+)$")
		if a then
			for i = tonumber(a), tonumber(b) do set[#set + 1] = i end
		elseif tonumber(part) then
			set[#set + 1] = tonumber(part)
		end
	end
	return set
end

local function diffLines(a, b)
	local n, m = #a, #b
	local L = {}
	for i = 0, n do
		L[i] = {}
		for j = 0, m do L[i][j] = 0 end
	end
	for i = n - 1, 0, -1 do
		for j = m - 1, 0, -1 do
			if a[i + 1] == b[j + 1] then L[i][j] = L[i + 1][j + 1] + 1
			else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
		end
	end
	local out, i, j = {}, 0, 0
	while i < n and j < m do
		if a[i + 1] == b[j + 1] then
			i, j = i + 1, j + 1
		elseif L[i + 1][j] >= L[i][j + 1] then
			out[#out + 1] = { "<", a[i + 1] }
			i = i + 1
		else
			out[#out + 1] = { ">", b[j + 1] }
			j = j + 1
		end
	end
	while i < n do out[#out + 1] = { "<", a[i + 1] }; i = i + 1 end
	while j < m do out[#out + 1] = { ">", b[j + 1] }; j = j + 1 end
	return out
end

function Terminal:_runShell(src, ctx)
	for _, l in ipairs(splitLines(src)) do
		if self._interrupt then break end
		if l:match("%S") and not l:match("^%s*#") then self:_execLine(l) end
	end
	return self.lastStatus
end

function Terminal:_installTools()
	local term = self
	local function reg(n, d) term:RegisterCommand(n, d) end

	local function editorCmd(name, Class, desc)
		reg(name, { description = desc, usage = name .. " [file]", run = function(ctx)
			if term._screen then ctx.error(name .. ": another full-screen app is open") return 1 end
			local app = Class.new(term, ctx, ctx.args[1])
			if app.ed.err then ctx.error(name .. ": " .. ctx.args[1] .. ": " .. app.ed.err) return 1 end
			app:run()
			return 0
		end })
	end
	editorCmd("vim", Vim, "Vi IMproved, a modal text editor")
	editorCmd("vi", Vim, "alias for vim")
	editorCmd("nano", Nano, "small, friendly text editor")

	reg("less", { description = "page through text", usage = "less [file]", run = function(ctx)
		local items = gatherInputs(ctx, "less")
		if #items == 0 then ctx.error("less: missing filename") return 1 end
		term:_pager(splitLines(items[1].text), items[1].name == "-" and "(stdin)" or items[1].name)
		return 0
	end })
	reg("more", { description = "page through text", usage = "more [file]", run = term.commands.less.run })

	reg("man", { description = "show help for a command", usage = "man command", run = function(ctx)
		local name = ctx.args[1]
		if not name then ctx.error("What manual page do you want?") return 1 end
		local def = term.commands[name]
		if not def then ctx.error("No manual entry for " .. name) return 1 end
		local lines = {
			"NAME", "    " .. name .. (def.description and (" - " .. def.description) or ""), "",
			"SYNOPSIS", "    " .. (def.usage or name), "",
		}
		if def.values and #def.values > 0 then
			lines[#lines + 1] = "OPTIONS WITH VALUES"
			lines[#lines + 1] = "    " .. table.concat(def.values, ", ")
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = "Use '" .. name .. " --help' for a short usage line."
		term:_pager(lines, "man " .. name)
		return 0
	end })

	-- file operations ------------------------------------------------------
	local function copyOrMove(ctx, move)
		local cname = move and "mv" or "cp"
		local args = ctx.args
		if #args < 2 then ctx.error(cname .. ": missing destination file operand") return 1 end
		local dest = ctx.resolve(args[#args])
		local destNode = ctx.fs:Get(dest)
		local destIsDir = destNode ~= nil and destNode.type == "dir"
		if #args > 2 and not destIsDir then
			ctx.error(cname .. ": target '" .. args[#args] .. "' is not a directory")
			return 1
		end
		local status = 0
		for i = 1, #args - 1 do
			local src = ctx.resolve(args[i])
			local sn = ctx.fs:Get(src)
			if not sn then
				ctx.error(string.format("%s: cannot stat '%s': No such file or directory", cname, args[i]))
				status = 1
			elseif sn.type == "dir" and not move and not (ctx.flags.r or ctx.flags.R) then
				ctx.error(string.format("cp: -r not specified; omitting directory '%s'", args[i]))
				status = 1
			else
				local target = destIsDir and (dest .. "/" .. (src:match("([^/]*)$") or "")) or dest
				local ok, err
				if move then ok, err = ctx.fs:Move(src, target) else ok, err = ctx.fs:Copy(src, target) end
				if not ok then
					ctx.error(string.format("%s: cannot %s '%s': %s", cname, move and "move" or "copy", args[i], err))
					status = 1
				end
			end
		end
		return status
	end
	reg("cp", { description = "copy files", usage = "cp [-r] source... dest", run = function(ctx) return copyOrMove(ctx, false) end })
	reg("mv", { description = "move or rename files", usage = "mv source... dest", run = function(ctx) return copyOrMove(ctx, true) end })

	reg("chmod", { description = "change the executable bit", usage = "chmod [+x|-x|755|644] file...", run = function(ctx)
		local mode = ctx.argv[2]
		if not mode then ctx.error("chmod: missing operand") return 1 end
		local on
		if mode:find("+", 1, true) and mode:find("x", 1, true) then on = true
		elseif mode:find("-", 1, true) and mode:find("x", 1, true) then on = false
		elseif mode:match("^[0-7]+$") then on = tonumber(mode:sub(1, 1)) % 2 == 1
		else ctx.error("chmod: invalid mode: '" .. mode .. "'") return 1 end
		local status = 0
		for i = 3, #ctx.argv do
			local node = ctx.fs:Get(ctx.resolve(ctx.argv[i]))
			if not node then
				ctx.error("chmod: cannot access '" .. ctx.argv[i] .. "': No such file or directory")
				status = 1
			elseif node.type == "file" then
				node.executable = on
			end
		end
		return status
	end })

	reg("stat", { description = "show file status", usage = "stat file...", run = function(ctx)
		local status = 0
		for _, a in ipairs(ctx.args) do
			local node = ctx.fs:Get(ctx.resolve(a))
			if not node then
				ctx.error("stat: cannot statx '" .. a .. "': No such file or directory")
				status = 1
			else
				local kind = node.type == "dir" and "directory" or "regular file"
				local perms = node.type == "dir" and "drwxr-xr-x" or (isExec(node) and "-rwxr-xr-x" or "-rw-r--r--")
				ctx.print("  File: " .. a)
				ctx.print(string.format("  Size: %d\tType: %s", node.type == "dir" and 4096 or #(node.content or ""), kind))
				ctx.print("Access: " .. perms)
				ctx.print("Modify: " .. os.date("%Y-%m-%d %H:%M:%S", node.mtime or os.time()))
			end
		end
		return status
	end })

	reg("basename", { description = "strip directory from a path", usage = "basename path [suffix]", run = function(ctx)
		local p = ctx.args[1] or ""
		local b = p:gsub("/+$", ""):match("([^/]*)$") or ""
		local suf = ctx.args[2]
		if suf and b:sub(-#suf) == suf and #b > #suf then b = b:sub(1, -#suf - 1) end
		ctx.print(b)
	end })
	reg("dirname", { description = "strip last component from a path", usage = "dirname path", run = function(ctx)
		local p = (ctx.args[1] or ""):gsub("/+$", "")
		local d = p:match("^(.*)/[^/]*$")
		if d == nil then d = "." elseif d == "" then d = "/" end
		ctx.print(d)
	end })

	reg("find", { description = "search for files", usage = "find [path] [-name pattern] [-type f|d]", run = function(ctx)
		local start, pat, typ = ".", nil, nil
		local i = 2
		while i <= #ctx.argv do
			local a = ctx.argv[i]
			if a == "-name" then pat = ctx.argv[i + 1]; i = i + 1
			elseif a == "-type" then typ = ctx.argv[i + 1]; i = i + 1
			elseif a:sub(1, 1) ~= "-" then start = a end
			i = i + 1
		end
		local lp = pat and globToPattern(pat) or nil
		local root = ctx.fs:Get(ctx.resolve(start))
		if not root then ctx.error("find: '" .. start .. "': No such file or directory") return 1 end
		local function matches(name, node)
			if lp and not name:match(lp) then return false end
			if typ == "f" and node.type ~= "file" then return false end
			if typ == "d" and node.type ~= "dir" then return false end
			return true
		end
		local base = start:gsub("/+$", "")
		if base == "" then base = "/" end
		if matches(base:match("([^/]*)$"), root) then ctx.print(start) end
		local function walk(abs, shown)
			local list = ctx.fs:List(abs, true)
			if not list then return end
			for _, e in ipairs(list) do
				local childShown = (shown == "/" and "" or shown) .. "/" .. e.name
				if matches(e.name, e.node) then ctx.print(childShown) end
				if e.node.type == "dir" then walk((abs == "/" and "" or abs) .. "/" .. e.name, childShown) end
			end
		end
		walk(ctx.resolve(start), base)
	end })

	-- text processing -----------------------------------------------------
	reg("sort", { description = "sort lines", usage = "sort [-r] [-n] [-u] [file...]", run = function(ctx)
		local all = {}
		for _, it in ipairs(gatherInputs(ctx, "sort")) do
			for _, l in ipairs(splitLines(it.text)) do all[#all + 1] = l end
		end
		local function num(l) return tonumber(l:match("^%s*(-?[%d%.]+)")) or 0 end
		table.sort(all, function(a, b)
			if ctx.flags.n then
				local x, y = num(a), num(b)
				if x ~= y then return x < y end
			end
			return a < b
		end)
		if ctx.flags.r then
			for i = 1, math.floor(#all / 2) do all[i], all[#all - i + 1] = all[#all - i + 1], all[i] end
		end
		local last
		for _, l in ipairs(all) do
			if not (ctx.flags.u and l == last) then ctx.print(l) end
			last = l
		end
	end })

	reg("uniq", { description = "collapse adjacent duplicate lines", usage = "uniq [-c] [file]", run = function(ctx)
		for _, it in ipairs(gatherInputs(ctx, "uniq")) do
			local prev, count
			local function emit()
				if prev ~= nil then ctx.print(ctx.flags.c and string.format("%7d %s", count, prev) or prev) end
			end
			for _, l in ipairs(splitLines(it.text)) do
				if l == prev then count = count + 1 else emit(); prev, count = l, 1 end
			end
			emit()
		end
	end })

	reg("cut", { description = "select fields from lines", usage = "cut -d DELIM -f FIELDS [file]", values = { "d", "f" }, run = function(ctx)
		local delim = ctx.flags.d or "\t"
		if type(delim) ~= "string" then delim = "\t" end
		if type(ctx.flags.f) ~= "string" then ctx.error("cut: you must specify -f") return 1 end
		local fields = parseFields(ctx.flags.f)
		for _, it in ipairs(gatherInputs(ctx, "cut")) do
			for _, l in ipairs(splitLines(it.text)) do
				local parts = {}
				local pos = 1
				while true do
					local s, e = l:find(delim, pos, true)
					if not s then parts[#parts + 1] = l:sub(pos); break end
					parts[#parts + 1] = l:sub(pos, s - 1)
					pos = e + 1
				end
				local out = {}
				for _, f in ipairs(fields) do if parts[f] then out[#out + 1] = parts[f] end end
				ctx.print(table.concat(out, delim))
			end
		end
	end })

	reg("tr", { description = "translate or delete characters (stdin)", usage = "tr SET1 SET2  |  tr -d SET", run = function(ctx)
		local text = ctx.stdin or ""
		if ctx.flags.d then
			local del = {}
			for _, c in ipairs(expandSet(ctx.args[1] or "")) do del[c] = true end
			ctx.write((text:gsub(".", function(c) return del[c] and "" or nil end)))
			return 0
		end
		local a, b = expandSet(ctx.args[1] or ""), expandSet(ctx.args[2] or "")
		if #a == 0 or #b == 0 then ctx.error("tr: missing operand") return 1 end
		local map = {}
		for i, c in ipairs(a) do map[c] = b[math.min(i, #b)] end
		ctx.write((text:gsub(".", map)))
	end })

	reg("sed", { description = "substitute text (s/old/new/[g], plain text)", usage = "sed 's/old/new/g' [file...]", run = function(ctx)
		local expr = table.remove(ctx.args, 1)
		if not expr then ctx.error("sed: no script given") return 1 end
		local d, pat, rep, flags = expr:match("^s(.)(.-)%1(.-)%1(.*)$")
		if not d or not pat or pat == "" then ctx.error("sed: only s/old/new/[g] is supported") return 1 end
		for _, it in ipairs(gatherInputs(ctx, "sed")) do
			for _, l in ipairs(splitLines(it.text)) do
				local out, pos = {}, 1
				while true do
					local s, e = l:find(pat, pos, true)
					if not s then break end
					out[#out + 1] = l:sub(pos, s - 1) .. rep
					pos = e + 1
					if not flags:find("g") then break end
				end
				out[#out + 1] = l:sub(pos)
				ctx.print(table.concat(out))
			end
		end
	end })

	reg("tee", { description = "copy stdin to files and stdout", usage = "tee [-a] file...", run = function(ctx)
		local text = ctx.stdin or ""
		ctx.write(text)
		for _, a in ipairs(ctx.args) do
			local node, err = ctx.fs:WriteFile(ctx.resolve(a), text, { append = ctx.flags.a, parents = false })
			if not node then ctx.error("tee: " .. a .. ": " .. err) end
		end
	end })

	reg("seq", { description = "print a sequence of numbers", usage = "seq [first [step]] last", run = function(ctx)
		local a = ctx.args
		local first, step, last = 1, 1, nil
		if #a == 1 then last = tonumber(a[1])
		elseif #a == 2 then first, last = tonumber(a[1]), tonumber(a[2])
		elseif #a >= 3 then first, step, last = tonumber(a[1]), tonumber(a[2]), tonumber(a[3]) end
		if not (first and step and last) or step == 0 then ctx.error("seq: invalid argument") return 1 end
		local count = 0
		for v = first, last, step do
			ctx.print(v)
			count = count + 1
			if count > 100000 then break end
		end
	end })

	reg("diff", { description = "compare two files line by line", usage = "diff file1 file2", run = function(ctx)
		if #ctx.args < 2 then ctx.error("diff: missing operand") return 2 end
		local ta, ea = ctx.fs:ReadFile(ctx.resolve(ctx.args[1]))
		if not ta then ctx.error("diff: " .. ctx.args[1] .. ": " .. ea) return 2 end
		local tb, eb = ctx.fs:ReadFile(ctx.resolve(ctx.args[2]))
		if not tb then ctx.error("diff: " .. ctx.args[2] .. ": " .. eb) return 2 end
		local a, b = splitLines(ta), splitLines(tb)
		if #a * #b > 4000000 then ctx.error("diff: files too large") return 2 end
		local d = diffLines(a, b)
		for _, e in ipairs(d) do
			ctx.printc(e[1] == "<" and "red" or "green", e[1] .. " " .. e[2])
		end
		return #d > 0 and 1 or 0
	end })

	-- network -------------------------------------------------------------
	local function fetch(ctx, url, cname)
		if not url then ctx.error(cname .. ": missing URL") return nil end
		if not url:match("^https?://") then url = "https://" .. url end
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if not ok then
			ctx.error(cname .. ": request failed: " .. tostring(body))
			return nil
		end
		return body
	end
	reg("curl", { description = "fetch a URL (game:HttpGet)", usage = "curl [-o file] url", values = { "o" }, run = function(ctx)
		local body = fetch(ctx, ctx.args[1], "curl")
		if not body then return 1 end
		if type(ctx.flags.o) == "string" then
			local node, err = ctx.fs:WriteFile(ctx.resolve(ctx.flags.o), body, { parents = false })
			if not node then ctx.error("curl: " .. ctx.flags.o .. ": " .. err) return 1 end
		else
			ctx.write(body)
			if body:sub(-1) ~= "\n" then ctx.write("\n") end
		end
	end })
	reg("wget", { description = "download a URL into a file", usage = "wget [-O file] url", values = { "O" }, run = function(ctx)
		local url = ctx.args[1]
		local body = fetch(ctx, url, "wget")
		if not body then return 1 end
		local name = type(ctx.flags.O) == "string" and ctx.flags.O or ((url:gsub("[?#].*$", ""):match("([^/]+)$")) or "index.html")
		local node, err = ctx.fs:WriteFile(ctx.resolve(name), body, { parents = false })
		if not node then ctx.error("wget: " .. name .. ": " .. err) return 1 end
		ctx.print(string.format("saved '%s' (%d bytes)", name, #body))
	end })

	-- shell ---------------------------------------------------------------
	reg("alias", { description = "define or list aliases", usage = "alias [name='command']", run = function(ctx)
		if #ctx.argv < 2 then
			local keys = {}
			for k in pairs(term.aliases) do keys[#keys + 1] = k end
			table.sort(keys)
			for _, k in ipairs(keys) do ctx.print(string.format("alias %s='%s'", k, term.aliases[k])) end
			return 0
		end
		for i = 2, #ctx.argv do
			local k, v = ctx.argv[i]:match("^([^=]+)=(.*)$")
			if k then
				term.aliases[k] = v
			elseif term.aliases[ctx.argv[i]] then
				ctx.print(string.format("alias %s='%s'", ctx.argv[i], term.aliases[ctx.argv[i]]))
			else
				ctx.error("bash: alias: " .. ctx.argv[i] .. ": not found")
			end
		end
	end })
	reg("unalias", { description = "remove aliases", usage = "unalias name...", run = function(ctx)
		for _, a in ipairs(ctx.args) do term.aliases[a] = nil end
	end })

	local function shellRun(ctx)
		local path = ctx.args[1]
		if not path then ctx.error(ctx.name .. ": missing script") return 2 end
		local text, err = ctx.fs:ReadFile(ctx.resolve(path))
		if not text then ctx.error(ctx.name .. ": " .. path .. ": " .. err) return 127 end
		return term:_runShell(text, ctx)
	end
	reg("sh", { description = "run a shell script", usage = "sh script", run = shellRun })
	reg("bash", { description = "run a shell script", usage = "bash script", run = shellRun })
	reg("source", { description = "run a shell script", usage = "source script", run = shellRun })

	reg("true", { description = "do nothing, successfully", run = function() return 0 end })
	reg("false", { description = "do nothing, unsuccessfully", run = function() return 1 end })

	reg("uptime", { description = "show how long the terminal has been running", run = function(ctx)
		local up = os.clock() - term.startTime
		ctx.print(string.format(" %s up %d min,  1 user,  load average: 0.00, 0.00, 0.00", os.date("%H:%M:%S"), math.floor(up / 60)))
	end })
	reg("free", { description = "show Lua memory usage", run = function(ctx)
		ctx.print(string.format("Lua heap in use: %.2f MB", collectgarbage("count") / 1024))
	end })
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
