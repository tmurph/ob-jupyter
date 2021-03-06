;;; jupyter-test --- Unit tests for the Jupyter library

;;; Commentary:
;; Every library needs a test suite.

;;; Code:
(require 'ert)
(require 'jupyter)

(defmacro ert-deftest-parametrize (prefix params values &rest body)
  "Create ERT deftests from a list of parameters.

Give them names starting with PREFIX, e.g. PREFIX-0, PREFIX-1, etc.
Bind PARAMS to sequential elements from VALUES and execute test BODY."
  (declare (indent defun))
  (cl-loop for i below (length values)
           collect
           `(ert-deftest ,(intern
                           (concat
                            (symbol-name prefix) "-" (number-to-string i)))
                ()
              (cl-destructuring-bind ,params (list ,@(nth i values))
                ,@body))
           into result
           finally return (cons 'progn result)))

(ert-deftest-parametrize jupyter-hmac
  (key message-contents expected-hash)
  (("" ""
    "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad")
   ("9c6bbbfb-6ad699d44a15189c4f3d3371" ""
    "036749381352371cf2577f47bf8eaec408eea4d094e47ad51efc593c30eb7064")
   ("9c6bbbfb-6ad699d44a15189c4f3d3371"
    (concat
     "{\"version\":\"5.2\",\"date\":\"2018-01-09T01:46:34.813548Z\",\"session\":\"8bffabe8-0b093fa41c5e64c1e4658f19\",\"username\":\"trevor\",\"msg_type\":\"status\",\"msg_id\":\"bbbce125-a39d00a3915d19ea263fa079\"}"
     "{\"version\":\"5.2\",\"date\":\"2018-01-09T01:46:34.741321Z\",\"session\":\"5fb1de18-b00dd5546ac621744597e9d7\",\"username\":\"trevor\",\"msg_type\":\"kernel_info_request\",\"msg_id\":\"d12ab02b-234818ae85b917b1415f7c7c\"}"
     "{}"
     "{\"execution_state\":\"busy\"}")
    "ad2ecf0031e4176cf0e41d8093ad2562c4ffbf65e37febb737b6a1ae768adaa0"))
  (should (string= (jupyter--hmac-sha256 message-contents key)
                   expected-hash)))

(ert-deftest-parametrize jupyter-msg-auth
  (key msg)
  (("9c6bbbfb-6ad699d44a15189c4f3d3371"
    '("kernel.7d6d6bc5-babd-4697-9d94-25698a4c86df.status"
      "<IDS|MSG>"
      "4b838daae4acb5c3a2e4d27ed4624275d097fb4cf5766f293233c5db1eec4052"
      "{\"version\":\"5.2\",\"date\":\"2018-01-12T07:59:12.329556Z\",\"session\":\"4ab8f73f-19c578e1d7cf0679d3c998bf\",\"username\":\"trevor\",\"msg_type\":\"status\",\"msg_id\":\"051b8a6b-1057ed8c76b427271d469144\"}"
      "{\"version\":\"5.2\",\"date\":\"2018-01-12T07:59:11.712205Z\",\"session\":\"de122a00-364186727422e49083ac6d69\",\"username\":\"trevor\",\"msg_type\":\"execute_request\",\"msg_id\":\"2ef76a8e-c1adec30345557ab489c4ca2\"}"
      "{}"
      "{\"execution_state\":\"idle\"}"))
   ("any key" '("no hash" "<IDS|MSG>" ""
                "header" "parent_header" "metadata" "content")))
  (should (equal (jupyter--authenticate-message key msg)
                 msg)))

(ert-deftest-parametrize jupyter-msg-auth-error
  (key msg)
  (("malformed" "input")
   ("malformed" '("input"))
   ("malformed" '("input" "<IDS|MSG>"))
   ("9c6bbbfb-6ad699d44a15189c4f3d3371"
    '("fake-status" "<IDS|MSG>" "not-authenticated"
      "header" "parent_header" "metadata" "content")))
  (should-error (jupyter--authenticate-message msg key)))

(defun jupyter-default-valid-header ()
  "Return a sample valid header alist."
  '((msg_id . "uuid")
    (username . "me")
    (session . "uuid")
    (date . "now")
    (msg_type . "type")
    (version . "version")))

(ert-deftest jupyter-validate-msg ()
  "Does `jupyter--validate-msg' return successfully valid messages?"
  (let ((valid-msg
         `((header ,@(jupyter-default-valid-header))
           (parent_header)
           (metadata)
           (content))))
    (should (equal (jupyter--validate-alist valid-msg)
                   valid-msg))))

(ert-deftest-parametrize jupyter-validate-msg-alist-error
  (alist)
  (("malformed_input")
   ('((header)
      (parent_header)
      (metadata)
      (content)))
   ('((header
       (msg_id ("malformed"))
       (username)
       (session)
       (date)
       (msg_type)
       (version))
      (parent_header)
      (metadata)
      (content)))
   (`((header ,@(jupyter-default-valid-header))
      (parent_header . "malformed")
      (metadata)
      (content)))
   (`((header ,@(jupyter-default-valid-header))
      (parent_header ,@(jupyter-default-valid-header))
      (metadata . "malformed")
      (content)))
   (`((header ,@(jupyter-default-valid-header))
      (parent_header)
      (metadata (valid . "meta"))
      (content . "malformed"))))
  (should-error (jupyter--validate-alist alist)))

(ert-deftest-parametrize jupyter-signed-msg
  (key id-parts msg-parts expected-msg)
  (("e66550e7-bb4ecf567ca2b22868d416e4"
    nil
    '("{\"version\":\"5.2\",\"date\":\"2018-01-13T10:58:08.126175Z\",\"session\":\"ac9fe695-c70d0e985b372c6c29abbcca\",\"username\":\"trevor\",\"msg_type\":\"kernel_info_request\",\"msg_id\":\"e1a8cb82-0c5c2e5de6db532cedad5fed\"}"
      "{}" "{}" "{}")
    '("<IDS|MSG>"
      "024ec03acbcc106af23faf1afecadbf0b3180bd7df76230c94a52e42195fb54c"
      "{\"version\":\"5.2\",\"date\":\"2018-01-13T10:58:08.126175Z\",\"session\":\"ac9fe695-c70d0e985b372c6c29abbcca\",\"username\":\"trevor\",\"msg_type\":\"kernel_info_request\",\"msg_id\":\"e1a8cb82-0c5c2e5de6db532cedad5fed\"}"
      "{}" "{}" "{}"))
   (nil "don't sign" '("header" "parent_header" "metadata" "contents")
        '("don't sign"
          "<IDS|MSG>"
          ""
          "header" "parent_header" "metadata" "contents")))
  (should (equal
           (jupyter--signed-message-from-parts key id-parts msg-parts)
           expected-msg)))

(ert-deftest jupyter-alist-from-msg-parse ()
  "Does `jupyter--alist-from-message' parse messages?"
  (let ((msg
         '("kernel.7d6d6bc5-babd-4697-9d94-25698a4c86df.status"
           "<IDS|MSG>"
           "4b838daae4acb5c3a2e4d27ed4624275d097fb4cf5766f293233c5db1eec4052"
           "{\"version\":\"5.2\",\"date\":\"2018-01-12T07:59:12.329556Z\",\"session\":\"4ab8f73f-19c578e1d7cf0679d3c998bf\",\"username\":\"trevor\",\"msg_type\":\"status\",\"msg_id\":\"051b8a6b-1057ed8c76b427271d469144\"}"
           "{\"version\":\"5.2\",\"date\":\"2018-01-12T07:59:11.712205Z\",\"session\":\"de122a00-364186727422e49083ac6d69\",\"username\":\"trevor\",\"msg_type\":\"execute_request\",\"msg_id\":\"2ef76a8e-c1adec30345557ab489c4ca2\"}"
           "{}"
           "{\"execution_state\":\"idle\"}"))
        (expected-alist
         '((header
            (version . "5.2")
            (date . "2018-01-12T07:59:12.329556Z")
            (session . "4ab8f73f-19c578e1d7cf0679d3c998bf")
            (username . "trevor")
            (msg_type . "status")
            (msg_id . "051b8a6b-1057ed8c76b427271d469144"))
           (parent_header
            (version . "5.2")
            (date . "2018-01-12T07:59:11.712205Z")
            (session . "de122a00-364186727422e49083ac6d69")
            (username . "trevor")
            (msg_type . "execute_request")
            (msg_id . "2ef76a8e-c1adec30345557ab489c4ca2"))
           (metadata)
           (content
            (execution_state . "idle")))))
    (should (equal (jupyter--alist-from-message msg)
                   expected-alist))))

(ert-deftest jupyter-msg-from-alist-parse ()
  "Does `jupyter--msg-parts-from-alist' parse alists?"
  (let ((alist
         '((header
            (version . "5.2")
            (date . "2018-01-15T00:07:16.780954Z")
            (session . "d21cef59-80ab-437c-a9c7-5b16c02b0ce5")
            (username . "trevor")
            (msg_type . "status")
            (msg_id . "6d56a56b-4877-4d1d-897b-9ff60b940ebe"))
           (parent_header
            (version . "5.2")
            (date . "2018-01-15T00:07:10.000000Z")
            (session . "c6decad2-18b9-4935-a02e-a66b3c1b4cc4")
            (username . "trevor")
            (msg_type . "execute_request")
            (msg_id . "fcf0b3fd-552d-4f47-b31c-ebf6ecd6a2cc"))
           (metadata)
           (content
            (execution_state . "idle"))))
        (expected-msg
         '("{\"version\":\"5.2\",\"date\":\"2018-01-15T00:07:16.780954Z\",\"session\":\"d21cef59-80ab-437c-a9c7-5b16c02b0ce5\",\"username\":\"trevor\",\"msg_type\":\"status\",\"msg_id\":\"6d56a56b-4877-4d1d-897b-9ff60b940ebe\"}"
           "{\"version\":\"5.2\",\"date\":\"2018-01-15T00:07:10.000000Z\",\"session\":\"c6decad2-18b9-4935-a02e-a66b3c1b4cc4\",\"username\":\"trevor\",\"msg_type\":\"execute_request\",\"msg_id\":\"fcf0b3fd-552d-4f47-b31c-ebf6ecd6a2cc\"}"
           "{}"
           "{\"execution_state\":\"idle\"}")))
    (should (equal (jupyter--msg-parts-from-alist alist)
                   expected-msg))))

(ert-deftest jupyter-language ()
  "Does `jupyter--language' parse kernel info reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "kernel_info_reply"))
             (parent_header)
             (metadata)
             (content
              (language_info
               (name . "python")))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-text "python"))
    (should (string= (jupyter--language alist)
                     expected-text))))

(ert-deftest jupyter-implementation ()
  "Does `jupyter--implementaion' parse kernel info reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "kernel_info_reply"))
             (parent_header)
             (metadata)
             (content
              (implementation . "ipython"))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-text "ipython"))
    (should (string= (jupyter--implementation alist)
                     expected-text))))

(ert-deftest jupyter-status ()
  "Does `jupyter--status' parse execute reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "execute_reply"))
             (parent_header)
             (metadata)
             (content
              (status . "ok"))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-text "ok"))
    (should (string= (jupyter--status alist)
                     expected-text))))

(ert-deftest-parametrize jupyter-execute-result
  (alist expected)
  (('((iopub
       ((header (msg_type . "status"))
        (content (execution_state . "busy")))
       ((header (msg_type . "execute_input")))
       ((header (msg_type . "status"))
        (content (execution_state . "idle")))))
    nil)
   ('((iopub
       ((header (msg_type . "status"))
        (content (execution_state . "busy")))
       ((header (msg_type . "execute_input")))
       ((header (msg_type . "execute_result"))
        (content
         (data
          (text/plain . "'/path/to/some/dir'"))))
       ((header (msg_type . "status"))
        (content (execution_state . "idle")))))
    '((text/plain . "'/path/to/some/dir'")))
   ('((iopub
       ((header (msg_type . "execute_result"))
        (content
         (data
          (text/plain . "minimal example"))))))
    '((text/plain . "minimal example"))))
  (should (equal (jupyter--execute-result alist) expected)))

(ert-deftest jupyter-stream ()
  "Does `jupyter--stream' parse execution reply alists?"
  (let ((alist '((iopub
                  ((header (msg_type . "stream"))
                   (content
                    (name . "stdout")
                    (text . "contents"))))))
        (expected '((name . "stdout")
                    (text . "contents"))))
    (should (equal (jupyter--stream alist) expected))))

(ert-deftest jupyter-display-data ()
  "Does `jupyter--display-data' parse execution reply alists?"
  (let ((alist '((iopub
                  ((header (msg_type . "display_data"))
                   (content
                    (data
                     (text/plain . "always here")
                     (image/png . "maybe here")))))))
        (expected '((text/plain . "always here")
                    (image/png . "maybe here"))))
    (should (equal (jupyter--display-data alist) expected))))

(ert-deftest jupyter-error ()
  "Does `jupyter--error' parse execution reply alists?"
  (let ((alist '((iopub
                  ((header (msg_type . "error"))
                   (content
                    (traceback . ["tb lines"])
                    (ename . "name")
                    (evalue . "value"))))))
        (expected '((traceback . ["tb lines"])
                    (ename . "name")
                    (evalue . "value"))))
    (should (equal (jupyter--error alist) expected))))

(ert-deftest jupyter-inspect-text ()
  "Does `jupyter--inspect-text' parse inspect reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "inspect_reply"))
             (parent_header)
             (metadata)
             (content
              (data
               (text/plain . "Hello World!")))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-text "Hello World!"))
    (should (string= (jupyter--inspect-text alist)
                     expected-text))))

(ert-deftest jupyter-cursor-pos ()
  "Does `jupyter--cursor-pos' parse complete reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "complete_reply"))
             (parent_header)
             (metadata)
             (content
              (cursor_end . 6)
              (cursor_start . 0))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-cons (cons 0 6)))
    (should (equal (jupyter--cursor-pos alist)
                   expected-cons))))

(ert-deftest jupyter-matches ()
  "Does `jupyter--matches' parse complete reply alists?"
  (let ((alist
         '((shell
            ((header
              (msg_type . "complete_reply"))
             (parent_header)
             (metadata)
             (content
              (matches .
                       ["np.add" "np.add_docstring" "np.add_newdoc" "np.add_newdoc_ufunc" "np.add_newdocs"]))))
           (iopub
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "busy")))
            ((header)
             (parent_header)
             (metadata)
             (content
              (execution_state . "idle"))))))
        (expected-lst '("np.add" "np.add_docstring" "np.add_newdoc"
                        "np.add_newdoc_ufunc" "np.add_newdocs")))
    (should (equal (jupyter--matches alist)
                   expected-lst))))

(provide 'jupyter-test)
;;; jupyter-test.el ends here
