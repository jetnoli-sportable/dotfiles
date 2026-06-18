vim.api.nvim_create_user_command("GoAddTags", function(opts)
	require("gomodifytags").GoAddTags(opts.fargs[1], opts.args)
end, { nargs = "+" })

return {
	"simondrake/gomodifytags",
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	config = true,
	opts = {
		transformation = "camelcase",
		-- skip_unexported = true,
		override = true,
		options = { "json=omitempty" },
		-- parse = { enabled = true, seperator = "--" },
	},
}
