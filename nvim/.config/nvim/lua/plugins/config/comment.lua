return {
	"numToStr/Comment.nvim",
	opts = {},
	config = true,
	keys = {
		{ "gc", mode = { "n", "v" }, desc = "Toggle comment" },
		{
			"<C-/>",
			mode = { "n", "v" },
			function()
				require("Comment.api").toggle.linewise.current()
			end,
			desc = "Toggle comment",
		},
	},
}
