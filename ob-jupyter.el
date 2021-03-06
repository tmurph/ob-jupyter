;;; ob-jupyter.el --- interact with Jupyter kernels via Org Babel  -*- lexical-binding: t; -*-

;; Author: Trevor Murphy <trevor.m.murphy@gmail.com>
;; Maintainer: Trevor Murphy <trevor.m.murphy@gmail.com>

;; This file is not part of GNU Emacs.

;; Copyright (C) 2018 Trevor Murphy

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; Jupyter Minor Mode aims to make Emacs a full-fledged Jupyter client.
;; The mode provides commands to inspect available kernels, start
;; inferior kernel processes, and connect buffers to existing processes.

;; This library supports Org Babel communication with Jupyter kernels.
;;
;; Enable with
;;   (add-to-list 'org-src-lang-modes '("jupyter" . fundamental))
;;
;; The library will take care of setting up Org Source buffers with the
;; appropriate kernel language.

;;; Code:

(require 'ob)
(require 'jupyter)

;; Customize

(defgroup ob-jupyter nil
  "Settings for Org Babel interaction with Jupyter kernels."
  :prefix "ob-jupyter-"
  :group 'jupyter)

(defcustom ob-jupyter-redisplay-images nil
  "If t, call `org-redisplay-inline-images' after any source block inserts a file."
  :type 'boolean)

(declare-function org-src--get-lang-mode "org-src" (lang))
(declare-function org-redisplay-inline-images "org" nil)

(defun ob-jupyter--babel-output (execute-reply-alist)
  "Process the Jupyter EXECUTE-REPLY-ALIST to Babel :result-type 'output.

Currently this returns the contents of the \"stdout\" stream."
  (->> execute-reply-alist
       (jupyter--stream)
       (assoc 'text)                    ; assume it's all stdout
       (cdr)))

(defun ob-jupyter--babel-value (execute-reply-alist)
  "Process the Jupyter EXECUTE-REPLY-ALIST to Babel :result-type 'value."
  (->> execute-reply-alist
       (jupyter--execute-result)
       (assoc 'text/plain)
       (cdr)))

(defun ob-jupyter--babel-value-to-dataframe
    (execute-reply-alist &optional index names)
  "Process the Jupyter EXECUTE-REPLY-ALIST and return a list-of-lists.

This function assumes that the Jupyter reply represents some sort
of dataframe-like object, so the Babel params :df-index
and :df-names specify how to handle the index and column names.

Process first row of data according to NAMES:
 - if nil, don't do any column name processing
 - if \"yes\", insert an 'hline after the first row of data
 - if \"no\", exclude the first row / column names

Process first column of data according to INDEX:
 - if nil or \"yes\", don't do any index processing
 - if \"no\", exclude the first column / index column"
  (let* ((result-alist (jupyter--execute-result execute-reply-alist))
         (text (cdr (assoc 'text/plain result-alist)))
         (all-rows (split-string text "\n"))
         (row-fn (if (string= index "no")
                     (lambda (row) (cdr (split-string row " +")))
                   (lambda (row) (split-string row " +"))))
         results)
    (cond
     ((string= names "yes")
      (push (funcall row-fn (pop all-rows)) results)
      (push 'hline results))
     ((string= names "no")
      (pop all-rows)))
    (dolist (row all-rows)
      (push (funcall row-fn row) results))
    (nreverse results)))

(defun ob-jupyter--babel-value-to-series
    (execute-reply-alist &optional index)
  "Process the Jupyter EXECUTE-REPLY-ALIST and return a list-of-lists.

This function assumes that the Jupyter reply represents a Pandas
Series object, and the Babel param :s-index specifies how to
handle the index column.

Process first column of data according to INDEX:
 - if nil or \"yes\", leave the index in place
 - if \"no\", exclude the first column / index column"
  (let* ((result-alist (jupyter--execute-result execute-reply-alist))
         (text (cdr (assoc 'text/plain result-alist)))
         (all-rows (split-string text "\n"))
         (row-fn (if (string= index "no")
                     (lambda (row) (cdr (split-string row " +")))
                   (lambda (row) (split-string row " +"))))
         results)
    (dolist (row all-rows)
      (push (funcall row-fn row) results))
    ;; the last entry in the reply is the dtype of the series
    ;; let's ignore that for now
    (pop results)
    (nreverse results)))

(defun ob-jupyter--babel-value-to-file
    (execute-reply-alist &optional file-name output-dir file-ext)
  "Process the Jupyter EXECUTE-REPLY-ALIST and return a filename.

This function assumes that the Jupyter reply contains an image,
so file extensions should be png or svg.

If FILE-NAME is provided, put results in that file and return that name.

In the following cases, if OUTPUT-DIR is not provided, use the
current directory.

If FILE-NAME is not provided, generate a file with extension
FILE-EXT in OUTPUT-DIR using `make-temp-name'.

If neither FILE-NAME nor FILE-EXT is provided, generate a file in
OUTPUT-DIR using `make-temp-name' and the mime types available in
EXECUTE-REPLY-ALIST.  Prefer png over svg."
  (let* ((display-alist (jupyter--display-data execute-reply-alist))
         (png-data (cdr (assoc 'image/png display-alist)))
         (svg-data (cdr (assoc 'image/svg+xml display-alist))))
    (unless file-ext
      (cond
       (png-data
        (setq file-ext "png"))
       (svg-data
        (setq file-ext "svg"))))
    (unless file-name
      (setq file-name (concat (make-temp-name "") "." file-ext)))
    (unless (or (not output-dir)
                (string-prefix-p output-dir file-name))
      (setq file-name (concat (file-name-as-directory output-dir)
                              file-name)))
    (cond
     ((string= file-ext "png")
      (with-temp-buffer
        (let ((buffer-file-coding-system 'binary)
              (require-final-newline nil))
          (insert (base64-decode-string png-data))
          (write-region nil nil file-name))))
     ((string= file-ext "svg")
      (with-temp-buffer
        (let ((require-final-newline nil))
          (insert svg-data)
          (write-region nil nil file-name)))))
    file-name))

(defun ob-jupyter--babel-extract-fn (params)
  "Return the appropriate function to compute results according to Babel PARAMS."
  (let* ((result-type (alist-get :result-type params))
         (result-params (alist-get :result-params params))
         (df-index (alist-get :df-index params))
         (df-names (alist-get :df-names params))
         (s-index (alist-get :s-index params))
         (file (alist-get :file params))
         (output-dir (alist-get :output-dir params))
         (file-ext (alist-get :file-ext params)))
    (cond
     ((eq result-type 'output)
      #'ob-jupyter--babel-output)
     ((member "dataframe" result-params)
      (lambda (alist)
        (ob-jupyter--babel-value-to-dataframe alist df-index df-names)))
     ((member "series" result-params)
      (lambda (alist)
        (ob-jupyter--babel-value-to-series alist s-index)))
     ((member "file" result-params)
      (lambda (alist)
        (ob-jupyter--babel-value-to-file alist file output-dir file-ext)))
     (t
      (lambda (alist)
        (let ((value (ob-jupyter--babel-value alist)))
          (and value
               (org-babel-result-cond result-params
                 value
                 (org-babel-script-escape value)))))))))

(defun ob-jupyter--acquire-session (session params)
  "Wrap `jupyter--acquire-session' for use from `ob-jupyter' functions.

Extract appropriate values from PARAMS and pass them along with SESSION."
  (let* ((kernel-param (alist-get :kernel params))
         (conn-filename (alist-get :existing params))
         (ssh-server (alist-get :ssh params))
         (cmd-args (alist-get :cmd-args params))
         (kernel-args (alist-get :kernel-args params)))
    (jupyter--acquire-session session kernel-param conn-filename
                              ssh-server cmd-args kernel-args)))

(defvar org-babel-default-header-args:jupyter
  '((:df-names . "yes")
    (:df-index . "yes")
    (:s-index . "yes")
    (:session . "default")
    (:kernel . "python")
    (:exports . "both")))

(defun org-babel-edit-prep:jupyter (babel-info)
  "Set up the edit buffer per BABEL-INFO.

BABEL-INFO is as returned by `org-babel-get-src-block-info'."
  (let* ((params (nth 2 babel-info))
         (session (alist-get :session params))
         (kernel (cdr (assoc session jupyter--session-kernels-alist)))
         (lang (cdr (assoc session jupyter--session-langs-alist))))
    (if (not kernel)
        (message "No running kernel. Cannot set up src buffer.")
      ;; We're going to change the source buffer major mode from
      ;; `fundamental-mode' to whatever the kernel language calls for.

      ;; This violates an important Org assumption.  Specifically,
      ;; `org-edit-src-code' sets up local variables that tell Org how
      ;; to return edits back to the original buffer.  These local
      ;; variables will get killed when we reset the major mode, so here
      ;; we hack around that behavior.

      ;; We could avoid this hack by storing the desired buffer major
      ;; mode in a babel param like Org Babel expects.  However, I don't
      ;; know how to do that with my current code.
      (cl-letf (((symbol-function 'kill-all-local-variables)
                 (lambda () (run-hooks 'change-major-mode-hook))))
        (funcall (org-src--get-lang-mode lang)))
      (setq-local jupyter--current-kernel kernel)
      (jupyter-mode +1)
      (run-hook-with-args
       (intern (format "ob-jupyter-%s-edit-prep-hook" lang))
       babel-info))))

(defun org-babel-variable-assignments:jupyter (params)
  "Return variable assignment statements according to PARAMS.

PARAMS must include a :session parameter associated with an
active kernel, to determine the underlying expansion language."
  (let* ((session (alist-get :session params))
         (lang (cdr (assoc session jupyter--session-langs-alist)))
         (var-fn (intern (format "org-babel-variable-assignments:%s" lang)))
         (var-fn (if (fboundp var-fn) var-fn #'ignore)))
    (if (not lang)
        (user-error "No kernel language for variable assignment")
      (funcall var-fn params))))

(defun org-babel-expand-body:jupyter (body params &optional var-lines)
  "Expand BODY according to PARAMS.

PARAMS must include a :session parameter associated with an
active kernel, to determine the underlying expansion language.

If provided, include VAR-LINES before BODY."
  (let* ((session (alist-get :session params))
         (lang (cdr (assoc session jupyter--session-langs-alist)))
         (expand-fn (intern (format "org-babel-expand-body:%s" lang)))
         (expand-fn (if (fboundp expand-fn)
                        expand-fn
                      #'org-babel-expand-body:generic)))
    (if (not lang)
        (user-error "No kernel language for code expansion")
      (funcall expand-fn body params var-lines))))

(defun org-babel-execute:jupyter (body params)
  "Execute the BODY of an Org Babel Jupyter src block.

PARAMS are the Org Babel parameters associated with the block."
  (let* ((session (alist-get :session params))
         (kernel (cdr (ob-jupyter--acquire-session session params)))
         (deferred-timeout (alist-get :timeout params))
         (result-params (alist-get :result-params params))
         (extract-fn (ob-jupyter--babel-extract-fn params))
         (redisplay (and (member "file" result-params)
                         ob-jupyter-redisplay-images))
         (src-marker (point-marker))
         var-lines code)
    (if (not kernel)
        (user-error "No running kernel to execute src block")
      ;; do this here, after the kernel error check
      ;; if we do this in the let form, we get confusing error messages
      (setq var-lines (org-babel-variable-assignments:jupyter params)
            code (org-babel-expand-body:jupyter body params var-lines))
      (deferred:$
        (jupyter--execute-deferred kernel code deferred-timeout)
        (deferred:nextc it #'jupyter--raise-error-maybe)
        (deferred:nextc it extract-fn)
        (deferred:set-next it
          (make-deferred
           :callback (lambda (result)
                       (with-current-buffer (marker-buffer src-marker)
                         (save-mark-and-excursion
                          (goto-char src-marker)
                          (org-babel-insert-result result result-params)
                          (set-marker src-marker nil))
                         (when redisplay (org-redisplay-inline-images))))
           :errorback (lambda (e)
                        (with-current-buffer (marker-buffer src-marker)
                          (save-mark-and-excursion
                           (goto-char src-marker)
                           (org-babel-remove-result)
                           (set-marker src-marker nil)))
                        (deferred:resignal e)))))
      "*")))

;;; This function is expected to return the session buffer.
;;; It functions more like -acquire-session (in the RAII sense).
(defun org-babel-jupyter-initiate-session (session params)
  "Return the comint buffer associated with SESSION.

If no such buffer exists yet, one will be created via
`jupyter--initialize-kernel'.  If the PARAMS plist includes any
of the following keys, they will be passed to
`jupyter--initialize-kernel':

 :kernel :existing :ssh :cmd-args :kernel-args"
  (let* ((session-cons (ob-jupyter--acquire-session session params))
         (kernel (cdr session-cons)))
    (jupyter-struct-buffer kernel)))

;; Python specific

(defvar ob-jupyter-python-edit-prep-hook nil)

(provide 'ob-jupyter)
;;; ob-jupyter.el ends here
