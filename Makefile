# make lint    type-check the config with lua-language-server (no warnings)
# make check   start Neovim headless with this config: no errors on startup

NVIM ?= nvim
VIMRUNTIME := $(shell $(NVIM) --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c q 2>&1)
PLUGINS := $(HOME)/.local/share/nvim/site/pack/core/opt

.PHONY: lint check

lint:
	@dir=$$(mktemp -d); printf '{"runtime.version":"LuaJIT","diagnostics.globals":["vim"],"workspace.checkThirdParty":false,"workspace.library":["%s/lua","%s/gitsigns.nvim/lua"]}' \
		'$(VIMRUNTIME)' '$(PLUGINS)' > $$dir/luarc.json; \
	lua-language-server --check . --configpath=$$dir/luarc.json --checklevel=Warning 2>&1 \
		| tr '\r' '\n' | sed 's/\x1b\[[0-9;]*m//g' | grep -E '\[(Warning|Error)\]|^Diagnosis'; \
	rm -rf $$dir

check:
	@out=$$($(NVIM) --headless -c 'qa!' 2>&1); if [ -n "$$out" ]; then echo "$$out"; exit 1; else echo 'Started cleanly.'; fi
