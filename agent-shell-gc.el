;;; agent-shell-gc.el --- Garbage collection for agent-shell sessions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Iaroslav Zeigerman

;; Author: Iaroslav Zeigerman
;; Maintainer: Iaroslav Zeigerman
;; URL: https://github.com/izeigerman/agent-shell-gc
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.1"))
;; Keywords: convenience, tools

;; This file is not part of GNU Emacs.

;; Released under the MIT License; see the LICENSE file for details.

;;; Commentary:

;; Automatically kill `agent-shell' sessions that have been idle for longer
;; than `agent-shell-gc-idle-session-ttl', and remove the git worktrees they
;; leave behind once those have been idle for longer than
;; `agent-shell-gc-idle-worktree-ttl'.  Both TTLs are nil by default, so
;; enabling `agent-shell-gc-mode' destroys nothing until one is set.
;;
;; A single sweeper timer drives everything.  Each sweep folds per-buffer
;; activity into a persistent store, then kills idle sessions, then removes
;; idle worktrees, in that order, so a worktree TTL shorter than the session
;; TTL cannot fire early: a worktree is only ever a candidate once it holds no
;; live sessions.
;;
;; Activity is recorded from agent-shell's own event stream, from typing in a
;; shell or its viewport, and, for worktrees, from saving a file or
;; selecting a buffer inside one.  Edits made entirely outside Emacs are not
;; observed; set the worktree TTL generously (days) to accommodate that.
;;
;; The store is on disk because both halves outlive Emacs: worktree TTLs are
;; measured in days, and `agent-shell-desktop' restores session buffers across
;; restarts.  Sessions are keyed by (AGENT-CONFIG-ID . SESSION-ID) rather than
;; by buffer, since the buffer object is not stable across a restore.
;;
;; Killing a session is cheap and reversible, since the transcript stays on disk
;; and the ACP session id stays valid agent-side.  Removing a worktree is not,
;; so worktree defaults are conservative: only linked worktrees, only ones we
;; have seen a session running in, never one with uncommitted or unmerged work.
;;
;;   (agent-shell-gc-mode)
;;   (setq agent-shell-gc-idle-session-ttl (* 4 60 60))
;;   (setq agent-shell-gc-idle-worktree-ttl (* 7 24 60 60))

;;; Code:

(require 'agent-shell)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell-viewport--shell-buffer "agent-shell-viewport" (&optional viewport-buffer))

(defvar agent-shell-gc-mode)
(defvar desktop-after-read-hook)

;;;; Customization

(defgroup agent-shell-gc nil
  "Garbage collection for `agent-shell' sessions and worktrees."
  :group 'agent-shell
  :prefix "agent-shell-gc-")

(defcustom agent-shell-gc-idle-session-ttl nil
  "Seconds of inactivity after which an agent session is killed.
Nil disables session collection, which is the default: enabling
`agent-shell-gc-mode' alone never kills a session."
  :type '(choice (const :tag "Never" nil) (integer :tag "Seconds")))

(defcustom agent-shell-gc-idle-worktree-ttl nil
  "Seconds of inactivity after which an idle git worktree is removed.
Nil disables worktree collection, which is the default.

A worktree is only ever considered once it holds no live sessions, so a
value below `agent-shell-gc-idle-session-ttl' cannot make worktrees go
first: the sessions must be collected before their worktree is."
  :type '(choice (const :tag "Never" nil) (integer :tag "Seconds")))

(defcustom agent-shell-gc-poll-interval 60
  "Seconds between sweeps."
  :type 'integer)

(defcustom agent-shell-gc-grace 300
  "Seconds for which collection is suppressed after a discontinuity.
A discontinuity is enabling the mode, a Desktop restore, or a wall-clock
jump much larger than `agent-shell-gc-poll-interval' (a suspended
machine).  Without this, restoring a long-idle session would kill it
moments later, and waking a laptop would reap everything at once.

Activity tracking continues throughout; only destruction is held."
  :type 'integer)

(defcustom agent-shell-gc-session-protect-functions
  (list #'agent-shell-gc-protect-busy-p
        #'agent-shell-gc-protect-visible-p
        #'agent-shell-gc-protect-pending-input-p
        #'agent-shell-gc-protect-kept-p)
  "Predicates that veto killing a session.
Each is called with the shell buffer; any non-nil return protects it.

Sessions blocked on a permission response are deliberately not protected
by default: a permission prompt nobody answered for a whole TTL is the
stale case this package exists to collect.  Add a predicate to opt out."
  :type 'hook)

(defcustom agent-shell-gc-worktree-scope 'registered
  "Which worktrees may be collected.

`registered'   Only worktrees we have observed a session running in.
`agent-shell'  Also worktrees under the directory
               `agent-shell-dot-subdir-function' resolves \"worktrees\" to.
`linked'       Any linked worktree of a repository we know about.
FUNCTION       Called with the worktree entry alist; non-nil to allow.

`registered' is the default because a worktree's location cannot be
inferred from its path: the base directory is configurable via
`agent-shell-dot-subdir-function' and is only a default in the prompt
`agent-shell-new-worktree-shell' offers, so any worktree may live
anywhere.  Recording what we saw is the only reliable signal."
  :type '(choice (const :tag "Seen a session in it" registered)
                 (const :tag "Also agent-shell's worktrees directory" agent-shell)
                 (const :tag "Any linked worktree" linked)
                 (function :tag "Custom predicate")))

(defcustom agent-shell-gc-worktree-dirty-action 'skip
  "What to do with a worktree holding uncommitted or unmerged work.

`skip'   Leave it alone and warn once.  The default.
`force'  Remove it anyway, discarding the work."
  :type '(choice (const :tag "Skip and warn" skip)
                 (const :tag "Remove anyway" force)))

(defcustom agent-shell-gc-worktree-activity-function nil
  "Function returning extra last-activity time for a worktree, or nil.
Called with the worktree directory; must return a `float-time' or nil.
Its value is folded into the recorded activity, so a larger value defers
collection.

Use this to derive activity from the filesystem, since edits made outside
Emacs are otherwise invisible to this package."
  :type '(choice (const :tag "None" nil) function))

(defcustom agent-shell-gc-delete-worktree-branch nil
  "When non-nil, also delete the branch a collected worktree checked out.
Uses \"git branch -d\", never \"-d --force\", so an unmerged branch
survives even with this enabled."
  :type 'boolean)

(defcustom agent-shell-gc-dry-run nil
  "When non-nil, log what would be collected but destroy nothing."
  :type 'boolean)

(defcustom agent-shell-gc-notify-function #'agent-shell-gc-log
  "Function called with a format string and arguments to report activity."
  :type 'function)

(defcustom agent-shell-gc-store-file
  (locate-user-emacs-file "agent-shell-gc/state.eld")
  "File holding recorded session and worktree activity."
  :type 'file)

(defconst agent-shell-gc-log-buffer-name "*agent-shell-gc*"
  "Name of the buffer `agent-shell-gc-log' writes to.")

;;;; State

(defvar agent-shell-gc--sessions (make-hash-table :test 'equal)
  "Hash of (AGENT-CONFIG-ID . SESSION-ID) to a session entry alist.
Entry keys: `:last-activity', `:directory', `:buffer-name'.")

(defvar agent-shell-gc--worktrees (make-hash-table :test 'equal)
  "Hash of worktree directory to a worktree entry alist.
Entry keys: `:first-seen', `:last-activity', `:repo', `:branch',
`:origin' and `:warned'.")

(defvar agent-shell-gc--worktree-cache (make-hash-table :test 'equal)
  "Hash of directory to its resolved worktree plist, or `none'.")

(defvar agent-shell-gc--timer nil
  "The sweeper timer.")

(defvar agent-shell-gc--save-timer nil
  "One-shot timer debouncing writes to `agent-shell-gc-store-file'.")

(defvar agent-shell-gc--store-loaded nil
  "Non-nil once the store has been read from disk.")

(defvar agent-shell-gc--last-tick nil
  "`float-time' of the previous sweep, for detecting wall-clock jumps.")

(defvar agent-shell-gc--grace-until 0
  "Collection is suppressed until this `float-time'.")

(defvar-local agent-shell-gc--activity nil
  "`float-time' of this buffer's last activity in this Emacs session.
Nil when there has been none, which is not the same as \"long ago\": a
Desktop-restored session starts nil and falls back to its stored time.")

(defvar-local agent-shell-gc--keep nil
  "When non-nil, this session is never collected.")

(defvar-local agent-shell-gc--subscription nil
  "This buffer's `agent-shell-subscribe-to' token.")

(defvar-local agent-shell-gc--replaying t
  "Non-nil while a session is initializing or replaying its history.
Events emitted during a `session/load' replay describe old activity, not
new, so stamping them would give every Desktop-restored session a fresh
clock and stop worktrees from ever being collected.")

;;;; Logging

(defun agent-shell-gc-log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to the log buffer."
  (with-current-buffer (get-buffer-create agent-shell-gc-log-buffer-name)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "[%F %T] ")
              (apply #'format format-string args)
              "\n"))
    (unless (derived-mode-p 'special-mode)
      (special-mode))))

(defun agent-shell-gc--notify (format-string &rest args)
  "Report FORMAT-STRING formatted with ARGS via the notify function."
  (when (functionp agent-shell-gc-notify-function)
    (apply agent-shell-gc-notify-function format-string args)))

(defun agent-shell-gc--format-duration (seconds)
  "Return SECONDS as a compact human-readable duration."
  (let ((seconds (max 0 (truncate (or seconds 0)))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh%02dm" (/ seconds 3600)
                                     (/ (% seconds 3600) 60)))
          (t (format "%dd%02dh" (/ seconds 86400)
                     (/ (% seconds 86400) 3600))))))

;;;; Store

(defun agent-shell-gc--load-store ()
  "Read the store from `agent-shell-gc-store-file'."
  (setq agent-shell-gc--store-loaded t)
  (clrhash agent-shell-gc--sessions)
  (clrhash agent-shell-gc--worktrees)
  (when (file-readable-p agent-shell-gc-store-file)
    (condition-case err
        (let ((store (with-temp-buffer
                       (insert-file-contents agent-shell-gc-store-file)
                       (read (current-buffer)))))
          (pcase-dolist (`(,key . ,entry) (map-elt store :sessions))
            (puthash key entry agent-shell-gc--sessions))
          (pcase-dolist (`(,key . ,entry) (map-elt store :worktrees))
            (puthash key entry agent-shell-gc--worktrees)))
      (error
       (agent-shell-gc--notify "could not read %s: %s"
                               agent-shell-gc-store-file
                               (error-message-string err))))))

(defun agent-shell-gc--save-store ()
  "Write the store to `agent-shell-gc-store-file'."
  (when agent-shell-gc--store-loaded
    (condition-case err
        (let ((store (list (cons :version 1)
                           (cons :sessions (map-pairs agent-shell-gc--sessions))
                           (cons :worktrees (map-pairs agent-shell-gc--worktrees)))))
          (make-directory (file-name-directory agent-shell-gc-store-file) t)
          (with-temp-file agent-shell-gc-store-file
            (let ((print-length nil)
                  (print-level nil))
              (prin1 store (current-buffer))
              (insert "\n"))))
      (error
       (agent-shell-gc--notify "could not write %s: %s"
                               agent-shell-gc-store-file
                               (error-message-string err))))))

(defun agent-shell-gc--schedule-save ()
  "Write the store out shortly, coalescing bursts of changes."
  (when (timerp agent-shell-gc--save-timer)
    (cancel-timer agent-shell-gc--save-timer))
  (setq agent-shell-gc--save-timer
        (run-with-idle-timer 5 nil #'agent-shell-gc--save-store)))

;;;; Buffers and sessions

(defun agent-shell-gc--shell-buffer (buffer)
  "Return the agent shell BUFFER belongs to, or nil.
A viewport buffer resolves to the shell it is viewing, so reading or
composing in one counts as activity on the session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cond ((derived-mode-p 'agent-shell-mode)
             buffer)
            ((and (or (derived-mode-p 'agent-shell-viewport-view-mode)
                      (derived-mode-p 'agent-shell-viewport-edit-mode))
                  (fboundp 'agent-shell-viewport--shell-buffer))
             (agent-shell-viewport--shell-buffer buffer))))))

(defun agent-shell-gc--session-key (buffer)
  "Return BUFFER's (AGENT-CONFIG-ID . SESSION-ID) key, or nil.

AGENT-CONFIG-ID names the agent backend (`claude-code', `codex',
`gemini-cli', ...).  It is part of the key because ACP session ids are
minted by each agent independently and are therefore unique only
per-backend.  This is also the pair `agent-shell-desktop' matches a
restored buffer on.

Nil while a session id has not been assigned yet, which makes such a
shell untracked, which is fine: it is too young to collect anyway."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (when-let* ((state (agent-shell--state))
                    (session-id (map-nested-elt state '(:session :id)))
                    (agent-config-id (map-nested-elt state '(:agent-config :identifier))))
          (cons agent-config-id session-id))))))

(defun agent-shell-gc--session-activity (key)
  "Return the stored last-activity time for session KEY, or nil."
  (when key
    (map-elt (gethash key agent-shell-gc--sessions) :last-activity)))

(defun agent-shell-gc--record-session (key time buffer)
  "Record TIME as session KEY's last activity, described by BUFFER."
  (puthash key
           (list (cons :last-activity time)
                 (cons :directory (buffer-local-value 'default-directory buffer))
                 (cons :buffer-name (buffer-name buffer)))
           agent-shell-gc--sessions)
  (agent-shell-gc--schedule-save))

(defun agent-shell-gc--latest (stamp stored)
  "Return the more recent of in-memory STAMP and persisted STORED, or nil.
Either may be nil: a session with no activity this Emacs session falls
back to its stored time, which is how a Desktop-restored buffer keeps
the clock it had before the restart."
  (cond ((and stamp stored) (max stamp stored))
        (stamp)
        (stored)))

(defun agent-shell-gc--idle (buffer)
  "Return how many seconds BUFFER has been idle."
  (if-let* ((latest (agent-shell-gc--latest
                     (buffer-local-value 'agent-shell-gc--activity buffer)
                     (agent-shell-gc--session-activity
                      (agent-shell-gc--session-key buffer)))))
      (- (float-time) latest)
    0))

;;;; Activity tracking

(defun agent-shell-gc--stamp (&optional buffer)
  "Record now as the last activity of BUFFER's shell."
  (when-let* ((shell (agent-shell-gc--shell-buffer (or buffer (current-buffer)))))
    (with-current-buffer shell
      (setq agent-shell-gc--activity (float-time)))))

(defun agent-shell-gc--stamp-typing ()
  "Record typing in the current buffer, unless it is still replaying."
  (unless (buffer-local-value 'agent-shell-gc--replaying (current-buffer))
    (agent-shell-gc--stamp)))

(defun agent-shell-gc--on-event (event)
  "Record EVENT as activity on the current shell.

Events are ignored while the session is initializing or replaying
history, since a `session/load' replay re-emits old output and would
otherwise make every restored session look freshly active.
`input-submitted' is always honoured, since it can only come from the user."
  (let ((name (map-elt event :event)))
    (pcase name
      ((or 'prompt-ready 'session-restored 'init-finished 'input-submitted)
       (setq agent-shell-gc--replaying nil))
      (_ nil))
    (cond ((eq name 'clean-up)
           (agent-shell-gc--flush-buffer))
          ((or (eq name 'input-submitted) (not agent-shell-gc--replaying))
           (agent-shell-gc--stamp)))))

(defun agent-shell-gc--flush-buffer ()
  "Write the current shell's activity to the store before it goes away."
  (when-let* ((key (agent-shell-gc--session-key (current-buffer)))
              (stamp agent-shell-gc--activity))
    (agent-shell-gc--record-session key stamp (current-buffer))))

(defun agent-shell-gc--setup-buffer ()
  "Track the current agent shell buffer.
Installed on `agent-shell-mode-hook', which runs once buffer state is
available."
  (when (and agent-shell-gc-mode (derived-mode-p 'agent-shell-mode))
    (setq agent-shell-gc--replaying t)
    (add-hook 'post-command-hook #'agent-shell-gc--stamp-typing nil t)
    (add-hook 'kill-buffer-hook #'agent-shell-gc--flush-buffer nil t)
    (unless agent-shell-gc--subscription
      (setq agent-shell-gc--subscription
            (agent-shell-subscribe-to :shell-buffer (current-buffer)
                                      :on-event #'agent-shell-gc--on-event)))
    (agent-shell-gc--register-worktree default-directory 'session)))

(defun agent-shell-gc--setup-viewport-buffer ()
  "Track typing in the current viewport buffer."
  (when agent-shell-gc-mode
    (add-hook 'post-command-hook #'agent-shell-gc--stamp-typing nil t)))

(defun agent-shell-gc--on-window-selection (&rest _)
  "Record the selected buffer as activity on its shell or worktree."
  (when agent-shell-gc-mode
    (if (agent-shell-gc--shell-buffer (current-buffer))
        (agent-shell-gc--stamp)
      (agent-shell-gc--touch-worktree-at default-directory))))

(defun agent-shell-gc--on-save ()
  "Record saving the current file as activity on its worktree."
  (when (and agent-shell-gc-mode buffer-file-name)
    (agent-shell-gc--touch-worktree-at (file-name-directory buffer-file-name))))

(defun agent-shell-gc--on-desktop-restore ()
  "Suppress collection for a while after Desktop restores buffers."
  (when agent-shell-gc-mode
    (agent-shell-gc--start-grace "desktop restore")))

;;;; Worktrees

(defun agent-shell-gc--normalize-dir (dir)
  "Return DIR as an absolute, symlink-resolved directory name.
Normalizing matters: on macOS a \"/tmp\" and a \"/private/tmp\" spelling
of the same worktree would otherwise become two entries, each of which
looks idle."
  (directory-file-name (file-truename (expand-file-name dir))))

(defun agent-shell-gc--git (dir &rest args)
  "Run git ARGS in DIR, returning trimmed output, or nil on failure."
  (when (and dir (file-directory-p dir) (executable-find "git"))
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory dir)))
        (when (zerop (apply #'process-file "git" nil t nil args))
          (string-trim (buffer-string)))))))

(defun agent-shell-gc--read-file (file)
  "Return the trimmed contents of FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (string-trim (buffer-string)))))

(defun agent-shell-gc--head-branch (gitdir)
  "Return the branch name GITDIR's HEAD points at, or nil when detached."
  (when-let* ((head (agent-shell-gc--read-file (expand-file-name "HEAD" gitdir)))
              ((string-match "\\`ref: refs/heads/\\(.+\\)\\'" head)))
    (match-string 1 head)))

(defun agent-shell-gc--resolve-worktree (dir)
  "Return a plist describing the worktree containing DIR, or nil.
Keys: `:worktree', `:repo', `:linked', `:branch' and `:gitdir'.

Reads git's on-disk layout directly: a main worktree has a `.git'
directory, a linked one a `.git' file naming its real gitdir, whose
`commondir' points back at the main repository."
  (when-let* ((root (ignore-errors (locate-dominating-file
                                    (file-name-as-directory (expand-file-name dir))
                                    ".git"))))
    (let* ((root (agent-shell-gc--normalize-dir root))
           (dot (expand-file-name ".git" root)))
      (if (file-directory-p dot)
          (list :worktree root :repo root :linked nil :gitdir dot
                :branch (agent-shell-gc--head-branch dot))
        (when-let* ((pointer (agent-shell-gc--read-file dot))
                    ((string-match "\\`gitdir: \\(.+\\)\\'" pointer))
                    (gitdir (expand-file-name (match-string 1 pointer) root)))
          (if-let* ((common (agent-shell-gc--read-file
                             (expand-file-name "commondir" gitdir))))
              (let ((commondir (expand-file-name common gitdir)))
                (list :worktree root
                      :repo (agent-shell-gc--normalize-dir
                             (file-name-directory (directory-file-name commondir)))
                      :linked t
                      :gitdir gitdir
                      :branch (agent-shell-gc--head-branch gitdir)))
            ;; A `.git' file without a commondir is a submodule, not a
            ;; worktree.  Never collectable.
            (list :worktree root :repo root :linked nil :gitdir gitdir
                  :branch (agent-shell-gc--head-branch gitdir))))))))

(defun agent-shell-gc--worktree-info (dir)
  "Return the worktree plist for DIR, or nil.  Cached per directory."
  (when dir
    (let ((cached (gethash dir agent-shell-gc--worktree-cache 'missing)))
      (cond ((eq cached 'missing)
             (let ((info (agent-shell-gc--resolve-worktree dir)))
               (puthash dir (or info 'none) agent-shell-gc--worktree-cache)
               info))
            ((eq cached 'none) nil)
            (t cached)))))

(defun agent-shell-gc--register-worktree (dir origin)
  "Register the linked worktree containing DIR with ORIGIN.  Return its key.

A first registration seeds last-activity from the gitdir's mtime rather
than from now, so installing this package does not hand every stale
worktree a fresh full TTL."
  (when-let* ((info (agent-shell-gc--worktree-info dir))
              ((plist-get info :linked))
              (key (plist-get info :worktree)))
    (unless (gethash key agent-shell-gc--worktrees)
      (let ((seeded (or (float-time
                         (file-attribute-modification-time
                          (file-attributes (plist-get info :gitdir))))
                        (float-time))))
        (puthash key
                 (list (cons :first-seen (float-time))
                       (cons :last-activity seeded)
                       (cons :repo (plist-get info :repo))
                       (cons :branch (plist-get info :branch))
                       (cons :origin origin))
                 agent-shell-gc--worktrees)
        (agent-shell-gc--schedule-save)))
    key))

(defun agent-shell-gc--touch-worktree (key time)
  "Record TIME as worktree KEY's last activity when it is more recent."
  (when-let* ((entry (gethash key agent-shell-gc--worktrees))
              (time)
              ((> time (or (map-elt entry :last-activity) 0))))
    (setf (map-elt entry :last-activity) time)
    (setf (map-elt entry :warned) nil)
    (puthash key entry agent-shell-gc--worktrees)
    (agent-shell-gc--schedule-save)))

(defun agent-shell-gc--touch-worktree-at (dir)
  "Record now as the last activity of the worktree containing DIR."
  (when-let* ((info (agent-shell-gc--worktree-info dir))
              ((plist-get info :linked))
              (key (plist-get info :worktree))
              ((gethash key agent-shell-gc--worktrees)))
    (agent-shell-gc--touch-worktree key (float-time))))

(defun agent-shell-gc--buffers-under (dir)
  "Return the live shell buffers whose working directory is under DIR."
  (let ((dir (file-name-as-directory dir)))
    (seq-filter (lambda (buffer)
                  (and (buffer-live-p buffer)
                       (file-in-directory-p
                        (buffer-local-value 'default-directory buffer) dir)))
                (agent-shell-buffers))))

(defun agent-shell-gc--dot-worktrees-dir (repo)
  "Return REPO's configured agent-shell worktrees directory, or nil."
  (when (functionp agent-shell-dot-subdir-function)
    (ignore-errors
      (let ((default-directory (file-name-as-directory repo)))
        (file-name-as-directory
         (funcall agent-shell-dot-subdir-function "worktrees"))))))

(defun agent-shell-gc--in-scope-p (dir entry)
  "Return non-nil when worktree DIR with ENTRY may be collected."
  (let ((registered (eq (map-elt entry :origin) 'session)))
    (pcase agent-shell-gc-worktree-scope
      ('registered registered)
      ('agent-shell (or registered
                        (when-let* ((worktrees (agent-shell-gc--dot-worktrees-dir
                                                (map-elt entry :repo))))
                          (file-in-directory-p dir worktrees))))
      ('linked t)
      ((and scope (pred functionp)) (funcall scope entry))
      (_ registered))))

(defun agent-shell-gc--discover-worktrees ()
  "Register linked worktrees of known repositories.
Only needed by the wider scopes; `registered' already has everything."
  (unless (eq agent-shell-gc-worktree-scope 'registered)
    (dolist (repo (seq-uniq (seq-keep (lambda (entry) (map-elt entry :repo))
                                      (map-values agent-shell-gc--worktrees))))
      (dolist (line (split-string (or (agent-shell-gc--git repo "worktree" "list"
                                                           "--porcelain")
                                      "")
                                  "\n" t))
        (when (string-prefix-p "worktree " line)
          (agent-shell-gc--register-worktree
           (substring line (length "worktree ")) 'discovered))))))

(defun agent-shell-gc--worktree-unsafe-reason (dir repo branch)
  "Return why worktree DIR holds work worth keeping, or nil.
Both uncommitted changes and commits unreachable from any other ref
count: an unmerged branch is work, not garbage."
  (let ((status (agent-shell-gc--git dir "status" "--porcelain")))
    (cond
     ((null status) "git status failed")
     ((not (string-empty-p status)) "uncommitted changes")
     (t
      (let ((head (agent-shell-gc--git dir "rev-parse" "HEAD")))
        (cond
         ((null head) nil)
         (t (let ((refs (agent-shell-gc--git repo "for-each-ref" "--contains" head
                                             "--format=%(refname)")))
              (cond
               ((null refs) "could not determine whether commits are merged")
               ((null (seq-remove
                       (lambda (ref)
                         (and branch (equal ref (concat "refs/heads/" branch))))
                       (split-string refs "\n" t)))
                "unmerged commits"))))))))))

;;;; Session protection

(defun agent-shell-gc-protect-busy-p (buffer)
  "Return non-nil when BUFFER's agent is mid-turn."
  (eq (ignore-errors (agent-shell-status :shell-buffer buffer)) 'busy))

(defun agent-shell-gc-protect-visible-p (buffer)
  "Return non-nil when BUFFER is on screen."
  (get-buffer-window buffer 'visible))

(defun agent-shell-gc-protect-pending-input-p (buffer)
  "Return non-nil when BUFFER has unsubmitted text at its prompt."
  (with-current-buffer buffer
    (when-let* ((prompt comint-last-prompt)
                (end (marker-position (cdr prompt)))
                ((<= end (point-max))))
      (not (string-empty-p
            (string-trim (buffer-substring-no-properties end (point-max))))))))

(defun agent-shell-gc-protect-kept-p (buffer)
  "Return non-nil when BUFFER was pinned with `agent-shell-gc-toggle-keep'."
  (buffer-local-value 'agent-shell-gc--keep buffer))

(defun agent-shell-gc--protected-by (buffer)
  "Return the predicate protecting BUFFER from collection, or nil."
  (seq-find (lambda (predicate)
              (ignore-errors (funcall predicate buffer)))
            agent-shell-gc-session-protect-functions))

;;;; Sweeping

(defun agent-shell-gc--start-grace (reason)
  "Suppress collection for `agent-shell-gc-grace' seconds because of REASON."
  (setq agent-shell-gc--grace-until (+ (float-time) agent-shell-gc-grace))
  (agent-shell-gc--notify "holding collection for %s (%s)"
                          (agent-shell-gc--format-duration agent-shell-gc-grace)
                          reason))

(defun agent-shell-gc--in-grace-p ()
  "Return non-nil while collection is suppressed."
  (< (float-time) agent-shell-gc--grace-until))

(defun agent-shell-gc--check-discontinuity (now)
  "Start a grace window when NOW is far past the previous sweep."
  (when (and agent-shell-gc--last-tick
             (> (- now agent-shell-gc--last-tick)
                (* 3 agent-shell-gc-poll-interval)))
    (agent-shell-gc--start-grace "clock jump")))

(defun agent-shell-gc--track ()
  "Fold live buffer activity into the store."
  (dolist (buffer (agent-shell-buffers))
    (when (buffer-live-p buffer)
      (let ((stamp (buffer-local-value 'agent-shell-gc--activity buffer))
            (key (agent-shell-gc--session-key buffer)))
        (when key
          ;; A session we have never seen starts its clock now; one we have
          ;; keeps the later of its two times.
          (agent-shell-gc--record-session
           key
           (or (agent-shell-gc--latest
                stamp (agent-shell-gc--session-activity key))
               (float-time))
           buffer))
        (when-let* ((dir (buffer-local-value 'default-directory buffer))
                    (worktree (agent-shell-gc--register-worktree dir 'session)))
          (agent-shell-gc--touch-worktree
           worktree (or stamp (agent-shell-gc--session-activity key)))))))
  (agent-shell-gc--prune))

(defun agent-shell-gc--prune ()
  "Drop store entries for worktrees that no longer exist."
  (let (gone)
    (maphash (lambda (dir _entry)
               (unless (file-directory-p dir)
                 (push dir gone)))
             agent-shell-gc--worktrees)
    (dolist (dir gone)
      (remhash dir agent-shell-gc--worktrees))
    (when gone
      (agent-shell-gc--schedule-save))))

(defun agent-shell-gc--sweep-sessions ()
  "Kill sessions idle past `agent-shell-gc-idle-session-ttl'."
  (when agent-shell-gc-idle-session-ttl
    (dolist (buffer (agent-shell-buffers))
      (when (and (buffer-live-p buffer)
                 (agent-shell-gc--session-key buffer)
                 (>= (agent-shell-gc--idle buffer) agent-shell-gc-idle-session-ttl))
        (if-let* ((protected (agent-shell-gc--protected-by buffer)))
            (agent-shell-gc--notify "keeping session %s: %s"
                                    (buffer-name buffer) protected)
          (agent-shell-gc--kill-session buffer))))))

(defun agent-shell-gc--kill-session (buffer)
  "Kill session BUFFER, releasing its ACP client and temporary directory."
  (let ((name (buffer-name buffer))
        (idle (agent-shell-gc--format-duration (agent-shell-gc--idle buffer))))
    (if agent-shell-gc-dry-run
        (agent-shell-gc--notify "would kill session %s (idle %s)" name idle)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))
      (agent-shell-gc--notify "killed session %s (idle %s)" name idle))))

(defun agent-shell-gc--sweep-worktrees ()
  "Remove worktrees idle past `agent-shell-gc-idle-worktree-ttl'.
A worktree holding live sessions is never a candidate, so a worktree TTL
below the session TTL cannot collect one before its sessions are gone."
  (when agent-shell-gc-idle-worktree-ttl
    (agent-shell-gc--discover-worktrees)
    (let ((now (float-time)))
      (dolist (dir (map-keys agent-shell-gc--worktrees))
        (when-let* ((entry (gethash dir agent-shell-gc--worktrees))
                    ((agent-shell-gc--in-scope-p dir entry))
                    ((null (agent-shell-gc--buffers-under dir)))
                    (activity (max (or (map-elt entry :last-activity) 0)
                                   (or (and agent-shell-gc-worktree-activity-function
                                            (ignore-errors
                                              (funcall agent-shell-gc-worktree-activity-function
                                                       dir)))
                                       0)))
                    ((>= (- now activity) agent-shell-gc-idle-worktree-ttl)))
          (agent-shell-gc--collect-worktree dir entry (- now activity)))))))

(defun agent-shell-gc--collect-worktree (dir entry idle)
  "Remove worktree DIR described by ENTRY, idle for IDLE seconds."
  (let* ((repo (map-elt entry :repo))
         (branch (map-elt entry :branch))
         (pretty (abbreviate-file-name dir))
         (idle (agent-shell-gc--format-duration idle))
         (unsafe (unless (eq agent-shell-gc-worktree-dirty-action 'force)
                   (agent-shell-gc--worktree-unsafe-reason dir repo branch))))
    (cond
     (unsafe
      (unless (map-elt entry :warned)
        (setf (map-elt entry :warned) t)
        (puthash dir entry agent-shell-gc--worktrees)
        (agent-shell-gc--schedule-save)
        (agent-shell-gc--notify "keeping worktree %s (idle %s): %s"
                                pretty idle unsafe)))
     (agent-shell-gc-dry-run
      (agent-shell-gc--notify "would remove worktree %s (idle %s)" pretty idle))
     (t
      (agent-shell-gc--git repo "worktree" "prune")
      (if (null (apply #'agent-shell-gc--git repo
                       (append '("worktree" "remove")
                               (when (eq agent-shell-gc-worktree-dirty-action 'force)
                                 '("--force"))
                               (list dir))))
          (agent-shell-gc--notify "could not remove worktree %s" pretty)
        (remhash dir agent-shell-gc--worktrees)
        (clrhash agent-shell-gc--worktree-cache)
        (agent-shell-gc--schedule-save)
        (agent-shell-gc--notify "removed worktree %s (idle %s)" pretty idle)
        (when (and agent-shell-gc-delete-worktree-branch branch)
          (if (agent-shell-gc--git repo "branch" "-d" branch)
              (agent-shell-gc--notify "deleted branch %s" branch)
            (agent-shell-gc--notify "kept branch %s (not merged)" branch))))))))

(defun agent-shell-gc--sweep ()
  "Run one sweep: track activity, then collect what has expired."
  (let ((now (float-time)))
    (agent-shell-gc--check-discontinuity now)
    (agent-shell-gc--track)
    (if (agent-shell-gc--in-grace-p)
        (setq agent-shell-gc--last-tick now)
      (agent-shell-gc--sweep-sessions)
      (agent-shell-gc--sweep-worktrees)
      (setq agent-shell-gc--last-tick now))))

;;;; Commands

;;;###autoload
(defun agent-shell-gc-now ()
  "Sweep immediately, ignoring any grace window."
  (interactive)
  (unless agent-shell-gc-mode
    (user-error "`agent-shell-gc-mode' is not enabled"))
  (setq agent-shell-gc--grace-until 0)
  (agent-shell-gc--sweep)
  (message "agent-shell-gc: swept"))

;;;###autoload
(defun agent-shell-gc-toggle-keep ()
  "Pin or unpin the current session, exempting it from collection."
  (interactive)
  (let ((shell (agent-shell-gc--shell-buffer (current-buffer))))
    (unless shell
      (user-error "Not in an agent shell"))
    (with-current-buffer shell
      (setq agent-shell-gc--keep (not agent-shell-gc--keep))
      (message "agent-shell-gc: %s %s"
               (if agent-shell-gc--keep "keeping" "no longer keeping")
               (buffer-name shell)))))

(defun agent-shell-gc--countdown (idle ttl)
  "Return a description of how long IDLE has left against TTL."
  (cond ((null ttl) "disabled")
        ((>= idle ttl) "due")
        (t (agent-shell-gc--format-duration (- ttl idle)))))

;;;###autoload
(defun agent-shell-gc-list ()
  "Show tracked sessions and worktrees with their idle times."
  (interactive)
  (unless agent-shell-gc--store-loaded
    (agent-shell-gc--load-store))
  (let ((buffer (get-buffer-create "*agent-shell-gc-list*"))
        (now (float-time)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Sessions (ttl %s)\n"
                        (if agent-shell-gc-idle-session-ttl
                            (agent-shell-gc--format-duration
                             agent-shell-gc-idle-session-ttl)
                          "disabled")))
        (dolist (shell (agent-shell-buffers))
          (let* ((idle (agent-shell-gc--idle shell))
                 (protected (agent-shell-gc--protected-by shell)))
            (insert (format "  %-40s idle %-8s %s\n"
                            (buffer-name shell)
                            (agent-shell-gc--format-duration idle)
                            (if protected
                                (format "kept: %s" protected)
                              (agent-shell-gc--countdown
                               idle agent-shell-gc-idle-session-ttl))))))
        (insert (format "\nWorktrees (ttl %s)\n"
                        (if agent-shell-gc-idle-worktree-ttl
                            (agent-shell-gc--format-duration
                             agent-shell-gc-idle-worktree-ttl)
                          "disabled")))
        (maphash
         (lambda (dir entry)
           (let ((idle (- now (or (map-elt entry :last-activity) now)))
                 (sessions (length (agent-shell-gc--buffers-under dir))))
             (insert (format "  %-40s idle %-8s %s\n"
                             (abbreviate-file-name dir)
                             (agent-shell-gc--format-duration idle)
                             (cond ((not (agent-shell-gc--in-scope-p dir entry))
                                    "out of scope")
                                   ((> sessions 0)
                                    (format "%d live session(s)" sessions))
                                   (t (agent-shell-gc--countdown
                                       idle agent-shell-gc-idle-worktree-ttl)))))))
         agent-shell-gc--worktrees)
        (when (agent-shell-gc--in-grace-p)
          (insert (format "\nCollection held for %s\n"
                          (agent-shell-gc--format-duration
                           (- agent-shell-gc--grace-until now)))))
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buffer
                    `((display-buffer-reuse-window
                       display-buffer-pop-up-window)
                      (inhibit-same-window . ,(not (eq (window-buffer) buffer)))))))

;;;; Mode

(defun agent-shell-gc--setup-existing-buffers ()
  "Track agent shells that already exist."
  (dolist (buffer (agent-shell-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (agent-shell-gc--setup-buffer)))))

(defun agent-shell-gc--enable ()
  "Install hooks and start the sweeper."
  (agent-shell-gc--load-store)
  (add-hook 'agent-shell-mode-hook #'agent-shell-gc--setup-buffer)
  (add-hook 'agent-shell-viewport-view-mode-hook #'agent-shell-gc--setup-viewport-buffer)
  (add-hook 'agent-shell-viewport-edit-mode-hook #'agent-shell-gc--setup-viewport-buffer)
  (add-hook 'window-selection-change-functions #'agent-shell-gc--on-window-selection)
  (add-hook 'after-save-hook #'agent-shell-gc--on-save)
  (add-hook 'desktop-after-read-hook #'agent-shell-gc--on-desktop-restore)
  (add-hook 'kill-emacs-hook #'agent-shell-gc--save-store)
  (agent-shell-gc--setup-existing-buffers)
  (setq agent-shell-gc--last-tick nil)
  (agent-shell-gc--start-grace "mode enabled")
  (setq agent-shell-gc--timer
        (run-with-timer agent-shell-gc-poll-interval
                        agent-shell-gc-poll-interval
                        #'agent-shell-gc--sweep)))

(defun agent-shell-gc--disable ()
  "Remove hooks and stop the sweeper."
  (remove-hook 'agent-shell-mode-hook #'agent-shell-gc--setup-buffer)
  (remove-hook 'agent-shell-viewport-view-mode-hook #'agent-shell-gc--setup-viewport-buffer)
  (remove-hook 'agent-shell-viewport-edit-mode-hook #'agent-shell-gc--setup-viewport-buffer)
  (remove-hook 'window-selection-change-functions #'agent-shell-gc--on-window-selection)
  (remove-hook 'after-save-hook #'agent-shell-gc--on-save)
  (remove-hook 'desktop-after-read-hook #'agent-shell-gc--on-desktop-restore)
  (remove-hook 'kill-emacs-hook #'agent-shell-gc--save-store)
  (dolist (buffer (agent-shell-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (remove-hook 'post-command-hook #'agent-shell-gc--stamp-typing t)
        (remove-hook 'kill-buffer-hook #'agent-shell-gc--flush-buffer t)
        (when agent-shell-gc--subscription
          (agent-shell-unsubscribe :subscription agent-shell-gc--subscription)
          (setq agent-shell-gc--subscription nil)))))
  (when (timerp agent-shell-gc--timer)
    (cancel-timer agent-shell-gc--timer))
  (setq agent-shell-gc--timer nil)
  (agent-shell-gc--save-store))

;;;###autoload
(define-minor-mode agent-shell-gc-mode
  "Collect idle `agent-shell' sessions and the worktrees they leave behind.

Nothing is collected until `agent-shell-gc-idle-session-ttl' or
`agent-shell-gc-idle-worktree-ttl' is set; enabling this mode alone only
starts recording activity."
  :global t
  :group 'agent-shell-gc
  (if agent-shell-gc-mode
      (agent-shell-gc--enable)
    (agent-shell-gc--disable)))

(provide 'agent-shell-gc)

;;; agent-shell-gc.el ends here
