-- persistence.nvim — reopen vim where you left off (roadmap 9f-2). Sessions
-- are keyed by cwd by default, which matches wb.sh's model for free: one
-- worktree = one cwd = one tmux session, so there's no extra scoping logic
-- to write here.
--
-- Auto-restore on VimEnter, but only when nvim was launched with no real
-- file argument. wb_layout_session (wb.sh) launches the nvim window with
-- `nvim .`, not a bare `nvim` -- the standard `argc() == 0` guard other
-- kickstart-style configs use would never fire for a wb session, since "."
-- counts as an argument. Verified empirically (headless round-trip: save a
-- session editing two files, quit, reopen with a literal `nvim .`) that a
-- plain `vim.fn.argv(0) == "."` check is NOT enough either: oil.nvim
-- intercepts the directory argument before VimEnter and rewrites it to an
-- `oil://...` buffer, so argv(0) never reads back as the literal "." by the
-- time this callback runs. Check the resulting buffer name / isdirectory
-- instead, which is robust to that rewrite.
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
				if launched_with_no_real_file() then
					require("persistence").load()
				end
			end,
			nested = true,
		})
	end,
}

return config
