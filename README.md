This is a simple module system for Emacs Lisp, inspired by [Nic
Ferrier's proposal](https://lists.gnu.org/archive/html/emacs-devel/2013-07/msg00738.html).  It allows short symbol
names in the source code but exports the names using the standard
elisp-style module prefixes.

To define a module, see `define-module`.  After a `define-module`,
some symbols in the current load file will be renamed.  In
particular, symbols coming from `defvar`, `defconst`, `defun` and
the like will be renamed -- but other symbols will not be.  This
feature is critical to keeping normal Elisp working, as the Emacs
core sometimes requires certain symbol names in APIs.

Note that a private symbol must be seen -- declared with `defvar` or
the like -- before any uses.  Otherwise the renamer will not know to
rename the use.  Normally this is not a problem but you must take care
to declare internal functions when you need mutual recursion.  You can
do this like so:

```elisp
(declare-internal-function private-function)
```

When renaming, exported symbols will be given the package prefix, and
internal symbols will use the "--" convention.

E.g., consider:

```elisp
(define-module testmodule :export (somevar))
(defvar somevar nil)
(defvar private nil)
(provide 'testmodule)
```

This defines a module named `testmodule` and two variables, an
"exported" one named `testmodule-somevar`, and a "private" one named
`testmodule--private`.

Symbols from other modules can be imported using `import-module`.
Because module boundaries are purely based on symbol naming
conventions, you can also "import" from modules that do not use
module.el.  Importing a module implicitly `require`s the feature.

A module is terminated by calling `provide`.

### Bugs

The renaming is not perfect.  If your code uses `intern` or otherwise
reflects on symbols then you have to be aware of the transforms done
by module.el.

Another bug is that autoload cookies aren't rewritten.

A feature request is to make `import-module` warn about shadowing.

There is no facility for sub-modules.  It may be useful to provide
this.

Maybe I should have called these "namespaces", not "modules".
