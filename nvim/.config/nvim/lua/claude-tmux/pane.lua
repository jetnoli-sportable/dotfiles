-- Talk to the Claude Code tmux pane.
--
-- Pane discovery is delegated to the shared tmux helper (lib.sh) so the
-- detection logic stays in one place (same `pane_current_command == claude`
-- check the session picker uses). Sending uses a tmux buffer + bracketed
-- paste-buffer so multi-line replies arrive intact instead of submitting on
-- every embedded newline, followed by a single Enter to send.

local config = require("claude-tmux.config")

local M = {}

-- Resolve the Claude pane target (session:window.pane) for a cwd.
-- Returns target on success, or nil + an error message.
function M.find(cwd)
	cwd = cwd or vim.fn.getcwd()
	if not vim.env.TMUX then
		return nil, "not inside tmux"
	end
	local lib = config.options.tmux.lib
	if vim.fn.filereadable(lib) == 0 then
		return nil, "tmux helper not found: " .. lib
	end
	local out = vim.fn.system({ "bash", "-c", 'source "$1"; tmux_find_claude_pane "$2"', "_", lib, cwd })
	out = vim.trim(out or "")
	if vim.v.shell_error ~= 0 or out == "" then
		return nil, "no Claude pane running in " .. cwd
	end
	return out
end

-- Paste `text` into `target`'s prompt without submitting. Returns true on
-- success. Used for sending context the user will add a question to.
function M.paste_text(target, text)
	local name = "claude_tmux_send"
	vim.fn.system({ "tmux", "set-buffer", "-b", name, text })
	if vim.v.shell_error ~= 0 then
		return false
	end
	-- -p: bracketed paste if the app requested it; -d: delete the buffer after.
	vim.fn.system({ "tmux", "paste-buffer", "-d", "-p", "-b", name, "-t", target })
	return vim.v.shell_error == 0
end

-- Paste `text` into `target` and submit it with Enter. Returns true on success.
function M.send_text(target, text)
	if not M.paste_text(target, text) then
		return false
	end
	vim.fn.system({ "tmux", "send-keys", "-t", target, "Enter" })
	return vim.v.shell_error == 0
end

return M
