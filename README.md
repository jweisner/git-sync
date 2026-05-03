# git-sync

Scans a directory tree for git repositories and keeps them in sync. For each
repo it fetches from all configured remotes, then pulls, pushes, or reports
problems depending on the state of the working tree. Pushes go to every remote,
not just `origin`.

## Install

### Homebrew

```sh
brew install jweisner/git-sync/git-sync
```

### Manual

Copy the `git-sync` script to a directory on your `PATH`:

```sh
curl -Lo ~/.local/bin/git-sync https://raw.githubusercontent.com/jweisner/git-sync/main/git-sync
chmod +x ~/.local/bin/git-sync
```

## Behaviour

| State | Action |
|---|---|
| Clean, up to date | No output; omitted from summary (shown with `-v` or when fetch had errors) |
| Clean, behind remote | `git pull --ff-only` |
| Clean, ahead of remote | `git push` to all remotes |
| Clean, diverged | Attempts push to all remotes, reports failure if rebase required |
| Dirty | Reports changed files; advises on pull/push/conflict risk |
| No tracking branch | Reports and skips |
| All remotes unreachable | `fetch failed` with skipped/failed remote names |

When a repo has multiple remotes, the repo header lists them and push results
are reported per-remote. If some remotes succeed and others fail, the summary
shows `partial push` with the names of the failed remotes.

With `--dry-run`, no push or pull is performed — the summary shows `would push`
(listing the target remotes) or `would pull` instead.

A summary table is printed at the end with one row per repository, coloured by
status (green = healthy, yellow = attention, red = needs intervention).

## Usage

```sh
git-sync [-h] [-o] [-v] [-d] [-a] [-t N] [directory]
```

If `directory` is omitted, the current working directory is used.

| Flag | Long form | Description |
|---|---|---|
| `-h` | `--help` | Show usage and exit |
| `-o` | `--offline` | Skip `git fetch`; use last known remote refs (useful offline) |
| `-v` | `--verbose` | Include up-to-date repos in the summary table |
| `-d` | `--dry-run` | Preview actions without pulling or pushing |
| `-a` | `--ascii` | Use ASCII-only symbols (`^` `v` `--` `~` `->`) instead of Unicode |
| `-t N` | `--timeout N` | Seconds before a stalled remote operation times out (default: 10) |

Flags can be combined: `-vo`, `-va`, `-oda`, etc.

## Timeouts and unreachable hosts

Before contacting a remote for the first time, git-sync probes the host with a
TCP connection test (`nc -z`, 5-second timeout). If the probe fails the host is
added to a blocklist and every remote pointing at it is skipped instantly for the
rest of the run. This keeps the script fast when a VPN is down or a server is
unreachable.

If `nc` (netcat) is not installed, probing is disabled and a warning is printed.
The script will still work but will rely on git-native timeouts to detect
unreachable hosts.

For active connections, git-sync uses git's built-in stall detection rather than
a wall-clock timer, so large fetches on slow links are never killed mid-transfer:

- **HTTPS**: `http.lowSpeedLimit` (1 KB/s) and `http.lowSpeedTime` abort
  transfers only when throughput drops below the threshold for the timeout
  duration.
- **SSH**: `ConnectTimeout`, `ServerAliveInterval`, and `ServerAliveCountMax`
  detect dead sessions without interfering with slow-but-progressing transfers.

If a git operation fails with a connection error, the host is added to the
blocklist so subsequent repos at the same host are skipped without waiting.

### Fetch failures in the summary

Connection errors and skipped remotes during fetch are surfaced in the summary
table:

- If **all** remotes for a repo failed to fetch, the summary shows `fetch failed`
  in red with details like `skipped: gitlab; failed: origin`.
- If **some** remotes failed but others succeeded, the normal status is shown with
  the fetch failure appended to the details column (e.g. `main (skipped: gitlab)`)
  and the row colour is upgraded to yellow.
- Repos that would normally be hidden as "up to date" are always shown when they
  have fetch warnings, even without `-v`.

## Ctrl+C handling

Press **Ctrl+C** once to skip the current repository and move on to the next.
Press **Ctrl+C** twice quickly (within one second) to exit immediately. Skipped
repos appear in the summary as `skipped` / `interrupted`.

## Example

```
$ git-sync ~/projects

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
