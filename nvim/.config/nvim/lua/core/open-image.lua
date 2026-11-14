-- <leader>mo: open the image or diagram under the cursor in the system viewer
-- (xdg-open / open). In Markdown it's the link target under the cursor, else
-- the first link on the line; in a .d2 file it's the .svg rendered beside it.
-- The fallback for terminals that can't show images inline.
local function link_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] + 1
	local first
	for s, target, e in line:gmatch("()%[[^%]]*%]%(([^)%s]+)[^)]*%)()") do
		first = first or target
		if col >= s and col < e then
			return target
		end
	end
	return first or vim.fn.expand("<cfile>")
end

local function open_target()
	local target
	if vim.bo.filetype == "d2" then
		target = vim.fn.expand("%:p:r") .. ".svg"
	else
		target = link_under_cursor()
		if target == "" then
			vim.notify("open-image: no link under the cursor", vim.log.levels.WARN)
			return
		end
		if not target:match("^%a[%w+.-]*://") then
			target = target:gsub("#.*$", "")
			if not target:match("^/") and not target:match("^~") then
				target = vim.fn.expand("%:p:h") .. "/" .. target
			end
			target = vim.fn.fnamemodify(vim.fn.expand(target), ":p")
		end
	end
	if not target:match("://") and vim.fn.filereadable(target) == 0 then
		vim.notify("open-image: no such file: " .. target, vim.log.levels.WARN)
		return
	end
	vim.ui.open(target)
end

vim.filetype.add({ extension = { d2 = "d2" } })

vim.api.nvim_create_autocmd("FileType", {
	pattern = { "markdown", "d2" },
	callback = function(args)
		vim.keymap.set("n", "<leader>mo", open_target, { buffer = args.buf, desc = "[M]arkdown: [o]pen image/diagram" })
	end,
})
