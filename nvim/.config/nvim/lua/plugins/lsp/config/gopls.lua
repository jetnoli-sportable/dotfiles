-- gopls server-specific options must live under settings.gopls, otherwise
-- lspconfig ignores them. Formatting/imports are handled by conform.nvim
-- (gofumpt + goimports), so no format-on-save autocmd here.
local config = {
	settings = {
		gopls = {
			gofumpt = true,
			staticcheck = true,
			analyses = {
				unusedparams = true,
				unreachable = true,
				nilness = true,
				shadow = true,
			},
		},
	},
}

return config
