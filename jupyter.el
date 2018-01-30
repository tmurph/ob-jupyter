;;; jupyter.el --- interact with Jupyter kernels  -*- lexical-binding: t; -*-

;; Author: Trevor Murphy <trevor.m.murphy@gmail.com>
;; Maintainer: Trevor Murphy <trevor.m.murphy@gmail.com>
;; Version: 0.1.0
;; URL: https://github.com/tmurph/jupyter-mode
;; Package-Requires: (company deferred dash emacs-ffi)

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

;; This library also includes `ob-jupyter.el', Org-Babel support for
;; communicating with Jupyter kernels.
;;
;; Enable with
;;   (add-to-list 'org-src-lang-modes '("jupyter" . fundamental))
;;
;; The library will take care of setting up Org Source buffers with the
;; appropriate kernel language.

;; This library also includes `company-jupyter.el', support for
;; completion with Company.
;;
;; Enable with
;;   (add-to-list 'company-backends 'company-jupyter)
;;
;; Completion will only work in a buffer when Jupyter minor mode is
;; active and the buffer has an associated inferior kernel process.

;; Much of the ZMQ FFI code has been copied without changes from John
;; Kitchin's work here:
;; http://kitchingroup.cheme.cmu.edu/blog/2017/07/13/An-Emacs-zeromq-library-using-an-ffi/
;; Used under a CC BY-AS 4.0 license.

;; The rest is very much inspired by (though not copied from) Greg
;; Sexton's ob-ipython.el here:
;; https://github.com/gregsexton/ob-ipython

;;; Code:

(require 'ffi)
(require 'hmac-def)
(require 'json)
(require 'dash)
(require 'deferred)
(require 'company)
(require 'ob)

;; Bullshit

;;; this is exactly like `assq-delete-all' except with `equal'
;;; for some reason that's not built in
(defun ob-jupyter-assoc-delete-all (key alist)
  "Delete from ALIST all elements whose car is `equal' to KEY.
Return the modified alist.
Elements of ALIST that are not conses are ignore."
  (while (and (consp (car alist))
              (equal (car (car alist)) key))
    (setq alist (cdr alist)))
  (let ((tail alist) tail-cdr)
    (while (setq tail-cdr (cdr tail))
      (if (and (consp (car tail-cdr))
               (equal (car (car tail-cdr)) key))
          (setcdr tail (cdr tail-cdr))
        (setq tail tail-cdr))))
  alist)

;; Constants

(defconst ob-jupyter-delim "<IDS|MSG>"
  "The special delimiter used in the Jupyter wire protocol.")

(defconst ob-jupyter-protocol-version "5.2"
  "Messaging protocol implemented in this library.

The Jupyter message specification is versioned independently of
the packages that use it, e.g. jupyter servers and clients.

For full details see
http://jupyter-client.readthedocs.io/en/latest/messaging.html#versioning")

(defconst ob-jupyter-zmq-max-recv (expt 2 17)
  "The size, in bytes, allocated to read ZMQ messages.")

;; External Definitions

(autoload 'org-id-uuid "org-id")
(declare-function org-src--get-lang-mode "org-src" (lang))

(autoload 'ansi-color-apply "ansi-color")

(defvar python-shell-buffer-name)
(defvar python-shell--interpreter)
(defvar python-shell--interpreter-args)
(declare-function inferior-python-mode "python" nil)

(declare-function org-babel-python-without-earmuffs "ob-python" (session))

(defvar ob-jupyter-python-edit-prep-hook)

;; Customize

(defgroup jupyter nil
  "Settings for Jupyter kernel interaction."
  :prefix "jupyter-"
  :group 'languages)

(defcustom jupyter-runtime-dir "~/Library/Jupyter/runtime"
  "The directory to look for runtime connection files."
  :type 'string
  :group 'jupyter)

(defcustom jupyter-command "jupyter-console"
  "Command to start the interactive interpreter."
  :type 'string
  :group 'jupyter)

(defcustom jupyter-command-args '("--simple-prompt")
  "Default arguments for the interactive interpreter."
  :type '(repeat string)
  :group 'jupyter)

(defcustom jupyter-poll-msec 5
  "The wait time (in msec) between polls to Jupyter sockets.

A shorter wait time increases Emacs CPU load."
  :type 'integer
  :group 'jupyter)

;; ZMQ ffi

(define-ffi-library zmq "libzmq")

(define-ffi-function zmq-errno "zmq_errno"
  (:int "the C errno")
  nil zmq
  "retrieve the C errno as known to the 0MQ thread.
http://api.zeromq.org/4-2:zmq-errno")

(define-ffi-function zmq-strerror "zmq_strerror"
  (:pointer "Error message string")
  ((:int errnum "The C errno"))
  zmq
  "the error message string corresponding to the specified error number
http://api.zeromq.org/4-2:zmq-strerror")

(define-ffi-function zmq-ctx-new "zmq_ctx_new"
  (:pointer "Pointer to a context")
  nil zmq
  "create new ØMQ context.
http://api.zeromq.org/4-2:zmq-ctx-new")

(define-ffi-function zmq-ctx-destroy "zmq_ctx_destroy"
  (:int "status")
  ((:pointer *context)) zmq
  "terminate a ØMQ context.
http://api.zeromq.org/4-2:zmq-ctx-destroy")

(define-ffi-function zmq-socket "zmq_socket"
  (:pointer "Pointer to a socket.")
  ((:pointer *context "Created by `zmq-ctx-new '.")
   (:int type)) zmq
   "create ØMQ socket.
http://api.zeromq.org/4-2:zmq-socket")

(define-ffi-function zmq-close "zmq_close"
  (:int "Status")
  ((:pointer *socket "Socket pointer created by `zmq-socket'")) zmq
  "close ØMQ socket.
http://api.zeromq.org/4-2:zmq-close")

(define-ffi-function zmq-connect "zmq_connect"
  (:int "Status")
  ((:pointer *socket "Socket pointer created by `zmq-socket'")
   (:pointer *endpoint "Char pointer, e.g. (ffi-make-c-string \"tcp://localhost:5555\")"))
  zmq
  "create outgoing connection from socket.
http://api.zeromq.org/4-2:zmq-connect")

(define-ffi-function zmq-disconnect "zmq_disconnect"
  (:int "Status")
  ((:pointer *socket "Socket pointer created by `zmq-socket'")
   (:pointer *endpoint "Char pointer, e.g. (ffi-make-c-string \"tcp://localhost:5555\")"))
  zmq
  "disconnect from socket from endpoint.
http://api.zeromq.org/4-2:zmq-disconnect")

(define-ffi-function zmq-setsockopt "zmq_setsockopt"
  (:int "Status")
  ((:pointer *socket "Socket pointer created by `zmq-socket'")
   (:int optnam "Name of option to set")
   (:pointer *optval "Pointer to option value")
   (:size_t len "Option value length in bytes"))
  zmq
  "set socket option.
http://api.zeromq.org/4-2:zmq-setsockopt")

(define-ffi-function zmq-getsockopt "zmq_getsockopt"
  (:int "Status")
  ((:pointer *socket "Socket pointer created by `zmq-socket'")
   (:int optnam "Name of option to get")
   (:pointer *optval "Buffer to receive option value")
   (:pointer *len "Pointer to length of bytes written to OPTVAL."))
  zmq
  "get socket option.
http://api.zeromq.org/4-2:zmq-getsockopt")

(define-ffi-function zmq-send "zmq_send"
  (:int "Number of bytes sent or -1 on failure.")
  ((:pointer *socket "Pointer to a socket.")
   (:pointer *msg "Pointer to a C-string to send")
   (:size_t len "Number of bytes to send")
   (:int flags))
  zmq
  "send a message part on a socket.
http://api.zeromq.org/4-2:zmq-send")

(define-ffi-function zmq-recv "zmq_recv"
  (:int "Number of bytes received or -1 on failure.")
  ((:pointer *socket)
   (:pointer *buf "Pointer to c-string to put result in.")
   (:size_t len "Length to truncate message at.")
   (:int flags))
  zmq
  "receive a message part from a socket.
http://api.zeromq.org/4-2:zmq-recv")

;; We cannot get these through a ffi because the are #define'd for the
;; CPP and invisible in the library. They only exist in the zmq.h file.

;; socket types

(defconst ZMQ-SUB 2
  "ZMQ Subscriber socket type.

A socket of type ZMQ_SUB is used by a subscriber to subscribe to
data distributed by a publisher.  Initially a ZMQ_SUB socket is
not subscribed to any messages, use the ZMQ_SUBSCRIBE option of
zmq_setsockopt(3) to specify which messages to subscribe to.  The
zmq_send() function is not implemented for this socket type.")

(defconst ZMQ-REQ 3
  "ZMQ Request socket type.

A socket of type ZMQ_REQ is used by a client to send requests to
and receive replies from a service.  This socket type allows only
an alternating sequence of zmq_send(request) and subsequent
zmq_recv(reply) calls.  Each request sent is round-robined among
all services, and each reply received is matched with the last
issued request.")

(defconst ZMQ-DEALER 5
  "ZMQ Dealer socket type.

A socket of type ZMQ_DEALER is an advanced pattern used for
extending request/reply sockets.  Each message sent is
round-robined among all connected peers, and each message
received is fair-queued from all connected peers.")

;; socket options

(defconst ZMQ-SUBSCRIBE 6
  "ZMQ Subscriber socket option.

The ZMQ_SUBSCRIBE option shall establish a new message filter on
a ZMQ_SUB socket.  Newly created ZMQ_SUB sockets shall filter out
all incoming messages, therefore you should call this option to
establish an initial message filter.

An empty option_value of length zero shall subscribe to all
incoming messages.  A non-empty option_value shall subscribe to
all messages beginning with the specified prefix.  Multiple
filters may be attached to a single ZMQ_SUB socket, in which case
a message shall be accepted if it matches at least one filter.")

(defconst ZMQ-RCVMORE 13
  "ZMQ socket option.

The ZMQ_RCVMORE option shall return True (1) if the message part
last received from the socket was a data part with more parts to
follow.  If there are no data parts to follow, this option shall
return False (0).")

(defconst ZMQ-EVENTS 15
  "ZMQ socket option.

The ZMQ_EVENTS option shall retrieve the event state for the
specified socket.  The returned value is a bit mask constructed
by OR'ing a combination of the following event flags:

ZMQ_POLLIN --- indicates that at least one message may be
received from the specified socket without blocking.

ZMQ_POLLOUT --- indicates that at least one message may be sent
to the specified socket without blocking.")

(defconst ZMQ-POLLIN 1)
(defconst ZMQ-POLLOUT 2)

;; send/recv options

(defconst ZMQ-DONTWAIT 1
  "ZMQ send/recv option.

With send: for socket types (DEALER, PUSH) that block when there
are no available peers (or all peers have full high-water mark),
specifies that the operation should be performed in non-blocking
mode.  If the message cannot be queued on the socket, the
zmq_send() function shall fail with errno set to EAGAIN.

With recv: specifies that the operation should be performed in
non-blocking mode.  If there are no messages available on the
specified socket, the zmq_recv() function shall fail with errno
set to EAGAIN.")

(defconst ZMQ-SNDMORE 2
  "ZMQ send option.

Specifies that the message being sent is a multi-part message,
and that further message parts are to follow.  An application
that sends multi-part messages must use the ZMQ_SNDMORE flag when
sending each message part except the final one.")

;; ZMQ API

(defun zmq-error-string ()
  "Retrieve the error message string of the last ZMQ error."
  (ffi-get-c-string (zmq-strerror (zmq-errno))))

(defun zmq-receive (num socket)
  "Read a string (up to NUM bytes) from SOCKET.

May read fewer bytes if that's all that the socket has to give."
  (let ((status -1))
    (with-ffi-string (r (make-string num ? ))
      (while (< status 0)
        (setq status (zmq-recv socket r num ZMQ-DONTWAIT)))
      (substring (ffi-get-c-string r) 0 status))))

(defun zmq-receive-multi (num socket)
  "Read a multipart message (up to NUM bytes per message) from SOCKET.

Returns a list of the various parts."
  (let ((more t)
        num-bytes ret)
    (with-ffi-temporaries ((zmore :int)
                           (size :size_t))
      (with-ffi-string (recv-str (make-string num ? ))
        (ffi--mem-set size :size_t (ffi--type-size :int))
        (while more
          (setq num-bytes (zmq-recv socket recv-str num 0))
          (when (= -1 num-bytes)
            (error "Could not receive a message"))
          (push (substring (ffi-get-c-string recv-str) 0 num-bytes) ret)
          (zmq-getsockopt socket ZMQ-RCVMORE zmore size)
          (setq more (ffi--mem-ref zmore :bool)))))
    (nreverse ret)))

(defun zmq-send-multi (str-list socket)
  "Send STR-LIST as a multi-part message to SOCKET."
  (let (str flag)
    (while (setq flag 0
                 str (pop str-list))
      (when str-list
        (setq flag ZMQ-SNDMORE))
      (with-ffi-string (s str)
        (zmq-send socket s (length str) flag)))))

(defun zmq-check-for-receive (socket)
  "Check if a message may be received from SOCKET."
  (let (events)
    (with-ffi-temporaries ((zevents :int)
                           (size :size_t))
      (ffi--mem-set size :size_t (ffi--type-size :int))
      (zmq-getsockopt socket ZMQ-EVENTS zevents size)
      (setq events (ffi--mem-ref zevents :int)))
    (> (logand events ZMQ-POLLIN) 0)))

;; Authentication

(defun ob-jupyter-strings-to-unibyte (strings)
  "Convert STRINGS to UTF8 unibyte strings."
  (let (ret)
    (dolist (s strings (nreverse ret))
      (push (encode-coding-string s 'utf-8 t) ret))))

(defun ob-jupyter-hash-to-string (bytestring)
  "Convert BYTESTRING to ascii string of hex digits."
  (let (ret)
    (dolist (c (string-to-list bytestring)
               (apply #'concat (nreverse ret)))
      (push (format "%02x" c) ret))))

(defun ob-jupyter-sha256 (object)
  "Hash OBJECT with the sha256 algorithm."
  (secure-hash 'sha256 object nil nil t))

(define-hmac-function ob-jupyter-hmac-sha256
  ob-jupyter-sha256 64 32)

(advice-add 'ob-jupyter-hmac-sha256 :filter-args
            #'ob-jupyter-strings-to-unibyte)

(advice-add 'ob-jupyter-hmac-sha256 :filter-return
            #'ob-jupyter-hash-to-string)

;; Process Management

(cl-defstruct (ob-jupyter-struct
               (:constructor ob-jupyter-struct-create)
               (:copier ob-jupyter-struct-copy))
  "Jupyter kernel management object.

`ob-jupyter-struct-name' The name used to identify this struct.

`ob-jupyter-struct-process' The Jupyter process started by Emacs.

`ob-jupyter-struct-buffer' The comint REPL buffer.

`ob-jupyter-struct-conn-file-name'

`ob-jupyter-struct-iopub' A ZMQ socket object connected to the
  Jupyter IOPub port.

`ob-jupyter-struct-shell' A ZMQ socket object connected to the
Jupyter Shell port.

`ob-jupyter-struct-context' A ZMQ context object to manage the sockets.

`ob-jupyter-struct-key' The HMAC-SHA256 key used to authenticate
to the Jupyter server."
  (name nil :read-only t)
  (process nil :read-only t)
  (buffer nil :read-only t)
  (conn-file-name nil :read-only t)
  (iopub nil :read-only t)
  (shell nil :read-only t)
  (context nil :read-only t)
  (key nil :read-only t))

(defun ob-jupyter-initialize-kernel
    (kernel name &optional cmd-args kernel-args)
  "Start a Jupyter KERNEL and associate a comint repl.

If KERNEL is nil, just use the Jupyter default (python).

The process name, comint buffer name, and Jupyter connection file
name will all derive from NAME.

If provided, the CMD-ARGS and KERNEL-ARGS (which must be lists) will
be passed to `jupyter-command' like so:

$ `jupyter-command' `jupyter-command-args'
  -f derived-connection-file
  CMD-ARGS --kernel KERNEL KERNEL-ARGS

Returns an `ob-jupyter-struct'."
  (let* ((proc-name (format "*ob-jupyter-%s*" name))
         (proc-buffer-name (format "*Jupyter:%s*" name))
         (conn-file (format "emacs-%s.json" name))
         (full-file (expand-file-name conn-file jupyter-runtime-dir))
         (full-args (-flatten
                     (list jupyter-command-args
                           "-f" conn-file cmd-args
                           (and kernel '("--kernel" kernel))
                           kernel-args)))
         proc-buf json ctx iopub shell)
    ;; this creates the conn-file in `jupyter-runtime-dir'
    (setq proc-buf (apply #'make-comint-in-buffer proc-name
                          proc-buffer-name jupyter-command
                          nil full-args))
    (while (not (file-exists-p full-file)) (sleep-for 0 5))
    ;; so we can read the file here
    (setq json (json-read-file full-file)
          ctx (zmq-ctx-new)
          shell (zmq-socket ctx ZMQ-DEALER)
          iopub (zmq-socket ctx ZMQ-SUB))
    (with-ffi-strings ((s (format "%s://%s:%s"
                                  (cdr (assq 'transport json))
                                  (cdr (assq 'ip json))
                                  (cdr (assq 'shell_port json))))
                       (i (format "%s://%s:%s"
                                  (cdr (assq 'transport json))
                                  (cdr (assq 'ip json))
                                  (cdr (assq 'iopub_port json))))
                       (z ""))
      (zmq-connect shell s)
      (zmq-connect iopub i)
      (zmq-setsockopt iopub ZMQ-SUBSCRIBE z 0))
    (ob-jupyter-struct-create :name name
                              :process (get-buffer-process proc-buf)
                              :buffer proc-buf
                              :conn-file-name conn-file
                              :iopub iopub
                              :shell shell
                              :context ctx
                              :key (cdr (assq 'key json)))))

(defun ob-jupyter-finalize-kernel (struct)
  "Forcibly stop the kernel in STRUCT and clean up associated ZMQ objects."
  (let ((proc (ob-jupyter-struct-process struct)))
    (when (process-live-p proc)
      (kill-process proc)
      (sleep-for 0 5)))
  (kill-buffer (ob-jupyter-struct-buffer struct))
  (zmq-close (ob-jupyter-struct-iopub struct))
  (zmq-close (ob-jupyter-struct-shell struct))
  (zmq-ctx-destroy (ob-jupyter-struct-context struct)))

;; Low level

(defun ob-jupyter-recv-message (socket)
  "Read a Jupyter protocol message from 0MQ SOCKET.

Returns a list of elements of the message."
  (zmq-receive-multi ob-jupyter-zmq-max-recv socket))

(defun ob-jupyter-send-message (socket msg)
  "Send Jupyter protocol MSG to 0MQ SOCKET.

MSG is a list of elements of the message."
  (zmq-send-multi msg socket))

(defun ob-jupyter-poll-deferred (socket &optional timeout)
  "Defer polling SOCKET until a reply is ready.

If TIMEOUT is not nil, will time out after TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (deferred:new
    (deferred:lambda (elapsed)
      (cond
       ((zmq-check-for-receive socket) t)
       ((and timeout elapsed (> elapsed timeout))
        (error "Socket poll timed out"))
       (t (deferred:next self (+ (or elapsed 0) jupyter-poll-msec)))))))

;; Mid level

(defun ob-jupyter-authenticate-message (key msg)
  "Error if MSG does not authenticate with and KEY.

Returns MSG unchanged if it authenticates.

Uses `ob-jupyter-hmac-sha256' to authenticate."
  (let ((orig-msg msg)
        hmac rest)
    (while (and msg (not (string= ob-jupyter-delim (pop msg)))))
    (setq hmac (pop msg)
          rest (apply #'concat msg))
    (unless (or (string= hmac "")
                (string= hmac (ob-jupyter-hmac-sha256 rest key)))
      (error (concat "Message failed to authenticate!\n"
                     "  msg: %.70s") msg))
    orig-msg))

(defun ob-jupyter-validate-header-alist (alist)
  "Error if ALIST is not a valid Jupyter protocol header section."
  (let ((keys '(msg_id username session date msg_type version))
        value)
    (dolist (key keys)
      (setq value (assq key alist))
      (unless value
        (error (concat "Header is missing a required key!\n"
                       "  key: %s") key))
      (unless (stringp (cdr value))
        (error (concat "Header value is not a string!\n"
                       "  key: %s\n"
                       "  value: %s") key value)))))

(defun ob-jupyter-validate-parent_header-alist (alist)
  "Error if ALIST is not a valid Jupyter protocol parent_header section."
  (when alist
    (ob-jupyter-validate-header-alist alist)))

(defun ob-jupyter-validate-metadata-alist (alist)
  "Error if ALIST is not a valid Jupyter protocol metadata section."
  (unless (json-encode-alist alist)
    (error (concat "Metadata is not a valid alist!\n"
                   "  meta: %.70s") alist)))

(defun ob-jupyter-validate-content-alist (alist)
  "Error if ALIST is not a valid Jupyter protocol content section."
  (unless (json-encode-alist alist)
    (error (concat "Content is not a valid alist!\n"
                   "  content: %.70s") alist)))

(defun ob-jupyter-validate-alist (alist)
  "Error if ALIST is not a valid Jupyter protocol representation.

Returns alist unchanged if it is valid.

ALIST may include the following keys:
 - ident (may be a list of IDs or just a single ID)

ALIST must include the following nested key structure:
 - header
   - msg_id
   - username
   - session
   - date
   - msg_type
   - version
 - parent_header
 - metadata
 - content

For additional details, see http://jupyter-client.readthedocs.io/en/latest/messaging.html#general-message-format"
  (let ((keys '(header parent_header metadata content)))
    (dolist (key keys alist)
      (funcall (symbol-function (intern (format
                                         "ob-jupyter-validate-%s-alist"
                                         key)))
               (cdr (assq key alist))))))

(defun ob-jupyter-signed-message-from-parts (key id-parts msg-parts)
  "Create a signed Jupyter protocol message from KEY, ID-PARTS, and MSG-PARTS.

ID-PARTS may be nil, a single string ident, or a list of string
idents.  MSG-PARTS must be a list of four strings encoding JSON
dictionaries as per the Jupyter protocol.

If KEY is nil or the empty string, don't actually sign the
message before returning."
  (let (ret)
    (if (stringp id-parts)
        (push id-parts ret)
      (dolist (elt id-parts) (push elt ret)))
    (push ob-jupyter-delim ret)
    (if (and key (not (string= key "")))
        (push (ob-jupyter-hmac-sha256 (apply #'concat msg-parts) key) ret)
      (push "" ret))
    (dolist (elt msg-parts) (push elt ret))
    (nreverse ret)))

(defun ob-jupyter-alist-from-message (msg)
  "Convert Jupyter protocol MSG (in list-of-json-str form) to alist."
  (let ((keys '(header parent_header metadata content))
        key json-str ret)
    (while (and msg (not (string= ob-jupyter-delim (pop msg)))))
    (pop msg)                             ; discard hmac
    (while (setq key (pop keys)
                 json-str (pop msg))
      (push (cons key (json-read-from-string json-str)) ret))
    (nreverse ret)))

(defun ob-jupyter-msg-parts-from-alist (alist)
  "Convert Jupyter protocol ALIST to lists of json str."
  (let ((keys '(header parent_header metadata content))
        ret)
    (dolist (key keys (nreverse ret))
      (push (json-encode-alist (cdr (assq key alist))) ret))))

(defun ob-jupyter-msg-type-from-alist (alist)
  "Extract the \"msg_type\" value from Jupyter protocol ALIST."
  (->> alist
       (assoc 'header)
       (assoc 'msg_type)
       (cdr)))

(defun ob-jupyter-default-header (msg_type &optional session)
  "Create a Jupyter protocol header alist of type MSG_TYPE.

If SESSION is provided, use that as the session value.
Otherwise, generate a new session UUID."
  `((msg_id . ,(org-id-uuid))
    (username . ,(user-login-name))
    (session . ,(or session (org-id-uuid)))
    (date . ,(format-time-string "%FT%T.%6NZ" nil t))
    (msg_type . ,msg_type)
    (version . ,ob-jupyter-protocol-version)))

(defun ob-jupyter-kernel-info-request-alist ()
  "Return a Jupyter protocol request for kernel info."
  `((header ,@(ob-jupyter-default-header "kernel_info_request"))
    (parent_header)
    (metadata)
    (content)))

(defun ob-jupyter-execute-request-alist (code)
  "Return a Jupyter protocol request to execute CODE."
  `((header ,@(ob-jupyter-default-header "execute_request"))
    (parent_header)
    (metadata)
    (content
     (code . ,code)
     (silent . :json-false)
     (store_history . t)
     (user_expressions)
     (allow_stdin . :json-false)
     (stop_on_error . t))))

(defun ob-jupyter-inspect-request-alist (pos code)
  "Return a Jupyter protocol request to inspect the object at POS in CODE."
  `((header ,@(ob-jupyter-default-header "inspect_request"))
    (parent_header)
    (metadata)
    (content
     (code . ,code)
     (cursor_pos . ,pos)
     (detail_level . 0))))

(defun ob-jupyter-complete-request-alist (pos code)
  "Return a Jupyter protocol request to complete the CODE at POS."
  `((header ,@(ob-jupyter-default-header "complete_request"))
    (parent_header)
    (metadata)
    (content
     (code . ,code)
     (cursor_pos . ,pos))))

(defun ob-jupyter-shutdown-request-alist (&optional restart)
  "Return a Jupyter protocol request to shut down the kernel.

If RESTART, restart the kernel after the shutdown."
  `((header ,@(ob-jupyter-default-header "shutdown_request"))
    (parent_header)
    (metadata)
    (content
     (restart . ,(if restart t :json-false)))))

(defun ob-jupyter-iopub-last-p (alist)
  "Return t if ALIST is the last expected message on the IOPub channel."
  (->> alist
       (assq 'content)
       (assq 'execution_state)
       cdr
       (string= "idle")))

(defun ob-jupyter-shell-last-p (alist)
  "Return t if ALIST is the last expected message on the Shell channel."
  (->> alist
       (assq 'header)
       (assq 'msg_type)
       cdr
       (string-match-p "reply\\'")))

(defun ob-jupyter-shell-content-from-alist (reply-alist)
  "Extract the \"content\" alist from the \"shell\" part of REPLY-ALIST."
  (->> reply-alist
       (assoc 'shell)
       (cadr)       ; assume shell reply is a list with just one message
       (assoc 'content)))

(defun ob-jupyter-iopub-content-from-alist (msg-type reply-alist)
  "Extract the \"content\" alist from the first IOPub message of type MSG-TYPE in REPLY-ALIST."
  (let ((rest (cdr (assoc 'iopub reply-alist)))
        alist result)
    (while (and rest (not result))
      (setq alist (car rest)
            rest (cdr rest))
      (when (string= msg-type (ob-jupyter-msg-type-from-alist alist))
        (setq result alist)))
    (assoc 'content result)))

(defun ob-jupyter-language (kernel-info-reply-alist)
  "Extract the kernel language from KERNEL-INFO-REPLY-ALIST."
  (->> kernel-info-reply-alist
       (ob-jupyter-shell-content-from-alist)
       (assoc 'language_info)
       (assoc 'name)
       (cdr)))

(defun ob-jupyter-implementation (kernel-info-reply-alist)
  "Extract the kernel implementation from KERNEL-INFO-REPLY-ALIST."
  (->> kernel-info-reply-alist
       (ob-jupyter-shell-content-from-alist)
       (assoc 'implementation)
       (cdr)))

(defun ob-jupyter-status (execute-reply-alist)
  "Extract the execution status from EXECUTE-REPLY-ALIST.

Returns a string, either \"ok\", \"abort\", or \"error\"."
  (->> execute-reply-alist
       (ob-jupyter-shell-content-from-alist)
       (assoc 'status)
       (cdr)))

(defun ob-jupyter-execute-result (execute-reply-alist)
  "Extract the IOPub \"execute_result\" from EXECUTE-REPLY-ALIST.

Returns an alist of mimetypes and contents, so like:
 \((text/plain . \"this is always here\")
  \(text/html . \"maybe this is here\"))"
  (->> execute-reply-alist
       (ob-jupyter-iopub-content-from-alist "execute_result")
       (assoc 'data)
       (cdr)))

(defun ob-jupyter-stream (execute-reply-alist)
  "Extract the IOPub \"stream\" from EXECUTE-REPLY-ALIST.

Returns an alist of stream data like:
 \((name . \"stdout\")
  \(text . \"contents\"))"
  (->> execute-reply-alist
       (ob-jupyter-iopub-content-from-alist "stream")
       (cdr)))

(defun ob-jupyter-display-data (execute-reply-alist)
  "Extract the IOPub \"display_data\" from EXECUTE-REPLY-ALIST.

Returns an alist of mimetypes and contents, so like:
 \((text/plain . \"this is always here\")
  \(image/png . \"base 64 encoded string, maybe\"))"
  (->> execute-reply-alist
       (ob-jupyter-iopub-content-from-alist "display_data")
       (assoc 'data)
       (cdr)))

(defun ob-jupyter-error (execute-reply-alist)
  "Extract the IOPub \"error\" data from EXECUTE-REPLY-ALIST.

Returns an alist like:
 \((traceback . [\"error tb line 1\" \"error tb line 2\"])
  \(ename . \"error name\")
  \(evalue . \"error value\"))"
  (cdr (ob-jupyter-iopub-content-from-alist "error" execute-reply-alist)))

(defun ob-jupyter-error-traceback-buffer (error-alist)
  "Create a buffer with the traceback from ERROR-ALIST."
  (let ((buf (get-buffer-create "*ob-jupyter-traceback*"))
        (tb (cdr (assoc 'tracback error-alist))))
    (with-current-buffer buf
      (erase-buffer)
      (mapc (lambda (line)
              (insert (ansi-color-apply (format "%s\n" line))))
            tb)
      (current-buffer))))

(defun ob-jupyter-error-string (error-alist)
  "Format ERROR-ALIST to a string."
  (format "%s: %s" (cdr (assoc 'ename error-alist))
          (cdr (assoc 'evalue error-alist))))

(defun ob-jupyter-raise-error-maybe (execute-reply-alist)
  "Raise an Emacs error from EXECUTE-REPLY-ALIST if appropriate.

If the error contains a traceback, attempt to display that
traceback in another window.

Return EXECUTE-REPLY-ALIST unchanged if no error."
  (let ((status (ob-jupyter-status execute-reply-alist))
        (tb-buffer (ob-jupyter-error-traceback-buffer
                    (ob-jupyter-error execute-reply-alist))))
    (cond
     ((string= status "ok") execute-reply-alist)
     ((string= status "error")
      (when tb-buffer
        (display-buffer tb-buffer 'display-in-other-window))
      (error (ob-jupyter-error-string
              (ob-jupyter-error execute-reply-alist))))
     ((string= status "abort")
      (error "Kernel execution aborted")))))

(defun ob-jupyter-inspect-text (inspect-reply-alist)
  "Extract the plaintext description from INSPECT-REPLY-ALIST."
  (->> inspect-reply-alist
       (ob-jupyter-shell-content-from-alist)
       (assoc 'data)
       (assoc 'text/plain)
       (cdr)))

(defun ob-jupyter-cursor-pos (complete-reply-alist)
  "Extract a cons like (CURSOR_START . CURSOR_END) from COMPLETE-REPLY-ALIST."
  (let* ((content (ob-jupyter-shell-content-from-alist
                   complete-reply-alist))
         (cursor-end (cdr (assoc 'cursor_end content)))
         (cursor-start (cdr (assoc 'cursor_start content))))
    (cons cursor-start cursor-end)))

(defun ob-jupyter-matches (complete-reply-alist)
  "Extract the list of completions from COMPLETE-REPLY-ALIST."
  (let* ((content (ob-jupyter-shell-content-from-alist
                   complete-reply-alist))
         (matches-vector (cdr (assoc 'matches content)))
         (matches-lst (append matches-vector nil)))
    matches-lst))

;; High level API

(defun ob-jupyter-send-alist-sync (alist socket &optional key)
  "Send Jupyter request ALIST to SOCKET.

If KEY is provided, sign messages with HMAC-SHA256 and KEY.

Block until the send completes."
  (->> alist
       (ob-jupyter-validate-alist)
       (ob-jupyter-msg-parts-from-alist)
       (ob-jupyter-signed-message-from-parts key nil)
       (ob-jupyter-send-message socket)))

(defun ob-jupyter-recv-alist-sync (socket &optional key)
  "Receive a Jupyter reply alist from SOCKET.

If KEY is provided, authenticate messages with HMAC-SHA256 and KEY.

Block until the receive completes."
  (->> (ob-jupyter-recv-message socket)
       (ob-jupyter-authenticate-message key)
       (ob-jupyter-alist-from-message)))

(defun ob-jupyter-send-alist-deferred (alist socket &optional key)
  "Defer sending a Jupyter request ALIST to SOCKET.

If KEY is provided, sign messages with HMAC-SHA256 and KEY.

Returns a deferred object that can be chained with `deferred:$'."
  (deferred:new
    (lambda () (ob-jupyter-send-alist-sync alist socket key))))

(defun ob-jupyter-recv-alist-deferred (socket &optional key)
  "Defer receiving a Jupyter reply alist from SOCKET.

If KEY is provided, authenticate messages with HMAC-SHA256 and KEY.

Returns a deferred object that can be chained with `deferred:$'."
  (deferred:new
    (lambda () (ob-jupyter-recv-alist-sync socket key))))

(defun ob-jupyter-recv-all-deferred (socket last-p &optional key timeout)
  "Defer receiving a list of Jupyter reply alists from SOCKET.

Loops until (funcall LAST-P alist) is not nil.

If TIMEOUT is provided, terminate early if any receive takes
longer than TIMEOUT msec.

If KEY is provided, authenticate messages with HMAC-SHA256 and KEY.

Returns a deferred object that can be chained with `deferred:$'."
  (deferred:new
    (deferred:lambda (results)
      (deferred:$
        (deferred:callback-post
          (ob-jupyter-poll-deferred socket timeout))
        (deferred:set-next it
          (ob-jupyter-recv-alist-deferred socket key))
        (deferred:nextc it
          (lambda (alist)
            (push alist results)
            alist))
        (deferred:set-next it
          (make-deferred
           :callback (lambda (alist)
                       (if (funcall last-p alist)
                           (nreverse results)
                         (deferred:next self results)))
           :errorback (lambda () (nreverse results))))))))

(defun ob-jupyter-roundtrip-deferred-1
    (alist shell-socket io-socket &optional key timeout)
  "Defer a Jupyter roundtrip request / reply pattern.

When fired, send ALIST to SHELL-SOCKET and collect all messages
sent back on SHELL-SOCKET and IO-SOCKET into an alist
like ((shell shell-socket-list) (iopub io-socket-list)).

If KEY is provided, authenticate messages with HMAC-SHA256 and KEY.

If TIMEOUT is provided, stop receiving from a socket if any
receive on that socket takes longer than TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (deferred:new
    (lambda ()
      (deferred:callback-post
        (ob-jupyter-send-alist-deferred alist shell-socket key))
      (deferred:parallel
        `((shell . ,(deferred:callback-post
                      (ob-jupyter-recv-all-deferred
                       shell-socket
                       #'ob-jupyter-shell-last-p key timeout)))
          (iopub . ,(deferred:callback-post
                      (ob-jupyter-recv-all-deferred
                       io-socket
                       #'ob-jupyter-iopub-last-p key timeout))))))))

(defun ob-jupyter-roundtrip-deferred (alist kernel &optional timeout)
  "Defer a Jupyter roundtrip request / reply pattern.

When fired, send request ALIST to KERNEL and collect the reply.

If TIMEOUT is provided, stop receiving from a socket if any
receive on that socket takes longer than TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred-1
   alist
   (ob-jupyter-struct-shell kernel)
   (ob-jupyter-struct-iopub kernel)
   (ob-jupyter-struct-key kernel)
   timeout))

(defun ob-jupyter-kernel-info-deferred (kernel &optional timeout)
  "Defer a Jupyter kernel info request / reply roundtrip.

When fired, queries KERNEL for basic info.

If TIMEOUT is provided, stop receiving from kernel socket if any
receive on that socket takes longer that TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred
   (ob-jupyter-kernel-info-request-alist)
   kernel timeout))

(defun ob-jupyter-execute-deferred (kernel code &optional timeout)
  "Defer a Jupyter code execution request / reply roundtrip.

When fired, execute CODE on KERNEL.

If TIMEOUT is provided, stop receiving replies from a kernel
socket if any receive on that socket takes longer than TIMEOUT
msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred
   (ob-jupyter-execute-request-alist code)
   kernel timeout))

(defun ob-jupyter-inspect-deferred (kernel pos code &optional timeout)
  "Defer a Jupyter inspection request / reply roundtrip.

When fired, queries KERNEL for info on the object at POS in CODE.

If TIMEOUT is provided, stop receiving from a kernel socket if
any receive on that socket takes longer than TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred
   (ob-jupyter-inspect-request-alist pos code)
   kernel timeout))

(defun ob-jupyter-complete-deferred (kernel pos code &optional timeout)
  "Defer a Jupyter completion request / reply roundtrip.

When fired, queries KERNEL for completion info at POS in CODE.

If TIMEOUT is provided, stop receiving from a kernel socket if
any receive on that socket takes longer than TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred
   (ob-jupyter-complete-request-alist pos code)
   kernel timeout))

;;; wtf? why doesn't this actually shut things down?
(defun ob-jupyter-shutdown-deferred (kernel &optional restart timeout)
  "Defer a Jupyter shutdown request / reply roundtrip.

When fired, ask KERNEL to shutdown.

If RESTART is provided, ask KERNEL to restart after shutdown.

If TIMEOUT is provided, stop receiving from a kernel socket if
any receive on that socket takes longer than TIMEOUT msec.

Returns a deferred object that can be chained with `deferred:$'."
  (ob-jupyter-roundtrip-deferred
   (ob-jupyter-shutdown-request-alist restart)
   kernel timeout))

;; Debug

(defvar ob-jupyter-deferred-result nil
  "A place to store the last async result.

Handy for debugging.  Set it with `ob-jupyter-sync-deferred'.")

(defun ob-jupyter-sync-deferred (d)
  "Fire deferred object D and save the result to `ob-jupyter-deferred-result'."
  (deferred:watch d
    (lambda (reply) (setq ob-jupyter-deferred-result reply)))
  (deferred:callback d))

;;; Emacs

;; Minor Mode

(define-minor-mode jupyter-mode
  "Utilities for working with connected Jupyter kernels."
  nil " Jupyter" nil)

(defvar-local jupyter-current-kernel nil
  "The Jupyter kernel struct associated with the current buffer.")

;; Company Completion

(defun ob-jupyter-company-prefix-async (kernel pos code callback)
  "Query KERNEL for the completion prefix at POS in CODE and pass the result to CALLBACK."
  (deferred:$
    (deferred:callback-post
      (ob-jupyter-complete-deferred kernel pos code))
    (deferred:nextc it #'ob-jupyter-cursor-pos)
    (deferred:nextc it
      (lambda (cursor-cons)
        (substring-no-properties
         code (car cursor-cons) (cdr cursor-cons))))
    (deferred:nextc it callback)))

(defun ob-jupyter-company-candidates-async (kernel pos code callback)
  "Query KERNEL for completion candidates at POS in CODE and pass the results to CALLBACK."
  (deferred:$
    (deferred:callback-post
      (ob-jupyter-complete-deferred kernel pos code 1000))
    (deferred:nextc it #'ob-jupyter-matches)
    (deferred:nextc it callback)))

(defun ob-jupyter-company-doc-buffer-async (kernel pos code callback)
  "Query KERNEL for documentation at POS in CODE, put it in a buffer, and pass that buffer to CALLBACK."
  (deferred:$
    (deferred:callback-post
      (ob-jupyter-inspect-deferred kernel pos code 1000))
    (deferred:nextc it #'ob-jupyter-inspect-text)
    (deferred:nextc it #'company-doc-buffer)
    (deferred:nextc it callback)))

(defun company-ob-jupyter (command &optional arg &rest ignored)
  "Provide completion info according to COMMAND and ARG.

IGNORED is not used."
  (interactive (list 'interactive))
  (let ((kernel jupyter-current-kernel)
        (pos (1- (point)))
        (code (buffer-substring-no-properties (point-min) (point))))
    (cl-case command
      (interactive (company-begin-backend 'company-ob-jupyter))
      (prefix (and
               jupyter-mode
               (not (company-in-string-or-comment))
               (cons :async
                     (apply-partially #'ob-jupyter-company-prefix-async
                                      kernel pos code))))
      (candidates (cons :async
                        (apply-partially
                         #'ob-jupyter-company-candidates-async
                         kernel pos code)))
      (sorted t)
      (doc-buffer (cons :async
                        (apply-partially
                         #'ob-jupyter-company-doc-buffer-async
                         kernel (length arg) arg))))))

;; Babel

(defvar ob-jupyter-session-kernels-alist nil
  "Internal alist of (SESSION . KERNEL) pairs.")

(defvar ob-jupyter-session-langs-alist nil
  "Internal alist of (SESSION . LANGUAGE) pairs.")

(defun ob-jupyter-babel-output (execute-reply-alist)
  "Process the Jupyter EXECUTE-REPLY-ALIST to Babel :result-type 'output.

Currently this returns the contents of the \"stdout\" stream."
  (->> execute-reply-alist
       (ob-jupyter-stream)
       (assoc 'text)                    ; assume it's all stdout
       (cdr)))

(defun ob-jupyter-babel-value (execute-reply-alist)
  "Process the Jupyter EXECUTE-REPLY-ALIST to Babel :result-type 'value."
  (->> execute-reply-alist
       (ob-jupyter-execute-result)
       (assoc 'text/plain)
       (cdr)))

(defun ob-jupyter-babel-value-to-table
    (execute-reply-alist &optional rownames colnames)
  "Process the Jupyter EXECUTE-REPLY-ALIST and return a list-of-lists.

This function assumes that the Jupyter reply represents some sort
of dataframe-like object, so the Babel params :rownames
and :colnames are overloaded to handle that case specifically.

Process first row of data according to COLNAMES:
 - if nil, don't do any column name processing
 - if \"yes\", insert an 'hline after the first row of data
 - if \"no\", exclude the first row / column names

Process first column of data according to ROWNAMES:
 - if nil or \"yes\", don't do any row name processing
 - if \"no\", exclude the first column / row names / index column"
  (let* ((result-alist (ob-jupyter-execute-result execute-reply-alist))
         (text (cdr (assoc 'text/plain result-alist)))
         (all-rows (split-string text "\n"))
         (row-fn (if (string= rownames "no")
                     (lambda (row) (cdr (split-string row " +")))
                   (lambda (row) (split-string row " +"))))
         results)
    (cond
     ((string= colnames "yes")
      (push (funcall row-fn (pop all-rows)) results)
      (push 'hline results))
     ((string= colnames "no")
      (pop all-rows)))
    (dolist (row all-rows)
      (push (funcall row-fn row) results))
    (nreverse results)))

(defun ob-jupyter-babel-value-to-file
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
  (let* ((display-alist (ob-jupyter-display-data execute-reply-alist))
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

(defun ob-jupyter-babel-extract-fn (params)
  "Return the appropriate function to compute results according to Babel PARAMS."
  (let* ((result-type (cdr (assq :result-type params)))
         (result-params (cdr (assq :result-params params)))
         (rownames (cdr (assq :rownames params)))
         (colnames (cdr (assq :colnames params)))
         (file (cdr (assq :file params)))
         (output-dir (cdr (assq :output-dir params)))
         (file-ext (cdr (assq :file-ext params))))
    (cond
     ((eq result-type 'output)
      #'ob-jupyter-babel-output)
     ((or (member "table" result-params) (member "vector" result-params))
      (lambda (alist)
        (ob-jupyter-babel-value-to-table alist rownames colnames)))
     ((member "file" result-params)
      (lambda (alist)
        (ob-jupyter-babel-value-to-file alist file output-dir file-ext)))
     (t
      #'ob-jupyter-babel-value))))

(defvar org-babel-default-header-args:jupyter
  '((:colnames . "yes")
    (:rownames . "no")))

(defun org-babel-edit-prep:jupyter (babel-info)
  "Set up the edit buffer per BABEL-INFO.

BABEL-INFO is as returned by `org-babel-get-src-block-info'."
  (let* ((params (nth 2 babel-info))
         (session (cdr (assq :session params)))
         (kernel (cdr (assoc session ob-jupyter-session-kernels-alist)))
         (lang (cdr (assoc session ob-jupyter-session-langs-alist))))
    (if (not kernel)
        (message "No running kernel. Cannot set up src buffer.")
      ;; Hack around the normal behavior of changing major mode.

      ;; We have to do this b/c `org-edit-src-code' sets up important
      ;; local variables after setting the major mode, which we miss
      ;; when we reset the major mode *after* setting up the buffer.

      ;; I suppose in a perfect world we could associate the appropriate
      ;; language with a babel param, like Org Babel expects.  But I
      ;; dunno how to do that with my current code.
      (cl-letf (((symbol-function 'kill-all-local-variables)
                 (lambda () (run-hooks 'change-major-mode-hook))))
        (funcall (org-src--get-lang-mode lang)))
      (setq-local jupyter-current-kernel kernel)
      (jupyter-mode +1)
      (run-hook-with-args
       (intern (format "ob-jupyter-%s-edit-prep-hook" lang))
       babel-info))))

(defun org-babel-variable-assignments:jupyter (params)
  "Return variable assignment statements according to PARAMS.

PARAMS must include a :session parameter associated with an
active kernel, to determine the underlying expansion language."
  (let* ((session (cdr (assq :session params)))
         (lang (cdr (assoc session ob-jupyter-session-langs-alist)))
         (var-fn (intern (format "org-babel-variable-assignments:%s" lang)))
         (var-fn (if (fboundp var-fn) var-fn #'ignore)))
    (if (not lang)
        (error "No kernel language for variable assignment")
      (funcall var-fn params))))

(defun org-babel-expand-body:jupyter (body params &optional var-lines)
  "Expand BODY according to PARAMS.

PARAMS must include a :session parameter associated with an
active kernel, to determine the underlying expansion language.

If provided, include VAR-LINES before BODY."
  (let* ((session (cdr (assq :session params)))
         (lang (cdr (assoc session ob-jupyter-session-langs-alist)))
         (expand-fn (intern (format "org-babel-expand-body:%s" lang)))
         (expand-fn (if (fboundp expand-fn)
                        expand-fn
                      #'org-babel-expand-body:generic)))
    (if (not lang)
        (error "No kernel language for code expansion")
      (funcall expand-fn body params var-lines))))

(defun org-babel-execute:jupyter (body params)
  "Execute the BODY of an Org Babel Jupyter src block.

PARAMS are the Org Babel parameters associated with the block."
  (let* ((session (cdr (assq :session params)))
         (kernel (cdr (assoc session ob-jupyter-session-kernels-alist)))
         (var-lines (org-babel-variable-assignments:jupyter params))
         (code (org-babel-expand-body:jupyter body params var-lines))
         (result-params (cdr (assq :result-params params)))
         (extract-fn (ob-jupyter-babel-extract-fn params))
         (src-buf (current-buffer))
         (src-point (point)))
    (if (not kernel)
        (error "No running kernel to execute src block")
      (deferred:$
        (deferred:callback-post
          (ob-jupyter-execute-deferred kernel code))
        (deferred:nextc it #'ob-jupyter-raise-error-maybe)
        (deferred:nextc it extract-fn)
        (deferred:nextc it
          (lambda (result)
            (with-current-buffer src-buf
              (save-excursion
                (goto-char src-point)
                (org-babel-insert-result result result-params))))))
      "*")))

;;; This function is expected to return the session buffer.
;;; It functions more like -acquire-session (in the RAII sense).
(defun org-babel-jupyter-initiate-session (session params)
  "Return the comint buffer associated with SESSION.

If no such buffer exists yet, create one with
`ob-jupyter-initialize-kernel'.  If Babel PARAMS includes
a :kernel parameter, that will be passed to
`ob-jupyter-initialize-kernel'."
  (let ((kernel (cdr (assoc session ob-jupyter-session-kernels-alist)))
        (kernel-param (cdr (assq :kernel params))))
    (unless kernel
      (setq kernel (ob-jupyter-initialize-kernel kernel-param session))
      (push (cons session kernel) ob-jupyter-session-kernels-alist)
      (deferred:$
        (deferred:callback-post
          (ob-jupyter-kernel-info-deferred kernel))
        (deferred:nextc it #'ob-jupyter-language)
        (deferred:nextc it
          (lambda (lang)
            (push (cons session lang) ob-jupyter-session-langs-alist)))
        (deferred:set-next it
          (ob-jupyter-kernel-info-deferred kernel))
        (deferred:nextc it #'ob-jupyter-implementation)
        (deferred:nextc it
          (lambda (interpreter)
            (ob-jupyter-setup-inferior
             interpreter (ob-jupyter-struct-buffer kernel))))))
    (ob-jupyter-struct-buffer kernel)))

(defun ob-jupyter-setup-inferior (interp inf-buffer)
  "Set up the appropriate major mode in INF-BUFFER according to INTERP."
  (cond
   ((string= interp "ipython")
    (ob-jupyter-setup-inferior-ipython inf-buffer))))

(defun ob-jupyter-cleanup-session (session)
  "Remove SESSION from internal alists and finalize the kernel."
  (let ((kernel (cdr (assoc session ob-jupyter-session-kernels-alist))))
    (setq ob-jupyter-session-kernels-alist
          (ob-jupyter-assoc-delete-all
           session ob-jupyter-session-kernels-alist)
          ob-jupyter-session-langs-alist
          (ob-jupyter-assoc-delete-all
           session ob-jupyter-session-langs-alist))
    (ob-jupyter-assoc-delete-all session ob-jupyter-session-langs-alist)
    (ob-jupyter-finalize-kernel kernel)))

;; Python specific

(defun ob-jupyter-python-edit-prep (babel-info)
  "Set up Python source buffers.

Currently, this just sets `python-shell-buffer-name' to the
kernel buffer associated with :session in BABEL-INFO."
  (let* ((params (nth 2 babel-info))
         (session (cdr (assq :session params))))
    (set (make-local-variable 'python-shell-buffer-name)
         (org-babel-python-without-earmuffs
          (buffer-name
           (org-babel-jupyter-initiate-session session params))))))

(add-hook 'ob-jupyter-python-edit-prep-hook
          #'ob-jupyter-python-edit-prep)

(defun ob-jupyter-setup-inferior-ipython (inf-buffer)
  "Set up inferior IPython mode in INF-BUFFER."
  (let ((python-shell--interpreter "ipython")
        (python-shell--interpreter-args
         (mapconcat #'identity (cons "-i" jupyter-command-args) " ")))
    (with-current-buffer inf-buffer
      (inferior-python-mode))))

(provide 'jupyter)
;;; jupyter.el ends here