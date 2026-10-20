# Cheatsheet

Leader is `Space`, written `SPC`. Command-line completion pops up as you type:
`Tab` moves through it, `Enter` runs, `Up`/`Down` recall history.

## Files and search

| Keys | Does |
|---|---|
| `SPC f` | `:find`: fuzzy file under the cwd (spaces allowed: `:find user model`) |
| `SPC r` | `:Recent`: recently used files |
| `SPC b` | `:buffer`: open buffers, fuzzy |
| `SPC /` | `:Grep {regex}`: ripgrep into the quickfix list |
| `SPC *` | grep the word under the cursor, or the selection |
| `SPC q` | close the location list or quickfix list; with neither open, open quickfix |
| `]q` `[q` | next/previous quickfix item (`]l` `[l` location list) |
| `Esc` | clear search highlighting |
| `SPC e` | this file's directory, on the file |
| `SPC E` | the project's root (the repository's, or the cwd) |

Directories open in netrw, Vim's own browser (`F1` lists every key):

| In a directory | Does |
|---|---|
| `Enter` / `-` | open the entry / go up a directory |
| `Ctrl-^` | back to the file you came from |
| `%` / `d` | new file / new directory |
| `R` / `D` | rename / delete |
| `o` / `v` / `t` | open in a split / a vertical split / a tab |
| `p` | preview |
| `gh` | show or hide dotfiles |
| `Ctrl-r` | refresh (going into a directory re-reads it anyway) |

Images (PNG; JPEG, GIF and WebP too, where `sips` or ImageMagick can convert
them) open as the picture, fitted to the window, in Ghostty and over SSH.
`:Open %` opens one in your system's viewer.

Saving is automatic: on leaving insert mode, after changes, on switching
buffers or apps. Files reload as soon as something else changes them. If a
file changed on disk while you had unsaved edits, the statusline says
`[conflict]` and autosave pauses for it:
- `:e!` takes the version on disk;
- `:w` asks before overwriting it.

## Editing

| Keys | Does |
|---|---|
| `SPC L` | change every occurrence of the word (or selection): `:%s`, previewed live |
| `*` then `cgn`, `.` | change matches one at a time |
| `gq{motion}` / `gqq` | rewrap comments and docstrings to the wrap width (`gqq`: the whole paragraph) |
| `gw{motion}` | Vim's own rewrap, ignoring language servers |
| `j` / `k` | down/up a line on screen, where lines wrap (Markdown, text); with a count (`5j`), real lines |
| `gO` | in Markdown: an outline of the headings (`SPC q` closes) |
| `]]` `[[` | in Markdown: next/previous section |
| `gcc` / `gc{motion}` | comment / uncomment |
| `van` / `vin` | select the syntax node around the cursor; repeat `an`/`in` to grow/shrink |
| `u` / `Ctrl-r` | undo / redo |
| `SPC u` | undo tree: move in it to move through the file's history (`q` closes) |
| `zc` `zo` `za` `zM` `zR` | fold: close, open, toggle, all closed, all open |

Markdown and text files wrap long lines on screen. Markdown hides its markup
(`**`, backticks, a link's URL, code fences) except on the cursor's line.

## Code

These are Neovim's own LSP keys, plus a few of ours.

| Keys | Does |
|---|---|
| `K` | hover documentation |
| `gd` or `Ctrl-]` | go to definition (`Ctrl-o` back) |
| `grr` | references (into the quickfix list) |
| `gri` / `grt` | implementation / type definition |
| `grn` | rename the symbol, across files |
| `gra` | code actions: fixes, imports (normal or visual) |
| `gO` | symbols in this file (location list; `SPC q` closes) |
| `]d` `[d` | next/previous diagnostic |
| `Ctrl-s` (insert) | signature help |
| `SPC =` | format the file (ruff, oxfmt or rustfmt) |
| `SPC ti` | toggle inlay hints |

Completion pops up as you type:
- `Ctrl-n` / `Ctrl-p` move through it.
- `Ctrl-y` accepts, which also adds the import.
- `Ctrl-e` dismisses it.

Each language uses its project's own tools when it has them:
- **Python:** ty and ruff.
- **TypeScript and JavaScript:** TypeScript 7's server, plus oxlint and oxfmt
  where the project uses them.
- **Rust:** rust-analyzer, with clippy.
- **Lua:** lua_ls.

## Windows, tabs, terminal

| Keys | Does |
|---|---|
| `Ctrl-h/j/k/l` | move between windows (from `:terminal` too) |
| `SPC 1` … `SPC 9` | go to tab N (the tabline numbers them) |
| `SPC Tab Tab` | back to the last tab |
| `SPC Tab n` / `d` / `o` | new tab / close it / close the others |
| `SPC Tab r` | name the tab |
| `SPC Tab ]` `[` / `>` `<` | next/previous tab / move it right/left |
| `gt` `gT` `Ctrl-w T` | Vim's own: next/previous tab, this window to a new tab |
| `:terminal` | a terminal; `Ctrl-w` then a window key works inside it |
| `Esc` (terminal) | normal mode at a shell prompt (inside a running program, it's the program's) |
| `Ctrl-w N` / `Ctrl-w .` | normal mode / send a literal `Ctrl-w` |
| `ZR` | restart Neovim (reloads the config) |
| `ZZ` / `ZQ` | save and close / close without saving |

## Git: the gutter

| Keys | Does |
|---|---|
| `]c` `[c` | next/previous hunk |
| `SPC hs` / `SPC hr` | stage / reset the hunk, or the selected lines |
| `SPC hp` | preview the hunk inline |
| `SPC hb` / `SPC hB` | blame this line / the whole file |
| `SPC tb` | toggle blame at the end of the line |
| `SPC hq` | every hunk in the repo, in the quickfix list |
| `ih` | hunk text object (`dih`, `vih`) |

## Git: diff views

| Keys | Does |
|---|---|
| `SPC gd` | `:Diff`: unstaged and staged changes |
| `SPC gf` | `:Diff -- %`: this file's changes |
| `SPC gl` / `SPC gh` | `:Log`: history / this file's history (follows renames) |
| `:Diff {args}` | as `git diff`: `main`, `A..B`, `A...B`, `--staged`, `--merge-base main`, `-- paths` |
| `:Show [rev]` | a commit against its parent |

In a view, the right side is the real file when it's the working tree: edit
and stage as you read.

| Keys | Does |
|---|---|
| `]f` `[f` | next/previous file (anywhere in the tab) |
| `]c` `[c` | next/previous change |
| `Enter` | show the file; on a commit, open or close it |
| `s` / `S` / `U` | stage or unstage the file / stage all / unstage all |
| `X` | discard the file's changes (asks first) |
| `v` | mark viewed and go to the next unviewed (any change since unmarks it) |
| `q` | close the view |
| `:q` | on the left side or the file list: stop comparing, keep editing the file |

## Review comments and threads

Comments are yours and local, anchored to code, and they follow it as it
moves. Threads come from GitHub pull requests. In the gutter:
- `●` is your comment.
- `◆` is a thread: yellow when open, dim when resolved, blue when it's yours
  and not sent yet.

| Keys | Does |
|---|---|
| `SPC c` | comment on this line, edit its comment, or open its thread |
| `SPC c` (visual) | comment on the selected lines |
| `SPC C` | delete the comment on this line (or your unsent reply) |
| `SPC gc` | `:Review`: all comments and open threads, in the quickfix list |
| `:Review export [file]` | as markdown for an agent: copied to the clipboard |
| `:Review clear` | delete all comments (asks first) |

| In the comment window | Does |
|---|---|
| `ZZ` / `ZQ` / `ZD` | save / discard the edit / delete the comment |

| In a thread window | Does |
|---|---|
| `ZZ` | save your reply, typed below the line (it's sent with your review) |
| `ZC` | resolve the thread, or reopen it |
| `ZD` | delete your reply |
| `ZQ` | close |

## GitHub

| Keys | Does |
|---|---|
| `SPC gp` | `:PR`: this checkout's pull request |
| `:PR {n}` | that pull request; also `owner/repo#n` or its URL |
| `SPC gP` | `:PR list [filters]`: this repo's pull requests |
| `SPC gi` | `:PR inbox`: yours, and those waiting for your review, everywhere |
| `:PR submit` | send your comments and replies as one review |
| `:PR browse` | open it on GitHub |

When a pull request's branch is checked out in a worktree, its view opens
there. Running `:PR` again in its view reloads it.

**Filters** use GitHub's own search syntax, and Tab completes them:
- `author:@me`, `review-requested:@me`, `review:required`;
- `label:x`, `is:merged`, `draft:false`, `sort:created-desc`;
- `repo:`, `org:` or `user:` to search beyond this repo.

| In a PR's view | Does |
|---|---|
| `K` (in the file list) | read it: description, checks, reviews, conversation |

| In a list | Does |
|---|---|
| `Enter` | open it (`⎇ name` says which worktree has it checked out) |
| `Enter` on `⋯ more` | load the next 100 |
| `K` | read it |
| `o` | open it on GitHub |
| `f` | change the filters |
| `R` | reload |
| `q` | back |

**Sending a review:**
1. `:PR submit` opens a window: write a summary at the top if you like.
2. Delete a comment's line to keep it back.
3. `ZZ`, then choose Comment, Approve or Request changes.

## Another machine

From `~/.config/nvim`, `scripts/send HOST` sends your committed config to HOST
over ssh and sets the machine up (Neovim too). Run it again after changes.

Over SSH:
- `y` copies to your computer's clipboard, and `p` puts the last yank.
- Cmd-V pastes from your computer.
- Opening a link (`gx`, `o` on a pull request) copies it.

## Theme

retrobox, Vim's own retro scheme (gruvbox's colors), light or dark with
macOS: `appearance` switches Ghostty and Neovim together.
- **Force one in Neovim:** `:set background=light` or `:set background=dark`.
- **Try another scheme:** `:colorscheme wildcharm` (or any in
  `:colorscheme <Tab>`).
