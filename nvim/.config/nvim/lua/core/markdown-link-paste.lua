-- Paste URLs in markdown buffers as markdown links.
--
-- Pasting a bare URL with `p`/`P` (or a terminal paste in insert mode)
-- inserts `[](url)` and leaves the cursor in insert mode between the
-- brackets, ready to type the link name.
--
-- The visual-mode flow (paste a URL over selected text to get
-- `[selection](url)`) is handled by markdown.nvim's link.paste option —
-- see lua/plugins/config/markdown-url.lua.

-- Return the trimmed register/clipboard text when it is a single bare URL,
-- nil otherwise.
local function as_url(text)
	if type(text) ~= "string" then
		return nil
	end
	text = vim.trim(text)
	if text == "" or text:find("%s") then
		return nil
	end
	if text:match("^https?://%S+$") or text:match("^www%.%S+$") then
		return text
	end
	return nil
end

-- Insert `[](url)` at byte column `insert_at` on the current line and enter
-- insert mode between the brackets.
local function insert_link(url, row, insert_at)
	vim.api.nvim_buf_set_text(0, row - 1, insert_at, row - 1, insert_at, { "[](" .. url .. ")" })
	vim.api.nvim_win_set_cursor(0, { row, insert_at + 1 })
end

-- Normal-mode paste: `after = true` mirrors `p` (insert after the character
-- under the cursor), `after = false` mirrors `P`.
local function paste_as_link(after)
	return function()
		local url = as_url(vim.fn.getreg(vim.v.register))
		if not url then
			-- Not a URL — fall through to the builtin paste, preserving
			-- count and register.
			vim.api.nvim_feedkeys(vim.v.count1 .. '"' .. vim.v.register .. (after and "p" or "P"), "n", false)
			return
		end

		local row, col = unpack(vim.api.nvim_win_get_cursor(0))
		local insert_at = col
		if after then
			local line = vim.api.nvim_get_current_line()
			if #line > 0 then
				-- Advance past the character under the cursor (multibyte-safe).
				insert_at = col + #vim.fn.strcharpart(line:sub(col + 1), 0, 1)
			end
		end
		insert_link(url, row, insert_at)
		vim.cmd.startinsert()
	end
end

vim.api.nvim_create_autocmd("FileType", {
	desc = "Paste URLs as markdown links",
	group = vim.api.nvim_create_augroup("markdown-link-paste", { clear = true }),
	pattern = "markdown",
	callback = function(event)
		vim.keymap.set("n", "p", paste_as_link(true), {
			buffer = event.buf,
			desc = "Paste (URL becomes markdown link)",
		})
		vim.keymap.set("n", "P", paste_as_link(false), {
			buffer = event.buf,
			desc = "Paste before (URL becomes markdown link)",
		})
	end,
})

-- Terminal pastes (e.g. Ctrl+Shift+V) bypass registers and go through
-- vim.paste — intercept single-line URL pastes in insert mode too.
local default_paste = vim.paste
vim.paste = function(lines, phase)
	if phase == -1 and #lines == 1 and vim.bo.filetype == "markdown" and vim.api.nvim_get_mode().mode:find("^i") then
		local url = as_url(lines[1])
		if url then
			local row, col = unpack(vim.api.nvim_win_get_cursor(0))
			insert_link(url, row, col)
			return true
		end
	end
	return default_paste(lines, phase)
end
