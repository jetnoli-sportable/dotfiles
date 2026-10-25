-- Live, read-only view of a Claude session's reply log.
--
-- claude-reply-log.sh's Stop hook writes each session's turns to
-- ~/.claude/replies/<session-id>.md. The prefix+v tmux binding opens this view
-- in a split beside the Claude pane (`claude-reply-log.sh view`), running
--   nvim -R -c "lua require('claude-tmux.replies').follow({ pane = '%12', script = '…' })"
--
-- Every second it asks `claude-reply-log.sh chain --pane <pane>` which reply
-- files belong to the pane's session (its wb task's earlier sessions first, so a
-- /clear just adds the new session below), and rebuilds the buffer when any of
-- them changed. One buffer, filetype=markdown, so render-markdown.nvim attaches.

local uv = vim.uv or vim.loop

local M = {}

local function read_lines(path)
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local lines = vim.split(f:read("*a"), "\n", { plain = true })
	f:close()
	return lines
end

-- A reply file minus its frontmatter (which only ever starts on line 1).
local function body(path)
	local lines = read_lines(path)
	if lines[1] ~= "---" then
		return lines
	end
	for i = 2, #lines do
		if lines[i] == "---" then
			return vim.list_slice(lines, i + 1)
		end
	end
	return lines
end

-- path..mtime..size of every file, so any write to any of them shows up.
local function signature(paths)
	local parts = {}
	for _, p in ipairs(paths) do
		local st = uv.fs_stat(p)
		parts[#parts + 1] = p .. ":" .. (st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or "-")
	end
	return table.concat(parts, "|")
end

-- Cursor on the last line, with that line at the bottom of the window.
local function pin_bottom(win, buf)
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zb")
	end)
end

local function render(buf, paths)
	local lines = {}
	for _, p in ipairs(paths) do
		vim.list_extend(lines, body(p))
	end
	if #lines == 0 then
		lines = { "*Waiting for this session's first reply…*" }
	end
	-- Stay pinned to the bottom only if the cursor was already there.
	local wins = vim.fn.win_findbuf(buf)
	local was_bottom = {}
	for _, w in ipairs(wins) do
		was_bottom[w] = vim.api.nvim_win_get_cursor(w)[1] >= vim.api.nvim_buf_line_count(buf)
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	for _, w in ipairs(wins) do
		if was_bottom[w] then
			pin_bottom(w, buf)
		end
	end
end

-- opts.pane   — the Claude pane's tmux id (%N)
-- opts.script — path to claude-reply-log.sh
function M.follow(opts)
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	-- `nvim -R` marks the buffer readonly; it's rewritten in place, so only
	-- `modifiable` (toggled around each rewrite) guards it.
	vim.bo[buf].readonly = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.api.nvim_buf_set_name(buf, "claude://replies/" .. opts.pane)
	vim.wo.wrap = true
	vim.wo.linebreak = true
	vim.keymap.set("n", "q", "<cmd>qa!<cr>", { buffer = buf, desc = "Close the reply log view" })

	local last_sig
	local busy = false
	local timer = uv.new_timer()
	local function tick()
		if busy then
			return
		end
		busy = true
		vim.system({ opts.script, "chain", "--pane", opts.pane }, { text = true }, function(res)
			vim.schedule(function()
				busy = false
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				local paths = vim.tbl_filter(function(l)
					return l ~= ""
				end, vim.split(res.stdout or "", "\n", { plain = true }))
				local sig = signature(paths)
				if sig ~= last_sig then
					local first = last_sig == nil
					last_sig = sig
					render(buf, paths)
					if first then
						pin_bottom(vim.api.nvim_get_current_win(), buf)
					end
				end
			end)
		end)
	end
	timer:start(0, 1000, vim.schedule_wrap(tick))
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			timer:stop()
			timer:close()
		end,
	})
end

return M
