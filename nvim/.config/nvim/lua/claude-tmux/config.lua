-- Configuration + defaults for the Claude ⇄ nvim/tmux bridge.
--
-- `setup(opts)` deep-merges user overrides over these defaults and stashes the
-- result in `M.options`, which every other submodule reads.

local M = {}

M.defaults = {
	-- Where Claude Code stores per-project session transcripts.
	projects_dir = vim.fn.expand("~/.claude/projects"),

	tmux = {
		-- Shared tmux helper library providing tmux_find_claude_pane.
		lib = vim.fn.expand("~/.config/scripts/tmux/lib.sh"),
		-- wb.sh, providing wb_ensure_repo_ignore — the idempotent per-repo
		-- .git/info/exclude registration the queue's lazy-create path calls
		-- on first stash into a worktree that predates the feature.
		wb = vim.fn.expand("~/.config/scripts/tmux/wb.sh"),
	},

	-- Leader prefix for all this plugin's keymaps (must match the which-key
	-- group registered in lua/plugins/config/whichkey.lua).
	prefix = "<leader>a",

	-- How the read-only output buffer is shown.
	output = {
		split = "vertical", -- "vertical" | "horizontal"
		focus = true, -- move the cursor into the output window on grab
	},

	-- Reply behaviour. `mode` is the A/B-testable knob:
	--   "scratch" — unnamed buffer in a split; draft is lost when closed.
	--   "file"    — per-session file on disk; draft survives; the literal
	--               "if I didn't write to the file, nothing triggers" gate.
	reply = {
		mode = "scratch",
		split = "horizontal",
		height = 10,
		send = "keymap", -- "keymap" | "save" (save only applies in file mode)
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

return M
