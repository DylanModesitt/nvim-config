-- rust_analyzer: Rust. Types, completion, navigation, renames, fixes;
-- clippy's lints as you save; rustfmt for <leader>=. The root is the
-- workspace's (where Cargo.lock is), so a workspace of crates is one server.
return {
  cmd = { 'rust-analyzer' },
  filetypes = { 'rust' },
  root_markers = { 'Cargo.lock', 'rust-project.json', 'Cargo.toml', '.git' },
  settings = {
    ['rust-analyzer'] = { check = { command = 'clippy' } },
  },
}
