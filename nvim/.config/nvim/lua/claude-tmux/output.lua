-- The read-only markdown view of Claude's output.
--
-- A single reusable scratch buffer holds whichever assistant message you last
-- grabbed/picked. It's filetype=markdown so render-markdown.nvim attaches
-- automatically. The buffer is never the reply surface (see reply.lua), so the
-- live-follow watcher can rewrite it freely without touching your draft.

local config = require("claude-tmux.config")
local transcript = require("claude-tmux.transcript")

local uv = vim.uv or vim.loop

local M = {}

-- Module-level singletons so repeated grabs reuse one buffer/window.
M._buf = nil

local function notify(msg, level)
	vim.notify("[claude-tmux] " .. msg, level or vim.log.levels.INFO)
end

-- Get (or lazily create) the output buffer.
local function ensure_buf()
	if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
		return M._buf
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "claude://output")
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	-- In the output buffer, gf follows Claude's `file:line` references.
	vim.keymap.set("n", "gf", function()
		require("claude-tmux.jump").jump_under_cursor()
	end, { buffer = buf, desc = "Claude: jump to file reference" })
	M._buf = buf
	return buf
end

-- Ensure the output buffer is visible in a window and return that window.
local function ensure_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	local cmd = config.options.output.split == "horizontal" and "botright split" or "botright vsplit"
	vim.cmd(cmd)
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	return win
end

-- Find the window currently showing the output buffer, if any.
local function buf_window(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

-- Write `text` into the (possibly hidden) output buffer. Never opens a window.
local function set_contents(buf, text)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.bo[buf].modifiable = false
end

-- Replace the output buffer contents and show it.
--   opts.show  — open a window if none shows the buffer (default true)
--   opts.focus — move the cursor into the output window (default per config)
--   opts.reset_cursor — jump to the top (default true)
function M.render(text, opts)
	opts = opts or {}
	local buf = ensure_buf()
	set_contents(buf, text)

	local win = buf_window(buf)
	if not win and opts.show ~= false then
		win = ensure_win(buf)
	end
	if not win then
		return buf, nil
	end

	if opts.reset_cursor ~= false then
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end
	local focus = opts.focus
	if focus == nil then
		focus = config.options.output.focus
	end
	if focus then
		vim.api.nvim_set_current_win(win)
	end
	return buf, win
end

-- Resolve the active session for the current cwd, notifying on failure.
local function require_session()
	local path = transcript.active_session()
	if not path then
		notify("no Claude session transcript found for " .. vim.fn.getcwd(), vim.log.levels.WARN)
		return nil
	end
	return path
end

-- Grab the latest assistant message into the output buffer.
function M.grab_latest()
	local path = require_session()
	if not path then
		return
	end
	local latest = transcript.latest_assistant(path)
	if not latest then
		notify("no assistant messages in the current session yet", vim.log.levels.WARN)
		return
	end
	M.render(latest.text)
end

-- Live-follow: poll the active transcript and refresh the output buffer when a
-- new assistant message lands. Never steals focus or moves the cursor, so it
-- can't disturb whatever you're doing (including drafting a reply elsewhere).
M._follow = nil

local function stop_follow()
	if not M._follow then
		return
	end
	if M._follow.poll then
		M._follow.poll:stop()
	end
	M._follow = nil
end

function M.toggle_follow()
	if M._follow then
		stop_follow()
		notify("live-follow off")
		return
	end

	local path = require_session()
	if not path then
		return
	end
	-- Seed the buffer immediately so there's something to follow.
	M.grab_latest()

	local poll = uv.new_fs_poll()
	local last_text
	M._follow = { poll = poll, path = path }
	poll:start(path, 1000, function(err)
		if err then
			return
		end
		vim.schedule(function()
			if not M._follow then
				return
			end
			local latest = transcript.latest_assistant(path)
			if latest and latest.text ~= last_text then
				last_text = latest.text
				M.render(latest.text, { focus = false, reset_cursor = false, show = false })
			end
		end)
	end)
	notify("live-follow on")
end

-- Browse every assistant message in the session and open the chosen one.
function M.picker()
	local path = require_session()
	if not path then
		return
	end
	local items = transcript.list_assistant(path)
	if #items == 0 then
		notify("no assistant messages in the current session yet", vim.log.levels.WARN)
		return
	end

	local ok_telescope = pcall(require, "telescope")
	if not ok_telescope then
		-- Fallback: plain vim.ui.select over the previews.
		vim.ui.select(items, {
			prompt = "Claude messages",
			format_item = function(item)
				return item.preview
			end,
		}, function(choice)
			if choice then
				M.render(choice.text)
			end
		end)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	-- Newest message first feels most useful when scanning.
	local ordered = {}
	for i = #items, 1, -1 do
		table.insert(ordered, items[i])
	end

	pickers
		.new({}, {
			prompt_title = "Claude messages",
			finder = finders.new_table({
				results = ordered,
				entry_maker = function(item)
					return {
						value = item,
						display = item.preview,
						ordinal = item.preview,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Message",
				define_preview = function(self, entry)
					local lines = vim.split(entry.value.text, "\n", { plain = true })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						M.render(entry.value.text)
					end
				end)
				return true
			end,
		})
		:find()
end

-- Collect fenced code blocks (```lang ... ```) from a list of lines.
-- Returns a list of { lang, code, start_line }.
local function code_blocks(lines)
	local blocks = {}
	local in_block, fence, lang, start, body = false, nil, nil, nil, nil
	for i, line in ipairs(lines) do
		local open = line:match("^%s*(```+)")
		if not in_block and open then
			in_block, fence, start, body = true, open, i, {}
			lang = line:match("^%s*```+%s*([%w%-%+%.]*)") or ""
		elseif in_block and line:match("^%s*" .. fence .. "%s*$") then
			table.insert(blocks, { lang = lang, code = table.concat(body, "\n"), start_line = start })
			in_block = false
		elseif in_block then
			table.insert(body, line)
		end
	end
	return blocks
end

-- Pick a code block from the output buffer and yank it to the unnamed and `+`
-- registers (clean, no terminal-wrapping artefacts).
function M.yank_code()
	local buf = M._buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		notify("no output buffer — grab a message first", vim.log.levels.WARN)
		return
	end
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local blocks = code_blocks(lines)
	if #blocks == 0 then
		notify("no code blocks in the current message", vim.log.levels.WARN)
		return
	end

	local function yank(block)
		vim.fn.setreg('"', block.code)
		vim.fn.setreg("+", block.code)
		notify(("yanked %s block (%d lines)"):format(block.lang ~= "" and block.lang or "code", select(2, block.code:gsub("\n", "\n")) + 1))
	end

	if #blocks == 1 then
		yank(blocks[1])
		return
	end

	vim.ui.select(blocks, {
		prompt = "Yank code block",
		format_item = function(block)
			local label = block.lang ~= "" and block.lang or "code"
			local first = (block.code:match("^([^\n]*)") or ""):sub(1, 50)
			return ("%s: %s"):format(label, first)
		end,
	}, function(choice)
		if choice then
			yank(choice)
		end
	end)
end

M._code_blocks = code_blocks

return M
