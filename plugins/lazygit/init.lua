-- Lazygit in a floating layer over the window: alt+g opens it for the focused
-- pane's repository, alt+g again minimizes it, and quitting lazygit closes the
-- pane with it.
--
-- Comment out require("plugins.lazygit") in init.lua to disable it. A float
-- that is already open keeps running until you quit lazygit.

local SHELL = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"
local HOME = os.getenv("HOME")
local BOUNDS = { 0.04, 0.04, 0.92, 0.92 }   -- x, y, width, height

-- A terminal reports its directory as a file:// URL, or as a plain path when it
-- has no URL to report.
local function decode_path(path)
  if path == nil or path == "" then return nil end
  path = path:gsub("^file://[^/]*", "")
  return (path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function same_dir(a, b)
  if a == nil or b == nil then return false end
  return (a:gsub("/+$", "")) == (b:gsub("/+$", ""))
end

local function shorten(path)
  if HOME ~= nil and path:sub(1, #HOME) == HOME then
    return "~" .. path:sub(#HOME + 1)
  end
  return path
end

-- Every window's layers and blocks, so one scan can answer about any of them.
local function blocks(view)
  return coroutine.wrap(function()
    for _, w in ipairs(view and view.windows or {}) do
      for _, l in ipairs(w.layers or {}) do
        for _, b in ipairs(l.blocks or {}) do
          coroutine.yield(w, l, b)
        end
      end
    end
  end)
end

-- A key or a pane header hands a block over; the palette and the CLI don't, so
-- fall back to the focused block of the active window.
local function target_block(view, ctx)
  if ctx.block_id ~= nil then return ctx.block_id end
  for _, w in ipairs(view and view.windows or {}) do
    if w.window_id == view.active_window_id then return w.focused_block_id end
  end
end

-- A shell only reports its directory when its prompt says so, so ask the
-- process where it is when the report is missing.
local function pane_dir(block_id)
  local r = rex.block.call(TERMINAL, "pwd", { block_id = block_id })
  local dir = decode_path(r and r.pwd)
  if dir ~= nil then return dir end
  local proc = rex.block.call(TERMINAL, "process", { block_id = block_id })
  local fg = proc and proc.foreground
  if fg ~= nil and fg.cwd ~= nil and fg.cwd ~= "" then return fg.cwd end
  return HOME
end

-- The git root above dir, or nil when dir isn't inside a repository.
local function repo_root(dir)
  local r = rex.exec({ "git", "-C", dir, "rev-parse", "--show-toplevel" },
    { timeout = 5, stderr = false })
  if r == nil or not r.ok then return nil end
  return (r.stdout:gsub("%s+$", ""))
end

-- The repository's name, from the origin remote when the clone has one and from
-- the directory when it doesn't. Short enough to label a minimized pane.
local function repo_title(dir)
  local r = rex.exec({ "git", "-C", dir, "remote", "get-url", "origin" },
    { timeout = 5, stderr = false })
  local url = (r and r.ok and r.stdout or ""):gsub("%s+$", "")
  local name = url:match("([%w._%-]+)%.git$") or url:match("([%w._%-]+)$")
  if name ~= nil and name ~= "" then return name end
  local path = dir:gsub("/+$", "")
  return path:match("([^/]+)$") or path
end

-- The floating lazygit for dir, if one is open. The label alone isn't enough:
-- two clones of the same repository share it, so check where the pane runs.
local function locate(view, label, dir)
  for w, l, b in blocks(view) do
    if b.label == label and l.kind == "floating" and same_dir(pane_dir(b.block_id), dir) then
      return {
        block_id  = b.block_id,
        window_id = w.window_id,
        layer_id  = l.layer_id,
        state     = l.state or "normal",
      }
    end
  end
end

local function window_of(view, block_id)
  for w, _, b in blocks(view) do
    if b.block_id == block_id then return w.window_id end
  end
end

local function lazygit_block(dir, label)
  return rex.layout.block{
    flavor = SHELL,
    label = label,
    options = { cwd = dir, command = { "lazygit", "-p", dir } },
  }
end

rex.action{
  name        = "lazygit",
  title       = "Lazygit",
  description = "Show or minimize the floating lazygit for the focused pane's repository",
  category    = "Git",
  keywords    = "lazygit git status stage commit branch stash log float toggle",
  run = function(ctx)
    local view = rex.session.view{}
    local block_id = target_block(view, ctx)
    if block_id == nil then error("lazygit: no focused pane", 0) end

    local here = pane_dir(block_id)
    local dir = repo_root(here)
    if dir == nil then
      error("lazygit: " .. shorten(here) .. " is not a git repository", 0)
    end

    local label = repo_title(dir)
    local found = locate(view, label, dir)

    if found ~= nil then
      if found.state == "minimized" then
        -- Bring it back, lazygit still running where it left off.
        rex.session.set_layer_state{
          layer_id = found.layer_id, state = "normal", focus = true,
        }
        return { restored = true, block_id = found.block_id }
      end

      if found.window_id ~= view.active_window_id then
        -- In sight in another window: show that window rather than hide the pane.
        rex.session.set_layer_state{
          layer_id = found.layer_id, state = "normal", focus = true,
        }
        return { reused = true, block_id = found.block_id }
      end

      -- In sight here: minimize it. Focus returns to the pane used before it.
      rex.session.set_layer_state{ layer_id = found.layer_id, state = "minimized" }
      return { minimized = true, block_id = found.block_id }
    end

    local l, err = rex.session.new_layer{
      window_id = window_of(view, block_id),
      bounds = BOUNDS,
      focus = true,
      layout = lazygit_block(dir, label),
    }
    if err ~= nil then error(err, 0) end
    return { opened = true, layer_id = l.layer_id, block_id = l.block_ids[1] }
  end,
}

rex.bind("alt+g", "lazygit")
