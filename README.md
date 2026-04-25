# git-sync

Scans a directory tree for git repositories and keeps them in sync. For each
repo it fetches from origin, then pulls, pushes, or reports problems depending
on the state of the working tree.

## Behaviour

| State | Action |
|---|---|
| Clean, up to date | No output (appears in summary only) |
| Clean, behind remote | `git pull --ff-only` |
| Clean, ahead of remote | `git push origin` |
| Clean, diverged | Attempts push, reports failure |
| Dirty | Reports changed files; advises on pull/push/conflict risk |
| No tracking branch | Reports and skips |

A summary table is printed at the end with one row per repository, coloured by
status (green = healthy, yellow = attention, red = needs intervention).

## Usage

```sh
git-sync.sh [--no-fetch|-n] <directory>
```

`-n` / `--no-fetch` skips the `git fetch` step. Useful when offline — ahead/behind counts are based on the last known remote refs.

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
────────────────────────────────────────────────
Repo                  Status          Details
────────────────────────────────────────────────
api-server            pushed          2↑
frontend              dirty/can pull  1↓ available
mobile                up to date      main
infra/k8s             pulled          3↓
infra/terraform       up to date      main
────────────────────────────────────────────────
```
