-- bash-language-server: an empty shfmt.path turns its shfmt formatting off
-- (server.js: "Shfmt formatting is disabled as shfmt.path was not set"), so
-- conform's lsp_format = "fallback" never reformats shell on save. shfmt is
-- run by the format-on-edit hook, with the style in the repo's .editorconfig.
return {
	settings = {
		bashIde = {
			shfmt = { path = "" },
		},
	},
}
