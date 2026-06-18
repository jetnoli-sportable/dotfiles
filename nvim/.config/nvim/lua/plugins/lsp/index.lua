local clangDConfig = require("plugins.lsp.config.clangd")
local goConfig = require("plugins.lsp.config.gopls")
local luaConfig = require("plugins.lsp.config.lua_ls")
local tsConfig = require("plugins.lsp.config.ts_ls")
local htmlConfig = require("plugins.lsp.config.html")
local emmetConfig = require("plugins.lsp.config.emmet")
local templConfig = require("plugins.lsp.config.go-templ")
local bashConfig = require("plugins.lsp.config.bash")

local eslintConfig = {
	on_attach = function(client, bufnr)
		-- You can add eslint-specific keymaps or rely on the general ones from LspAttach
	end,
	settings = {
		-- You can customize eslint settings here if needed
	},
}

-- LSP Plugins
local config = {
	-- Main LSP Configuration
	"neovim/nvim-lspconfig",
	dependencies = {
		-- Automatically install LSPs and related tools to stdpath for Neovim
		-- Mason must be loaded before its dependents so we need to set it up here.
		{ "williamboman/mason.nvim", opts = {} },
		"williamboman/mason-lspconfig.nvim",
		"WhoIsSethDaniel/mason-tool-installer.nvim",

		-- Useful status updates for LSP.
		{ "j-hui/fidget.nvim", opts = {} },

		-- Allows extra capabilities provided by blink.cmp
		"saghen/blink.cmp",
	},
	config = function()
		-- Telescope's LSP pickers send a single request and report
		-- "No <X> found" on an empty reply — indistinguishable from "the
		-- server is still indexing" (gopls takes a while on large repos).
		-- Track in-flight $/progress work per client so the pickers below
		-- can say which one it is.
		local active_progress = {} -- client_id -> { [token] = title }
		vim.api.nvim_create_autocmd("LspProgress", {
			group = vim.api.nvim_create_augroup("lsp-progress-track", { clear = true }),
			callback = function(event)
				local value = event.data.params.value
				local tokens = active_progress[event.data.client_id]
				if not tokens then
					tokens = {}
					active_progress[event.data.client_id] = tokens
				end
				if value.kind == "begin" then
					tokens[event.data.params.token] = value.title or "working"
				elseif value.kind == "end" then
					tokens[event.data.params.token] = nil
				end
			end,
		})

		-- Wrap an LSP picker: if an attached server is mid-progress, warn that
		-- an empty result may mean "not ready yet" rather than "doesn't exist".
		local function with_indexing_notice(picker)
			return function()
				for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
					local _, title = next(active_progress[client.id] or {})
					if title then
						vim.notify(
							("%s is still busy (%s) — empty results may just mean it isn't ready, retry shortly"):format(
								client.name,
								title
							),
							vim.log.levels.WARN
						)
						break
					end
				end
				picker()
			end
		end

		--  This function gets run when an LSP attaches to a particular buffer.
		--    That is to say, every time a new file is opened that is associated with
		--    an lsp (for example, opening `main.rs` is associated with `rust_analyzer`) this
		--    function will be executed to configure the current buffer
		vim.api.nvim_create_autocmd("LspAttach", {
			group = vim.api.nvim_create_augroup("kickstart-lsp-attach", { clear = true }),
			callback = function(event)
				-- diffview.nvim's historical/index side opens read-only git-blob
				-- buffers named `diffview://…`. There's no real file behind them,
				-- so a server (gopls especially) that attaches there answers
				-- viewport-driven requests with errors or non-LSP output, which the
				-- LSP-RPC parser then chokes on ("RPC parse error" while scrolling
				-- the comparison view). Detach immediately; the live working-tree
				-- side keeps its real path and a normal LSP session.
				if vim.api.nvim_buf_get_name(event.buf):match("^diffview://") then
					vim.schedule(function()
						vim.lsp.buf_detach_client(event.buf, event.data.client_id)
					end)
					return
				end

				-- In this case, we create a function that lets us more easily define mappings specific
				-- for LSP related items. It sets the mode, buffer and description for us each time.
				local map = function(keys, func, desc, mode)
					mode = mode or "n"
					vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = "LSP: " .. desc })
				end

				vim.keymap.set("n", "<leader>rs", vim.lsp.buf.rename, { buffer = event.buf, desc = "LSP: Rename symbol" })

				-- Rename the variable under your cursor.
				--  Most Language Servers support renaming across files, etc.
				map("grn", vim.lsp.buf.rename, "[R]e[n]ame")

				-- Execute a code action, usually your cursor needs to be on top of an error
				-- or a suggestion from your LSP for this to activate.
				map("gra", vim.lsp.buf.code_action, "[G]oto Code [A]ction", { "n", "x" })

				-- Find references for the word under your cursor.
				map("grr", with_indexing_notice(require("telescope.builtin").lsp_references), "[G]oto [R]eferences")

				-- Jump to the implementation of the word under your cursor.
				--  Useful when your language has ways of declaring types without an actual implementation.
				map(
					"gri",
					with_indexing_notice(require("telescope.builtin").lsp_implementations),
					"[G]oto [I]mplementation"
				)

				-- Jump to the definition of the word under your cursor.
				--  This is where a variable was first declared, or where a function is defined, etc.
				--  To jump back, press <C-t>.
				map("gd", with_indexing_notice(require("telescope.builtin").lsp_definitions), "[G]oto [D]efinition (picker)")
				map("grd", vim.lsp.buf.definition, "[G]oto [D]efinition (direct)")

				-- WARN: This is not Goto Definition, this is Goto Declaration.
				--  For example, in C this would take you to the header.
				map("grD", vim.lsp.buf.declaration, "[G]oto [D]eclaration")

				-- Fuzzy find all the symbols in your current document.
				--  Symbols are things like variables, functions, types, etc.
				map("gO", require("telescope.builtin").lsp_document_symbols, "Open Document Symbols")

				-- Fuzzy find all the symbols in your current workspace.
				--  Similar to document symbols, except searches over your entire project.
				map(
					"gW",
					with_indexing_notice(require("telescope.builtin").lsp_dynamic_workspace_symbols),
					"Open Workspace Symbols"
				)

				-- Jump to the type of the word under your cursor.
				--  Useful when you're not sure what type a variable is and you want to see
				--  the definition of its *type*, not where it was *defined*.
				map(
					"grt",
					with_indexing_notice(require("telescope.builtin").lsp_type_definitions),
					"[G]oto [T]ype Definition"
				)
				-- map("K", vim.lsp.buf.hover, "Hover Documentation")

				vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = bufnr, desc = "Hover Symbol" })

				-- This function resolves a difference between neovim nightly (version 0.11) and stable (version 0.10)
				---@param client vim.lsp.Client
				---@param method vim.lsp.protocol.Method
				---@param bufnr? integer some lsp support methods only in specific files
				---@return boolean
				local function client_supports_method(client, method, bufnr)
					if vim.fn.has("nvim-0.11") == 1 then
						return client:supports_method(method, bufnr)
					else
						return client.supports_method(method, { bufnr = bufnr })
					end
				end

				-- The following two autocommands are used to highlight references of the
				-- word under your cursor when your cursor rests there for a little while.
				--    See `:help CursorHold` for information about when this is executed
				--
				-- When you move your cursor, the highlights will be cleared (the second autocommand).
				local client = vim.lsp.get_client_by_id(event.data.client_id)
				if
					client
					and client_supports_method(
						client,
						vim.lsp.protocol.Methods.textDocument_documentHighlight,
						event.buf
					)
				then
					local highlight_augroup = vim.api.nvim_create_augroup("kickstart-lsp-highlight", { clear = false })
					vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
						buffer = event.buf,
						group = highlight_augroup,
						callback = vim.lsp.buf.document_highlight,
					})

					vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
						buffer = event.buf,
						group = highlight_augroup,
						callback = vim.lsp.buf.clear_references,
					})

					vim.api.nvim_create_autocmd("LspDetach", {
						group = vim.api.nvim_create_augroup("kickstart-lsp-detach", { clear = true }),
						callback = function(event2)
							vim.lsp.buf.clear_references()
							vim.api.nvim_clear_autocmds({ group = "kickstart-lsp-highlight", buffer = event2.buf })
						end,
					})
				end

				-- The following code creates a keymap to toggle inlay hints in your
				-- code, if the language server you are using supports them
				--
				-- This may be unwanted, since they displace some of your code
				if
					client
					and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf)
				then
					map("<leader>th", function()
						vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = event.buf }))
					end, "[T]oggle Inlay [H]ints")
				end
			end,
		})

		-- Diagnostic Config
		-- See :help vim.diagnostic.Opts
		vim.diagnostic.config({
			severity_sort = true,
			float = { border = "rounded", source = "if_many" },
			underline = { severity = vim.diagnostic.severity.ERROR },
			signs = vim.g.have_nerd_font and {
				text = {
					[vim.diagnostic.severity.ERROR] = "󰅚 ",
					[vim.diagnostic.severity.WARN] = "󰀪 ",
					[vim.diagnostic.severity.INFO] = "󰋽 ",
					[vim.diagnostic.severity.HINT] = "󰌶 ",
				},
			} or {},
			virtual_text = {
				source = "if_many",
				spacing = 2,
				format = function(diagnostic)
					local diagnostic_message = {
						[vim.diagnostic.severity.ERROR] = diagnostic.message,
						[vim.diagnostic.severity.WARN] = diagnostic.message,
						[vim.diagnostic.severity.INFO] = diagnostic.message,
						[vim.diagnostic.severity.HINT] = diagnostic.message,
					}
					return diagnostic_message[diagnostic.severity]
				end,
			},
		})

		-- LSP servers and clients are able to communicate to each other what features they support.
		--  By default, Neovim doesn't support everything that is in the LSP specification.
		--  When you add blink.cmp, luasnip, etc. Neovim now has *more* capabilities.
		--  So, we create new capabilities with blink.cmp, and then broadcast that to the servers.
		local capabilities = require("blink.cmp").get_lsp_capabilities()

		-- Enable the following language servers
		--  Feel free to add/remove any LSPs that you want here. They will automatically be installed.
		--
		--  Add any additional override configuration in the following tables. Available keys are:
		--  - cmd (table): Override the default command used to start the server
		--  - filetypes (table): Override the default list of associated filetypes for the server
		--  - capabilities (table): Override fields in capabilities. Can be used to disable certain LSP features.
		--  - settings (table): Override the default settings passed when initializing the server.
		--        For example, to see the options for `lua_ls`, you could go to: https://luals.github.io/wiki/settings/
		local servers = {
			eslint = eslintConfig,
			clangd = clangDConfig,
			templ = templConfig,
			emmet_language_server = emmetConfig,
			html = htmlConfig,
			-- htmx-lsp removed: it's a Rust crate that needs the cargo toolchain to
			-- install (not present here), and the project is stalled at v0.1.0.
			-- emmet/html cover most htmx attributes. To re-add: install Rust
			-- (rustup), then restore `htmx = htmxConfig` here, `htmx = "htmx-lsp"`
			-- in mason_package_map, and lua/plugins/lsp/config/htmx.lua.
			gopls = goConfig,
			ts_ls = tsConfig,
			lua_ls = luaConfig,
			bashls = bashConfig,
		}

		local mason_package_map = {
			ts_ls = "typescript-language-server",
			eslint = "eslint-lsp",
			clangd = "clangd",
			lua_ls = "lua-language-server",
			bashls = "bash-language-server",
			gopls = "gopls",
			templ = "templ",
			emmet_language_server = "emmet-language-server",
			html = "html-lsp",
		}

		local ensure_installed = {}
		for server_key, _ in pairs(servers) do
			local pkg_name = mason_package_map[server_key]
			if pkg_name then
				table.insert(ensure_installed, pkg_name)
			else
				print("Warning: No Mason package mapping for LSP server: " .. server_key)
			end
		end

		vim.list_extend(ensure_installed, {
			"stylua", -- Lua formatter (conform)
			"prettier", -- JS/TS/CSS/HTML/JSON/YAML/Markdown formatter (conform)
			"gofumpt", -- Go formatter (conform)
			"goimports", -- Go import organizer (conform)
			"gomodifytags", -- Go struct tag editing (:GoAddTags)
			"delve", -- Go debugger (nvim-dap-go)
		})
		require("mason-tool-installer").setup({ ensure_installed = ensure_installed })

		require("mason-lspconfig").setup({
			ensure_installed = {}, -- explicitly set to an empty table (Kickstart populates installs via mason-tool-installer)
			automatic_installation = false,
			handlers = {
				function(server_name)
					local server = servers[server_name] or {}
					-- This handles overriding only values explicitly passed
					-- by the server configuration above. Useful when disabling
					-- certain features of an LSP (for example, turning off formatting for ts_ls)
					server.capabilities = vim.tbl_deep_extend("force", {}, capabilities, server.capabilities or {})
					require("lspconfig")[server_name].setup(server)
				end,
			},
		})
	end,
}

return config
