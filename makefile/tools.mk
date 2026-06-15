# tools.mk — per-tool install rules.
#
# Each tool is one $(eval $(call ...,)) line. Three macros are defined in
# the Makefile; pick the one that matches the tool's install shape:
#
#   EGET_TOOL  — PREFERRED for single-binary GitHub releases. Delegates
#                to eget which figures out the right asset and layout.
#                One line per tool: name, version, user/repo[, tag][, extras].
#                Used by ~42 tools below. Joins $(SCOPE_TOOLS).
#
#   TOOL       — Direct call to a helper (archive.sh/direct.sh/pipe.sh/
#                helix.sh). Use for: non-GitHub URLs (ncdu/broot/nb/sysz/
#                ssh-copy-id), multi-binary archives where eget --all
#                pulls in junk (age, yazi), helix's multi-file install,
#                chezmoi's curl-pipe installer. Joins $(SCOPE_TOOLS).
#
#   USER_TOOL  — pip user-site tools (glances/asciinema/harlequin). Never
#                under sudo. Joins $(USER_TOOLS); used by `make user-tools`.
#
# Library helpers (lib/):
#   eget.sh     <user/repo> <tag> [extra eget args]    (called by EGET_TOOL)
#   archive.sh  <name[=dest][:name[=dest]...]> <url>   tar.gz/tar.bz2/tar.xz/zip
#   direct.sh   <name> <url>                           raw binary URL (no archive)
#   pip.sh      <pkg>                                  Python user-site
#   helix.sh    <version>                              multi-file special case
#   pipe.sh     <name> <url> [-- <args>]               curl-piped installer
#
# Adding a tool (preferred — most cases):
#   1. <NAME>_VERSION := ...   in versions.mk
#   2. $(eval $(call EGET_TOOL,<name>,$(<NAME>_VERSION),<user/repo>))
#   3. If the upstream tag isn't `v$VERSION` (e.g. plain "0.19.2", or
#      "gping-vX.Y.Z"), pass the explicit tag as the 4th arg.
#   4. If eget auto-detect picks wrong (both musl and gnu published,
#      `.deb` side-files, etc.), add disambiguating eget flags as the
#      5th arg — typically "--asset musl" or "--asset '^.foo'".
#
# Adding a non-GitHub-release tool, multi-binary archive, helix-shape,
# etc.: use TOOL/USER_TOOL with the matching helper.

# =============================================================================
# META-INSTALLER (bootstrap)  — installs the eget binary that's used by
# every EGET_TOOL entry below. eget itself is a regular GitHub-release
# install, so we use the existing archive.sh path (no chicken-and-egg).
# All EGET_TOOL rules carry an order-only `| eget` dep, so Make ensures
# this stamp lands first under `make -j8`.
# =============================================================================
$(eval $(call TOOL,eget,$(EGET_VERSION),\
  $(LIB)/archive.sh eget https://github.com/zyedidia/eget/releases/download/v$(EGET_VERSION)/eget-$(EGET_VERSION)-linux_amd64.tar.gz))

# =============================================================================
# ARCHIVE single-binary  (tar.gz / tar.bz2 / tar.xz / zip)
# archive.sh walks the extracted tree with `find -name <binary>` and installs
# the first match, so the internal layout doesn't matter — top-level,
# ./prefix, wrapper dir, nested bin/, all handled identically.
# =============================================================================

# --- Tier-0 ------------------------------------------------------------------
$(eval $(call EGET_TOOL,fzf,$(FZF_VERSION),junegunn/fzf))
$(eval $(call EGET_TOOL,zoxide,$(ZOXIDE_VERSION),ajeetdsouza/zoxide,,--asset musl))
$(eval $(call EGET_TOOL,starship,$(STARSHIP_VERSION),starship/starship,,--asset musl))
# zellij 0.44 added a second musl asset (zellij-no-web-*), so --asset musl
# alone now matches two tarballs and eget aborts asking to pick. Exclude the
# no-web build to keep auto-selecting the full zellij-<arch>-*-musl.tar.gz.
$(eval $(call EGET_TOOL,zellij,$(ZELLIJ_VERSION),zellij-org/zellij,,--asset musl --asset '^no-web'))

# glow — wrapper-dir tarball; default v-tag; default asset filters
# exclude the .sbom.json side-file.
$(eval $(call EGET_TOOL,glow,$(GLOW_VERSION),charmbracelet/glow))

# --- Tier-1 ------------------------------------------------------------------
$(eval $(call EGET_TOOL,fd,$(FD_VERSION),sharkdp/fd,,--asset musl))
$(eval $(call EGET_TOOL,bat,$(BAT_VERSION),sharkdp/bat,,--asset musl))
$(eval $(call EGET_TOOL,btop,$(BTOP_VERSION),aristocratos/btop,,--asset musl))

# ncdu — published at dev.yorhel.nl, not GitHub. Stays on archive.sh.
$(eval $(call TOOL,ncdu,$(NCDU_VERSION),\
  $(LIB)/archive.sh ncdu https://dev.yorhel.nl/download/ncdu-$(NCDU_VERSION)-linux-x86_64.tar.gz))

$(eval $(call EGET_TOOL,bandwhich,$(BANDWHICH_VERSION),imsnif/bandwhich,,--asset musl))
# usql — both regular and `usql_static` variants published per arch.
# `--asset '^_static'` excludes the static-linked one (matches the existing
# behavior — we install the regular dynamically-linked usql).
# NOTE: the dynamic build requires GLIBC 2.38+ and GLIBCXX 3.4.30+
# (≈ RHEL 9.4 / Fedora 38 / Ubuntu 24.04 baseline). On hosts with older
# glibc (e.g. AlmaLinux 9 ships glibc 2.34) usql will install but fail
# to run with "GLIBC_2.38 not found"; switch to the static archive
# (--asset _static, archive contains binary `usql_static`) if you need
# it working on those hosts.
$(eval $(call EGET_TOOL,usql,$(USQL_VERSION),xo/usql,,--asset '^_static'))
$(eval $(call EGET_TOOL,lazydocker,$(LAZYDOCKER_VERSION),jesseduffield/lazydocker))
$(eval $(call EGET_TOOL,dive,$(DIVE_VERSION),wagoodman/dive))
$(eval $(call EGET_TOOL,lnav,$(LNAV_VERSION),tstack/lnav,,--asset musl))
$(eval $(call EGET_TOOL,gopass,$(GOPASS_VERSION),gopasspw/gopass))

# fastfetch — non-v tag; publishes both .tar.gz and .zip per Linux variant.
# Prefer the tarball for consistency with the other tools.
$(eval $(call EGET_TOOL,fastfetch,$(FASTFETCH_VERSION),fastfetch-cli/fastfetch,$(FASTFETCH_VERSION),--asset musl --asset .tar.gz))

# --- Second-wave -------------------------------------------------------------
# gitui — ./prefix tarball (auto-handled by eget); default v-tag.
$(eval $(call EGET_TOOL,gitui,$(GITUI_VERSION),gitui-org/gitui))

$(eval $(call EGET_TOOL,lazygit,$(LAZYGIT_VERSION),jesseduffield/lazygit))
$(eval $(call EGET_TOOL,jj,$(JUJUTSU_VERSION),jj-vcs/jj))

# yazi — multi-binary with shell completions in the archive. eget's --all
# would install the completions/ subdir into $(DEST) as junk; stays on
# archive.sh which uses an explicit binary spec to extract only yazi + ya.
$(eval $(call TOOL,yazi,$(YAZI_VERSION),\
  $(LIB)/archive.sh yazi:ya https://github.com/sxyazi/yazi/releases/download/v$(YAZI_VERSION)/yazi-x86_64-unknown-linux-musl.zip))

# ast-grep ships two binaries (sg + ast-grep)
# ast-grep — multi-binary archive (installs both `sg` and `ast-grep`).
# Tag has no `v` prefix. eget's auto-detect picks the right asset
# (only one Linux variant published); --all extracts every executable.
# Note: clean-ast-grep only removes ast-grep — `sg` lingers in $(DEST).
$(eval $(call EGET_TOOL,ast-grep,$(AST_GREP_VERSION),ast-grep/ast-grep,$(AST_GREP_VERSION),--all))

# television — binary inside the archive is `tv`; non-v tag; both musl/gnu
# published. eget extracts `tv` to $(DEST); the EGET_TOOL macro's stamp
# uses the registered name (`television`).
$(eval $(call EGET_TOOL,television,$(TELEVISION_VERSION),alexpasmantier/television,$(TELEVISION_VERSION),--asset musl))

# --- (2026-06) interactive explorers + git replay ---------------------------
# nnn — the musl-static tarball's internal binary is named `nnn-musl-static`,
# not `nnn`; archive.sh's `src=dst` spec renames it on install. eget can't do
# this cleanly for archive members (its repo-name rename only applies to
# raw-binary assets), so nnn uses TOOL+archive.sh like yazi/ncdu — no eget dep.
$(eval $(call TOOL,nnn,$(NNN_VERSION),\
  $(LIB)/archive.sh nnn-musl-static=nnn https://github.com/jarun/nnn/releases/download/v$(NNN_VERSION)/nnn-musl-static-$(NNN_VERSION).x86_64.tar.gz))

# fx — interactive JSON viewer. Non-v tag (like television), so pass it as the
# explicit 4th arg. Assets are raw binaries; eget auto-detects linux/amd64 and
# installs it as `fx`.
$(eval $(call EGET_TOOL,fx,$(FX_VERSION),antonmedv/fx,$(FX_VERSION)))

# gitlogue — cinematic git-log replay. Single linux asset (gnu-glibc only; no
# musl build), so no --asset filter. Tag defaults to v$(GITLOGUE_VERSION).
$(eval $(call EGET_TOOL,gitlogue,$(GITLOGUE_VERSION),unhappychoice/gitlogue))

$(eval $(call EGET_TOOL,xh,$(XH_VERSION),ducaale/xh,,--asset musl))

# gping — non-standard tag prefix (gping-v$VERSION); both gnu and musl
# variants published, prefer musl for static linking.
$(eval $(call EGET_TOOL,gping,$(GPING_VERSION),orf/gping,gping-v$(GPING_VERSION),--asset musl))

# atuin — publishes the client AND a `atuin-server` binary + per-binary
# `-update` archives. We just want the regular client tarball.
$(eval $(call EGET_TOOL,atuin,$(ATUIN_VERSION),atuinsh/atuin,,--asset musl --asset .tar.gz --asset '^server' --asset '^update'))

# delta — tag has no `v` prefix; both gnu and musl variants published.
$(eval $(call EGET_TOOL,delta,$(DELTA_VERSION),dandavison/delta,$(DELTA_VERSION),--asset musl))

# micro — publishes linux64.tar.gz AND linux64-static.tar.gz. We want the
# static one for portability (matches our musl preference everywhere else).
$(eval $(call EGET_TOOL,micro,$(MICRO_VERSION),zyedidia/micro,,--asset static))
# eza — both .tar.gz and .zip variants published per arch; pick tarball.
$(eval $(call EGET_TOOL,eza,$(EZA_VERSION),eza-community/eza,,--asset musl --asset .tar.gz))
$(eval $(call EGET_TOOL,sd,$(SD_VERSION),chmln/sd,,--asset musl))
$(eval $(call EGET_TOOL,k9s,$(K9S_VERSION),derailed/k9s))
$(eval $(call EGET_TOOL,rclone,$(RCLONE_VERSION),rclone/rclone))
# croc — release naming uses Linux-64bit / Linux-32bit / Linux-ARM
# (not standard arch tokens), so eget's system detection doesn't narrow
# automatically. `--asset 64bit` selects the right one.
$(eval $(call EGET_TOOL,croc,$(CROC_VERSION),schollz/croc,,--asset 64bit))
$(eval $(call EGET_TOOL,hyperfine,$(HYPERFINE_VERSION),sharkdp/hyperfine,,--asset musl))
# mise — publishes the same binary in 4 archive formats per arch (tar.gz,
# tar.xz, tar.zst, bare). --asset .tar.gz disambiguates after --asset musl
# narrows to the right libc variant.
$(eval $(call EGET_TOOL,mise,$(MISE_VERSION),jdx/mise,,--asset musl --asset .tar.gz))

# uv — multi-binary tarball (uv + uvx) with no other files. Non-v tag.
# --all extracts both binaries cleanly; verified the archive doesn't
# contain extras that would pollute $(DEST).
# Note: clean-uv only removes uv — `uvx` lingers in $(DEST).
$(eval $(call EGET_TOOL,uv,$(UV_VERSION),astral-sh/uv,$(UV_VERSION),--asset musl --all))

$(eval $(call EGET_TOOL,dsq,$(DSQ_VERSION),multiprocessio/dsq))

# --- Robustness gap-fillers --------------------------------------------------
# gh — tarball has wrapper-dir + nested bin/gh; eget walks the tree to find it.
$(eval $(call EGET_TOOL,gh,$(GH_VERSION),cli/cli))

$(eval $(call EGET_TOOL,htmlq,$(HTMLQ_VERSION),mgdm/htmlq))

# ouch — non-v tag; both musl/gnu published.
$(eval $(call EGET_TOOL,ouch,$(OUCH_VERSION),ouch-org/ouch,$(OUCH_VERSION),--asset musl))

# watchexec — runs commands on file changes. Default v-tag (v$VERSION).
# Both x86_64 musl and gnu tarballs published, plus .deb/.rpm side-files
# (already excluded by eget.sh's anti-match filter); --asset musl picks the
# static build, matching the repo's musl-everywhere convention. EGET_TOOL so
# it installs on BOTH dev (/usr/local/bin) and prod (~/.local/bin) — unlike
# inotify-tools/fswatch, which are source-only upstream and thus dev-only
# (dnf, see packages.mk).
$(eval $(call EGET_TOOL,watchexec,$(WATCHEXEC_VERSION),watchexec/watchexec,,--asset musl))

# bottom — non-v tag; binary inside archive is `btm`. Archive also ships
# a zsh completion at completion/_btm which eget would otherwise treat as
# a candidate (it fuzzy-matches the tool name `bottom` against any file
# ending in `btm`), bailing with "2 candidates ... please select manually".
# Pinning --file btm tells eget to pick the binary unambiguously. The
# EGET_TOOL macro uses the registered name (`bottom`) for the stamp;
# eget extracts `btm` to $(DEST). clean-bottom doesn't remove btm
# (cosmetic only).
$(eval $(call EGET_TOOL,bottom,$(BOTTOM_VERSION),ClementTsang/bottom,$(BOTTOM_VERSION),--asset musl --file btm))

$(eval $(call EGET_TOOL,systemctl-tui,$(SYSTEMCTL_TUI_VERSION),rgwood/systemctl-tui,,--asset musl))

# age — multi-binary archive with LICENSE + age-inspect + age-plugin-batchpass
# alongside the wanted age + age-keygen. eget's --all would install all 5
# (including LICENSE) into $(DEST). Stays on archive.sh which uses an
# explicit binary spec to extract only the two we want.
$(eval $(call TOOL,age,$(AGE_VERSION),\
  $(LIB)/archive.sh age:age-keygen https://github.com/FiloSottile/age/releases/download/v$(AGE_VERSION)/age-v$(AGE_VERSION)-linux-amd64.tar.gz))

# =============================================================================
# DIRECT  (raw binary URL, no archive)
# =============================================================================

$(eval $(call TOOL,nb,$(NB_VERSION),\
  $(LIB)/direct.sh nb https://raw.githubusercontent.com/xwmx/nb/master/nb))

$(eval $(call TOOL,jq,$(JQ_VERSION),\
  $(LIB)/direct.sh jq https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-amd64))

$(eval $(call TOOL,yq,$(YQ_VERSION),\
  $(LIB)/direct.sh yq https://github.com/mikefarah/yq/releases/download/v$(YQ_VERSION)/yq_linux_amd64))

# tealdeer binary is installed as `tldr` for the canonical command name
$(eval $(call TOOL,tldr,$(TEALDEER_VERSION),\
  $(LIB)/direct.sh tldr https://github.com/tealdeer-rs/tealdeer/releases/download/v$(TEALDEER_VERSION)/tealdeer-linux-x86_64-musl))

$(eval $(call TOOL,witr,$(WITR_VERSION),\
  $(LIB)/direct.sh witr https://github.com/pranshuparmar/witr/releases/download/v$(WITR_VERSION)/witr-linux-amd64))

# broot has no version pinning — upstream always serves "latest" at this URL
$(eval $(call TOOL,broot,$(BROOT_VERSION),\
  $(LIB)/direct.sh broot https://dystroy.org/broot/download/x86_64-linux/broot))

$(eval $(call TOOL,ctop,$(CTOP_VERSION),\
  $(LIB)/direct.sh ctop https://github.com/bcicen/ctop/releases/download/v$(CTOP_VERSION)/ctop-$(CTOP_VERSION)-linux-amd64))

$(eval $(call TOOL,sops,$(SOPS_VERSION),\
  $(LIB)/direct.sh sops https://github.com/getsops/sops/releases/download/v$(SOPS_VERSION)/sops-v$(SOPS_VERSION).linux.amd64))

$(eval $(call TOOL,lazyjournal,$(LAZYJOURNAL_VERSION),\
  $(LIB)/direct.sh lazyjournal https://github.com/Lifailon/lazyjournal/releases/download/$(LAZYJOURNAL_VERSION)/lazyjournal-$(LAZYJOURNAL_VERSION)-linux-amd64))

$(eval $(call TOOL,sysz,$(SYSZ_VERSION),\
  $(LIB)/direct.sh sysz https://raw.githubusercontent.com/joehillen/sysz/$(SYSZ_VERSION)/sysz))

$(eval $(call TOOL,ssh-copy-id,$(SSH_COPY_ID_VERSION),\
  $(LIB)/direct.sh ssh-copy-id https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/ssh-copy-id))

# =============================================================================
# HELIX  (special-cased — binary + runtime tree)
# =============================================================================

$(eval $(call TOOL,helix,$(HELIX_VERSION),\
  $(LIB)/helix.sh $(HELIX_VERSION)))

# =============================================================================
# UPSTREAM INSTALLER  (curl-piped, scope-aware via -b flag)
# =============================================================================

$(eval $(call TOOL,chezmoi,$(CHEZMOI_VERSION),\
  $(LIB)/pipe.sh chezmoi https://get.chezmoi.io -- -b $(DEST)))

# =============================================================================
# USER TOOLS  (pip user-site — never under sudo, always ~/.local)
# =============================================================================

$(eval $(call USER_TOOL,glances,$(GLANCES_VERSION),\
  $(LIB)/pip.sh glances))

$(eval $(call USER_TOOL,asciinema,$(ASCIINEMA_VERSION),\
  $(LIB)/pip.sh asciinema))

$(eval $(call USER_TOOL,harlequin,$(HARLEQUIN_VERSION),\
  $(LIB)/pip.sh harlequin))

# chezit — TUI for chezmoi (Go single-binary). Launched via the `czt`
# alias. cheznav (Python) was tried first but its pip package requires
# Python 3.14, which AlmaLinux 9's base modules don't ship.
$(eval $(call EGET_TOOL,chezit,$(CHEZIT_VERSION),daptify14/chezit,,--asset linux_amd64))

# =============================================================================
# CHEATSHEETS  (cheat — offline CLI; cht.sh — online cheat.sh client)
# Both join $(SCOPE_TOOLS) → installed on dev AND prod.
# =============================================================================

# cheat — non-v tag (5.1.0); assets are gzipped single binaries
# (cheat-linux-amd64.gz). Verified: eget 1.3.4 decompresses the .gz and installs
# a binary named `cheat` (not the asset name). --asset amd64 excludes the
# arm5/6/7/arm64 Linux variants published in the same release.
$(eval $(call EGET_TOOL,cheat,$(CHEAT_VERSION),cheat/cheat,$(CHEAT_VERSION),--asset amd64))

# cht.sh — rolling bash script served at cht.sh/:cht.sh (not a GitHub release),
# so direct.sh fetches the raw URL and installs it 0755 as `cht.sh`. On an
# offline host it simply errors at query time; cheat + tldr stay offline-capable.
$(eval $(call TOOL,cht.sh,$(CHTSH_VERSION),\
  $(LIB)/direct.sh cht.sh https://cht.sh/:cht.sh))

# =============================================================================
# UPDATE-CHECK REGISTRY (make check-updates) — hand-registered specs for every
# pin that is NOT an EGET_TOOL line (those self-register via the EGET_TOOL
# macro in the Makefile). Format: `name|version|repo-or-git-url|tag`, where
# tag is the exact upstream tag the pin installs and MUST end with the version
# (its leading remainder becomes the ls-remote glob prefix — see
# lib/check-updates.sh). "latest" pins are reported as rolling; repo `-`
# means "no upstream tag source to compare against".
#
# When you add a TOOL/USER_TOOL entry above (or a new versions.mk pin outside
# the macros), add its spec line here too. EGET_TOOL entries need nothing.
# =============================================================================

# TOOL-installed (archive.sh / direct.sh / helix.sh) with real version pins:
UPDATE_SPECS += eget|$(EGET_VERSION)|zyedidia/eget|v$(EGET_VERSION)
UPDATE_SPECS += ncdu|$(NCDU_VERSION)|https://code.blicky.net/yorhel/ncdu.git|v$(NCDU_VERSION)
UPDATE_SPECS += yazi|$(YAZI_VERSION)|sxyazi/yazi|v$(YAZI_VERSION)
UPDATE_SPECS += nnn|$(NNN_VERSION)|jarun/nnn|v$(NNN_VERSION)
UPDATE_SPECS += age|$(AGE_VERSION)|FiloSottile/age|v$(AGE_VERSION)
UPDATE_SPECS += jq|$(JQ_VERSION)|jqlang/jq|jq-$(JQ_VERSION)
UPDATE_SPECS += yq|$(YQ_VERSION)|mikefarah/yq|v$(YQ_VERSION)
UPDATE_SPECS += tldr|$(TEALDEER_VERSION)|tealdeer-rs/tealdeer|v$(TEALDEER_VERSION)
UPDATE_SPECS += witr|$(WITR_VERSION)|pranshuparmar/witr|v$(WITR_VERSION)
UPDATE_SPECS += ctop|$(CTOP_VERSION)|bcicen/ctop|v$(CTOP_VERSION)
UPDATE_SPECS += sops|$(SOPS_VERSION)|getsops/sops|v$(SOPS_VERSION)
UPDATE_SPECS += lazyjournal|$(LAZYJOURNAL_VERSION)|Lifailon/lazyjournal|$(LAZYJOURNAL_VERSION)
UPDATE_SPECS += sysz|$(SYSZ_VERSION)|joehillen/sysz|$(SYSZ_VERSION)
UPDATE_SPECS += helix|$(HELIX_VERSION)|helix-editor/helix|$(HELIX_VERSION)

# Rolling pins — reported as such (no upstream comparison possible/needed):
# nb/broot/cht.sh/ssh-copy-id/chezmoi/claude track latest; the pip user-tools
# upgrade through pip itself.
UPDATE_SPECS += nb|$(NB_VERSION)|-|-
UPDATE_SPECS += broot|$(BROOT_VERSION)|-|-
UPDATE_SPECS += cht.sh|$(CHTSH_VERSION)|-|-
UPDATE_SPECS += ssh-copy-id|$(SSH_COPY_ID_VERSION)|-|-
UPDATE_SPECS += chezmoi|$(CHEZMOI_VERSION)|-|-
UPDATE_SPECS += claude-cli|$(CLAUDE_VERSION)|-|-
UPDATE_SPECS += glances|$(GLANCES_VERSION)|-|-
UPDATE_SPECS += asciinema|$(ASCIINEMA_VERSION)|-|-
UPDATE_SPECS += harlequin|$(HARLEQUIN_VERSION)|-|-

# Bespoke / non-tool pins from versions.mk:
UPDATE_SPECS += node|$(NODE_VERSION)|nodejs/node|v$(NODE_VERSION)
UPDATE_SPECS += ccstatusline|$(CCSTATUSLINE_VERSION)|sirmalloc/ccstatusline|v$(CCSTATUSLINE_VERSION)
UPDATE_SPECS += dozzle|$(DOZZLE_VERSION)|amir20/dozzle|v$(DOZZLE_VERSION)
UPDATE_SPECS += nerd-fonts|$(JETBRAINSMONO_NERD_VERSION)|ryanoasis/nerd-fonts|v$(JETBRAINSMONO_NERD_VERSION)
