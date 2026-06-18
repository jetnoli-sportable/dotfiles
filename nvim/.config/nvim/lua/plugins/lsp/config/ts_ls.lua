return {
	cmd = { "typescript-language-server", "--stdio" },
	filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
	init_options = {
		hostInfo = "neovim",
	},
	capabilities = {
		renameProvider = true, -- Enable rename
		workspace = {
			didCreateFiles = true, -- Enable file move notifications
		},
	},
	settings = {
		typescript = {
			format = {
				enable = true,
			},
		},
	},
}
