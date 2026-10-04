EMACS ?= emacs
BATCH = $(EMACS) -Q --batch -L . -L test

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile acurl.el test/acurl-test.el

checkdoc:
	$(BATCH) -l test/run-checkdoc.el acurl.el

test:
	$(BATCH) -l test/acurl-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
