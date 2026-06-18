-- Locate and parse Claude Code session transcripts.
--
-- Claude writes one JSONL file per session under
--   ~/.claude/projects/<slug>/<session-uuid>.jsonl
-- where <slug> is the absolute cwd with `/` and `.` replaced by `-`
-- (e.g. /home/jetnoli/.config/nvim -> -home-jetnoli--config-nvim).
--
-- Each line is one JSON object. Assistant turns are `type == "assistant"`
-- with `message.content[]` blocks; the human-readable markdown lives in the
-- blocks whose `type == "text"`. `thinking` and `tool_use` blocks are skipped.

local config = require("claude-tmux.config")

local M = {}

local uv = vim.uv or vim.loop

-- Slugify a cwd the way Claude Code names its project directories.
local function slug(cwd)
	return (cwd:gsub("[/.]", "-"))
end

-- Read the first decodable JSON line of a file (cheap probe for its `cwd`).
local function first_object(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	for line in f:lines() do
		if line ~= "" then
			local ok, obj = pcall(vim.json.decode, line)
			f:close()
			if ok then
				return obj
			end
			return nil
		end
	end
	f:close()
	return nil
end

-- List immediate subdirectories of a directory.
local function subdirs(dir)
	local out = {}
	local handle = uv.fs_scandir(dir)
	if not handle then
		return out
	end
	while true do
		local name, typ = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if typ == "directory" then
			table.insert(out, dir .. "/" .. name)
		end
	end
	return out
end

-- Fallback when the slug rule doesn't resolve (encoding edge cases): scan every
-- project dir and match on the `cwd` recorded inside its newest transcript.
local function find_dir_by_cwd(cwd)
	local root = config.options.projects_dir
	local best_dir, best_mtime
	for _, dir in ipairs(subdirs(root)) do
		local session = M.active_session_in(dir)
		if session then
			local obj = first_object(session)
			if obj and obj.cwd == cwd then
				local st = uv.fs_stat(session)
				local mtime = st and st.mtime.sec or 0
				if not best_mtime or mtime > best_mtime then
					best_mtime, best_dir = mtime, dir
				end
			end
		end
	end
	return best_dir
end

-- The project directory holding `cwd`'s transcripts, or nil if none exist yet.
function M.project_dir(cwd)
	cwd = cwd or vim.fn.getcwd()
	local dir = config.options.projects_dir .. "/" .. slug(cwd)
	if uv.fs_stat(dir) then
		return dir
	end
	return find_dir_by_cwd(cwd)
end

-- Newest-mtime *.jsonl in a specific project directory.
function M.active_session_in(dir)
	local newest, newest_mtime
	local handle = uv.fs_scandir(dir)
	if not handle then
		return nil
	end
	while true do
		local name = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if name:match("%.jsonl$") then
			local path = dir .. "/" .. name
			local st = uv.fs_stat(path)
			local mtime = st and st.mtime.sec or 0
			if not newest_mtime or mtime > newest_mtime then
				newest_mtime, newest = mtime, path
			end
		end
	end
	return newest
end

-- The active session transcript for a cwd (defaults to the editor's cwd).
function M.active_session(cwd)
	local dir = M.project_dir(cwd)
	if not dir then
		return nil
	end
	return M.active_session_in(dir)
end

-- Concatenate the text blocks of an assistant entry, or nil if it has none.
local function assistant_text(entry)
	if type(entry) ~= "table" or entry.type ~= "assistant" then
		return nil
	end
	local msg = entry.message
	if type(msg) ~= "table" then
		return nil
	end
	local content = msg.content
	if type(content) == "string" then
		return content
	end
	if type(content) ~= "table" then
		return nil
	end
	local parts = {}
	for _, block in ipairs(content) do
		if type(block) == "table" and block.type == "text" and block.text then
			table.insert(parts, block.text)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n\n")
end

-- Decode every line of a transcript into a list of objects (undecodable lines
-- are skipped — partial/streaming writes shouldn't abort the whole parse).
local function decode_lines(path)
	local objects = {}
	local f = io.open(path, "r")
	if not f then
		return objects
	end
	for line in f:lines() do
		if line ~= "" then
			local ok, obj = pcall(vim.json.decode, line)
			if ok then
				table.insert(objects, obj)
			end
		end
	end
	f:close()
	return objects
end

-- The markdown of the most recent assistant message in `path`, or nil.
function M.latest_assistant(path)
	local latest
	for _, obj in ipairs(decode_lines(path)) do
		local text = assistant_text(obj)
		if text then
			latest = { text = text, timestamp = obj.timestamp }
		end
	end
	return latest
end

-- Every assistant message in `path`, oldest-first, for the picker.
-- Each item: { text, timestamp, preview } where preview is a one-line summary.
function M.list_assistant(path)
	local items = {}
	for _, obj in ipairs(decode_lines(path)) do
		local text = assistant_text(obj)
		if text then
			local first_line = text:match("^%s*([^\n]*)") or ""
			table.insert(items, {
				text = text,
				timestamp = obj.timestamp,
				preview = first_line,
			})
		end
	end
	return items
end

-- Exposed for unit testing the extraction logic without touching the FS.
M._assistant_text = assistant_text

return M
