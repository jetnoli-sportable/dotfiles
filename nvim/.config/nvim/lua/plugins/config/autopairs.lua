return {
	"windwp/nvim-autopairs",
	event = "InsertEnter",
	-- blink.cmp handles bracket-on-accept natively, so no nvim-cmp integration.
	opts = {
		map_cr = true,
		check_ts = true,
	},
}
