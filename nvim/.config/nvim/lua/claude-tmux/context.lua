-- Send context from nvim to the Claude pane (the inverse of reading output).
--
-- Context is pasted into Claude's prompt WITHOUT submitting, so you can add a
-- question before hitting Enter yourself. Files are sent as `@path` references
-- (Claude reads them); selections are sent as a fenced snippet tagged with
-- their source location.

local pane = require("claude-tmux.pane")

local M = {}

local function notify(msg, level)
	vim.notify("[claude-tmux] " .. msg, level or vim.log.levels.INFO)
end

-- Paste `text` to the Claude pane for the current cwd; returns success.
local function paste(text)
	local target, err = pane.find(vim.fn.getcwd())
	if not target then
		notify(err or "no Claude pane", vim.log.levels.ERROR)
		return false
	end
	if pane.paste_text(target, text) then
		notify("context sent to " .. target)
		return true
	end
	notify("failed to send context to " .. target, vim.log.levels.ERROR)
	return false
end

-- Path of the current buffer relative to cwd (falls back to absolute).
local function rel_path()
	local abs = vim.api.nvim_buf_get_name(0)
	if abs == "" then
		return nil
	end
	return vim.fn.fnamemodify(abs, ":.")
end

-- Send the current file as an `@path` reference.
function M.send_file()
	local path = rel_path()
	if not path then
		notify("current buffer has no file", vim.log.levels.WARN)
		return
	end
	paste("@" .. path .. " ")
end

-- Send the visual selection as a fenced snippet tagged with `path:lines`.
function M.send_selection()
	local path = rel_path() or "selection"
	local s = vim.fn.getpos("'<")
	local e = vim.fn.getpos("'>")
	local lines = vim.api.nvim_buf_get_lines(0, s[2] - 1, e[2], false)
	if #lines == 0 then
		notify("empty selection", vim.log.levels.WARN)
		return
	end
	local ft = vim.bo.filetype ~= "" and vim.bo.filetype or ""
	local header = ("%s:%d-%d"):format(path, s[2], e[2])
	local block = ("%s\n```%s\n%s\n```\n"):format(header, ft, table.concat(lines, "\n"))
	paste(block)
end

return M
