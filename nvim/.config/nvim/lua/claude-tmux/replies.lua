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

-- Draws a divider above the turn whose anchor carries `id` (the first turn Jet
-- has not seen), taking the turn's `## ` heading line, just above the anchor,
-- as its start. Returns the new lines and the divider text's line number, or
-- the lines unchanged and nil when no turn carries that id.
function M.with_divider(lines, id, count)
	if not id or id == "" then
		return lines, nil
	end
	local needle = '"prompt_id":"' .. id .. '"'
	for i, l in ipairs(lines) do
		if l:sub(1, 11) == "<!-- turn {" and l:find(needle, 1, true) then
			local at = (i > 1 and lines[i - 1]:sub(1, 3) == "## ") and i - 1 or i
			local text = "──── " .. (count and count > 0 and (count .. " ") or "") .. "unseen since you left ────"
			local out = vim.list_slice(lines, 1, at - 1)
			vim.list_extend(out, { "", text, "" })
			vim.list_extend(out, vim.list_slice(lines, at))
			return out, at + 1
		end
	end
	return lines, nil
end

-- Returns the line number of the divider drawn, or nil.
local function render(buf, paths, unseen)
	local lines = {}
	for _, p in ipairs(paths) do
		vim.list_extend(lines, body(p))
	end
	local divider
	if unseen and unseen.ids and unseen.ids[1] then
		lines, divider = M.with_divider(lines, unseen.ids[1], unseen.count)
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
	return divider
end

-- opts.pane   — the Claude pane's tmux id (%N)
-- opts.script — path to claude-reply-log.sh
-- opts.unseen — { ids = { <prompt id>, … }, count = N }: the turns a `wb continue`
--               restart took from Jet's sight; the first id gets a divider and
--               the view opens there instead of at the bottom
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
	local rendered = false
	local landed = false
	local busy = false
	local timer = uv.new_timer()
	local function tick()
		if busy then
			return
		end
		busy = true
		-- pcall + timeout: a missing script or a hung chain must not leave busy set
		local started = pcall(vim.system, { opts.script, "chain", "--pane", opts.pane }, { text = true, timeout = 5000 }, function(res)
			vim.schedule(function()
				busy = false
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end
				local paths = vim.tbl_filter(function(l)
					return l ~= ""
				end, vim.split(res.stdout or "", "\n", { plain = true }))
				-- /clear: the pane's new session has no file yet; keep what is shown
				if #paths == 0 and rendered then
					return
				end
				local sig = signature(paths)
				if sig ~= last_sig then
					local first = last_sig == nil
					last_sig = sig
					rendered = #paths > 0
					local divider = render(buf, paths, opts.unseen)
					if first and not divider then
						pin_bottom(vim.api.nvim_get_current_win(), buf)
					end
					-- Open at the divider once; after that the view follows new turns
					-- only while the cursor is on the last line, as it always has.
					if divider and not landed then
						landed = true
						local win = vim.api.nvim_get_current_win()
						vim.api.nvim_win_set_cursor(win, { divider, 0 })
						vim.api.nvim_win_call(win, function()
							vim.cmd("normal! zt")
						end)
					end
				end
			end)
		end)
		if not started then
			busy = false
		end
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
