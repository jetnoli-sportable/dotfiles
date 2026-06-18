-- Claude ⇄ nvim/tmux bridge — entry point.
--
-- `require("claude-tmux").setup({...})` applies config, defines user commands,
-- and wires keymaps under the configured prefix (default <leader>a). The
-- which-key group for that prefix is registered in
-- lua/plugins/config/whichkey.lua.

local config = require("claude-tmux.config")

local M = {}

-- Lazy-required so a broken submodule can't stop the whole plugin loading.
local function output()
	return require("claude-tmux.output")
end
local function reply()
	return require("claude-tmux.reply")
end
local function context()
	return require("claude-tmux.context")
end
local function jump()
	return require("claude-tmux.jump")
end

function M.setup(opts)
	config.setup(opts)
	local prefix = config.options.prefix

	vim.api.nvim_create_user_command("ClaudeGrab", function()
		output().grab_latest()
	end, { desc = "Grab Claude's latest message into a markdown buffer" })

	vim.api.nvim_create_user_command("ClaudePick", function()
		output().picker()
	end, { desc = "Pick a Claude message from the current session" })

	vim.api.nvim_create_user_command("ClaudeYankCode", function()
		output().yank_code()
	end, { desc = "Yank a code block from the Claude output buffer" })

	vim.api.nvim_create_user_command("ClaudeFollow", function()
		output().toggle_follow()
	end, { desc = "Toggle live-follow of Claude's output" })

	vim.api.nvim_create_user_command("ClaudeReply", function()
		reply().open()
	end, { desc = "Open the Claude reply buffer" })

	vim.api.nvim_create_user_command("ClaudeSend", function()
		reply().send()
	end, { desc = "Send the reply draft to the Claude pane" })

	local map = function(mode, suffix, fn, desc)
		vim.keymap.set(mode, prefix .. suffix, fn, { desc = desc })
	end

	-- Read side
	map("n", "o", function()
		output().grab_latest()
	end, "Claude: grab latest [o]utput")
	map("n", "p", function()
		output().picker()
	end, "Claude: [p]ick message")
	map("n", "f", function()
		output().toggle_follow()
	end, "Claude: toggle live-[f]ollow")
	map("n", "y", function()
		output().yank_code()
	end, "Claude: [y]ank code block")

	-- Reply side
	map("n", "r", function()
		reply().open()
	end, "Claude: open [r]eply buffer")
	-- <leader>as: send reply (normal) / send selection as context (visual)
	map("n", "s", function()
		reply().send()
	end, "Claude: [s]end reply")
	map("v", "s", function()
		context().send_selection()
	end, "Claude: [s]end selection as context")

	-- Context
	map("n", "c", function()
		context().send_file()
	end, "Claude: send current file as [c]ontext")

	-- Jump-to-ref (also bound to gf inside the output buffer; see output.lua)
	map("n", "j", function()
		jump().jump_under_cursor()
	end, "Claude: [j]ump to file reference")
end

return M
