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

# Same top-level -j default as makefile/Makefile (see the "Parallel by
# default" block there for the full why). It must ALSO live here because this
# shim is MAKELEVEL 0 for root invocations — the sub-make it spawns is level 1
# and deliberately never self-assigns -j (it inherits this jobserver instead).
# Not a rule; the never-add-rules-here policy above still holds.
NPROC := $(shell nproc 2>/dev/null || echo 4)
ifeq ($(filter -j%,$(MAKEFLAGS)),)
  MAKEFLAGS += --jobs=$(NPROC)
endif

GOALS := $(or $(MAKECMDGOALS),__default)
FIRST := $(firstword $(GOALS))
REST  := $(filter-out $(FIRST),$(GOALS))

.PHONY: $(GOALS)

$(FIRST):
	@$(MAKE) -C makefile $(MAKECMDGOALS)

$(REST): $(FIRST)
	@:
