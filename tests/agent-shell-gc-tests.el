;;; agent-shell-gc-tests.el --- Tests for agent-shell-gc -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Worktree tests run against real git repositories created in a temporary
;; directory, so git's on-disk layout is exercised rather than described.

;;; Code:

(require 'ert)
(require 'agent-shell-gc)

(defvar agent-shell-gc-tests--repo nil
  "Root of the repository built by `agent-shell-gc-tests--with-repo'.")

(defun agent-shell-gc-tests--git (dir &rest args)
  "Run git ARGS in DIR, failing the test when git does."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "git %s failed in %s: %s" (string-join args " ") dir
               (string-trim (buffer-string)))))))

(defun agent-shell-gc-tests--build-repo (root)
  "Populate ROOT with a repository and three linked worktrees.

  clean-turing     clean tree, one commit no other ref contains
  dirty-hopper     an untracked file
  outside-lovelace clean, at the main branch's tip, outside the repo"
  (let ((main (expand-file-name "main" root)))
    (make-directory main t)
    (agent-shell-gc-tests--git main "init" "-q")
    (agent-shell-gc-tests--git main "config" "user.email" "test@example.com")
    (agent-shell-gc-tests--git main "config" "user.name" "Test")
    (agent-shell-gc-tests--git main "config" "commit.gpgsign" "false")
    (write-region "hello\n" nil (expand-file-name "file.txt" main))
    (agent-shell-gc-tests--git main "add" "file.txt")
    (agent-shell-gc-tests--git main "commit" "-qm" "init")
    (agent-shell-gc-tests--git main "worktree" "add" "-q"
                               ".agent-shell/worktrees/clean-turing"
                               "-b" "clean-turing")
    (agent-shell-gc-tests--git main "worktree" "add" "-q"
                               ".agent-shell/worktrees/dirty-hopper"
                               "-b" "dirty-hopper")
    (agent-shell-gc-tests--git main "worktree" "add" "-q"
                               (expand-file-name "outside-lovelace" root)
                               "-b" "outside-lovelace")
    (write-region "scratch\n" nil
                  (expand-file-name ".agent-shell/worktrees/dirty-hopper/new.txt" main))
    (let ((clean (expand-file-name ".agent-shell/worktrees/clean-turing" main)))
      (write-region "more\n" nil (expand-file-name "file.txt" clean))
      (agent-shell-gc-tests--git clean "commit" "-qam" "unmerged work"))
    main))

(defmacro agent-shell-gc-tests--with-repo (&rest body)
  "Run BODY with `agent-shell-gc-tests--repo' bound to a fresh repository.
The store, registry and caches are isolated per test."
  (declare (indent 0))
  `(let* ((root (make-temp-file "agent-shell-gc-tests" t))
          (agent-shell-gc-tests--repo (agent-shell-gc-tests--build-repo root))
          (agent-shell-gc--sessions (make-hash-table :test 'equal))
          (agent-shell-gc--worktrees (make-hash-table :test 'equal))
          (agent-shell-gc--worktree-cache (make-hash-table :test 'equal))
          (agent-shell-gc--store-loaded t)
          (agent-shell-gc-store-file (expand-file-name "state.eld" root))
          (agent-shell-gc-notify-function #'ignore))
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defun agent-shell-gc-tests--worktree (name)
  "Return the normalized path of worktree NAME in the test repository."
  (agent-shell-gc--normalize-dir
   (if (equal name "outside-lovelace")
       (expand-file-name "../outside-lovelace" agent-shell-gc-tests--repo)
     (expand-file-name (concat ".agent-shell/worktrees/" name)
                       agent-shell-gc-tests--repo))))

;;; Worktree resolution

(ert-deftest agent-shell-gc-resolve-linked-worktree-test ()
  "A linked worktree resolves to itself, its repository and its branch."
  (agent-shell-gc-tests--with-repo
    (let ((info (agent-shell-gc--worktree-info
                 (agent-shell-gc-tests--worktree "clean-turing"))))
      (should (plist-get info :linked))
      (should (equal (plist-get info :branch) "clean-turing"))
      (should (equal (plist-get info :worktree)
                     (agent-shell-gc-tests--worktree "clean-turing")))
      (should (equal (plist-get info :repo)
                     (agent-shell-gc--normalize-dir agent-shell-gc-tests--repo))))))

(ert-deftest agent-shell-gc-resolve-main-worktree-test ()
  "A main worktree is resolved but never reported as linked."
  (agent-shell-gc-tests--with-repo
    (let ((info (agent-shell-gc--worktree-info agent-shell-gc-tests--repo)))
      (should info)
      (should-not (plist-get info :linked)))))

(ert-deftest agent-shell-gc-resolve-outside-repository-test ()
  "A directory in no repository resolves to nothing."
  (agent-shell-gc-tests--with-repo
    (should-not (agent-shell-gc--worktree-info temporary-file-directory))))

(ert-deftest agent-shell-gc-resolve-retries-after-worktree-appears-test ()
  "A directory outside any repository resolves once it becomes a worktree.
An agent shell regularly reaches its directory before `git worktree add'
has populated it, so a failed resolution must not be remembered."
  (agent-shell-gc-tests--with-repo
    (let ((dir (expand-file-name "../late-noether" agent-shell-gc-tests--repo)))
      (should-not (agent-shell-gc--worktree-info dir))
      (agent-shell-gc-tests--git agent-shell-gc-tests--repo
                                 "worktree" "add" "-q" dir "-b" "late-noether")
      (should (plist-get (agent-shell-gc--worktree-info dir) :linked))
      (should (equal (agent-shell-gc--register-worktree dir 'session)
                     (agent-shell-gc--normalize-dir dir))))))

(ert-deftest agent-shell-gc-resolve-retries-inside-repository-test ()
  "A path inside the main checkout resolves once it becomes a worktree.
Probed early it resolves to the enclosing main worktree, which must not
be remembered as DIR's own answer: this is where `agent-shell' puts its
worktrees, so caching it would hide every one of them."
  (agent-shell-gc-tests--with-repo
    (let ((dir (expand-file-name ".agent-shell/worktrees/late-noether"
                                 agent-shell-gc-tests--repo)))
      (should-not (plist-get (agent-shell-gc--worktree-info dir) :linked))
      (agent-shell-gc-tests--git agent-shell-gc-tests--repo
                                 "worktree" "add" "-q" dir "-b" "late-noether")
      (should (plist-get (agent-shell-gc--worktree-info dir) :linked))
      (should (equal (agent-shell-gc--register-worktree dir 'session)
                     (agent-shell-gc--normalize-dir dir))))))

(ert-deftest agent-shell-gc-resolve-normalizes-symlinked-paths-test ()
  "Two spellings of one worktree share a single cache entry.
Without this, a \"/tmp\" and a \"/private/tmp\" spelling on macOS become
two entries that each look idle."
  (agent-shell-gc-tests--with-repo
    (let* ((dir (expand-file-name "../outside-lovelace" agent-shell-gc-tests--repo))
           (resolved (expand-file-name (file-truename dir))))
      (should (equal (plist-get (agent-shell-gc--worktree-info dir) :worktree)
                     (plist-get (agent-shell-gc--worktree-info resolved) :worktree)))
      (should (equal (hash-table-count agent-shell-gc--worktree-cache) 1)))))

;;; Safety

(ert-deftest agent-shell-gc-uncommitted-changes-are-unsafe-test ()
  "A worktree with an untracked file holds work."
  (agent-shell-gc-tests--with-repo
    (should (equal (agent-shell-gc--worktree-unsafe-reason
                    (agent-shell-gc-tests--worktree "dirty-hopper")
                    agent-shell-gc-tests--repo "dirty-hopper")
                   "uncommitted changes"))))

(ert-deftest agent-shell-gc-unmerged-commits-are-unsafe-test ()
  "A clean worktree whose commit no other ref contains holds work."
  (agent-shell-gc-tests--with-repo
    (should (equal (agent-shell-gc--worktree-unsafe-reason
                    (agent-shell-gc-tests--worktree "clean-turing")
                    agent-shell-gc-tests--repo "clean-turing")
                   "unmerged commits"))))

(ert-deftest agent-shell-gc-merged-clean-worktree-is-safe-test ()
  "A clean worktree at a commit another branch contains is collectable."
  (agent-shell-gc-tests--with-repo
    (should-not (agent-shell-gc--worktree-unsafe-reason
                 (agent-shell-gc-tests--worktree "outside-lovelace")
                 agent-shell-gc-tests--repo "outside-lovelace"))))

;;; Registry

(ert-deftest agent-shell-gc-register-linked-worktree-test ()
  "Registering a linked worktree records it once, keyed by its true name."
  (agent-shell-gc-tests--with-repo
    (let ((key (agent-shell-gc--register-worktree
                (agent-shell-gc-tests--worktree "clean-turing") 'session)))
      (should (equal key (agent-shell-gc-tests--worktree "clean-turing")))
      (should (eq (map-elt (gethash key agent-shell-gc--worktrees) :origin) 'session))
      (agent-shell-gc--register-worktree key 'session)
      (should (= (hash-table-count agent-shell-gc--worktrees) 1)))))

(ert-deftest agent-shell-gc-register-ignores-main-worktree-test ()
  "A main worktree is never registered, so it can never be collected."
  (agent-shell-gc-tests--with-repo
    (should-not (agent-shell-gc--register-worktree agent-shell-gc-tests--repo 'session))
    (should (= (hash-table-count agent-shell-gc--worktrees) 0))))

(ert-deftest agent-shell-gc-register-seeds-activity-from-gitdir-test ()
  "A first registration seeds activity from disk rather than from now.
Otherwise installing this package hands every stale worktree a fresh TTL."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "clean-turing") 'session))
           (seeded (map-elt (gethash key agent-shell-gc--worktrees) :last-activity)))
      (should seeded)
      (should (<= seeded (float-time))))))

(ert-deftest agent-shell-gc-touch-worktree-only-moves-forward-test ()
  "Recording activity never rewinds a worktree's clock."
  (agent-shell-gc-tests--with-repo
    (let ((key (agent-shell-gc--register-worktree
                (agent-shell-gc-tests--worktree "clean-turing") 'session)))
      (agent-shell-gc--touch-worktree key (+ (float-time) 100))
      (agent-shell-gc--touch-worktree key (+ (float-time) 50))
      (should (> (map-elt (gethash key agent-shell-gc--worktrees) :last-activity)
                 (+ (float-time) 90))))))

(ert-deftest agent-shell-gc-prune-drops-vanished-worktrees-test ()
  "A worktree removed behind our back leaves no registry entry."
  (agent-shell-gc-tests--with-repo
    (let ((key (agent-shell-gc--register-worktree
                (agent-shell-gc-tests--worktree "dirty-hopper") 'session)))
      (delete-directory key t)
      (agent-shell-gc--prune)
      (should-not (gethash key agent-shell-gc--worktrees)))))

;;; Scope

(ert-deftest agent-shell-gc-scope-registered-excludes-discovered-test ()
  "The default scope collects only worktrees we saw a session in."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "clean-turing") 'discovered))
           (entry (gethash key agent-shell-gc--worktrees))
           (agent-shell-gc-worktree-scope 'registered))
      (should-not (agent-shell-gc--in-scope-p key entry))
      (setf (map-elt entry :origin) 'session)
      (should (agent-shell-gc--in-scope-p key entry)))))

(ert-deftest agent-shell-gc-scope-linked-includes-discovered-test ()
  "The `linked' scope collects any linked worktree we know about."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "clean-turing") 'discovered))
           (entry (gethash key agent-shell-gc--worktrees))
           (agent-shell-gc-worktree-scope 'linked))
      (should (agent-shell-gc--in-scope-p key entry)))))

(ert-deftest agent-shell-gc-scope-accepts-custom-predicate-test ()
  "A function scope decides from the worktree entry."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "clean-turing") 'session))
           (entry (gethash key agent-shell-gc--worktrees))
           (agent-shell-gc-worktree-scope
            (lambda (candidate) (equal (map-elt candidate :branch) "clean-turing"))))
      (should (agent-shell-gc--in-scope-p key entry)))))

(ert-deftest agent-shell-gc-discovery-finds-sibling-worktrees-test ()
  "Wider scopes enumerate the other worktrees of a known repository."
  (agent-shell-gc-tests--with-repo
    (let ((agent-shell-gc-worktree-scope 'linked))
      (agent-shell-gc--register-worktree
       (agent-shell-gc-tests--worktree "clean-turing") 'session)
      (agent-shell-gc--discover-worktrees)
      (should (= (hash-table-count agent-shell-gc--worktrees) 3)))))

(ert-deftest agent-shell-gc-discovery-skipped-for-registered-scope-test ()
  "The default scope has nothing to discover, so it does not look."
  (agent-shell-gc-tests--with-repo
    (agent-shell-gc--register-worktree
     (agent-shell-gc-tests--worktree "clean-turing") 'session)
    (agent-shell-gc--discover-worktrees)
    (should (= (hash-table-count agent-shell-gc--worktrees) 1))))

;;; Collection

(ert-deftest agent-shell-gc-collect-removes-idle-worktree-test ()
  "An idle, clean, merged worktree is removed from disk and registry."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "outside-lovelace") 'session))
           (entry (gethash key agent-shell-gc--worktrees)))
      (agent-shell-gc--collect-worktree key entry 99999)
      (should-not (file-directory-p key))
      (should-not (gethash key agent-shell-gc--worktrees)))))

(ert-deftest agent-shell-gc-collect-keeps-worktree-holding-work-test ()
  "Dirty and unmerged worktrees survive collection and stay registered."
  (agent-shell-gc-tests--with-repo
    (dolist (name '("dirty-hopper" "clean-turing"))
      (let* ((key (agent-shell-gc--register-worktree
                   (agent-shell-gc-tests--worktree name) 'session))
             (entry (gethash key agent-shell-gc--worktrees)))
        (agent-shell-gc--collect-worktree key entry 99999)
        (should (file-directory-p key))
        (should (gethash key agent-shell-gc--worktrees))))))

(ert-deftest agent-shell-gc-collect-warns-once-per-worktree-test ()
  "A worktree holding work is reported once, not on every sweep."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "dirty-hopper") 'session))
           (notices 0)
           (agent-shell-gc-notify-function
            (lambda (&rest _) (setq notices (1+ notices)))))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should (= notices 1)))))

(ert-deftest agent-shell-gc-activity-clears-the-warning-test ()
  "New activity re-arms the warning, so a recurrence is reported again."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "dirty-hopper") 'session))
           (notices 0)
           (agent-shell-gc-notify-function
            (lambda (&rest _) (setq notices (1+ notices)))))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (agent-shell-gc--touch-worktree key (float-time))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should (= notices 2)))))

(ert-deftest agent-shell-gc-dry-run-destroys-nothing-test ()
  "A dry run reports a collection it does not perform."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "outside-lovelace") 'session))
           (agent-shell-gc-dry-run t))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should (file-directory-p key))
      (should (gethash key agent-shell-gc--worktrees)))))

(ert-deftest agent-shell-gc-force-removes-dirty-worktree-test ()
  "`force' discards uncommitted work instead of skipping it."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "dirty-hopper") 'session))
           (agent-shell-gc-worktree-dirty-action 'force))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should-not (file-directory-p key)))))

(ert-deftest agent-shell-gc-keeps-unmerged-branch-test ()
  "Branch deletion refuses an unmerged branch even when enabled."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "clean-turing") 'session))
           (agent-shell-gc-worktree-dirty-action 'force)
           (agent-shell-gc-delete-worktree-branch t))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should-not (file-directory-p key))
      (should (agent-shell-gc--git agent-shell-gc-tests--repo
                                   "rev-parse" "--verify" "refs/heads/clean-turing")))))

(ert-deftest agent-shell-gc-deletes-merged-branch-test ()
  "Branch deletion removes a branch another ref already contains."
  (agent-shell-gc-tests--with-repo
    (let* ((key (agent-shell-gc--register-worktree
                 (agent-shell-gc-tests--worktree "outside-lovelace") 'session))
           (agent-shell-gc-delete-worktree-branch t))
      (agent-shell-gc--collect-worktree key (gethash key agent-shell-gc--worktrees) 99999)
      (should-not (agent-shell-gc--git agent-shell-gc-tests--repo
                                       "rev-parse" "--verify"
                                       "refs/heads/outside-lovelace")))))

;;; Store

(ert-deftest agent-shell-gc-store-round-trip-test ()
  "Sessions and worktrees survive a write and read of the store."
  (agent-shell-gc-tests--with-repo
    (let ((key (agent-shell-gc--register-worktree
                (agent-shell-gc-tests--worktree "clean-turing") 'session)))
      (agent-shell-gc--record-session '(claude-code . "session-abc") 1000.5
                                      (current-buffer))
      (agent-shell-gc--save-store)
      (agent-shell-gc--load-store)
      (should (= (agent-shell-gc--session-activity '(claude-code . "session-abc"))
                 1000.5))
      (should (gethash key agent-shell-gc--worktrees)))))

(ert-deftest agent-shell-gc-store-survives-corruption-test ()
  "An unreadable store leaves empty tables rather than an error."
  (agent-shell-gc-tests--with-repo
    (write-region "((((" nil agent-shell-gc-store-file)
    (agent-shell-gc--load-store)
    (should (= (hash-table-count agent-shell-gc--sessions) 0))))

;;; Activity

(ert-deftest agent-shell-gc-stamp-records-on-the-shell-test ()
  "Activity lands on the shell, not on the buffer reporting it.
Typing in a viewport is activity on the session it composes for."
  (let ((shell (generate-new-buffer "agent-shell-gc-tests-shell")))
    (unwind-protect
        (with-temp-buffer
          (agent-shell-gc--stamp shell)
          (should-not agent-shell-gc--activity)
          (should (buffer-local-value 'agent-shell-gc--activity shell)))
      (kill-buffer shell))))

;;; Events

(ert-deftest agent-shell-gc-settling-events-are-not-activity-test ()
  "The events a session settles with end the replay window silently.
A Desktop restore emits them for every session it brings back, so
stamping any one resets every session's idle clock on an Emacs restart."
  (dolist (name agent-shell-gc--settling-events)
    (with-temp-buffer
      (setq agent-shell-gc--replaying t)
      (agent-shell-gc--on-event (list (cons :event name)))
      (should-not agent-shell-gc--activity)
      (should-not agent-shell-gc--replaying))))

(ert-deftest agent-shell-gc-settling-events-do-not-stamp-each-other-test ()
  "No settling event counts, whichever of them arrives first.
A restore emits all of them, so one that ends the window must not leave
the next one looking like activity on a settled session."
  (with-temp-buffer
    (setq agent-shell-gc--replaying t)
    (dolist (name agent-shell-gc--settling-events)
      (agent-shell-gc--on-event (list (cons :event name))))
    (should-not agent-shell-gc--activity)))

(ert-deftest agent-shell-gc-replayed-output-is-not-activity-test ()
  "Output re-emitted while replaying history is not activity."
  (with-temp-buffer
    (setq agent-shell-gc--replaying t)
    (agent-shell-gc--on-event '((:event . agent-message-chunk)))
    (should-not agent-shell-gc--activity)))

(ert-deftest agent-shell-gc-output-after-settling-is-activity-test ()
  "Once a session has settled, its output counts again."
  (with-temp-buffer
    (setq agent-shell-gc--replaying t)
    (agent-shell-gc--on-event '((:event . session-restored)))
    (agent-shell-gc--on-event '((:event . agent-message-chunk)))
    (should agent-shell-gc--activity)))

(ert-deftest agent-shell-gc-input-submitted-is-always-activity-test ()
  "A submitted prompt counts even while the session looks like it is replaying."
  (with-temp-buffer
    (setq agent-shell-gc--replaying t)
    (agent-shell-gc--on-event '((:event . input-submitted)))
    (should agent-shell-gc--activity)
    (should-not agent-shell-gc--replaying)))

;;; Idle time

(ert-deftest agent-shell-gc-latest-prefers-most-recent-test ()
  "The later of in-memory and stored activity wins."
  (should (= (agent-shell-gc--latest 200.0 100.0) 200.0))
  (should (= (agent-shell-gc--latest 100.0 200.0) 200.0)))

(ert-deftest agent-shell-gc-latest-falls-back-to-stored-test ()
  "A session with no activity this Emacs session keeps its stored clock.
This is what lets a Desktop-restored buffer be collected at all."
  (should (= (agent-shell-gc--latest nil 100.0) 100.0))
  (should (= (agent-shell-gc--latest 100.0 nil) 100.0))
  (should-not (agent-shell-gc--latest nil nil)))

(ert-deftest agent-shell-gc-idle-of-untracked-buffer-is-zero-test ()
  "A buffer we know nothing about is never treated as idle."
  (with-temp-buffer
    (should (= (agent-shell-gc--idle (current-buffer)) 0))))

;;; Protection

(ert-deftest agent-shell-gc-protect-kept-buffer-test ()
  "A pinned session is protected."
  (with-temp-buffer
    (should-not (agent-shell-gc-protect-kept-p (current-buffer)))
    (setq agent-shell-gc--keep t)
    (should (agent-shell-gc-protect-kept-p (current-buffer)))))

(ert-deftest agent-shell-gc-protected-by-reports-the-predicate-test ()
  "The protecting predicate is returned so it can be reported."
  (with-temp-buffer
    (setq agent-shell-gc--keep t)
    (let ((agent-shell-gc-session-protect-functions
           (list #'agent-shell-gc-protect-kept-p)))
      (should (eq (agent-shell-gc--protected-by (current-buffer))
                  #'agent-shell-gc-protect-kept-p)))))

(ert-deftest agent-shell-gc-protection-survives-erroring-predicate-test ()
  "A predicate that errors does not abort the sweep."
  (with-temp-buffer
    (let ((agent-shell-gc-session-protect-functions
           (list (lambda (_buffer) (error "boom")))))
      (should-not (agent-shell-gc--protected-by (current-buffer))))))

;;; Grace

(ert-deftest agent-shell-gc-grace-suppresses-collection-test ()
  "A discontinuity holds collection for the configured window."
  (let ((agent-shell-gc--grace-until 0)
        (agent-shell-gc-grace 300)
        (agent-shell-gc-notify-function #'ignore))
    (should-not (agent-shell-gc--in-grace-p))
    (agent-shell-gc--start-grace "test")
    (should (agent-shell-gc--in-grace-p))))

(ert-deftest agent-shell-gc-clock-jump-starts-grace-test ()
  "Waking from a suspend holds collection instead of reaping everything."
  (let ((agent-shell-gc--grace-until 0)
        (agent-shell-gc-grace 300)
        (agent-shell-gc-poll-interval 60)
        (agent-shell-gc--last-tick (- (float-time) 3600))
        (agent-shell-gc-notify-function #'ignore))
    (agent-shell-gc--check-discontinuity (float-time))
    (should (agent-shell-gc--in-grace-p))))

(ert-deftest agent-shell-gc-regular-tick-does-not-start-grace-test ()
  "An ordinary sweep interval is not a discontinuity."
  (let ((agent-shell-gc--grace-until 0)
        (agent-shell-gc-grace 300)
        (agent-shell-gc-poll-interval 60)
        (agent-shell-gc--last-tick (- (float-time) 60))
        (agent-shell-gc-notify-function #'ignore))
    (agent-shell-gc--check-discontinuity (float-time))
    (should-not (agent-shell-gc--in-grace-p))))

;;; Formatting

(ert-deftest agent-shell-gc-format-duration-test ()
  "Durations are rendered at a useful scale."
  (should (equal (agent-shell-gc--format-duration 45) "45s"))
  (should (equal (agent-shell-gc--format-duration 300) "5m"))
  (should (equal (agent-shell-gc--format-duration 9000) "2h30m"))
  (should (equal (agent-shell-gc--format-duration 262800) "3d01h"))
  (should (equal (agent-shell-gc--format-duration -5) "0s")))

(ert-deftest agent-shell-gc-countdown-test ()
  "A countdown distinguishes disabled, due and pending."
  (should (equal (agent-shell-gc--countdown 100 nil) "disabled"))
  (should (equal (agent-shell-gc--countdown 100 50) "due"))
  (should (equal (agent-shell-gc--countdown 40 100) "1m")))

(ert-deftest agent-shell-gc-row-format-test ()
  "Every row shares a name column wide enough for the longest name."
  (let* ((short '(("shell" "1m" "6h")))
         (long (cons (list (make-string 60 ?x) "1m" "due") short))
         (rows (mapcar (lambda (row)
                         (apply #'format (agent-shell-gc--row-format long) row))
                       long)))
    (should (equal (agent-shell-gc--row-format short)
                   (format "  %%-%ds idle %%-8s %%s\n"
                           agent-shell-gc--list-name-width)))
    (should (apply #'= (mapcar (lambda (row) (string-match-p "idle " row))
                               rows)))))

(provide 'agent-shell-gc-tests)

;;; agent-shell-gc-tests.el ends here
