;;; module.el --- Simple module system for Emacs Lisp.

;; Copyright (C) 2014 Tom Tromey

;; Author: Tom Tromey <tom@tromey.com>
;; Keywords: lisp

;;; Commentary:

;; This is a simple module system for Emacs Lisp.  It allows short
;; symbol names in the source code but exports the names using the
;; standard elisp-style module prefixes.

;; To define a module, see 'define-module'.  After a define-module,
;; some symbols in the current load file will be renamed.  In
;; particular, symbols coming from `defvar', `defconst', `defun' and
;; the like will be renamed -- but other symbols will not be.  This
;; feature is critical to keeping normal Elisp working, as the Emacs
;; core sometimes requires certain symbol names in APIs.

;; When renaming, exported symbols will be given the package prefix,
;; and internal symbols will use the "--" convention.

;; E.g., consider:

;; (define-module testmodule :export (somevar))
;; (defvar somevar nil)
;; (defvar private nil)
;; (provide 'testmodule)

;; This defines a module named "testmodule" and two variables, an
;; "exported" one named "testmodule-somevar", and a "private" one
;; named "testmodule--private".

;; Symbols from other modules can be imported using 'import-module'.
;; Because module boundaries are purely based on symbol naming
;; conventions, you can also "import" from modules that do not use
;; module.el.  Importing a module implicitly 'require's the feature.

;; A module is terminated by calling 'provide'.

;; The renaming is not perfect.  If your code uses intern or otherwise
;; reflects on symbols then you have to be aware of the transforms
;; done by module.el.

;; To Do:

;; Sometimes you want to violate the rules a bit like e.g.,
;; define-minor-mode, or in this file, define-module.

;;; Code:

(require 'cl-macs)

;; The type of a module.
(cl-defstruct module
  ;; The module's prefix, as a symbol.  This is the same as the name
  ;; of the module and the feature it provides.
  prefix
  ;; A list of symbols that are exported from the module.  These are
  ;; all short names.
  exports)

;; An internal structure that is maintained while reading a module.
;; It is discarded when the module is closed.
(cl-defstruct module--internal
  ;; The name of the module, as a symbol.
  name
  ;; The file name of the module.  This is used to make sure that we
  ;; don't prematurely pop a module from the stack.
  file-name
  ;; The 'module' object for this module.
  module
  ;; Map the short name of a symbol to the full name.
  (name-map (make-hash-table))
  ;; The public prefix as a string.
  public-prefix
  ;; The private prefix as a string.
  private-prefix)

(defvar module--stack nil
  "Stack of modules being defined.")
(defvar module--current nil
  "Current module being defined.")

(defun module--define-full (sym new-sym)
  "Define a local mapping from SYM to NEW-SYM.

The new symbol will automatically be replaced in forms in the
current module."
  (puthash sym new-sym (module--internal-name-map module--current)))

(defun module--define-public (sym)
  "Define SYM as a public symbol.

SYM is the short name of a new symbol in the current module."
  (module--define-full
   sym (intern (concat
		(module--internal-public-prefix module--current)
		(symbol-name sym)))))

(defun module--maybe-define-private (sym)
  "Define SYM as a private symbol, unless it is already defined.

SYM is the short name of a new symbol in the current module."
  (unless (gethash sym (module--internal-name-map module--current))
    (module--define-full
     sym (intern (concat
		  (module--internal-private-prefix module--current)
		  (symbol-name sym))))))

(defun module--do-define (name module args)
  "Helper function for `define-module' that does most of the work."
  (push module--current module--stack)
  (setf module--current
	(make-module--internal
	 :name name
	 :file-name load-file-name
	 :module module
	 :public-prefix (concat (symbol-name name) "-")
	 :private-prefix (concat (symbol-name name) "--")))
  ;; Process ARGS.
  (while args
    (unless (eq (car args) :export)
      (error "Unhandled elements in define-module: %S" args))
    (pop args)
    (let ((exports (pop args)))
      (if (symbolp exports)
	  (push exports (module-exports module))
	(setf (module-exports module)
	      (append exports (module-exports module))))))
  (unless (module-exports module)
    (error "Module %s defined without any public symbols" name))
  ;; Now add mappings for all the public symbols.
  (dolist (sym (module-exports module))
    (module--define-public sym)))

(defmacro define-module (name &rest args)
  "Define a new module named NAME.

NAME must be a symbol.  It is both the name of the module and
also the prefix for symbols in the module.  The variable NAME is
also defined as a constant whose value is an object describing
the module.

ARGS is a plist consisting of keywords and values.  The defined
keywords are:

  :export NAMES   Export some symbols.  NAMES is either a single
                  symbol or a list of symbols.  The symbol names
                  are the shortened form.

At least one name must be exported.

A module is closed when `provide' is called for the module's
symbol.

Calls to `defvar', `defun', etc, are instrumented to rename
symbols.  All symbols defined this way are renamed -- if the
symbol is marked for export, then it is given the module prefix
followed by a single `-'; otherwise the symbol is given the
module prefix followed by `--'.

Symbols imported by `import-module' are also renamed during
loading.

Other symbols are left untouched.

Example:

    (define-module something :export (whatever))
    (defun inner () 13)
    (defun whatever () (inner))
    (provide 'something)

This results in two functions being defined, `something--inner'
and `something-whatever'."
  `(progn
     (defconst ,name (make-module :prefix ',name))
     (module--do-define ',name ,name ',args)))

(cl-defun module--do-import (name &key (symbols) &key (prefix name prefix-set))
  "Helper function for `import-module' that does most of the work."
  (unless module--current
    (error "No current module"))
  (let ((real-module (and (boundp name)
			  (module-p (symbol-value name)))))
    (when (and real-module prefix-set)
      (error
       "Cannot specify :prefix with a module defined by `define-module'."))
    (let* ((prefix-str (concat (symbol-name prefix) "-"))
	   ;; A function to check whether the symbol S is exported by
	   ;; the module in question.
	   (check (if symbols
		      (if real-module
			  (lambda (s _full-name)
			    (memq s (module-exports (symbol-value name))))
			(lambda (_s full-name)
			  (intern-soft full-name)))
		    (lambda (_s _full-name) t))))
      (unless symbols
	(if (boundp name)
	    (if (module-p (symbol-value name))
		(setf symbols (module-exports (symbol-value name)))
	      (error "%s is bound but does not name a module" name))
	  ;; Allow implicit modules.
	  (unless (featurep name)
	    (error "%s is neither a module nor a feature" name))
	  (let ((prefix-rx
		 (concat "^"
			 (regexp-quote (symbol-name prefix))
			 "-\\([^-].*\\)$")))
	    (mapatoms
	     (lambda (sym)
	       (let ((sym-name (symbol-name sym)))
		 ;; Strip off the "PREFIX-" prefix, leaving the bare name.
		 (if (string-match prefix-rx sym-name)
		     (push (intern (match-string 1 sym-name)) symbols))))))))
      (dolist (sym symbols)
	(let ((full-name (concat prefix-str (symbol-name sym))))
	  (unless (funcall check sym full-name)
	    (error "Symbol %S is not exported by module %S" sym name))
	  (module--define-full sym (intern full-name)))))))

(defmacro import-module (name &rest specs)
  "Import symbols from the module NAME.

NAME is a symbol which is passed to `require'.  If there is no
module named NAME, then it will be treated as an \"implicit
module\" and symbols using `NAME-' as a prefix will be treated as
if they were defined in a module.

SPECS is a list of keyword/argument pairs.  If SPECS is not
given, then all the exported symbols in the module named NAME
will be imported.

The defined keywords are:

  :prefix SYMBOL    For an implicit module, set the symbol prefix to
                    SYMBOL.  This keyword is invalid for modules
                    defined with `define-module'.  This option exists
                    so that some implicit modules can be meaningfully
                    imported, e.g.:

                        (import-module 'cl-macs :prefix 'cl)

  :symbols LIST     Import just the symbols in LIST from the module
                    NAME.  The shortened name of the symbol should be
                    given; `import-module' will add the module prefix.

Example:

    (define-module ZZZ :export (f))
    (import-module QQQ :symbols (a b))
    (defun f () (+ (a) (b)))
    (provide 'ZZZ)

This will define a function `ZZZ-f' which will call `QQQ-a' and
`QQQ-b'."
  `(progn
     (require ',name)
     (apply #'module--do-import ',name ',specs)))

(defun module--rewrite-form (form)
  "Rewrite FORM in-place to rename symbols according to the current module."
  (let ((map (module--internal-name-map module--current)))
    (while (consp form)
      (let ((elt (car form)))
	(cond
	 ((symbolp elt)
	  (let ((replace (gethash elt map)))
	    (when replace
	      (setcar form replace))))
	 ((consp elt)
	  (module--rewrite-form elt))))
      (setf form (cdr form)))))

(defun module--top-active-p ()
  "Return true if the file being loaded corresponds to the current module."
  (and module--current
       (boundp 'load-file-name)		; Paranoia.
       (equal (module--internal-file-name module--current)
	      load-file-name)))

(defmacro declare-internal-function (fn)
  "Declare FN as a function internal to this module.
This is needed in to allow mutual recursion while still
renaming symbols properly."
  (module--maybe-define-private fn))

(defun module--internal-macroexpand-for-load (form full-p)
  "After-advice for `internal-macroexpand-for-load' that rewrites forms."
  (when (and full-p (module--top-active-p))
    (when (consp form)
      (cond
       ((and (consp (cdr form))
	     (memq (car form) '(defvar defconst)))
	(module--maybe-define-private (cadr form)))
       ((and (consp (cdr form))
	     (consp (cadr form))
	     (memq (car form) '(defalias defvaralias fset))
	     (eq (cl-caadr form) 'quote))
	(module--maybe-define-private (cl-cadadr form)))))
    (module--rewrite-form form)))

;; Note that after advice is good enough because we are rewriting
;; in-place, and the case of a form consisting solely of a symbol is
;; unimportant.
(advice-add 'internal-macroexpand-for-load :after
	    #'module--internal-macroexpand-for-load)

(defun module--provide (feature &optional subfeatures)
  "After-advice for `provide' that wraps up the current module."
  (when module--current
    ;; Only pop the current module if it is what is being provided.
    ;; This lets plain old elisp continue to work.
    (when (eq (module--internal-name module--current) feature)
      (setf module--current (pop module--stack)))))

(advice-add 'provide :after #'module--provide)

(provide 'module)

;;; module.el ends here
