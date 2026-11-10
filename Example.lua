--[[
    Example.lua - demo of the Terminal UI library

    Run this file directly:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/Dynamic155/RbxTerm/main/Example.lua"))()

    The library itself is loaded from the same repo (see the first line below).

    Press RightControl to toggle the terminal. Then try:

        ls
        cd scripts/
        ls
        ./loadpart --cyl
        ./loadpart --ball --size=6 --color=red
        ./loadpart --clear
        ./hello.lua one two three
        ./guess.lua
        walkspeed 50
        lua print(game.PlaceId)
        ls | grep load
        nano notes.txt            (Ctrl+O save, Ctrl+X exit)
        vim hello.lua             (i to type, Ctrl+[ then :wq)
        less docs/readme.txt
        find . -name "*.lua"
        neofetch
        theme dracula
]]

local Players = game:GetService("Players")
local Terminal = loadstring(game:HttpGet("https://raw.githubusercontent.com/Dynamic155/RbxTerm/main/Terminal.lua"))()

local term = Terminal.new({
	Host = "roblox",
	Theme = "default",                       -- default | ubuntu | dracula | gruvbox | { custom overrides }
	ToggleKey = Enum.KeyCode.RightControl,
	BlurSize = 22,
})

local fs, home = term.fs, term.home

----------------------------------------------------------------------------
-- ~/scripts/loadpart : an "executable" written in Lua, with flags
----------------------------------------------------------------------------
local spawned = {}
local colors = {
	red = Color3.fromRGB(255, 70, 70), green = Color3.fromRGB(70, 220, 100),
	blue = Color3.fromRGB(70, 130, 255), yellow = Color3.fromRGB(255, 220, 70),
	orange = Color3.fromRGB(255, 150, 50), purple = Color3.fromRGB(170, 90, 255),
	white = Color3.fromRGB(240, 240, 240), black = Color3.fromRGB(20, 20, 20),
}

fs:AddExecutable(home .. "/scripts/loadpart", {
	description = "spawn a part in front of your character",
	usage = "loadpart [--cyl | --ball] [--size=N] [--color=NAME|#hex] [--free] [--clear]",
	values = { "size", "color" }, -- flags that take a value, so `--size 6` also works
	run = function(ctx)
		if ctx.flags.clear then
			local n = #spawned
			for _, p in ipairs(spawned) do p:Destroy() end
			table.clear(spawned)
			ctx.printc("yellow", ("removed %d part(s)"):format(n))
			return 0
		end

		local char = Players.LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then
			ctx.error("loadpart: no character found")
			return 1
		end

		local shape, shapeName = Enum.PartType.Block, "block"
		if ctx.flags.cyl then shape, shapeName = Enum.PartType.Cylinder, "cylinder"
		elseif ctx.flags.ball then shape, shapeName = Enum.PartType.Ball, "ball" end

		local size = tonumber(ctx.flags.size) or 4
		local color = colors[tostring(ctx.flags.color)]
		if not color and type(ctx.flags.color) == "string" then
			local ok, c = pcall(Color3.fromHex, ctx.flags.color)
			if ok then color = c end
		end

		local part = Instance.new("Part")
		part.Name = "TerminalPart"
		part.Shape = shape
		part.Size = Vector3.new(size, size, size)
		part.Color = color or colors.blue
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = not ctx.flags.free
		part.Position = root.Position + root.CFrame.LookVector * (size + 4) + Vector3.new(0, size / 2, 0)
		part.Parent = workspace
		spawned[#spawned + 1] = part

		ctx.printc("green", ("[ok] spawned %s (size %s) at %d, %d, %d"):format(
			shapeName, size, part.Position.X, part.Position.Y, part.Position.Z))
		return 0
	end,
})

----------------------------------------------------------------------------
-- Lua script files: shebang makes them executable. print() prints in the terminal.
----------------------------------------------------------------------------
fs:WriteFile(home .. "/hello.lua", [[#!lua
print("Hello from Lua running inside the terminal!")
print("player:", game.Players.LocalPlayer.Name)
print("args:", #args > 0 and table.concat(args, ", ") or "(none)")
for i = 1, 3 do
    print("tick " .. i)
    sleep(0.3)
end
]])

fs:WriteFile(home .. "/guess.lua", [[#!lua
local n = math.random(1, 20)
print("I'm thinking of a number between 1 and 20. You get 5 tries.")
for try = 1, 5 do
    local g = tonumber(read("guess> "))
    if not g then
        print("numbers only!")
    elseif g == n then
        print("Correct! It took you " .. try .. " tries.")
        return
    elseif g < n then
        print("higher")
    else
        print("lower")
    end
end
print("Out of tries. It was " .. n .. ".")
]])

fs:WriteFile(home .. "/docs/notes.txt", "loadpart is in ~/scripts\nTry: ./scripts/loadpart --cyl\n")

----------------------------------------------------------------------------
-- A registered command (lives in /bin, works from anywhere)
----------------------------------------------------------------------------
term:RegisterCommand("walkspeed", {
	description = "get or set your WalkSpeed",
	usage = "walkspeed [value]",
	run = function(ctx)
		local char = Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then ctx.error("walkspeed: no humanoid") return 1 end
		local v = tonumber(ctx.args[1])
		if v then
			hum.WalkSpeed = v
			ctx.printc("green", "WalkSpeed set to " .. v)
		else
			ctx.print(hum.WalkSpeed)
		end
		return 0
	end,
})

-- start in ~/scripts like the idea sketch, show the UI, and print a hint
term.cwd = home
term:Print("Hint: cd scripts/  ->  ls  ->  ./loadpart --cyl", "gray")
term:Show()

-- term:MirrorConsole(true)  -- uncomment to mirror the Roblox output log into the terminal
return term
