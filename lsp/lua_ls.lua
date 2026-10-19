-- lua_ls: for editing this config. All Lua here is Neovim Lua, so it always
-- gets LuaJIT and the Neovim runtime (vim.* types and docs).
return {
  cmd = { 'lua-language-server' },
  filetypes = { 'lua' },
  root_markers = { '.luarc.json', 'nvim-pack-lock.json', '.git' },
  settings = {
    Lua = {
      runtime = { version = 'LuaJIT' },
      workspace = { checkThirdParty = false, library = { vim.env.VIMRUNTIME } },
    },
  },
}
