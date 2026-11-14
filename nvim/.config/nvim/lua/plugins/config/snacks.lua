-- snacks.nvim, image module only (every other snacks module stays off).
-- Shows images linked from Markdown, including the .svg beside a /diagram
-- .d2 file, and renders ```mermaid blocks, inline in Ghostty under tmux
-- (tmux needs allow-passthrough, set in tmux.conf). Needs ImageMagick with
-- librsvg for SVG, and mermaid-cli (mmdc) for Mermaid. GNOME Terminal has no
-- graphics protocol, so there <leader>mo opens the image in the viewer instead.
return {
	"folke/snacks.nvim",
	priority = 1000,
	lazy = false,
	---@type snacks.Config
	opts = {
		image = {
			enabled = true,
			doc = { enabled = true, inline = true, float = true },
			convert = {
				-- snacks' default mmdc args plus -p (mermaid-puppeteer.json):
				-- --no-sandbox, because mmdc's bundled Chromium can't start its
				-- sandbox where AppArmor blocks user namespaces (Ubuntu 23.10+);
				-- and --host-resolver-rules, so a diagram from an untrusted file
				-- can't fetch URLs (a <img src=http://…> label would otherwise
				-- tell a server you opened it). Renders happen on file open.
				mermaid = function()
					local theme = vim.o.background == "light" and "neutral" or "dark"
					local puppeteer = vim.fn.stdpath("config") .. "/mermaid-puppeteer.json"
					return { "-i", "{src}", "-o", "{file}", "-b", "transparent", "-t", theme, "-s", "{scale}", "-p", puppeteer }
				end,
			},
		},
	},
}
