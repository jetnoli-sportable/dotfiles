-- The per-worktree queue: stash follow-up thoughts for the Claude pane
-- you're already watching, review and act on them later through a picker.
--
-- Stashing is a pure file append — it never touches the live tmux pane, so
-- it can't interrupt or distract the agent's current turn (unlike reply.lua,
-- which sends immediately). The queue file (.claude-queue.md) is gitignored
-- and lives at the worktree root (not nvim's stdpath('state')) so it's
-- reachable by Telescope/find — see plugins/config/telescope.lua's
-- always_include_globs.
--
-- Creation is lazy-only: M.stash() is the single place the file is ever
-- created, the moment the first message is stashed into a given worktree.
-- The same call also ensures that worktree's repo has registered the queue
-- pattern in its own .git/info/exclude (via wb.sh's wb_ensure_repo_ignore) —
-- this is what covers a worktree that predates the feature (or predates that
-- repo's most recent `wb new`), the case `wb new`'s own eager registration
-- can't reach.

local config = require("claude-tmux.config")
local pane = require("claude-tmux.pane")

local M = {}

local QUEUE_FILENAME = ".claude-queue.md"
-- Exact heading boundary a stashed message's own "## " heading can't be
-- mistaken for — a bare "## " boundary would fracture a pasted message that
-- itself contains a markdown heading into spurious extra picker entries.
local HEADING_PATTERN = "^## %d%d%d%d%-%d%d%-%d%dT"

local function notify(msg, level)
	vim.notify("[claude-tmux] " .. msg, level or vim.log.levels.INFO)
end

local function queue_file(cwd)
	return (cwd or vim.fn.getcwd()) .. "/" .. QUEUE_FILENAME
end

-- Register cwd's repo as ignoring the queue file pattern (idempotent). Shells
-- out to wb.sh the same way pane.lua's find() reaches lib.sh's
-- tmux_find_claude_pane — sourced via `bash -c` rather than duplicating the
-- flock/newline-safety logic in Lua.
local function ensure_repo_ignore(cwd)
	local wb = config.options.tmux.wb
	if vim.fn.filereadable(wb) == 0 then
		return false, "wb helper not found: " .. wb
	end
	vim.fn.system({ "bash", "-c", 'source "$1"; wb_ensure_repo_ignore "$2"', "_", wb, cwd })
	return vim.v.shell_error == 0
end

-- Stash `text` as a new capture block in the current worktree's queue file,
-- creating the file (and registering its repo's ignore rule) on first use.
function M.stash(text)
	text = vim.trim(text or "")
	if text == "" then
		notify("nothing to stash (empty)", vim.log.levels.WARN)
		return
	end

	local cwd = vim.fn.getcwd()
	local file = queue_file(cwd)
	-- Called on every stash, not just the worktree's first: wb_ensure_repo_ignore
	-- is idempotent and cheap (a flock-guarded grep), so a failed registration
	-- attempt gets retried on the very next stash instead of leaving the
	-- worktree permanently unregistered for its whole lifetime.
	local ok, err = ensure_repo_ignore(cwd)
	if not ok then
		notify("queue: could not register ignore rule (" .. (err or "unknown error") .. ") — stashing anyway", vim.log.levels.WARN)
	end

	-- ISO 8601, local time — same `date +%FT%H:%M:%S` shape notes-tui's own
	-- inbox capture blocks use (scripts/note.sh in ~/code/notes-tui).
	local block = { "## " .. os.date("%Y-%m-%dT%H:%M:%S"), "", text, "" }
	-- Append mode ("a"): creates the file if absent, otherwise appends in one
	-- write — a read-whole-file-then-write-whole-file round trip would let
	-- two nvim instances stashing near-simultaneously race and silently drop
	-- one entry (the second writer's whole-file write clobbers the first's).
	vim.fn.writefile(block, file, "a")
	notify("stashed")
end

-- Parse the queue file into { heading, text, preview } entries, split on the
-- exact timestamp-heading boundary (see HEADING_PATTERN above).
local function parse_entries(file)
	if vim.fn.filereadable(file) == 0 then
		return {}
	end
	local entries = {}
	local current
	for _, line in ipairs(vim.fn.readfile(file)) do
		if line:match(HEADING_PATTERN) then
			if current then
				table.insert(entries, current)
			end
			current = { heading = line, lines = {} }
		elseif current then
			table.insert(current.lines, line)
		end
	end
	if current then
		table.insert(entries, current)
	end
	for _, entry in ipairs(entries) do
		entry.text = vim.trim(table.concat(entry.lines, "\n"))
		local first_line = entry.text:match("^([^\n]*)") or ""
		entry.preview = entry.heading:gsub("^## ", "") .. "  " .. first_line:sub(1, 60)
	end
	return entries
end

-- Copy an entry's text to the unnamed and `+` registers — the v1 floor
-- (R5): make it available to copy, no pane interaction required.
local function copy_entry(entry)
	vim.fn.setreg('"', entry.text)
	vim.fn.setreg("+", entry.text)
	notify("copied to register")
end

-- Send an entry's text to the target pane — the stretch addition on top of
-- the copy floor, a thin reuse of pane.lua's existing send_text.
local function send_entry(entry)
	local target, err = pane.find(vim.fn.getcwd())
	if not target then
		notify(err or "no Claude pane", vim.log.levels.ERROR)
		return
	end
	if pane.send_text(target, entry.text) then
		notify("sent to " .. target)
	else
		notify("failed to send to " .. target, vim.log.levels.ERROR)
	end
end

-- Browse the current worktree's queued items. Reuses output.lua's exact
-- Telescope-plus-vim.ui.select-fallback shape (output.lua:179 M.picker()),
-- adapted to the queue's parsed-entry list instead of session-message data.
function M.picker()
	local entries = parse_entries(queue_file())
	if #entries == 0 then
		notify("queue is empty", vim.log.levels.INFO)
		return
	end

	-- Newest first, matching output.lua's picker ordering convention.
	local ordered = {}
	for i = #entries, 1, -1 do
		table.insert(ordered, entries[i])
	end

	local ok_telescope = pcall(require, "telescope")
	if not ok_telescope then
		vim.ui.select(ordered, {
			prompt = "Claude queue",
			format_item = function(entry)
				return entry.preview
			end,
		}, function(choice)
			if choice then
				copy_entry(choice)
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

	pickers
		.new({}, {
			prompt_title = "Claude queue",
			finder = finders.new_table({
				results = ordered,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.preview,
						ordinal = entry.preview,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Queued message",
				define_preview = function(self, telescope_entry)
					local lines = vim.split(telescope_entry.value.text, "\n", { plain = true })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						copy_entry(entry.value)
					end
				end)
				-- Stretch: send the selection straight to the target pane
				-- without leaving the copy-only default action's behavior.
				map({ "i", "n" }, "<C-s>", function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						send_entry(entry.value)
					end
				end)
				return true
			end,
		})
		:find()
end

-- Prompt for one line and stash it immediately (<leader>aQ) — no buffer.
function M.stash_prompt()
	vim.ui.input({ prompt = "Stash for Claude: " }, function(text)
		if text then
			M.stash(text)
		end
	end)
end

return M
