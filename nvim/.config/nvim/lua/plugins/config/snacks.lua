-- snacks.nvim, image module only (every other snacks module stays off).
-- Shows images linked from Markdown, including the .svg beside a /diagram
-- .d2 file, and renders ```mermaid blocks, inline in Ghostty under tmux
-- (tmux needs allow-passthrough, set in tmux.conf). Needs ImageMagick with
-- librsvg for SVG, and mermaid-cli (mmdc) for Mermaid. GNOME Terminal has no
-- graphics protocol, so there <leader>mo opens the image in the viewer instead.

-- ImageMagick 6 loads ~/.config/ImageMagick/delegates.xml after the system
-- one, so the system's svg:decode wins and D2's SVGs come out blank. Searched
-- first, the imagemagick package's rsvg-convert delegate wins.
vim.env.MAGICK_CONFIGURE_PATH = vim.env.MAGICK_CONFIGURE_PATH or vim.fn.expand("~/.config/ImageMagick")

return {
	"folke/snacks.nvim",
	priority = 1000,
	lazy = false,
	---@type snacks.Config
	opts = {
		image = {
			enabled = true,
			-- Wider than snacks' 80 columns so diagrams use the window, and
			-- shorter than its 40 rows: an inline image is virtual lines the
			-- cursor can't enter, so j/k jumps its whole height.
			doc = { enabled = true, inline = true, float = true, max_width = 120, max_height = 30 },
			convert = {
				-- snacks' default mmdc args plus -p (mermaid-puppeteer.json):
				-- --no-sandbox, because mmdc's bundled Chromium can't start its
				-- sandbox where AppArmor blocks user namespaces (Ubuntu 23.10+);
				-- and --host-resolver-rules, so a diagram from an untrusted file
				-- can't fetch URLs (a <img src=http://…> label would otherwise
				-- tell a server you opened it). Renders happen on file open.
				-- Twice the terminal's scale: at 1x the PNG is smaller than its
				-- place on screen and comes out blurry once stretched to fit.
				mermaid = function()
					local theme = vim.o.background == "light" and "neutral" or "dark"
					local puppeteer = vim.fn.stdpath("config") .. "/mermaid-puppeteer.json"
					local scale = tostring(2 * (Snacks.image.terminal.size().scale or 1))
					return { "-i", "{src}", "-o", "{file}", "-b", "transparent", "-t", theme, "-s", scale, "-p", puppeteer }
				end,
			},
		},
	},
}
