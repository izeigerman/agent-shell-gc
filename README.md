# agent-shell-gc

Garbage collection for [`agent-shell`](https://github.com/xenodium/agent-shell).

Kills agent sessions that have gone idle, and removes the git worktrees they
leave behind. Both are off by default. Enabling the mode only starts recording
activity; nothing is collected until you set a TTL.

- **Sessions** are killed after `agent-shell-gc-idle-session-ttl` seconds of
  inactivity, unless the agent is mid-turn, the buffer is on screen, there is
  unsubmitted text at the prompt, or you pinned it.
- **Worktrees** are removed after `agent-shell-gc-idle-worktree-ttl` seconds,
  but only once they hold no live sessions, so a worktree TTL shorter than the
  session TTL can never collect one out from under a running agent. Worktrees
  with uncommitted or unmerged work are left alone.

## Installation

### use-package with `:vc` (Emacs 30+)

```elisp
(use-package agent-shell-gc
  :vc (:url "https://github.com/izeigerman/agent-shell-gc" :rev :newest)
  :after agent-shell
  :config
  (setq agent-shell-gc-idle-session-ttl (* 4 60 60))    ; 4 hours
  (setq agent-shell-gc-idle-worktree-ttl (* 7 24 60 60)) ; 7 days
  (agent-shell-gc-mode))
```

### straight.el

```elisp
(use-package agent-shell-gc
  :straight (:host github :repo "izeigerman/agent-shell-gc")
  :after agent-shell
  :config
  (agent-shell-gc-mode))
```

### Manual

```sh
git clone https://github.com/izeigerman/agent-shell-gc ~/.emacs.d/site-lisp/agent-shell-gc
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/agent-shell-gc")
(require 'agent-shell-gc)
(agent-shell-gc-mode)
```

## Configuration

| Variable                                    | Default                                 | Meaning                                                                                |
|---------------------------------------------|-----------------------------------------|----------------------------------------------------------------------------------------|
| `agent-shell-gc-idle-session-ttl`           | `nil`                                   | Seconds before an idle session is killed. `nil` disables.                              |
| `agent-shell-gc-idle-worktree-ttl`          | `nil`                                   | Seconds before an idle worktree is removed. `nil` disables.                            |
| `agent-shell-gc-poll-interval`              | `60`                                    | Seconds between sweeps.                                                                |
| `agent-shell-gc-grace`                      | `300`                                   | Seconds collection is paused for after startup, a Desktop restore, or a suspend.       |
| `agent-shell-gc-session-protect-functions`  | busy / visible / pending input / pinned | Predicates vetoing a kill. Each is called with the shell buffer.                       |
| `agent-shell-gc-worktree-scope`             | `registered`                            | Which worktrees may be removed: `registered`, `agent-shell`, `linked`, or a predicate. |
| `agent-shell-gc-worktree-dirty-action`      | `skip`                                  | `skip` a worktree holding work (warning once), or `force` its removal.                 |
| `agent-shell-gc-worktree-activity-function` | `nil`                                   | Optional function returning extra activity time for a worktree.                        |
| `agent-shell-gc-delete-worktree-branch`     | `nil`                                   | Also delete the branch, via `git branch -d` (merged branches only).                    |
| `agent-shell-gc-dry-run`                    | `nil`                                   | Log what would be collected; destroy nothing.                                          |
| `agent-shell-gc-notify-function`            | `agent-shell-gc-log`                    | Where reports go. Defaults to the `*agent-shell-gc*` buffer.                           |
| `agent-shell-gc-store-file`                 | `~/.emacs.d/agent-shell-gc/state.eld`   | Where recorded activity is kept.                                                       |

## agent-shell-gc-worktree-scope

`agent-shell-gc-worktree-scope` defaults to `registered`, meaning only worktrees
this package has seen a session running in. A worktree's location cannot be inferred
from its path, since `agent-shell-dot-subdir-function` makes the base directory
configurable and `agent-shell-new-worktree-shell` only offers it as a default.

## agent-shell-gc-grace

`agent-shell-gc-grace` exists because idle time is measured against the wall
clock, so hours when Emacs was closed or the machine was asleep count towards a
TTL. Restore a Desktop session on Monday and everything from Friday is already
past a 4 hour TTL; wake a laptop and the first sweep sees the whole night as
idle. Either way the next sweep would collect a pile of things at once, seconds
after startup.

The grace window pauses collection for a few minutes after enabling the mode,
after a Desktop restore, and after a clock jump much larger than the poll
interval. Tracking continues throughout, so anything you touch during the window
gets a fresh clock and survives. It does not change what counts as idle, only
when the sweeper is allowed to act on it, which gives you a chance to check
`agent-shell-gc-list` and pin what you want to keep. Set it to 0 to collect
immediately on the first sweep instead.

## Commands

| Command                      | Description                                                           |
|------------------------------|----------------------------------------------------------------|
| `agent-shell-gc-mode`        | Global minor mode; installs tracking and the sweeper.          |
| `agent-shell-gc-list`        | Tracked sessions and worktrees with idle times and countdowns. |
| `agent-shell-gc-now`         | Sweep immediately, ignoring the grace window.                  |
| `agent-shell-gc-toggle-keep` | Pin or unpin the current session.                              |

## How it works

Activity comes from the events in `agent-shell`'s stream that report the user or
the agent doing something (a submitted prompt, streamed output, tool calls,
permission prompts, file writes), from typing in a shell or its viewport, and,
for worktrees, from saving a file or selecting a buffer inside one. Events about
a session's own machinery, such as starting up, replaying a restored
conversation, setting the default model or mode, or going idle, are not
activity. Edits made entirely outside Emacs are not observed, so set the
worktree TTL generously. Tracked activity is stored on disk, so it survives both
Emacs restarts and
[`agent-shell-desktop`](https://github.com/timfel/agent-shell-desktop.el)
session restores: a session brought back by a restore keeps the idle clock it
had before, rather than the time of the restart.

Start with `agent-shell-gc-dry-run` set and watch `agent-shell-gc-list` for a
day or so before trusting a TTL.
