-- The reply surface: type your answer here, send it to the Claude pane.
--
-- Two modes (config.reply.mode), sharing one send() core:
--   "scratch" — an unnamed buffer in a split; the draft is gone once closed.
--   "file"    — a per-cwd file under stdpath('state'); the draft survives, and
--               the send gate is the literal "is the file non-empty" check.
--
-- The reply buffer is always separate from the read-only output buffer, so the
-- live-follow watcher can never clobber a draft.

local config = require("claude-tmux.config")
local pane = require("claude-tmux.pane")

local M = {}

M._buf = nil

local function notify(msg, level)
	vim.notify("[claude-tmux] " .. msg, level or vim.log.levels.INFO)
end

-- Per-cwd reply file for "file" mode.
local function reply_file(cwd)
	local dir = vim.fn.stdpath("state") .. "/claude-tmux"
	vim.fn.mkdir(dir, "p")
	local slug = (cwd:gsub("[/.]", "-"))
	return dir .. "/reply" .. slug .. ".md"
end

-- Open the reply buffer in a split (reusing an existing one if present).
function M.open()
	local opts = config.options.reply
	local split = opts.split == "vertical" and "botright vsplit" or "botright " .. tostring(opts.height) .. "split"

	if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
		-- Focus it if already on screen, else reopen a split for it.
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(win) == M._buf then
				vim.api.nvim_set_current_win(win)
				vim.cmd.startinsert()
				return
			end
		end
		vim.cmd(split)
		vim.api.nvim_win_set_buf(0, M._buf)
		vim.cmd.startinsert()
		return
	end

	if opts.mode == "file" then
		local file = reply_file(vim.fn.getcwd())
		vim.cmd(split .. " " .. vim.fn.fnameescape(file))
		M._buf = vim.api.nvim_get_current_buf()
		vim.bo[M._buf].filetype = "markdown"
		if opts.send == "save" then
			vim.api.nvim_create_autocmd("BufWritePost", {
				buffer = M._buf,
				desc = "claude-tmux: send reply on save",
				callback = function()
					M.send()
				end,
			})
		end
	else
		vim.cmd(split)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, "claude://reply")
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.api.nvim_win_set_buf(0, buf)
		M._buf = buf
	end
	vim.cmd.startinsert()
end

-- Current draft text (trimmed), or "" if there's nothing meaningful to send.
local function draft_text()
	local opts = config.options.reply
	if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
		local lines = vim.api.nvim_buf_get_lines(M._buf, 0, -1, false)
		return vim.trim(table.concat(lines, "\n"))
	end
	if opts.mode == "file" then
		local file = reply_file(vim.fn.getcwd())
		if vim.fn.filereadable(file) == 1 then
			return vim.trim(table.concat(vim.fn.readfile(file), "\n"))
		end
	end
	return ""
end

-- Clear the draft after a successful send.
local function clear_draft()
	if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
		vim.bo[M._buf].modifiable = true
		vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, {})
		if config.options.reply.mode == "file" and vim.bo[M._buf].buftype == "" then
			-- Persist the cleared file without retriggering a save-send.
			vim.api.nvim_buf_call(M._buf, function()
				vim.cmd("noautocmd write")
			end)
		end
	elseif config.options.reply.mode == "file" then
		vim.fn.writefile({}, reply_file(vim.fn.getcwd()))
	end
end

-- Send the draft to the Claude pane. No-op (with a notice) when empty — the
-- "if I didn't write anything, nothing triggers" guarantee.
function M.send()
	local text = draft_text()
	if text == "" then
		notify("nothing to send (reply is empty)", vim.log.levels.WARN)
		return
	end
	local target, err = pane.find(vim.fn.getcwd())
	if not target then
		notify(err or "no Claude pane", vim.log.levels.ERROR)
		return
	end
	if pane.send_text(target, text) then
		clear_draft()
		notify("sent to " .. target)
	else
		notify("failed to send to " .. target, vim.log.levels.ERROR)
	end
end

return M
