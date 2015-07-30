;;; ranger.el --- Make dired more like ranger

;; Copyright (C) 2015  Rich Alesi
;; Copyright (C) 2014  Adam Sokolnicki (peep-dired)

;; Author : Rich Alesi <https://github.com/ralesi>
;; Version: 0.9.2
;; Keywords: files, convenience
;; Homepage: https://github.com/ralesi/ranger
;; Package-Requires: ((cl-lib "0.5"))

;; Based on work from
;; peep-dired - Author: Adam Sokolnicki <adam.sokolnicki@gmail.com>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a minor mode that runs within dired emulating many of the features of
;; ranger. This minor mode shows a stack of the parent directories and updates the
;; parent buffers while nvaigating the file system. The preview window takes some
;; of the ideas from Peep-Dired <https://github.com/asok/peep-dired> to display
;; previews for selected files in the primary dired buffer.

;;; FEATURES

;; Replaces dired buffer with features from Ranger
;; - show window stack of parent directories
;; - show preview window of selected directory or file
;; - fast navigation using vi-like keybindings
;; - move through navigation history

;;; HISTORY

;; version 0.9.1, 2015-07-19 changed package to ranger
;; version 0.9.2, 2015-07-26 improve exit from ranger, bookmark support

;;; Code:

(require 'cl-macs)

(declare-function dired-omit-mode "dired-x")

;; directory options
(defcustom ranger-cleanup-on-disable t
  "Cleanup opened buffers when disabling the minor mode."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-cleanup-eagerly nil
  "Cleanup opened buffers upon `ranger-next-file' & `ranger-prev-file'."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-show-dotfiles t
  "When t it will show dotfiles in directory."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-history-length 30
  "When t it will show dotfiles in directory."
  :group 'ranger
  :type 'integer)

(defcustom ranger-parent-depth 1
  "Number of directories up to traverse."
  :group 'ranger
  :type 'integer)

;; preview options
(defcustom ranger-excluded-extensions
  '("mkv"
    "iso"
    "mp4"
    "bin"
    "exe"
    "msi")
  "File extensions to not preview."
  :group 'ranger
  :type 'list)

(defcustom ranger-max-preview-size 10
  "File size in MB to prevent preview of files."
  :group 'ranger
  :type 'integer)

(defcustom ranger-show-literal t
  "When non-nil it will show file literally."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-persistent-sort nil
  "When non-nil, sort all directories with the current flags."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-preview-file t
  "When t preview the selected file."
  :group 'ranger
  :type 'boolean)

(defcustom ranger-width-preview 0.50
  "Fraction of frame width taken by preview window."
  :group 'ranger
  :type 'float)

;; parent options
(defcustom ranger-width-parents 0.12
  "Fraction of frame width taken by parent windows"
  :group 'ranger
  :type 'float)

(defcustom ranger-max-parent-width 0.36
  "The max width allocated to showing parent windows."
  :group 'ranger
  :type 'float)

(defcustom ranger-key "C-p"
  "`dired-mode' key used to toggle `ranger-mode'"
  :group 'ranger
  :type 'string)

;; header functions
(defvar ranger-header-func 'ranger-header-line
  "Function used to output header of primary ranger window.
Outputs a string that will show up on the header-line.")

(defvar ranger-parent-header-func 'ranger-parent-header-line
  "Function used to output header of primary ranger window.
Outputs a string that will show up on the header-line.")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar ranger-history-index 0)

(defvar ranger-sorting-switches nil)

(defvar ranger-history-ring (make-ring 30))

(defvar ranger-child-name nil)
(make-variable-buffer-local 'ranger-child-name)

(defvar ranger-image-scale-ratio 1.3)
(make-variable-buffer-local 'ranger-scale-image-ratio)

(defvar ranger-image-fit-window t)

(defvar ranger-window nil)

(defvar ranger-minimal nil)

(defvar ranger-pre-hl-mode nil)
(defvar ranger-pre-arev-mode nil)
(defvar ranger-pre-omit-mode nil)

(defvar ranger-preview-window nil)
(defvar ranger-preview-buffers ()
  "List with buffers of previewed files.")

(defvar ranger-parent-windows nil)
(defvar ranger-parent-buffers ()
  "List with buffers of parent buffers.")
(defvar ranger-parent-dirs nil)

(defvar ranger-parent-dir-hook '(dired-hide-details-mode
                                 ranger-sort
                                 ranger-omit           ; ; hide extraneous stuf
                                 auto-revert-mode
                                 hl-line-mode               ; ; show line at current file
                                 ranger-parent-window-setup))

(defvar ranger-mode-map (make-sparse-keymap))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; parent window
(defun ranger-parent-window-setup ()
  "Parent window options."
  ;; select child
  (when ranger-child-name
    (dired-goto-file ranger-child-name))

  ;; allow mouse click to jump to that directory
  (make-local-variable 'mouse-1-click-follows-link)
  (setq mouse-1-click-follows-link nil)
  (local-set-key (kbd  "<mouse-1>") 'ranger-find-file)

  ;; (setq header-line-format nil)
  (setq header-line-format `(:eval (,ranger-parent-header-func)))
  (ranger-clear-dired-header)
  ;; (setq header-line-format '(:eval (format "sl: %s" (window-parameter (get-buffer-window) 'window-slot))))
  )

;; mapping macro
(defmacro ranger-map (key func)
  "Define macro to bind evil and emacs state for ranger"
  `(progn
     (when (featurep 'evil)
       (evil-define-key 'normal ranger-mode-map ,key ,func))
     (define-key ranger-mode-map ,key ,func)))

;; mappings
(when ranger-key
  (when (featurep 'evil)
    (evil-define-key 'normal dired-mode-map (kbd ranger-key) 'ranger-mode))
  (define-key dired-mode-map (kbd ranger-key) 'ranger-mode))

(defun ranger-define-maps ()
  "Define mappings for ranger-mode."
  (ranger-map "gg"          'ranger-goto-top)
  (ranger-map "G"           'ranger-goto-bottom)
  (ranger-map "gh"          'ranger-go-home)
  (ranger-map "B"           'ranger-show-bookmarks)
  (ranger-map (kbd "C-h")   'ranger-history)
  (ranger-map "H"           'ranger-prev-history)
  (ranger-map "L"           'ranger-next-history)
  (ranger-map "I"           'dired-insert-subdir)
  (ranger-map "S"           'eshell)
  (ranger-map "f"           'ranger-search-files)
  (ranger-map "h"           'ranger-up-directory)
  (ranger-map "i"           'ranger-preview-toggle)
  (ranger-map "j"           'ranger-next-file)
  (ranger-map "k"           'ranger-prev-file)
  (ranger-map "l"           'ranger-find-file)
  (ranger-map "o"           'ranger-sort-criteria)
  (ranger-map "q"           'ranger-disable)
  (ranger-map "r"           'ranger-refresh)
  (ranger-map "u"           'dired-unmark)
  (ranger-map "v"           'dired-toggle-marks)
  (ranger-map "z+"          'ranger-more-parents)
  (ranger-map "zp"          'ranger-minimal-toggle)
  (ranger-map "z-"          'ranger-less-parents)
  (ranger-map "zf"          'ranger-toggle-scale-images)
  (ranger-map "zh"          'ranger-toggle-dotfiles)
  (ranger-map "zi"          'ranger-toggle-literal)
  (ranger-map "J"           'dired-next-subdir)
  (ranger-map "K"           'dired-prev-subdir)
  (ranger-map (kbd "C-SPC") 'dired-mark)
  (ranger-map (kbd "C-j")   'ranger-scroll-page-down)
  (ranger-map (kbd "C-k")   'ranger-scroll-page-up)
  (ranger-map (kbd "RET")   'ranger-find-file)

  (if (featurep 'evil)
      (progn
        ;; some evil specific bindings
        (evil-define-key 'visual ranger-mode-map "u" 'dired-unmark)
        (evil-define-key 'normal ranger-mode-map
          "V"            'evil-visual-line
          "n"            'evil-search-next
          "N"            'evil-search-previous)
        (add-hook 'ranger-mode-hook 'evil-normalize-keymaps))
    (progn
      ;; and simulating search in standard emacs
      (define-key ranger-mode-map "/" 'isearch-forward)
      (define-key ranger-mode-map "n" 'isearch-repeat-forward)
      (define-key ranger-mode-map "N" 'isearch-repeat-backward))))

;; interaction
(defun ranger-refresh ()
  "Refresh evil ranger buffer."
  (interactive)
  ;; make sure cursor is visible on screen
  (scroll-right)
  ;; reset dired trees
  (dired-kill-tree dired-directory)
  ;; refresh for any changes
  (revert-buffer)
  ;; setup buffer
  (ranger-setup))

(defun ranger-search-files ()
  "Search for files / directories in folder."
  (interactive)
  (if (featurep 'helm)
      (call-interactively 'helm-find-files)
    (call-interactively 'ido-find-file))
  (ranger-exit-check))

(defun ranger-preview-toggle ()
  "Toggle preview of selected file."
  (interactive)
  (if ranger-preview-file
      (progn
        (when (and ranger-preview-window
                   (window-live-p ranger-preview-window)
                   (window-at-side-p ranger-preview-window 'right))
          (ignore-errors
            (delete-window ranger-preview-window)))
        (dired-hide-details-mode -1)
        (funcall 'add-to-invisibility-spec 'dired-hide-details-information)
        (setq ranger-preview-file nil))
    (progn
      (setq ranger-preview-file t)
      (dired-hide-details-mode t))
    (ranger-setup-preview)))

(defun ranger-toggle-scale-images ()
  "Show/hide dot-files."
  (interactive)
  (if ranger-image-fit-window ; if currently showing
      (setq ranger-image-fit-window nil)
    (setq ranger-image-fit-window t))
  (when ranger-preview-file
    (ranger-setup-preview))
  (message (format "Fit Images to Window: %s"  ranger-image-fit-window)))

(defun ranger-toggle-dotfiles ()
  "Show/hide dot-files."
  (interactive)
  (if ranger-show-dotfiles ; if currently showing
      (progn
        (setq ranger-show-dotfiles nil)
        (ranger-hide-dotfiles))
    (progn
      (revert-buffer) ; otherwise just revert to re-show
      (ranger-clear-dired-header)
      (setq ranger-show-dotfiles t)))
  (message (format "Show Dotfiles: %s"  ranger-show-dotfiles)))

(defun ranger-hide-dotfiles ()
  "Hide dotfiles in directory."
  (unless ranger-show-dotfiles
    (dired-mark-files-regexp "^\\\.")
    (dired-do-kill-lines nil "")))

(defun ranger-sort-criteria (criteria)
  "Call sort-dired by different `CRITERIA'."
  (interactive
   (list
    (read-char-choice
     "criteria: (n/N)ame (e/E)xt (s/S)ize (t/T)ime" '(?q ?n ?N ?e ?E ?s ?S ?t ?T))))
  (unless (eq criteria ?q)
    (let* ((c (char-to-string criteria))
           (uppercasep (and (stringp c) (string-equal c (upcase c)) ))
           (cc (downcase c))
           (ranger-sort-flag
            (cond
             ((string-equal cc "n") "N")
             ((string-equal cc "e") "X")
             ((string-equal cc "t") "t")
             ((string-equal cc "s") "S")))
           )
      (setq ranger-sorting-switches
            (concat ranger-sort-flag
                    (when uppercasep "r")))
      (dired-sort-other
       (concat dired-listing-switches
               ranger-sorting-switches))
      (ranger-refresh))))

(defun ranger-up-directory ()
  "Move to parent directory."
  (interactive)
  (let ((current default-directory)
        (parent (ranger-parent-directory default-directory)))
    (when parent
      (ranger-find-file parent)
      (dired-goto-file current))))

(defun ranger-history (history)
  "Show history prompt for recent directories"
  (interactive (list  (completing-read "Select from history" (ring-elements ranger-history-ring))))
  (when history
    (ranger-find-file history)))

(defun ranger-jump-history (jump)
  "Move through history ring by increment `jump'"
  (let* ((ring ranger-history-ring)
         (curr-index ranger-history-index)
         (goto-idx (min
                    (max 0 (+ curr-index jump))
                    (- (ring-length ring) 1)))
         (jump-history (ring-ref ring goto-idx)))
    (when jump-history
      (setq ranger-history-index goto-idx)
      (ranger-find-file jump-history t))))

(defun ranger-next-history ()
  "Move forward in history"
  (interactive)
  (ranger-jump-history -1))

(defun ranger-prev-history ()
  "Move backward in history"
  (interactive)
  (ranger-jump-history 1))

(defun ranger-show-bookmarks (bookmark)
  "Show bookmark prompt for recent directories"
  (interactive
   (list
    (completing-read "Select from bookmarks"
                     (delq nil (mapcar
                                #'(lambda (bm)
                                    (when (file-directory-p (cdr (cadr bm)))
                                      (cdr  (cadr bm))))
                                bookmark-alist)))))
  (when bookmark
    (ranger-find-file bookmark)))

(setq ranger-history-ring (make-ring 30))

(defun ranger-find-file (&optional entry ignore-history)
  "Find file in ranger buffer.  `ENTRY' can be used as option, else will use
currently selected file in ranger. `IGNORE-HISTORY' will not update history-ring on change"
  (interactive)
  (let ((find-name (or entry
                       (dired-get-filename nil t))))
    (when find-name
      ;; insert directory in history
      (unless ignore-history
        ;; don't put the same directory twice
        (when (and
               (file-directory-p (file-name-directory find-name))
               (or (ring-empty-p ranger-history-ring)
                   (not (equal find-name (ring-ref ranger-history-ring 0)))))
          (progn
            (ring-insert ranger-history-ring find-name)
            (setq ranger-history-index 0))))
      (find-file find-name)
      (ranger-exit-check))))

(defun ranger-goto-top ()
  "Move to top of file list"
  (interactive)
  (goto-char (point-min))
  (ranger-prev-file))

(defun ranger-goto-bottom ()
  "Move to top of file list"
  (interactive)
  (goto-char (point-max))
  (ranger-next-file))

(defun ranger-go-home ()
  "Move to top of file list"
  (interactive)
  (goto-char (point-max))
  (ranger-find-file "~/"))

(defun ranger-next-file ()
  "Move to next file in ranger."
  (interactive)
  (dired-next-line 1)
  (when (eobp)
    (dired-next-line -1))
  (when ranger-preview-file
    (ranger-setup-preview)))

(defun ranger-prev-file ()
  "Move to previous file in ranger."
  (interactive)
  ;; (unless (bobp)
  (dired-previous-line 1)
  (when ranger-preview-file
    (ranger-setup-preview)))

;; parent window functions
(defun ranger-less-parents ()
  "Reduce number of ranger parents."
  (interactive)
  (setq ranger-parent-depth (max 0 (- ranger-parent-depth 1)))
  (ranger-setup))

(defun ranger-more-parents ()
  "Increase number of ranger parents."
  (interactive)
  (setq ranger-parent-depth (+ ranger-parent-depth 1))
  (ranger-setup))

(defun ranger-setup-parents ()
  "Setup all parent directories."
  (let ((parent-name (ranger-parent-directory default-directory))
        (current-name default-directory)
        (i 0)
        (unused-windows ()))

    (setq ranger-window (get-buffer-window (current-buffer)))

    ;; delete all ranger parent buffers currently not showing
    (cl-loop for buffer in ranger-parent-buffers do
             (unless (eq (get-buffer-window buffer) ranger-window)
               (kill-buffer buffer)))

    (setq ranger-parent-buffers ())
    (setq ranger-parent-windows ())
    (setq ranger-parent-dirs ())
    (while (and parent-name
                (not ranger-minimal)
                (file-directory-p parent-name)
                (< i ranger-parent-depth))
      (setq i (+ i 1))
      (unless (string-equal current-name parent-name)
        ;; (walk-window-tree
        ;;  (lambda (window)
        ;;    (when (eq (window-parameter window 'window-slot) (- 0 i))
        ;;      (setq unused-window window)
        ;;      ))
        ;;  nil nil 'nomini)
        (progn
          (add-to-list 'ranger-parent-dirs (cons (cons current-name parent-name) i))
          (setq current-name (ranger-parent-directory current-name))
          (setq parent-name (ranger-parent-directory parent-name))))
      )
    ;; (message (format "%s" ranger-parent-dirs))
    (mapc 'ranger-make-parent ranger-parent-dirs)

    (walk-window-tree
     (lambda (window)
       (unless (or
                (member window ranger-parent-windows)
                (eq window ranger-window))
         (add-to-list 'unused-windows window)
         ))
     nil nil 'nomini)

    (unless ranger-minimal
      (cl-loop for unused-window in unused-windows do
               (when (and unused-window
                          (window-live-p unused-window))
                 (delete-window unused-window))))))

(defun ranger-make-parent (parent)
  "Make parent window.  `PARENT' is a construct with ((current . parent) .
slot)."
  (let* ((parent-name (cdar parent))
         (current-name (caar parent))
         (slot (cdr parent))
         (parent-window
          (display-buffer
           (ranger-dir-buffer parent-name)
           `(ranger-display-buffer-at-side . ((side . left)
                                              (slot . ,(- 0 slot))
                                              (inhibit-same-window . t)
                                              (window-width . ,(min
                                                                (/ ranger-max-parent-width
                                                                   (length ranger-parent-dirs))
                                                                ranger-width-parents))))))
         (parent-buffer (window-buffer parent-window)))
    (setq ranger-child-name current-name)
    (add-to-list 'ranger-parent-buffers parent-buffer)
    (add-to-list 'ranger-parent-windows parent-window)))

;; find file subroutines
(defun ranger-dir-buffer (entry)
  "Open `ENTRY' in dired buffer."
  ;; (ignore-errors
  (with-current-buffer (or
                        (car (or (dired-buffers-for-dir entry) ()))
                        (dired-noselect entry))
    (run-hooks 'ranger-parent-dir-hook)
    (current-buffer)))

(defun ranger-preview-buffer (entry-name)
  "Create the preview buffer of `ENTRY-NAME'.  If `ranger-show-literal'
is set, show literally instead of actual buffer."
  (if ranger-show-literal
      ;; show literal version of file
      (let ((temp-buffer (or (get-buffer "*literal*")
                             (generate-new-buffer "*literal*"))))
        (with-current-buffer temp-buffer
          (erase-buffer)
          (insert-file-contents entry-name)
          (current-buffer)))
    ;; show file
    ;; (if (image-type-from-file-header entry-name)
    (if (and (image-type-from-file-header entry-name)
             (not (eq (image-type-from-file-header entry-name) 'gif))
             ranger-image-fit-window)
        (ranger-setup-image-preview entry-name)
      (with-current-buffer
          (or
           (find-buffer-visiting entry-name)
           (find-file-noselect entry-name nil ranger-show-literal))
        (current-buffer)))))

(defun ranger-setup-image-preview (entry-name)
  "Setup and maybe resize image"
  (let* ((new-file (expand-file-name image-dired-temp-image-file))
         (file (expand-file-name entry-name))
         ret success
         (width (* ranger-width-preview ranger-image-scale-ratio (image-dired-display-window-width)))
         (height (image-dired-display-window-height))
         (image-type 'jpeg) command)
    (if (and (not (eq (image-type-from-file-header entry-name) 'gif))
             ranger-image-fit-window)
        (progn
          (setq command
                (format-spec
                 image-dired-cmd-create-temp-image-options
                 (list
                  (cons ?p image-dired-cmd-create-temp-image-program)
                  (cons ?w width)
                  (cons ?h height)
                  (cons ?f file)
                  (cons ?t new-file))))
          (setq ret (call-process shell-file-name nil nil nil
                                  shell-command-switch command))
          (when (= 0 ret)
            (setq success 1))))
    (with-current-buffer (image-dired-create-display-image-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (clear-image-cache)
        (image-dired-insert-image (if success
                                      image-dired-temp-image-file
                                    file)
                                  image-type 0 0)
        (goto-char (point-min))
        (image-dired-update-property 'original-file-name file))
      image-dired-display-image-buffer)))

;; preview window functions
(defun ranger-setup-preview ()
  "Setup ranger preview window."
  (let* ((entry-name (dired-get-filename nil t))
         (fsize
          (nth 7 (file-attributes entry-name))))
    (when ranger-cleanup-eagerly
      (ranger-preview-cleanup))
    (when (and ranger-preview-window
               (window-live-p ranger-preview-window)
               ;; (window-at-side-p ranger-preview-window 'right)
               )
      (ignore-errors (delete-window ranger-preview-window)))
    (when (and (not ranger-minimal)
               entry-name
               ranger-preview-file)
      (unless (or
               (> fsize (* 1024 1024 ranger-max-preview-size))
               (member (file-name-extension entry-name)
                       ranger-excluded-extensions))
        (let* ((preview-window (display-buffer
                                (if (file-directory-p entry-name)
                                    (ranger-dir-buffer entry-name)
                                  (ranger-preview-buffer entry-name))
                                `(ranger-display-buffer-at-side . ((side . right)
                                                                   (slot . 1)
                                                                   ;; (inhibit-same-window . t)
                                                                   (window-width . ,ranger-width-preview)))))
               (preview-buffer
                (window-buffer preview-window)))
          (add-to-list 'ranger-preview-buffers preview-buffer)
          (setq ranger-preview-window preview-window)
          (dired-hide-details-mode t))))))

(defun ranger-toggle-literal ()
  "Toggle showing literal / actual preview of file."
  (interactive)
  (if ranger-show-literal
      (setq ranger-show-literal nil)
    (setq ranger-show-literal t))
  ;; (ignore-errors
  ;;   (mapc 'kill-buffer-if-not-modified ranger-preview-buffers)
  ;;   (delete-window ranger-preview-window))
  (when ranger-preview-file
    (ranger-setup-preview))
  (message (format "Literal Preview: %s"  ranger-show-literal)))

(defun ranger-scroll-page-down ()
  "Scroll preview window up."
  (interactive)
  (scroll-other-window))

(defun ranger-scroll-page-up ()
  "Scroll preview window down."
  (interactive)
  (scroll-other-window '-))

;; utilities
(defun ranger-parent-directory (entry)
  "Find the parent directory of `ENTRY'."
  (file-name-directory (directory-file-name entry)))

(defun ranger-fix-width (window)
  "Fix the width of `WINDOW'."
  (with-selected-window window
    (setq-local window-size-fixed 'width)))

(defun ranger-display-buffer-at-side (buffer alist)
  "Try displaying `BUFFER' at one side of the selected frame. This splits the
window at the designated `side' of the frame.  Accepts `window-width' as a
fraction of the total frame size"
  (let* ((side (or (cdr (assq 'side alist)) 'bottom))
         (slot (or (cdr (assq 'slot alist)) 0))
         (window-width (or (cdr (assq 'window-width alist)) 0.5))
         (window-size (ceiling  (* (frame-width) window-width)))
         (split-width-threshold 0)
         (current-window ranger-window)
         new-window
         reuse-window)

    ;; (walk-window-tree
    ;;  (lambda (window)
    ;;    (progn
    ;;      (when (not (eq current-window window))
    ;;        (when (eq (window-parameter window 'window-slot) slot)
    ;;          (setq reuse-window window))
    ;;        (when (eq (window-parameter window 'window-slot) (+ slot 1))
    ;;          (setq current-window window))
    ;;        )))
    ;;  nil nil 'nomini)

    (if reuse-window
        (progn
          (shrink-window (-  window-size (window-width reuse-window)) t)
          ;; (set-window-parameter reuse-window 'window-slot slot)
          (window--display-buffer
           buffer reuse-window 'reuse alist display-buffer-mark-dedicated)
          )
      (progn
        (setq new-window (split-window current-window window-size side))
        (set-window-parameter new-window 'window-slot slot)
        (window--display-buffer
         buffer new-window 'window alist display-buffer-mark-dedicated)))))

(defun ranger-preview-cleanup ()
  "Cleanup all old buffers and windows used by ranger."
  (mapc 'kill-buffer-if-not-modified ranger-preview-buffers)
  (setq ranger-preview-buffers ()))

(defun ranger-omit ()
  "Quietly omit files in dired."
  (setq-local dired-omit-verbose nil)
  (dired-omit-mode t))

(defun ranger-sort ()
  "Perform current sort on directory."
  (when ranger-persistent-sort
    (dired-sort-other
     (concat dired-listing-switches
             ranger-sorting-switches))))

(defun ranger-kill-buffers-without-window ()
  "Will kill all ranger buffers that are not displayed in any window."
  (interactive)
  (cl-loop for buffer in ranger-parent-buffers do
           (unless (get-buffer-window buffer t)
             (kill-buffer-if-not-modified buffer)))
  (cl-loop for buffer in ranger-preview-buffers do
           (unless (get-buffer-window buffer t)
             (kill-buffer-if-not-modified buffer))))

;; header-line functions
(defun ranger-parent-header-line ()
  "Setup header-line for ranger parent buffer."
  (let* ((current-name default-directory)
         (parent-name (ranger-parent-directory default-directory))
         (relative
          (if (string-equal current-name parent-name)
              current-name
            (file-relative-name current-name parent-name))))
    (if (eq (get-buffer-window (current-buffer)) ranger-preview-window)
        (concat
         (propertize
          ;; if at base directory, show base
          (concat " " relative)
          'face '(:background "#000000" :foreground "#ffffff" :weight bold)))
      (concat
       (propertize
        ;; if at base directory, show base
        (concat " " relative)
        'face '(:background "#ffffff" :foreground "#000000" :weight bold))))))

(defun ranger-header-line ()
  "Setup header-line for ranger buffer."
  (let* ((current-name default-directory)
         (parent-name (ranger-parent-directory default-directory))
         (relative
          (if (string-equal current-name parent-name)
              current-name
            (file-relative-name current-name parent-name)))
         (rhs
          (concat
           (format "%s | "
                   (if ranger-show-literal "literal" "actual"))
           (format "%s | "
                   (if ranger-show-dotfiles "show" "hide"))
           (format "parents: %s " ranger-parent-depth)))
         (used-length (+ (length rhs) (length relative)))
         (filler (make-string (max 0 (- (window-width) used-length)) (string-to-char " "))))
    (concat
     (propertize
      ;; if at base directory, show base
      (concat " "
              relative)
      'face
      '(
        :background "#ffffff"
                    :foreground "#000000"
                    :weight bold
                    )
      )
     filler
     rhs)))

(defun ranger-clear-dired-header ()
  ;; (when (eq ranger-window (get-buffer-window (current-buffer)))
  (save-excursion
    ;; (dired-hide-subdir)
    (goto-char 0)
    (let ((buffer-read-only nil)
          (dired-header-match (point-at-eol)))
      (when (search-forward-regexp ":$" dired-header-match t)
        (kill-whole-line)))))

;;;###autoload
(defun ranger-same-window ()
  "Launch dired in ranger-mode."
  (interactive)
  (setq ranger-minimal t)
  (ranger))

(defun ranger-minimal-toggle ()
  (interactive)
  (let ((minimal ranger-minimal))
    (ranger-revert)
    (if minimal
        (ranger)
      (ranger-same-window))))

;;;###autoload
(defun ranger ()
  "Launch dired in ranger-mode."
  (interactive)
  (let* ((file buffer-file-name)
         (dir (if file (file-name-directory file) default-directory)))
    (when file
      (add-hook 'window-configuration-change-hook 'ranger-window-check)
      (window-configuration-to-register :ranger_dired_before)
      (ranger-find-file dir))))

(defun ranger-enable ()
  "Interactively enable ranger-mode."
  (interactive)
  (ranger-mode t))

(defun ranger-disable ()
  "Interactively disable ranger-mode."
  (interactive)
  (ranger-mode -1))

(defun ranger-setup ()
  "Setup all associated ranger windows."
  (interactive)

  (unless (derived-mode-p 'dired-mode)
    (error "Run it from dired buffer"))
  ;; (when (derived-mode-p 'dired-mode)

  (add-hook 'window-configuration-change-hook 'ranger-window-check)

  (setq ranger-pre-hl-mode hl-line-mode)
  (setq ranger-pre-arev-mode auto-revert-mode)
  (setq ranger-pre-omit-mode dired-omit-mode)
  (hl-line-mode t)

  (unless (get-register :ranger_dired_before)
    (window-configuration-to-register :ranger_dired_before))

  (ranger-hide-dotfiles)
  (ranger-omit)
  (auto-revert-mode)

  ;; set hl-line-mode for ranger usage
  (setq ranger-preview-window nil)
  (setq ranger-window (get-buffer-window (current-buffer)))

  ;; truncate lines for primary window
  (set-window-hscroll ranger-window 0)
  (setq truncate-lines t)

  (dired-hide-details-mode -1)

  ;; hide details line at top
  (funcall 'add-to-invisibility-spec 'dired-hide-details-information)

  (ranger-sort)

  (unless ranger-minimal
    ;; clear out everything
    (delete-other-windows))

  (ranger-setup-parents)
  (ranger-setup-preview)

  (make-local-variable 'header-line-format)
  (setq header-line-format `(:eval (,ranger-header-func)))
  (ranger-clear-dired-header))

(defun ranger-revert ()
  "Revert ranger settings."

  (remove-hook 'window-configuration-change-hook 'ranger-window-check)

  (when (get-register :ranger_dired_before)
    (ignore-errors
      (jump-to-register :ranger_dired_before))
    (set-register :ranger_dired_before nil))

  (when ranger-cleanup-on-disable
    (mapc 'kill-buffer-if-not-modified ranger-preview-buffers))
  (mapc 'kill-buffer ranger-parent-buffers)

  ;; (mapc #'(lambda (window) (ignore-errors (delete-window window)))
  ;;       ranger-parent-windows)
  ;; (setq ranger-parent-windows ())
  (setq ranger-preview-buffers ()
        ranger-parent-buffers ())

  (setq ranger-minimal nil)
  ;; revert buffer local modes used in ranger
  (unless ranger-pre-hl-mode
    (hl-line-mode -1))
  (when (derived-mode-p 'dired-mode)
    (unless ranger-pre-arev-mode
      (auto-revert-mode -1))
    (unless ranger-pre-omit-mode
      (dired-omit-mode -1)))

  ;; revert dired buffer header-line
  (setq header-line-format nil)

  (when (derived-mode-p 'dired-mode)
    (revert-buffer t)))

(defun ranger-exit-check ()
  "Enable or disable ranger based on mode"
  (if (derived-mode-p 'dired-mode)
      (progn
        (ranger-enable))
    (progn
      ;; (remove-hook 'find-file-hook 'ranger-exit-check)
      (let ((current (current-buffer))
            (buffer (buffer-file-name (current-buffer))))
        (message "Exiting ranger")
        (ranger-disable)
        (if buffer
            (find-file buffer))
        (switch-to-buffer current)))))

(defun ranger-window-check ()
  "Detect when ranger-window is no longer part of ranger-mode"
  ;; (message (format "%s : %s"
  ;;                  major-mode
  ;;                  (current-buffer)))
  (when (and
         (not ranger-mode)
         (eq ranger-window (selected-window)))
    (remove-hook 'window-configuration-change-hook 'ranger-window-check)
    (ranger-exit-check)))

;;;###autoload
(define-minor-mode ranger-mode
  "A convienent way to look up file contents in other window while browsing directory in dired"
  :init-value nil
  :lighter " Ranger"
  :keymap 'ranger-mode-map
  :group 'ranger
  ;; :after-hook 'ranger-mode-hook

  ;; define keymaps
  (ranger-define-maps)

  ;; only run from dired-mode
  (if ranger-mode
      (ranger-setup)
    (ranger-revert)))

(provide 'ranger)

;;; ranger.el ends here
