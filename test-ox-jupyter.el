;;; test-ox-jupyter --- Unit tests for the Jupyter library

;;; Commentary:
;; Every library needs a test suite.

;;; Code:
(require 'ert)
(require 'ox-jupyter)

(defun ox-jupyter-concat-multiline (&rest lines)
  "Join LINES with \n in between."
  (mapconcat #'identity lines "\n"))

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

(ert-deftest-parametrize ox-jupyter-headline
  (headline contents info expected-text)
  (('(headline (:raw-value "Example" :level 1))
    nil nil (ox-jupyter-concat-multiline
             "{"
             "  \"cell_type\": \"markdown\","
             "  \"metadata\": null,"
             "  \"source\": ["
             "    \"# Example\""
             "  ]"
             "}")))
  (should (equal (ox-jupyter--headline headline contents info)
                 expected-text)))

(provide 'test-ox-jupyter)
;;; test-ox-jupyter.el ends here
