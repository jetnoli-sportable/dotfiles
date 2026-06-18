-- GoLand-parity debugging: nvim-dap + delve (see improvements/go-debugging.md).
-- Acceptance test: Part B of improvements/go-parity/CHECKLIST.md.
--
-- Loads on BufReadPre (not FileType) so persistent-breakpoints' BufReadPost
-- autocmd exists in time to restore saved breakpoints in the first Go file
-- opened.

local function dap()
	return require("dap")
end

-- Breakpoint mutations go through persistent-breakpoints so they survive
-- nvim restarts; raw dap.toggle_breakpoint would not be saved.
local function breakpoints()
	return require("persistent-breakpoints.api")
end

local config = {
	"mfussenegger/nvim-dap",
	dependencies = {
		{ "rcarriga/nvim-dap-ui", dependencies = { "nvim-neotest/nvim-nio" } },
		"leoluz/nvim-dap-go",
		"theHamsta/nvim-dap-virtual-text",
		{
			"Weissle/persistent-breakpoints.nvim",
			opts = { load_breakpoints_event = { "BufReadPost" } },
		},
	},
	event = { "BufReadPre *.go", "BufNewFile *.go" },
	keys = {
		-- GoLand muscle memory (modified F-keys depend on the terminal —
		-- the <leader>d maps below are the guaranteed path)
		{ "<F9>", function() dap().continue() end, desc = "Debug: Continue" },
		{ "<F8>", function() dap().step_over() end, desc = "Debug: Step over" },
		{ "<F7>", function() dap().step_into() end, desc = "Debug: Step into" },
		{ "<S-F8>", function() dap().step_out() end, desc = "Debug: Step out" },
		{ "<C-F8>", function() breakpoints().toggle_breakpoint() end, desc = "Debug: Toggle breakpoint" },
		{ "<A-F9>", function() dap().run_to_cursor() end, desc = "Debug: Run to cursor" },

		{ "<leader>dc", function() dap().continue() end, desc = "[D]ebug: [C]ontinue / start" },
		{ "<leader>dn", function() dap().step_over() end, desc = "[D]ebug: step over ([N]ext)" },
		{ "<leader>di", function() dap().step_into() end, desc = "[D]ebug: step [I]nto" },
		{ "<leader>do", function() dap().step_out() end, desc = "[D]ebug: step [O]ut" },
		{ "<leader>dg", function() dap().run_to_cursor() end, desc = "[D]ebug: run to cursor ([G]o)" },
		{ "<leader>db", function() breakpoints().toggle_breakpoint() end, desc = "[D]ebug: toggle [B]reakpoint" },
		{
			"<leader>dB",
			function() breakpoints().set_conditional_breakpoint() end,
			desc = "[D]ebug: conditional [B]reakpoint",
		},
		{ "<leader>dx", function() breakpoints().clear_all_breakpoints() end, desc = "[D]ebug: clear breakpoints" },
		{ "<leader>dt", function() require("dap-go").debug_test() end, desc = "[D]ebug: nearest Go [T]est" },
		{ "<leader>dT", function() require("dap-go").debug_last_test() end, desc = "[D]ebug: re-run last [T]est" },
		{
			"<leader>de",
			function() require("dapui").eval() end,
			mode = { "n", "v" },
			desc = "[D]ebug: [E]valuate expression",
		},
		{ "<leader>du", function() require("dapui").toggle() end, desc = "[D]ebug: toggle [U]I" },
		{ "<leader>dr", function() dap().repl.toggle() end, desc = "[D]ebug: [R]EPL" },
		{ "<leader>dq", function() dap().terminate() end, desc = "[D]ebug: [Q]uit session" },
	},
	config = function()
		local dap_, dapui = require("dap"), require("dapui")

		-- Registers the "go" adapter (dlv dap) + debug file/package/test/attach
		-- configurations. Repos' .vscode/launch.json entries with "type": "go"
		-- are picked up automatically by dap.continue()'s config providers.
		require("dap-go").setup()
		require("nvim-dap-virtual-text").setup({})
		dapui.setup()

		dap_.listeners.after.event_initialized["dapui_config"] = function()
			dapui.open()
		end
		dap_.listeners.before.event_terminated["dapui_config"] = function()
			dapui.close()
		end
		dap_.listeners.before.event_exited["dapui_config"] = function()
			dapui.close()
		end

		vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
		vim.fn.sign_define("DapBreakpointCondition", { text = "◆", texthl = "DiagnosticError" })
		vim.fn.sign_define("DapBreakpointRejected", { text = "○", texthl = "DiagnosticWarn" })
		vim.fn.sign_define("DapLogPoint", { text = "◉", texthl = "DiagnosticInfo" })
		vim.fn.sign_define("DapStopped", { text = "→", texthl = "DiagnosticOk", linehl = "Visual" })
	end,
}

return config
