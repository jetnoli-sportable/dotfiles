-- Turn `file:line` references in Claude's output into navigation.
--
-- Claude routinely writes references like `lua/plugins/index.lua:42`. With the
-- cursor on one, jump to that file+line in nvim, resolving relative paths
-- against the project cwd.

local M = {}

local function notify(msg, level)
	vim.notify("[claude-tmux] " .. msg, level or vim.log.levels.INFO)
end

-- Parse a token into { path, line, col }, or nil if it isn't a file ref.
-- Accepts `path`, `path:line`, and `path:line:col`.
function M.parse(token)
	if type(token) ~= "string" or token == "" then
		return nil
	end
	-- Strip surrounding punctuation Claude sometimes wraps refs in.
	token = token:gsub("^[%(%[`'\"]+", ""):gsub("[%)%]`'\".,;:]+$", "")
	local path, line, col = token:match("^([^:%s]+):(%d+):(%d+)$")
	if not path then
		path, line = token:match("^([^:%s]+):(%d+)$")
	end
	if not path then
		path = token:match("^([^:%s]+)$")
	end
	if not path or path == "" then
		return nil
	end
	return { path = path, line = tonumber(line), col = tonumber(col) }
end

-- Resolve a parsed ref's path against cwd and confirm it's an existing file.
local function resolve(ref)
	local path = ref.path
	if not path:match("^/") then
		path = vim.fn.getcwd() .. "/" .. path
	end
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	return path
end

-- Open a parsed ref in a sensible window (prefer a non-output window).
local function open(ref, path)
	-- Jump out of the output split if that's where we are.
	local cur = vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_get_name(cur):match("^claude://") then
		vim.cmd.wincmd("p")
	end
	vim.cmd.edit(vim.fn.fnameescape(path))
	if ref.line then
		vim.api.nvim_win_set_cursor(0, { ref.line, (ref.col or 1) - 1 })
		vim.cmd("normal! zz")
	end
end

-- Jump to the file reference under the cursor.
function M.jump_under_cursor()
	local ref = M.parse(vim.fn.expand("<cWORD>"))
	if not ref then
		notify("no file reference under cursor", vim.log.levels.WARN)
		return
	end
	local path = resolve(ref)
	if not path then
		notify("file not found: " .. ref.path, vim.log.levels.WARN)
		return
	end
	open(ref, path)
end

return M
