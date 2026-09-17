# versions.mk — the pins Make still owns after the tools moved to config*.toml.
# Every TOOL pin now lives in config.toml / config.linux.toml / config.dev.toml
# (+ mise.lock / mise.dev.lock / mise.linux.lock / locks/**). PR2 moves
# the rest into [vars].
ZJSTATUS_ZELLIJ_FLOOR := 0.45.0   # zjstatus' stated zellij floor; check-invariants asserts tools.zellij >= this
CLAUDE_VERSION := latest
DOZZLE_VERSION := 10.10.0
JETBRAINSMONO_NERD_VERSION := 3.5.1
VCPKG_VERSION  := 2026.07.29
PYTHON_VERSION := 3.14.7
