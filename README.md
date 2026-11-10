# RbxTerm

A Linux-style terminal UI library for Roblox, running entirely on the client.

It opens over the screen with a blurred background and gives you a small shell with a virtual filesystem, pipes, redirects, tab completion, history, a Lua REPL, and an API for adding your own commands and executable scripts. Anything you `print` from a Lua script shows up in the terminal.

## Quick start

```lua
local Terminal = loadstring(game:HttpGet("https://raw.githubusercontent.com/Dynamic155/RbxTerm/main/Terminal.lua"))()

local term = Terminal.new({ Theme = "default" })
term:Show()
```

Press `RightControl` to toggle the window. A full demo is in `Example.lua`:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Dynamic155/RbxTerm/main/Example.lua"))()
```

Requirements: an executor that provides `loadstring` (needed for the `lua` command and `.lua` scripts) and, optionally, `gethui` for hiding the UI. The library falls back to `CoreGui` and then `PlayerGui` if `gethui` is missing.

## Using the terminal

| Key | Action |
| --- | --- |
| Enter | Run the command |
| Tab | Complete command or path. Press again on an ambiguous match to list options |
| Up / Down | Browse history |
| Ctrl+C | Interrupt a running command, or cancel the current line |
| Ctrl+L | Clear the screen |
| Ctrl+U | Clear the input line |
| RightControl | Show or hide the terminal (configurable) |

Window controls: the red button closes, yellow collapses to the title bar, green maximizes. Drag the title bar to move the window and drag the bottom-right corner to resize it.

### Example session

```
user@roblox:~$ ls
docs/  scripts/  guess.lua  hello.lua
user@roblox:~$ cd scripts/
user@roblox:~/scripts$ ls
loadpart
user@roblox:~/scripts$ ./loadpart --cyl
[ok] spawned cylinder (size 4) at 12, 6, -30
user@roblox:~/scripts$ ls | grep load > found.txt && cat found.txt
loadpart
user@roblox:~/scripts$ lua print(game.PlaceId)
1818
```

## Shell syntax

| Feature | Example |
| --- | --- |
| Quoting | `echo "hello world"`, `echo 'literal $HOME'` |
| Variables | `export NAME=bob`, `echo $NAME`, `echo ${NAME}`, `echo $?` |
| Home shortcut | `cd ~`, `cat ~/docs/readme.txt` |
| Pipes | `ls \| grep lua` |
| Redirect | `echo hi > a.txt`, `echo more >> a.txt` |
| Sequencing | `cmd1; cmd2`, `cmd1 && cmd2`, `cmd1 \|\| cmd2` |
| Comments | `# ignored` |
| Run a file | `./script` or `/path/to/script` |
| PATH lookup | Executables in `/bin` and `/usr/local/bin` run by name |

The `lua` command receives the rest of the line verbatim, so you do not need to quote code: `lua print("a"); print("b")`.

Not supported: globbing (`*`), background jobs (`&`), subshells, command substitution, and job control.

## Built-in commands

| Command | Description |
| --- | --- |
| `help [cmd]` | List commands or show help for one |
| `ls [-a] [-l] [-1] [path...]` | List directory contents. Directories end in `/` |
| `cd [dir]` | Change directory. `cd -` goes back |
| `pwd` | Print working directory |
| `cat [file...]` | Print files or stdin |
| `echo [-n] [-e] [text...]` | Print text |
| `mkdir [-p] dir...` | Create directories |
| `touch file...` | Create empty files |
| `rm [-r] [-f] file...` | Remove files or directories |
| `tree [dir]` | Show a directory tree |
| `grep [-i] [-v] [-n] pattern [file...]` | Filter lines by plain text |
| `head [-n N]`, `tail [-n N]` | First or last lines |
| `wc [-l]` | Count lines, words, characters |
| `env`, `export K=V`, `unset K` | Environment variables |
| `which cmd...` | Locate a command in PATH |
| `history` | Show command history |
| `whoami`, `hostname`, `uname [-a]`, `date` | System info |
| `neofetch` | System info with a logo |
| `theme [name]` | List or switch themes |
| `lua [code or file]` | Run Lua, run a file, or start a REPL when given nothing |
| `sleep N` | Wait N seconds (interruptible) |
| `clear` | Clear the screen |
| `exit` | Close the terminal |

Every command that defines a `usage` string also answers to `--help`.

## Configuration

Pass a table to `Terminal.new`. All fields are optional.

| Option | Default | Description |
| --- | --- | --- |
| `Title` | auto | Fixed window title. When nil it shows `user@host: path` |
| `User` | your Roblox username, lowercase | Name shown in the prompt and used for `/home/<user>` |
| `Host` | `"roblox"` | Host name shown in the prompt |
| `Theme` | `"default"` | Theme name, or a table of overrides |
| `Font` | `Enum.Font.RobotoMono` | Terminal font |
| `TextSize` | `15` | Terminal text size |
| `Size` | `Vector2.new(780, 470)` | Initial window size |
| `Blur` | `true` | Blur the game behind the terminal |
| `BlurSize` | `22` | Blur strength |
| `Dim` | `0.35` | How much to darken the background (0 to 1) |
| `ToggleKey` | `Enum.KeyCode.RightControl` | Show or hide key |
| `MaxLines` | `600` | Scrollback limit |
| `Motd` | `true` | Print the welcome banner |
| `Draggable` | `true` | Allow moving the window |
| `Resizable` | `true` | Allow resizing the window |
| `DisplayOrder` | `10000` | ScreenGui display order |

### Themes

Built in: `default`, `ubuntu`, `dracula`, `gruvbox`. Switch at runtime with `theme dracula` or `term:SetTheme("dracula")`.

A custom theme overrides any subset of the default:

```lua
term:SetTheme({
    bg = Color3.fromRGB(10, 10, 10),
    header = Color3.fromRGB(20, 20, 20),
    stroke = Color3.fromRGB(40, 40, 40),
    text = Color3.fromRGB(220, 220, 220),
    dim = Color3.fromRGB(120, 120, 120),
    user = Color3.fromRGB(0, 255, 120),   -- user@host in the prompt
    path = Color3.fromRGB(80, 160, 255),  -- working directory in the prompt
    bgTransparency = 0.05,
    palette = { red = Color3.fromRGB(255, 80, 80) }, -- red green yellow blue magenta cyan white gray
})
```

You can also add themes by name: `Terminal.Themes.mine = { ... }`.

## Terminal API

| Member | Description |
| --- | --- |
| `Terminal.new(config)` | Create a terminal. The window starts hidden |
| `term:Show()`, `term:Hide()`, `term:Toggle()` | Visibility |
| `term:Destroy()` | Remove the UI, blur and connections |
| `term:Print(text, color, bold)` | Print a line. `color` is a palette name or `Color3` |
| `term:Error(text)`, `term:Warn(text)`, `term:Success(text)` | Colored lines |
| `term:PrintRich(markup)` | Print Roblox rich text markup |
| `term:Colorize(text, color, bold)` | Return escaped, colored markup |
| `term:Clear()` | Clear the screen |
| `term:Execute(line)` | Run a command line as if the user typed it (echoes the prompt) |
| `term:Run(line)` | Run a command line without echo |
| `term:Interrupt()` | Same as Ctrl+C |
| `term:RegisterCommand(name, def)` | Add a command. It appears in `/bin`, `help` and tab completion |
| `term:UnregisterCommand(name)` | Remove a command |
| `term:SetTheme(nameOrTable)` | Change theme |
| `term:SetTitle(text)` | Set a fixed title (nil returns to automatic) |
| `term:MirrorConsole(bool)` | Copy the Roblox output log into the terminal |
| `term.fs` | The virtual filesystem |
| `term.cwd`, `term.home`, `term.user`, `term.host` | Shell state |
| `term.env` | Environment variables table |
| `term.history` | Array of past command lines |

Color names for the palette: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`.

## Writing commands

A command is a function or a definition table:

```lua
term:RegisterCommand("greet", {
    description = "say hello",
    usage = "greet [--shout] [--times N] name",
    values = { "times" },          -- flags that take a value
    run = function(ctx)
        local name = ctx.args[1] or "world"
        for i = 1, tonumber(ctx.flags.times) or 1 do
            local msg = "hello " .. name
            ctx.printc("green", ctx.flags.shout and msg:upper() or msg)
        end
        return 0                   -- exit status (optional)
    end,
})
```

Definition fields:

| Field | Description |
| --- | --- |
| `run` | `function(ctx)` that does the work. May return an exit status |
| `description` | Shown by `help` |
| `usage` | Shown by `help <cmd>` and `<cmd> --help` |
| `values` | List of flag names that consume the next argument, so `--times 3` works as well as `--times=3` |
| `raw` | When true, the command gets the rest of the line unparsed in `ctx.raw` |

### The `ctx` object

| Field | Description |
| --- | --- |
| `ctx.args` | Positional arguments, flags removed |
| `ctx.flags` | Parsed flags. `--cyl` gives `flags.cyl == true`, `--size=6` gives `"6"`, `-la` sets `flags.l` and `flags.a` |
| `ctx.argv` | All raw tokens, with the command name at index 1 |
| `ctx.raw` | The unparsed argument string (only for `raw` commands) |
| `ctx.stdin` | Piped input as a string, or nil |
| `ctx.tty` | True when output goes to the screen, false when piped or redirected |
| `ctx.cwd` | Working directory when the command started |
| `ctx.fs`, `ctx.env`, `ctx.term` | Filesystem, environment and terminal |
| `ctx.print(...)` | Like `print`, tab separated, adds a newline |
| `ctx.printc(color, ...)` | Same, in a color |
| `ctx.write(text, color, bold)` | Write without a newline |
| `ctx.writeRich(markup)`, `ctx.printRich(markup)` | Write rich text markup |
| `ctx.color(color, text, bold)` | Return colored markup for building lines |
| `ctx.error(msg)`, `ctx.warn(msg)` | Always go to the screen, never into pipes |
| `ctx.read(prompt)` | Ask the user for a line of input. Yields until they press Enter |
| `ctx.sleep(seconds)` | Wait, and abort if the user presses Ctrl+C |
| `ctx.cancelled()` | True after Ctrl+C. Poll this in long loops |
| `ctx.resolve(path)` | Absolute path for a path relative to the working directory |

Output written with `ctx.print` is captured by pipes and redirects. Colors are stripped when captured.

## Executable files

Files can live in the virtual filesystem and be run with `./name` or by name when in PATH.

### Lua function executables

```lua
term.fs:AddExecutable(term.home .. "/scripts/loadpart", {
    description = "spawn a part",
    usage = "loadpart [--cyl] [--size=N]",
    values = { "size" },
    run = function(ctx)
        -- same ctx as commands
    end,
})
```

`AddExecutable` creates parent directories as needed.

### Lua script files

Any file whose first line starts with `#!` is executable, and `lua file.lua` runs any Lua file.

```lua
term.fs:WriteFile(term.home .. "/hello.lua", [[#!lua
print("hello from the terminal")
print("args:", table.concat(args, ", "))
sleep(0.5)
local name = read("name> ")
print("hi " .. name)
]])
```

Inside scripts and the REPL these globals are added on top of the normal environment:

| Global | Description |
| --- | --- |
| `print`, `warn` | Output to the terminal |
| `io.write`, `io.read`, `read` | Write and read terminal input |
| `sleep(n)` | Interruptible wait |
| `args`, `flags`, `argv`, `stdin` | Command line data |
| `term`, `ctx`, `fs` | The terminal, context and filesystem |
| `exit(code)` | Stop the script with a status |

Scripts run through `loadstring` with `setfenv`. If your executor lacks `setfenv`, the extra globals are not injected and plain `print` goes to the Roblox console instead.

## Filesystem API

Paths passed to `term.fs` are absolute (a leading `~` is accepted). Methods that can fail return `nil, errorMessage`.

| Method | Description |
| --- | --- |
| `fs:WriteFile(path, content, opts)` | Create or overwrite a file. `opts`: `append`, `executable`, `parents` (default true) |
| `fs:ReadFile(path)` | Returns the contents |
| `fs:MkDir(path, parents)` | Create a directory |
| `fs:AddExecutable(path, defOrFn)` | Create an executable backed by a Lua function |
| `fs:Remove(path, recursive)` | Delete a file or directory |
| `fs:List(path, showHidden)` | Array of `{ name, node }`, sorted |
| `fs:Get(path)` | Node table or nil |
| `fs:Exists(path)`, `fs:IsDir(path)` | Checks |
| `fs:Resolve(path, cwd, home)` | Normalize a path, handling `.`, `..` and `~` |

Default layout:

```
/
  bin/              one entry per registered command
  etc/              hostname, os-release
  tmp/
  usr/local/bin/    put your own executables here to run them by name
  home/<user>/      starting directory, docs/readme.txt, .bashrc
```

The filesystem lives in memory only. It resets each time the script runs.

## Notes and limitations

- Only one command runs at a time. Ctrl+C interrupts commands that use `ctx.sleep`, `ctx.read` or check `ctx.cancelled()`. A plain `task.wait` loop inside a script cannot be interrupted.
- Pipes buffer the whole output of a stage before the next stage starts.
- `grep` matches plain text, not patterns.
- The UI uses a few box-drawing characters (`tree`, `neofetch`, the resize grip). They need a font fallback that supports them, which Roblox provides in normal use.
- The library does not hook the real `print` globally. Only scripts run by the terminal print into it. Use `term:MirrorConsole(true)` to copy the developer console output.
- The window parents to `gethui()` when available so games cannot easily find it.

## Roadmap ideas

- `cp`, `mv`, `chmod`, globbing, and `alias`
- Background jobs and a process table
- Persisting the filesystem with `writefile` and `readfile`
- A small package manager that installs scripts from URLs into `/usr/local/bin`
