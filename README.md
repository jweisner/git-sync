# git-sync

Scans a directory tree for git repositories and keeps them in sync. For each
repo it fetches from all configured remotes, then pulls, pushes, or reports
problems depending on the state of the working tree. Pushes go to every remote,
not just `origin`.

## Behaviour

| State | Action |
|---|---|
| Clean, up to date | No output; omitted from summary (shown with `-v`) |
| Clean, behind remote | `git pull --ff-only` |
| Clean, ahead of remote | `git push` to all remotes |
| Clean, diverged | Attempts push to all remotes, reports failure if rebase required |
| Dirty | Reports changed files; advises on pull/push/conflict risk |
| No tracking branch | Reports and skips |

When a repo has multiple remotes, the repo header lists them and push results
are reported per-remote. If some remotes succeed and others fail, the summary
shows `partial push` with the names of the failed remotes.

With `--dry-run`, no push or pull is performed — the summary shows `would push`
(listing the target remotes) or `would pull` instead.

A summary table is printed at the end with one row per repository, coloured by
status (green = healthy, yellow = attention, red = needs intervention).

## Usage

```sh
git-sync.sh [-h] [-o] [-v] [-d] [-a] [directory]
```

If `directory` is omitted, the current working directory is used.

| Flag | Long form | Description |
|---|---|---|
| `-h` | `--help` | Show usage and exit |
| `-o` | `--offline` | Skip `git fetch`; use last known remote refs (useful offline) |
| `-v` | `--verbose` | Include up-to-date repos in the summary table |
| `-d` | `--dry-run` | Preview actions without pulling or pushing |
| `-a` | `--ascii` | Use ASCII-only symbols (`^` `v` `--` `~` `->`) instead of Unicode |

Flags can be combined: `-vo`, `-va`, `-oda`, etc.

## Example

```
$ git-sync.sh ~/projects

==> ~/projects/api-server
  Unpushed: 2 commit(s) on main — pushing
  Pushed → origin

==> ~/projects/frontend  (origin, github)
  DIRTY — branch: feature/login
  M  src/auth.ts
  ?? src/auth.test.ts
  Can pull: 1 new remote commit(s) — stash or commit first

==> ~/projects/infra/k8s  (origin, gitlab)
  Unpushed: 1 commit(s) on main — pushing
  Push to gitlab failed:
    error: could not push to 'gitlab'
  Pushed → origin

 SUMMARY
----------------------------------------------------
Repo        Status          Details
----------------------------------------------------
api-server  pushed          2↑
frontend    dirty/can pull  1↓ available
infra/k8s   partial push    failed: gitlab
----------------------------------------------------
```

Up-to-date repos are omitted from the summary by default. Pass `-v` to show all.
