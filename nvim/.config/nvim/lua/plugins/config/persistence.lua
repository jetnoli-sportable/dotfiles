-- persistence.nvim — reopen vim where you left off (roadmap 9f-2). Sessions
-- are keyed by cwd by default, which matches wb.sh's model for free: one
-- worktree = one cwd = one tmux session, so there's no extra scoping logic
-- to write here.
--
-- Auto-restore on VimEnter is OPT-IN via $WB_AUTO_RESTORE, not a blanket
-- "any bare/directory launch restores" rule (2026-07-09: a plain `vim .`
-- typed by hand silently resuming a stale session, with no way to just get
-- a fresh directory view, was surprising enough to file as a bug). Only
-- wb_layout_session (wb.sh) sets that env var before launching a worktree
-- session's first window -- typing `vim .`/`nvim .` yourself anywhere else
-- always gets a plain, non-restoring open. Explicit restore is still one
-- keypress away: <leader>ps (this cwd) / <leader>pl (last, any cwd), both
-- bound below.
--
-- The launch-shape check itself is unchanged from the original design:
-- wb's nvim window launches as `nvim .`, not a bare `nvim`, so the standard
-- `argc() == 0` guard other kickstart-style configs use would never fire
-- for it, since "." counts as an argument. Verified empirically (headless
-- round-trip: save a session editing two files, quit, reopen with a
-- literal `nvim .`) that a plain `vim.fn.argv(0) == "."` check is NOT
-- enough either: oil.nvim intercepts the directory argument before
-- VimEnter and rewrites it to an `oil://...` buffer, so argv(0) never reads
-- back as the literal "." by the time this callback runs. Check the
-- resulting buffer name / isdirectory instead, which is robust to that
-- rewrite.
--
-- The autocmd lives in `init`, NOT `config`: `config` only runs once the
-- plugin actually lazy-loads (on `event = "BufReadPre"` below), but a bare
-- `nvim` or `nvim .` launch never reads a real file before VimEnter fires,
-- so a VimEnter hook registered in `config` would be dead on arrival for
-- exactly the case this exists for. `init` runs at spec-registration time
-- regardless of the lazy-load condition; calling `require("persistence")`
-- from inside the callback is what actually triggers the load.
local function launched_with_no_real_file()
	local argc = vim.fn.argc()
	if argc == 0 then
		return true
	end
	if argc == 1 then
		local arg = vim.fn.argv(0)
		local bufname = vim.api.nvim_buf_get_name(0)
		return arg == "." or vim.fn.isdirectory(arg) == 1 or vim.startswith(bufname, "oil://")
	end
	return false
end
local config = {
	"folke/persistence.nvim",
	event = "BufReadPre",
	opts = {},
	keys = {
		{
			"<leader>ps",
			function()
				require("persistence").load()
			end,
			desc = "[P]ersistence: restore [S]ession for cwd",
		},
		{
			"<leader>pl",
			function()
				require("persistence").load({ last = true })
			end,
			desc = "[P]ersistence: restore [L]ast session (any cwd)",
		},
		{
			"<leader>pd",
			function()
				require("persistence").stop()
			end,
			desc = "[P]ersistence: [D]on't save this session on exit",
		},
	},
	init = function()
		vim.api.nvim_create_autocmd("VimEnter", {
			group = vim.api.nvim_create_augroup("persistence-autorestore", { clear = true }),
			callback = function()
				if vim.env.WB_AUTO_RESTORE == "1" and launched_with_no_real_file() then
					require("persistence").load()
				end
			end,
			nested = true,
		})
	end,
}

return config
