;;; racket-trace.el -*- lexical-binding: t; -*-

;; Copyright (c) 2013-2020 by Greg Hendershott.
;; Portions Copyright (C) 1985-1986, 1999-2013 Free Software Foundation, Inc.

;; Author: Greg Hendershott
;; URL: https://github.com/greghendershott/racket-mode

;; License:
;; This is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version. This is distributed in the hope that it will be
;; useful, but without any warranty; without even the implied warranty
;; of merchantability or fitness for a particular purpose. See the GNU
;; General Public License for more details. See
;; http://www.gnu.org/licenses/ for details.

(require 'color)
(require 'semantic/symref/grep)
(require 'xref)
(require 'pulse)
(require 'racket-util)
(require 'racket-show)

(defvar racket-trace-mode-map
  (racket--easy-keymap-define
   '(("RET" racket-trace-show-sites)
     ("."   racket-trace-goto-called-site)
     (","   racket-trace-goto-caller-site)
     ("c"   racket-trace-goto-context-site)
     ("n"   racket-trace-next)
     ("p"   racket-trace-previous)
     ("u"   racket-trace-up-level)
     ("/"   racket-trace-only-this-thread)
     ("a"   racket-trace-all-threads)
     ("t"   racket-trace-timing)
     ("A"   racket-trace-toggle-thread-fields-visibility)
     ("T"   racket-trace-toggle-timing-fields-visibility))))

(defvar racket--trace-known-threads nil)

;; There are two "dimensions" of visibility:
;;
;; 1. Each entire line gets an 'invisibile property value which is a
;; symbol: the user program thread name. This allows filtering trace
;; output by thread.
;;
;; 2. Some portions of the line ("fields") also get an 'invisible
;; value, which allows toggling their display on/off. For this we use
;; magic numbers (they can't collide with symbols), which are
;; `defconst'ed just below.
;;
;; See `racket--trace-on-notify' for how we set the 'invisible
;; property. See various commands for how they call
;; `add-to-invisibility-spec' or `remove-from-invisibility-spec'.
(defconst racket--trace-invisible-timing 0
  "A value for the 'invisible text property and the `add-to-invisibility-spec'.")
(defconst racket--trace-invisible-thread 1
  "A value for the 'invisible text property and the `add-to-invisibility-spec'.")

(define-derived-mode racket-trace-mode special-mode "Racket-Trace"
  "Major mode for trace output.
\\<racket-trace-mode-map>

Shows items logged to the racket-mode-trace topic, for example by
the \"vestige\" package, which is like racket/trace but supports
source location information.

\\{racket-trace-mode-map}"
  (setq-local buffer-undo-list t) ;disable undo
  (setq-local window-point-insertion-type t)
  (add-hook 'before-change-functions #'racket-trace-before-change-function)
  (add-hook 'kill-buffer-hook #'racket-trace-delete-all-overlays nil t)
  (setq-local revert-buffer-function #'racket-trace-revert-buffer-function)
  (setq buffer-invisibility-spec nil)
  (add-to-invisibility-spec racket--trace-invisible-timing)
  (add-to-invisibility-spec racket--trace-invisible-thread)
  (cl-pushnew 'racket--trace-called-marker overlay-arrow-variable-list)
  (cl-pushnew 'racket--trace-caller-marker overlay-arrow-variable-list)
  (cl-pushnew 'racket--trace-context-marker overlay-arrow-variable-list)
  (racket--trace-configure-level-faces)
  ;; xref
  (add-hook 'xref-backend-functions
            #'racket-trace-xref-backend-function
            nil t)
  (add-to-list 'semantic-symref-filepattern-alist
               '(racket-trace-mode "*.rkt" "*.rktd" "*.rktl")))

(defun racket-trace-revert-buffer-function (_ignore-auto noconfirm)
  (when (or noconfirm
            (y-or-n-p "Clear buffer?"))
    (with-silent-modifications
      (erase-buffer))
    (racket-trace-delete-all-overlays)
    (dolist (thd racket--trace-known-threads)
      (remove-from-invisibility-spec thd))
    (setq racket--trace-known-threads nil)))

(defconst racket--trace-buffer-name "*Racket Trace*")

(defun racket--trace-get-buffer-create ()
  "Create buffer if necessary."
  (or (get-buffer racket--trace-buffer-name)
      (with-current-buffer (get-buffer-create racket--trace-buffer-name)
        (racket-trace-mode)
        (current-buffer))))

;; "If your struct has a dozen members, you probably forgot one."
(cl-defstruct racket-trace
  callp tailp name show vals level xref formals header caller context thread msec)

(defun racket--trace-get (&optional accessor)
  "Get our `racket-trace' struct from a 'racket-trace text
property at point, and apply the struct ACCESSOR."
  (pcase (get-text-property (point) 'racket-trace)
    ((and (pred racket-trace-p) v)
     (if accessor
         (funcall accessor v)
       v))))

(defun racket--trace-on-notify (data)
  (with-current-buffer (racket--trace-get-buffer-create)
    (let ((inhibit-read-only  t)
          (original-point     (point)))
      (goto-char (point-max))
      (pcase data
        (`(,callp ,tailp ,show ,vals ,name ,level
                  ,def ,formals ,header ,caller ,ctx ,thread ,msec)
         (let* ((thread    (intern thread))
                (xref      (racket--trace-srcloc-line+col def))
                (formals   (racket--trace-srcloc-beg+end formals))
                (header    (racket--trace-srcloc-beg+end header))
                (caller    (racket--trace-srcloc-beg+end caller))
                (context   (racket--trace-srcloc-beg+end ctx))
                (v (make-racket-trace :callp   callp
                                      :tailp   tailp
                                      :name    name
                                      :show    show
                                      :vals    vals
                                      :level   level
                                      :xref    xref
                                      :formals formals
                                      :header  header
                                      :caller  caller
                                      :context context
                                      :thread  thread
                                      :msec    msec))
                (new-thread-p (save-excursion
                                (not (eq (and (zerop (forward-line -1))
                                              (racket--trace-get #'racket-trace-thread))
                                         thread))))
                (overline (if new-thread-p
                              `(:overline t)
                            `()))
                ;; The base face for the entire line. The main feature
                ;; here is to use :overline when this line's thread
                ;; differs from the previous line.
                (prefix (if callp
                            (if tailp "⤑ " "↘ ")
                          "   ⇒ ")))
           (cl-pushnew thread racket--trace-known-threads)
           ;; For an "inset boxes" effect, we start the line by
           ;; drawing a space for each parent level, in its background
           ;; color.
           (cl-loop for n to (1- level)
                    do
                    (insert
                     (propertize
                      "  "
                      'face         `(:inherit ,(racket--trace-level-face-name n)
                                               ,@overline)
                      'racket-trace v
                      'invisible    thread)))
           ;; Finally draw the interesting information for this line.
           ;; We insert several separately-propertized strings because
           ;; some are "fields" that need their own face and
           ;; 'invisible property.
           (let ((inherit `(:inherit ,(racket--trace-level-face-name level))))
             (insert
              (concat
               (propertize (concat prefix (racket--trace-limit-string show))
                           'face         `(,@inherit ,@overline)
                           'racket-trace v
                           'invisible    thread)
               (propertize (format "  %s" thread)
                           'face         `(,@inherit
                                           ,@overline
                                           :height 0.8
                                           ,@(when new-thread-p
                                               `(:weight bold)))
                           'racket-trace v
                           'invisible    (if new-thread-p
                                             thread
                                           (list thread
                                                 racket--trace-invisible-thread)))
               (propertize (format "  %s" msec)
                           'face         `(,@inherit
                                           ,@overline
                                           :height 0.8)
                           'racket-trace v
                           'invisible    (list thread
                                               racket--trace-invisible-timing))
               (propertize "\n"
                           'face         inherit
                           'racket-trace v
                           'invisible    thread)))))))
      (goto-char original-point))))

(defun racket--trace-srcloc-line+col (v)
  "Extract the line and col from a srcloc."
  (pcase v
    (`(,path ,line ,col ,_pos ,_span)
     `(,path ,line ,col))))

(defun racket--trace-srcloc-beg+end (v)
  "Extract the pos and span from a srcloc and convert to beg and end."
  (pcase v
    (`(,path ,_line ,_col ,pos ,span)
     `(,path ,pos ,(+ pos span)))))

(defface racket-trace-even-level-face '((t (:inherit default)))
  "Face for even levels. Calculated from theme. Not for user customization."
  :group 'racket-faces)
(defface racket-trace-odd-level-face '((t (:inherit default)))
  "Face for odd levels. Calculated from theme. Not for user customization."
  :group 'racket-faces)

(defun racket--trace-configure-level-faces (&rest _ignored)
  (let ((bg   (face-background 'match))
        (sign (if (eq 'dark (frame-parameter nil 'background-mode)) 1 -1)))
    (set-face-background 'racket-trace-even-level-face
                         (color-lighten-name bg (* 5 sign)))
    (set-face-background 'racket-trace-odd-level-face
                         (color-lighten-name bg (* 10 sign)))))

(advice-add 'load-theme    :after #'racket--trace-configure-level-faces)
(advice-add 'disable-theme :after #'racket--trace-configure-level-faces)

(defun racket--trace-level-face-name (level)
  (if (cl-evenp level)
      'racket-trace-even-level-face
    'racket-trace-odd-level-face))

(defun racket--trace-level-background (level)
  `(:background ,(face-background (racket--trace-level-face-name level))))

;;; Commands

;;;###autoload
(defun racket-trace ()
  "Select the `racket-trace-mode' buffer in a window."
  (interactive)
  (select-window
   (display-buffer-in-side-window (racket--trace-get-buffer-create)
                                  '((side . bottom)
                                    (slot . 1)
                                    (window-height . 15)))))

(defun racket-trace-next ()
  "Move to next line and show caller and definition sites.
Ignores i.e. skips invisible lines."
  (interactive)
  (when (racket--trace-forward-line 1)
    (racket--trace-back-to-indentation)
    (racket-trace-show-sites)))

(defun racket-trace-previous ()
  "Move to previous line and show caller and definition sites.
Ignores i.e. skips invisible lines."
  (interactive)
  (when (racket--trace-forward-line -1)
    (racket--trace-back-to-indentation)
    (racket-trace-show-sites)))

(defun racket--trace-forward-line (amt)
  "Like `forward-line' but ignores invisible lines and returns a boolean."
  (let ((orig (point))
        (result nil))
    (while (not (or result
                    (if (< amt 0) (bobp) (eobp))))
      (when (and (zerop (forward-line amt))
                 (not (or (invisible-p (point))
                          ;; At eob invisible-p can return nil so confirm:
                          (and (< 0 amt) (eobp)))))
        (setq result t)))
    (or result
        (progn (goto-char orig) nil))))

(defun racket-trace-up-level ()
  "Move up one level and show caller and definition sites."
  (interactive)
  (unless (and (racket--trace-up-level)
               (not (invisible-p (point))))
    (user-error "Cannot find parent level"))
  (racket--trace-back-to-indentation)
  (racket-trace-show-sites))

(defun racket--trace-up-level ()
  "Try to move up one level for same thread, returning boolean whether moved."
  (let* ((orig (point))
         (level (1- (racket--trace-get #'racket-trace-level)))
         (thread (racket--trace-get #'racket-trace-thread))
         (result nil))
    (while (not (or result (bobp)))
      (when (and (zerop (forward-line -1))
                 (eq level (racket--trace-get #'racket-trace-level))
                 (eq thread (racket--trace-get #'racket-trace-thread)))
        (setq result t)))
    (or result
        (progn (goto-char orig) nil))))

(defun racket--trace-back-to-indentation ()
  "Move to the start of information for a line, based on its indent, skipping any prefix."
  (back-to-indentation)
  (forward-char 2))

;;; Showing caller and formals sites

(defvar racket--trace-called-marker nil
  "A value for the variable `overlay-arrow-variable-list'.")
(defvar racket--trace-caller-marker nil
  "A value for the variable `overlay-arrow-variable-list'.")
(defvar racket--trace-context-marker nil
  "A value for the variable `overlay-arrow-variable-list'.")

(defvar racket--trace-overlays nil
  "List of overlays we've added in various buffers.")

(defun racket-trace-delete-all-overlays ()
  "Delete all overlays and overlay arrows in various buffers."
  (setq racket--trace-called-marker nil
        racket--trace-caller-marker nil
        racket--trace-context-marker nil)
  (dolist (o racket--trace-overlays) (delete-overlay o))
  (setq racket--trace-overlays nil))

(defun racket-trace-before-change-function (_beg _end)
  "When a buffer is modified, hide all overlays we have in it.
For speed we don't actually delete them, just move them \"nowhere\"."
  (setq racket--trace-called-marker nil
        racket--trace-caller-marker nil
        racket--trace-context-marker nil)
  (let ((buf (current-buffer)))
    (with-temp-buffer
      (dolist (o racket--trace-overlays)
        (when (equal (overlay-buffer o) buf)
          (with-temp-buffer (move-overlay o 1 1)))))))

(defun racket-trace-show-sites ()
  (interactive)
  "Show caller and definition sites for parent levels and current level."
  (racket-trace-delete-all-overlays)
  (pcase (racket--trace-get)
    ((and (pred racket-trace-p) v)
     ;; Draw called site first. That way it "wins" if the caller site
     ;; happens to intersect.
     (racket--trace-highlight-called-site v)
     (racket--trace-highlight-caller-site v)
     ;; Make the site(s) visible in buffers. Goto formals site last,
     ;; so if the caller site happens to be in same buffer, the
     ;; formals will be visible.
     (unless (ignore-errors (racket-trace-goto-caller-site))
       (message "No caller site available; press c to visit context site"))
     (ignore-errors (racket-trace-goto-called-site)))))

(defun racket--trace-highlight-called-site (v)
  "Highlight formals site."
  ;; TODO: An interesting possibility here is that, if racket-xp-mode
  ;; is active, we could utilize its def/uses data to fill in the
  ;; actual value of the formal parameter at all use sites, too.
  ;; See also comment at `racket--trace-goto-called-site'.
  (pcase-let ((`(,file ,beg ,end)
               (if (racket-trace-callp v)
                   (racket-trace-formals v)
                 (racket-trace-header v))))
    (with-current-buffer (racket--trace-buffer-for-file file)
      (racket--trace-put-highlight-overlay v
                                           (racket-trace-vals v)
                                           beg end
                                           102))))

(defun racket--trace-highlight-caller-site (v)
  (pcase (racket-trace-caller v)
    (`(,file ,beg ,end)
     (with-current-buffer (racket--trace-buffer-for-file file)
       (racket--trace-put-highlight-overlay v
                                            (racket-trace-show v)
                                            beg end
                                            101)))))

(defun racket--trace-put-highlight-overlay (v what beg end priority)
  ;; Avoid drawing overlays on top of each other, for example the
  ;; caller and called sites intersect. Whoever draws first wins.
  (unless (cl-some (lambda (o)
                     (eq (overlay-get o 'name) 'racket-trace-overlay))
                   (overlays-in beg end))
    (let* ((level (racket-trace-level v))
           (callp (racket-trace-callp v))
           (what (racket--trace-limit-string what))
           (o (make-overlay beg end))
           (face (racket--trace-level-face-name level)))
      (push o racket--trace-overlays)
      (overlay-put o 'name 'racket-trace-overlay)
      (overlay-put o 'priority priority)
      (if callp
          ;; `what' is call w/args; replace.
          (progn
            (overlay-put o 'face face)
            (overlay-put o 'display what))
        ;; `what' is results: display after. Avoid drawing redundant
        ;; results after-strings, which could happen with
        ;; trace-expression, because caller and called sites are the
        ;; same; overlay priorities won't help.
        (unless (cl-some (lambda (o)
                           (and (overlay-get o 'after-string)
                                (eq (overlay-get o 'name) 'racket-trace-overlay)))
                         (overlays-at beg))
          (overlay-put o 'display (buffer-substring beg end))
          (overlay-put o 'after-string (propertize (concat " ⇒ " what)
                                                   'face face))))))
  (list (current-buffer) beg end))

(defun racket-trace-goto-called-site ()
  (interactive)
  (pcase (racket--trace-get #'racket-trace-formals)
    (`(,file ,beg ,end)
     (setq racket--trace-called-marker
           (racket--trace-goto file beg end)))
    (_ (user-error "No called site information is available"))))

(defun racket-trace-goto-caller-site ()
  (interactive)
  (pcase (racket--trace-get #'racket-trace-caller)
    (`(,file ,beg ,end)
     (setq racket--trace-caller-marker
           (racket--trace-goto file beg end t)))
    (_ (user-error "No call site information is available"))))

(defun racket-trace-goto-context-site ()
  (interactive)
  (pcase (racket--trace-get #'racket-trace-context)
    (`(,file ,beg ,end)
     (setq racket--trace-context-marker
           (racket--trace-goto file beg end t)))
    (_ (user-error "No context site information is available"))))

(defun racket--trace-goto (file-or-buffer beg end &optional pulse-p)
  "Returns marker for BOL."
  (let ((buffer (if (bufferp file-or-buffer)
                    file-or-buffer
                  (racket--trace-buffer-for-file file-or-buffer))))
    (let ((win (display-buffer buffer
                               '((display-buffer-reuse-window
                                  display-buffer-below-selected
                                  display-buffer-use-some-window)
                                 (inhibit-same-window . t)))))
      (save-selected-window
        (select-window win)
        ;; When we move point and `racket-xp-mode' is active, its
        ;; point-motion thing kicks to display highlighting and
        ;; tooltips. Avoid by going to 1+ end, which is less likely to
        ;; be e.g. an identifier.
        (goto-char (1+ end))
        (when pulse-p
          (pulse-momentary-highlight-region beg end))
        (save-excursion (beginning-of-line) (point-marker))))))

(defun racket--trace-buffer-for-file (file)
  (or (get-file-buffer file)
      (let ((find-file-suppress-same-file-warnings t))
        (find-file-noselect file))))

(defun racket-trace-timing ()
  "Shows the time, or when a region is active, the duration."
  (interactive)
  (if (region-active-p)
      (let ((t0 (save-excursion (goto-char (region-beginning))
                                (racket--trace-get #'racket-trace-msec)))
            (t1 (save-excursion (goto-char (region-end))
                                (racket--trace-get #'racket-trace-msec))))
        (when (and (numberp t0) (numberp t1))
          (message "Duration: %s msec" (abs (- t1 t0)))))
    (let ((t0 (racket--trace-get #'racket-trace-msec)))
        (when (numberp t0)
          (message "Time: %s msec" t0)))))

;; Invisibility commands

(defun racket-trace-only-this-thread ()
  "Filter to show only traces for the thread at point."
  (interactive)
  (let ((thread (racket--trace-get #'racket-trace-thread)))
    (unless thread (user-error "No thread found"))
    (dolist (thd racket--trace-known-threads)
      (unless (eq thd thread)
        (add-to-invisibility-spec thd)))
    (save-selected-window (other-window 1)) ;HACK: cause redisplay
    (message "Showing only thread %s" thread)))

(defun racket-trace-all-threads ()
  "Remove filtering and show traces for all threads."
  (interactive)
  (dolist (thd racket--trace-known-threads)
    (remove-from-invisibility-spec thd))
  (save-selected-window (other-window 1)) ;HACK: cause redisplay
  (message "Showing all threads"))

(defun racket-trace-toggle-thread-fields-visibility ()
  (interactive)
  (if (memq racket--trace-invisible-thread buffer-invisibility-spec)
      (remove-from-invisibility-spec racket--trace-invisible-thread)
    (add-to-invisibility-spec racket--trace-invisible-thread))
  (save-selected-window (other-window 1))) ;HACK: cause redisplay

(defun racket-trace-toggle-timing-fields-visibility ()
  (interactive)
  (if (memq racket--trace-invisible-timing buffer-invisibility-spec)
      (remove-from-invisibility-spec racket--trace-invisible-timing)
    (add-to-invisibility-spec racket--trace-invisible-timing))
  (save-selected-window (other-window 1))) ;HACK: cause redisplay

;;; xref

(defun racket-trace-xref-backend-function ()
  'racket-trace-xref)

(cl-defmethod xref-backend-identifier-at-point ((_backend (eql racket-trace-xref)))
  (pcase (get-text-property (point) 'racket-trace)
    ((and (pred racket-trace-p) v)
     (propertize (racket-trace-name v) 'racket-trace v))))

(cl-defmethod xref-backend-identifier-completion-table ((_backend (eql racket-trace-xref)))
  nil)

(cl-defmethod xref-backend-definitions ((_backend (eql racket-trace-xref)) str)
  (pcase (get-text-property 0 'racket-trace str)
    ((and (pred racket-trace-p) v)
     (pcase (racket-trace-xref v)
       (`(,path ,line ,col)
        (list (xref-make str (xref-make-file-location path line col))))))))

;; TODO: Refine this limiting
(defun racket--trace-limit-string (str)
  (let ((max 80)
        (len (length str)))
    (if (< len max)
        str
      (concat (substring str 0 (min len (- 80 3)))
              "..."))))

(provide 'racket-trace)

;;; racket-trace.el ends here