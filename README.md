# Neovim

An editor for a terminal-first day. Agents (Claude Code, Codex) write code in
many git worktrees; this is where you watch what they write, read it as diffs,
leave review comments, and send that review on: to an agent as markdown, or
to GitHub as a pull request review.

The keys and commands are in [CHEATSHEET.md](CHEATSHEET.md). This file is
about how the configuration is built, and why. It's written for whoever
changes it next, person or agent: keep to its principles, or change them here
first.

## Principles

**Native first.** Neovim 0.12 ships most of an editor: a plugin manager
(`vim.pack`), language servers (`vim.lsp.config`, `lsp/*.lua`), completion as
you type, fuzzy command-line completion, diff mode, folds, treesitter, the
quickfix list, floats, an undo tree, a message UI without "Press ENTER". Use
those, and their own extension points (`findfunc`, `formatexpr`, `BufReadCmd`,
`tagfunc`, colorschemes, autocmds), before writing anything. `:find` is the
file picker, the quickfix list is every list of places, the command line is
the prompt.

**Plugins only where they are the best version of a thing.** There are two:
gitsigns (the gutter, hunks, blame) and nvim-treesitter (installing parsers and
their queries; Neovim ships only a few). Each is pinned to a major version in
`nvim-pack-lock.json`. The colors are Vim's own (retrobox).

**Custom code where it is the work itself.** Reviewing what changed is the
center of the day, so the git views, review comments and GitHub integration
are written here, on top of native diff mode, buffers and `gh`. They're small,
and they know about each other only through narrow, documented seams (below).

**Fast.** Startup is about 15 ms. Anything that waits on git, `gh` or the
network runs without blocking (`task.lua`, `vim.system` callbacks). Views
repaint only what changed, so a refresh that finds nothing new is invisible.
File watching is event-driven (FSEvents on macOS, inotify on Linux), never
polling.

**Minimal, not a mock GUI.** No sidebars, file-tree panes, dashboards, icons or
status-bar widgets. Things are buffers, windows, tabs, floats and the command
line, and behave like them: `:q` closes, `q` closes special buffers, `/`
searches lists, `<C-o>` goes back.

**Live.** Files on disk are the shared truth between you, agents, git and
tests. Buffers reload the moment their file changes; edits save at rest points
(`sync.lua`); diff views follow the working tree, index and HEAD as they
change. Where you and the disk both changed a file, nothing is overwritten
until you choose.

**Each project's own tools.** A worktree's language servers are the versions
its project pins (`.venv/bin`, `node_modules/.bin`), falling back to global
installs (`project.lua`).

**It fits in your head.** One concept per module. Every file starts with what
it does and its keys or commands. Names come from the user's side ("viewed",
"thread", "checkout"), not the implementation's. Messages are plain and
neutral, and never mention agents.

## Layout

```
init.lua            options, keymaps, autocmds; the table of contents
scripts/            install: set up a machine; send: to another, over ssh;
                    ghostty-theme.lua: a Ghostty theme from a colorscheme
lsp/*.lua           one file per language server
after/ftplugin/     per-language settings (Python's wrap width; Markdown and
                    text wrap on screen)
lua/
  find.lua          :find (fuzzy), :Recent, :Grep, on the native command line
  explore.lua       directories (netrw): <leader>e, <leader>E
  tabs.lua          tab labels and numbers, <leader><Tab> keys
  terminal.lua      :terminal with Vim's window keys
  sync.lua          reload on change, autosave at rest, conflict guard
  code.lua          treesitter, LSP, completion, diagnostics, formatting
  wrap.lua          gq rewraps comments and docstrings, leaves code alone
  image.lua         image files show as the image (in Ghostty, over SSH too)
  project.lua       each project's own tools
  task.lua          waiting on commands without freezing the editor
  git/              diff views, history, git:// buffers, gutter, checkouts
  review/           comments and threads on code, viewed marks, export
  github/           pull requests: views, threads, reviews, lists, pages
```

Each directory's `init.lua` explains its commands and its files.

## Concepts

**git/**
- A *side* is the working tree, the index, or a commit.
- A *comparison* is two sides, optionally limited to some paths. Its
  *changes* are the files that differ, as `git diff` lists them.
- A view shows *sections*, which come from a *source* (`git.Source`):
  - comparisons (`:Diff`, `:Show`);
  - commits (`:Log`);
  - a pull request (`:PR`).
- A file at a revision is a read-only buffer named
  `git://<root>//<rev>/<path>`.
- *Checkouts* are where a repository is checked out: its worktrees, and for a
  submodule, the same submodule in each worktree of its superproject.

**review/**
- A *comment* is yours and local, kept per repository in
  `stdpath('state')/review`. It is anchored to code: a revision, lines, and a
  snapshot of those lines, so it moves when the code moves and is marked
  outdated when that code is gone.
- A *thread* is a discussion from elsewhere. A *source* supplies threads;
  today only GitHub does. Threads are shown and found the same way as
  comments.
- *Viewed* marks record a file's content, so any change since makes it
  unviewed again.

**github/**
- A *pull request* is loaded into the checkout that has it checked out, if any
  does; there its right side is that checkout's files, live and editable.
  Otherwise it's shown at its head commit, fetched if missing.
- Your comments on it, and replies to its threads, are sent as one review.
- A *list* is a GitHub search, in GitHub's own syntax.

**How the parts depend on each other:**
- `git.view` shows review counts and viewed marks (`review.status`).
- `review` asks `git` for roots, object names, and which side of a view a
  window is (`git.view.side`). When comments change, it announces it with a
  `User ReviewChanged` event (as gitsigns does with `GitSignsChanged`), which
  `git/init.lua` turns into a view refresh.
- `github` builds on `git`, `review` and `task`, and plugs into them only
  through:
  - view sources (`git.Source`, including its `keys`);
  - thread sources (`review.add_source`);
  - the comment float (`review.compose.float`).
- Nothing outside `github/` requires it, apart from `init.lua` loading it.
- Review stores are files that another Neovim may also write. Code that
  changes one gets it (`store.get`) at that moment and finds comments by id,
  rather than holding on to it.

## Extending

- **A language:**
  1. Add its parser to the list in `code.lua`.
  2. Add `lsp/<name>.lua` (use `project.tool` for a project-pinned binary) and
     its name to `vim.lsp.enable` in `code.lua`.
  3. If it has a dedicated formatter, add the server's name to `formatters`
     in `code.lua`.
- **A view:** write a `git.Source` with `title`, `fetch(callback)`,
  `worktree` and optional `keys`, and pass it to `require('git.view').open(root, source)`.
- **Threads from somewhere else:** `require('review').add_source(function(root) return threads end)`.
- **A list of pull requests:** it's a search; see `github/list.lua`.
- **A theme:**
  - A scheme that has both light and dark (retrobox, wildcharm, lunaperche,
    vim) needs only `vim.cmd.colorscheme('<name>')` in `init.lua`.
  - A dark scheme and a different light one need a `colors/<name>.lua` that
    sources one or the other by `'background'`. A `:colorscheme` inside a
    colorscheme is ignored, so it has to source the file.
  - Then make Ghostty match: `scripts/ghostty-theme.lua` writes a Ghostty
    theme from a scheme.
  - The diff view's colors are tints of the scheme's own red and green, so
    they follow along.

## Conventions

- **File headers:** every file opens with a comment saying what it's for and
  what it adds (keys, commands), and directory `init.lua`s list their files.
  Keep these current when behavior changes; they are the documentation.
- **Comments:** explain why, not what. Match the surrounding density.
- **Window-local options:** use `vim.wo[win][0]` (`:setlocal`). Plain
  `vim.wo[win]` also sets the global value, which leaks into other windows.
- **Writes inside autocmds:** an autocmd that writes buffers needs
  `nested = true`, or `BufWritePost` handlers (LSP, views, comment anchors)
  don't run.
- **Async:**
  - `vim.system` callbacks hop back with `vim.schedule` before touching the
    editor.
  - Work that waits on several commands is a `task.run`. Build UI (windows,
    buffers) outside tasks, on the main loop: opening a buffer can run
    autocmds that can't yield.
  - Results that arrive late check they're still wanted (views keep a
    generation number).
- **Plugins:** add with `vim.pack.add` and a version range; commit
  `nvim-pack-lock.json`.
- **Lua style:** LuaJIT, 2-space indent, up to 120 columns (see
  `.editorconfig`). Annotate public functions for lua-language-server.
- **Outside this repo:** nothing gets pushed, posted to GitHub, or written to
  someone's files as a side effect of testing.

## Checking a change

- `make lint`: lua-language-server over the whole config. It must report no
  problems.
- `make check`: Neovim starts with the config, with no errors.
- **Logic:** run Neovim headless, e.g.
  `nvim --headless -c 'luafile test.lua' -c 'qa!'`, with `vim.wait` for async
  work.
- **UI:** drive a real Neovim in tmux: `tmux new-session -d -x 200 -y 50 'nvim -n'`,
  then `tmux send-keys` and `tmux capture-pane -p` (add `-e` to see colors).
- **GitHub writes:**
  - Replace `require('github').graphql` with a stub that records what would
    be sent.
  - To check a mutation's shape against GitHub's schema, send it with node
    ids that don't exist. It fails at the lookup and changes nothing.
- **Startup time:** `nvim --startuptime /tmp/st.log -c qa`.

## Another machine

`scripts/send HOST` puts this configuration on another machine over ssh, and
runs `scripts/install` there. That script sets up the machine it runs on:
Neovim, ripgrep, gh, tree-sitter, the language servers whose languages are
there, then plugins and parsers. It installs only what's missing, so it's
safe to run again. On Linux everything goes in `~/.local`, without sudo; on
macOS, Homebrew.

- **What's sent:** commits, with git. HOST's `~/.config/nvim` is a clone that
  takes pushes into its working tree only while it's clean, so nothing
  changed there is overwritten. Commit it there, `git pull HOST:.config/nvim`
  here, and send again.
- **Clipboard over SSH:** yanks reach your own computer's clipboard through
  the terminal (OSC 52), and opening a link copies it. Inside tmux on the
  host, that needs `set -g set-clipboard on`.
- **Linux file watching** doesn't see subdirectories. With inotify-tools
  (`sudo apt install inotify-tools`), diff views stay live. Without it, they
  catch up when you come back to them. Buffers reload live either way.
- **Ghostty's terminfo** must be on the host, or keys and colors go wrong:
  `shell-integration-features = ssh-terminfo` in Ghostty's config copies it
  over.

## Outside this repo

- **Ghostty:** `~/.config/ghostty/config` has
  `theme = light:retrobox-light,dark:retrobox-dark`. Both themes are generated
  from Neovim's retrobox (in `~/.config/ghostty/themes/`, by
  `scripts/ghostty-theme.lua`). Ghostty follows macOS (`appearance` toggles
  it), and Neovim follows Ghostty: Ghostty tells it when its theme changes,
  Neovim sets `'background'`, and retrobox switches.
- **Homebrew:** neovim, lua-language-server, rust-analyzer, typescript (7, for
  its native `tsc --lsp`), ripgrep, gh, tree-sitter (CLI, to build parsers),
  difftastic, git-delta.
- **uv tools:** ty and ruff, global fallbacks for projects whose `.venv`
  doesn't pin them.
- **State:** review comments live in `~/.local/state/nvim/review/*.json`.

## Not yet

- Staging single hunks by editing the index side of a diff.
- A single-pane (unified) diff layout.
- A 3-way view for merge conflicts.
- Folders in the view's file list.
- `:Review` and its export limited to the view you're in.
- Leaving old review requests out of `:PR inbox`.
- Multiple cursors: native in Neovim 0.13.
