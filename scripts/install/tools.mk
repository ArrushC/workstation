# tools.mk — per-tool install rules.
#
# Each tool is expressed as a single $(eval $(call TOOL,...)) line invoking
# the TOOL macro defined in the Makefile. The macro emits:
#   - a phony target named after the tool (so `make gitui` works)
#   - a stamp rule keyed on the version (so bumping a version forces reinstall)
#   - a clean-<tool> phony target (removes stamp + binary)
#
# To add a tool:
#   1. Add a <NAME>_VERSION := <ver> line to versions.mk.
#   2. Add a $(eval $(call TOOL,...)) line below, picking the right helper:
#        $(LIB)/archive.sh <binary[:binary2:...]> <url>   for tarball/zip
#        $(LIB)/direct.sh  <name> <url>                   for raw binary URL
#        $(LIB)/pipe.sh    <name> <url> [-- <args>]       for curl-piped installers
#        $(LIB)/pip.sh     <pkg> [<pkg>...]               for Python tools
#        $(LIB)/helix.sh   <version>                      special-cased (multi-file)
#
# Phase 1 — five pilot tools covering every helper.

# gitui — single binary, ./prefix tarball; find absorbs the `./`
$(eval $(call TOOL,gitui,$(GITUI_VERSION),\
  $(LIB)/archive.sh gitui https://github.com/gitui-org/gitui/releases/download/v$(GITUI_VERSION)/gitui-linux-x86_64.tar.gz))

# yazi (+ ya companion) — two binaries from one zip
$(eval $(call TOOL,yazi,$(YAZI_VERSION),\
  $(LIB)/archive.sh yazi:ya https://github.com/sxyazi/yazi/releases/download/v$(YAZI_VERSION)/yazi-x86_64-unknown-linux-musl.zip))

# helix — binary + runtime tree (special-cased helper)
$(eval $(call TOOL,helix,$(HELIX_VERSION),\
  $(LIB)/helix.sh $(HELIX_VERSION)))

# chezmoi — upstream installer respects -b for destination
$(eval $(call TOOL,chezmoi,$(CHEZMOI_VERSION),\
  $(LIB)/pipe.sh chezmoi https://get.chezmoi.io -- -b $(DEST)))

# nb — direct raw-binary download, no version pinning
$(eval $(call TOOL,nb,$(NB_VERSION),\
  $(LIB)/direct.sh nb https://raw.githubusercontent.com/xwmx/nb/master/nb))
