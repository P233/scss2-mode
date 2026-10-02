EMACS ?= emacs
PYTHON ?= python3
SCSS2_EMMET2_DIR ?= $(abspath ../emmet2-mode)
export EMACS PYTHON SCSS2_EMMET2_DIR

.PHONY: check test test-core test-semantic check-vendor check-package package

check: check-vendor test-core test-semantic test check-package

check-vendor:
	$(PYTHON) scripts/vendor-parser.py --check

test:
	$(PYTHON) -B -m unittest discover -s test -p '*_test.py'
	SCSS2_TEST_SUITE=all $(EMACS) --batch -Q -l scripts/test-emacs.el

test-core:
	SCSS2_TEST_SUITE=core $(EMACS) --batch -Q -l scripts/test-emacs.el

test-semantic:
	SCSS2_TEST_SUITE=semantic $(EMACS) --batch -Q -l scripts/test-emacs.el

check-package: check-vendor
	$(EMACS) --batch -Q -l scripts/check-package.el

package: check-vendor
	$(PYTHON) scripts/package.py --release
