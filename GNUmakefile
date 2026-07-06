# GNUmakefile — root convenience shim. The real build system lives entirely
# in makefile/ — NEVER add rules here.
#
# GNU make's makefile lookup order is GNUmakefile → makefile → Makefile, so
# this file wins over the `makefile/` DIRECTORY and fixes the documented
# footgun where `make lint MODE=prod` from the repo root died with
# `make: makefile: Is a directory`. Every goal forwards verbatim to
# makefile/; command-line variables (MODE=…) propagate automatically via
# MAKEFLAGS. With no goals it forwards goal-less, so makefile/Makefile's
# default behaviour (including scope.mk's informative MODE error) is
# identical to running `make -C makefile`.
#
# Multi-goal invocations (`make fmt lint MODE=prod`) forward ONCE with all
# goals: the first goal carries the recipe, the rest are no-op aliases that
# depend on it.

MAKEFLAGS += --no-print-directory

GOALS := $(or $(MAKECMDGOALS),__default)
FIRST := $(firstword $(GOALS))
REST  := $(filter-out $(FIRST),$(GOALS))

.PHONY: $(GOALS)

$(FIRST):
	@$(MAKE) -C makefile $(MAKECMDGOALS)

$(REST): $(FIRST)
	@:
