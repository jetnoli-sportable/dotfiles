return {
	"nvzone/minty",
	event = "VeryLazy",
	cmd = { "Shades", "Huefy" },
	dependencies = {
		"nvzone/volt",
	},

	huefy = {
		border = false,
		position = "cursor", -- cursor | center | func(w, h)
	},

	shades = {
		border = true,
		-- func must return { row, col }
		position = "cursor", -- cursor | center | func(w, h)
	},

	config = function()
		-- Function to check if a string is a valid color
		-- Map left mouse click in normal mode
		vim.keymap.set("n", "<leader>cp", function()
			require("minty.shades").open()
		end, { silent = true, noremap = true })

		vim.keymap.set("n", "<leader>ch", function()
			require("minty.huefy").open({ border = true })
		end, { noremap = true, silent = true })
	end,
}
