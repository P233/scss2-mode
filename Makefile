EMACS ?= emacs
PYTHON ?= python3
SCSS2_EMMET2_DIR ?= $(abspath ../emmet2-mode)
SCSS2_FRONTEND_DIR ?= $(abspath .dependencies)
export EMACS PYTHON SCSS2_EMMET2_DIR

.PHONY: check test test-core test-semantic test-frontends check-vendor check-package package

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

test-frontends:
	$(EMACS) --batch -Q -L . -L "$(SCSS2_EMMET2_DIR)" \
		-L "$(SCSS2_FRONTEND_DIR)/compat" -L "$(SCSS2_FRONTEND_DIR)/corfu" \
		-L "$(SCSS2_FRONTEND_DIR)/corfu/extensions" -L "$(SCSS2_FRONTEND_DIR)/yasnippet" \
		-l scripts/test-corfu.el
	$(EMACS) --batch -Q -L . -L "$(SCSS2_EMMET2_DIR)" \
		-L "$(SCSS2_FRONTEND_DIR)/compat" -L "$(SCSS2_FRONTEND_DIR)/company-mode" \
		-L "$(SCSS2_FRONTEND_DIR)/orderless" -l scripts/test-frontends.el
	$(EMACS) --batch -Q -L . -L "$(SCSS2_FRONTEND_DIR)/avy" -l scripts/test-avy.el

check-package: check-vendor
	$(EMACS) --batch -Q -l scripts/check-package.el

package: check-vendor
	$(PYTHON) scripts/package.py --release
