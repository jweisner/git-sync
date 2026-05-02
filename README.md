# git-sync

Scans a directory tree for git repositories and keeps them in sync. For each
repo it fetches from origin, then pulls, pushes, or reports problems depending
on the state of the working tree.

## Behaviour

| State | Action |
|---|---|
| Clean, up to date | No output; omitted from summary (shown with `-v`) |
| Clean, behind remote | `git pull --ff-only` |
| Clean, ahead of remote | `git push origin` |
| Clean, diverged | Attempts push, reports failure if rebase required |
| Dirty | Reports changed files; advises on pull/push/conflict risk |
| No tracking branch | Reports and skips |

With `--dry-run`, no push or pull is performed — the summary shows `would push`
or `would pull` instead.

A summary table is printed at the end with one row per repository, coloured by
status (green = healthy, yellow = attention, red = needs intervention).

## Usage

```sh
git-sync.sh [-n] [-v] [-d] [-a] [directory]
```

If `directory` is omitted, the current working directory is used.

| Flag | Long form | Description |
|---|---|---|
| `-n` | `--no-fetch` | Skip `git fetch`; use last known remote refs (useful offline) |
| `-v` | `--verbose` | Include up-to-date repos in the summary table |
| `-d` | `--dry-run` | Preview actions without pulling or pushing |
| `-a` | `--ascii` | Use ASCII-only symbols (`^` `v` `--` `~`) instead of Unicode |

Flags can be combined: `-vn`, `-va`, `-nda`, etc.

## Example

```
$ git-sync.sh ~/projects

==> ~/projects/api-server
  Unpushed: 2 commit(s) on main — pushing
  Pushed

==> ~/projects/frontend
  DIRTY — branch: feature/login
  M  src/auth.ts
  ?? src/auth.test.ts
  Can pull: 1 new remote commit(s) — stash or commit first

 SUMMARY
----------------------------------------------------
Repo        Status          Details
----------------------------------------------------
api-server  pushed          2↑
frontend    dirty/can pull  1↓ available
infra/k8s   pulled          3↓
----------------------------------------------------
```

Up-to-date repos are omitted from the summary by default. Pass `-v` to show all.
