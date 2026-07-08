local config = { -- Fuzzy Finder (files, lsp, etc)
	"nvim-telescope/telescope.nvim",
	event = "VimEnter",
	dependencies = {
		"nvim-lua/plenary.nvim",
		{ -- If encountering errors, see telescope-fzf-native README for installation instructions
			"nvim-telescope/telescope-fzf-native.nvim",

			-- `build` is used to run some command when the plugin is installed/updated.
			-- This is only run then, not every time Neovim starts up.
			build = "make",

			-- `cond` is a condition used to determine whether this plugin should be
			-- installed and loaded.
			cond = function()
				return vim.fn.executable("make") == 1
			end,
		},
		{ "nvim-telescope/telescope-ui-select.nvim" },

		-- Useful for getting pretty icons, but requires a Nerd Font.
		{ "nvim-tree/nvim-web-devicons", enabled = vim.g.have_nerd_font },
	},
	config = function()
		-- Telescope is a fuzzy finder that comes with a lot of different things that
		-- it can fuzzy find! It's more than just a "file finder", it can search
		-- many different aspects of Neovim, your workspace, LSP, and more!
		--
		-- The easiest way to use Telescope, is to start by doing something like:
		--  :Telescope help_tags
		--
		-- After running this command, a window will open up and you're able to
		-- type in the prompt window. You'll see a list of `help_tags` options and
		-- a corresponding preview of the help.
		--
		-- Two important keymaps to use while in Telescope are:
		--  - Insert mode: <c-/>
		--  - Normal mode: ?
		--
		-- This opens a window that shows you all of the keymaps for the current
		-- Telescope picker. This is really useful to discover what Telescope can
		-- do as well as how to actually do it!

		-- [[ Configure Telescope ]]
		-- See `:help telescope` and `:help telescope.setup()`

		-- Globs that should always show up in `find_files`, even when they are
		-- gitignored (e.g. config.hjson / .env files that live outside version
		-- control). Append to this list to surface more ignored files by pattern.
		local always_include_globs = {
			"*.hjson",
			".env*",
		}

		-- Build the find_files command: a normal fd pass (which respects
		-- .gitignore) followed by one --no-ignore pass per whitelisted glob,
		-- merged and de-duplicated. This keeps gitignore behaviour for
		-- everything except the patterns above.
		local find_files_command = function()
			local exclude = "--exclude .git --exclude node_modules --exclude dist"
			local passes = { "fd --type f --hidden " .. exclude }
			for _, glob in ipairs(always_include_globs) do
				table.insert(
					passes,
					"fd --type f --hidden --no-ignore " .. exclude .. " --glob '" .. glob .. "'"
				)
			end
			return { "sh", "-c", "{ " .. table.concat(passes, "; ") .. "; } | awk '!seen[$0]++'" }
		end

		require("telescope").setup({
			-- You can put your default mappings / updates / etc. in here
			--  All the info you're looking for is in `:help telescope.setup()`
			--
			-- defaults = {
			--   mappings = {
			--     i = { ['<c-enter>'] = 'to_fuzzy_refine' },
			--   },
			-- },
			defaults = {
				hidden = true,
				file_ignore_patterns = {
					"^node_modules/",
					"^.git/",
					"^dist/",
				},
				vimgrep_arguments = {
					"rg",
					"--color=never",
					"--no-heading",
					"--with-filename",
					"--line-number",
					"--column",
					"--smart-case",
					"--hidden",
					"--glob",
					"!.git/*",
				},
			},
			pickers = {
				find_files = {
					hidden = true,
					find_command = find_files_command(),
				},
			},
			extensions = {
				["ui-select"] = {
					require("telescope.themes").get_dropdown(),
				},
			},
		})

		-- Enable Telescope extensions if they are installed
		pcall(require("telescope").load_extension, "fzf")
		pcall(require("telescope").load_extension, "ui-select")

		-- See `:help telescope.builtin`
		local builtin = require("telescope.builtin")
		vim.keymap.set("n", "<leader>sh", builtin.help_tags, { desc = "[S]earch [H]elp" })
		vim.keymap.set("n", "<leader>sk", builtin.keymaps, { desc = "[S]earch [K]eymaps" })
		-- vim.keymap.set("n", "<leader>sf", builtin.find_files, { desc = "[S]earch [F]iles" })
		-- vim.keymap.set("n", "<leader>sd", function()
		-- 	require("telescope.builtin").find_files({
		-- 		prompt_title = "Dotfiles",
		-- 		cwd = vim.fn.expand("~/.config"),
		-- 		hidden = true,
		-- 	})
		-- end, { desc = "[S]earch [D]otfiles" })

		vim.keymap.set("n", "<leader>sf", function()
			require("telescope.builtin").find_files({
				hidden = true,
				no_ignore = false,
				follow = true,
			})
		end, { desc = "[S]earch [F]iles (including hidden)" })

		vim.keymap.set("n", "<leader>sF", function()
			require("telescope.builtin").find_files({
				hidden = true,
				no_ignore = true,
				follow = true,
				-- Override the picker default find_command so this picker shows
				-- *all* gitignored files, not just the whitelisted globs.
				find_command = { "fd", "--type", "f", "--hidden", "--no-ignore", "--exclude", ".git" },
			})
		end, { desc = "[S]earch [F]iles (including hidden and git ignored)" })

		vim.keymap.set("n", "<leader>ss", builtin.builtin, { desc = "[S]earch [S]elect Telescope" })
		vim.keymap.set("n", "<leader>sw", builtin.grep_string, { desc = "[S]earch current [W]ord" })
		vim.keymap.set("n", "<leader>sg", builtin.live_grep, { desc = "[S]earch by [G]rep" })
		-- vim.keymap.set("n", "<leader>sd", builtin.diagnostics, { desc = "[S]earch [D]iagnostics" })
		vim.keymap.set("n", "<leader>sd", function()
			builtin.diagnostics({})
		end, { desc = "[S]earch [D]iagnostics (all files)" })

		-- Add this keymap to run diagnostics on all files in the current Git project
		vim.keymap.set("n", "<leader>sr", builtin.resume, { desc = "[S]earch [R]esume" })
		vim.keymap.set("n", "<leader>s.", builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
		vim.keymap.set("n", "<leader>sb", builtin.buffers, { desc = "[ ] Find existing buffers" })
		vim.keymap.set("n", "<leader>sc", builtin.git_status, { desc = "[S]earch [C]hanged files (git status)" })

		-- Slightly advanced example of overriding default behavior and theme
		vim.keymap.set("n", "<leader>/", function()
			-- You can pass additional configuration to Telescope to change the theme, layout, etc.
			builtin.current_buffer_fuzzy_find(require("telescope.themes").get_dropdown({
				winblend = 10,
				previewer = false,
			}))
		end, { desc = "[/] Fuzzily search in current buffer" })

		-- It's also possible to pass additional configuration options.
		--  See `:help telescope.builtin.live_grep()` for information about particular keys
		vim.keymap.set("n", "<leader>s/", function()
			builtin.live_grep({
				grep_open_files = true,
				prompt_title = "Live Grep in Open Files",
			})
		end, { desc = "[S]earch [/] in Open Files" })
	end,
}

return config
