return {
	"MeanderingProgrammer/render-markdown.nvim",
	dependencies = { "nvim-treesitter/nvim-treesitter", "echasnovski/mini.nvim" },
	---@module 'render-markdown'
	---@type render.md.UserConfig
	-- opts only, no config function: lazy.nvim passes opts to setup() only
	-- when there's no custom config, and setup() is what registers the blink
	-- completion source (callout and checkbox names).
	opts = {
		completions = { blink = { enabled = true } },
	},
}
