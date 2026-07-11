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
  $(LIB)/archive.sh eget https://github.com/zyedidia/eget/releases/download/v$(EGET_VERSION)/eget-$(EGET_VERSION)-linux_amd64.tar.gz,eget))

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
  $(LIB)/archive.sh ncdu https://dev.yorhel.nl/download/ncdu-$(NCDU_VERSION)-linux-x86_64.tar.gz,ncdu))

$(eval $(call EGET_TOOL,bandwhich,$(BANDWHICH_VERSION),imsnif/bandwhich,,--asset musl))
# usql — universal SQL CLI. The regular dynamic build links GLIBC_2.38 +
# GLIBCXX_3.4.30 (absent on the glibc-2.34 fleet → "version not found" at exec:
# it installs but won't run). Install the STATIC variant instead — statically
# linked, no glibc floor, runs fleet-wide. The archive's binary is `usql_static`;
# install it as `usql` (same rename pattern as nnn). A TOOL (archive.sh) now, not
# EGET_TOOL, so it self-registers nothing for check-updates — see UPDATE-CHECK below.
$(eval $(call TOOL,usql,$(USQL_VERSION),\
  $(LIB)/archive.sh usql_static=usql https://github.com/xo/usql/releases/download/v$(USQL_VERSION)/usql_static-$(USQL_VERSION)-linux-amd64.tar.bz2,usql))
$(eval $(call EGET_TOOL,lazydocker,$(LAZYDOCKER_VERSION),jesseduffield/lazydocker))
$(eval $(call EGET_TOOL,dive,$(DIVE_VERSION),wagoodman/dive))
$(eval $(call EGET_TOOL,lnav,$(LNAV_VERSION),tstack/lnav,,--asset musl))
$(eval $(call EGET_TOOL,gopass,$(GOPASS_VERSION),gopasspw/gopass))

# fastfetch — non-v tag; publishes .tar.gz + .zip per Linux variant in three
# flavors: glibc `linux-amd64` (needs GLIBC_2.34), `linux-amd64-polyfilled`
# (needs only GLIBC_2.17), and `musl-amd64`. The musl build is DYNAMICALLY linked
# against /lib/ld-musl-x86_64.so.1, which the glibc fleet (AlmaLinux/RHEL) does
# not ship — so `fastfetch` died with "no such file or directory" (absent
# loader). Use the polyfilled glibc build: runs across the whole fleet incl.
# older prod hosts (floor 2.17 << the fleet's 2.28+). Prefer .tar.gz over .zip.
$(eval $(call EGET_TOOL,fastfetch,$(FASTFETCH_VERSION),fastfetch-cli/fastfetch,$(FASTFETCH_VERSION),--asset amd64-polyfilled --asset .tar.gz))

# --- Second-wave -------------------------------------------------------------
# gitui — ./prefix tarball (auto-handled by eget); default v-tag.
$(eval $(call EGET_TOOL,gitui,$(GITUI_VERSION),gitui-org/gitui))

$(eval $(call EGET_TOOL,lazygit,$(LAZYGIT_VERSION),jesseduffield/lazygit))
$(eval $(call EGET_TOOL,jj,$(JUJUTSU_VERSION),jj-vcs/jj))

# yazi — multi-binary with shell completions in the archive. eget's --all
# would install the completions/ subdir into $(DEST) as junk; stays on
# archive.sh which uses an explicit binary spec to extract only yazi + ya.
$(eval $(call TOOL,yazi,$(YAZI_VERSION),\
  $(LIB)/archive.sh yazi:ya https://github.com/sxyazi/yazi/releases/download/v$(YAZI_VERSION)/yazi-x86_64-unknown-linux-musl.zip,yazi))

# ast-grep ships two binaries (sg + ast-grep)
# ast-grep — multi-binary archive (installs both `sg` and `ast-grep`).
# Tag has no `v` prefix. eget's auto-detect picks the right asset
# (only one Linux variant published); --all extracts every executable.
# Note: clean-ast-grep only removes ast-grep — `sg` lingers in $(DEST).
$(eval $(call EGET_TOOL,ast-grep,$(AST_GREP_VERSION),ast-grep/ast-grep,$(AST_GREP_VERSION),--all))

# television — binary inside the archive is `tv`; non-v tag; both musl/gnu
# published. eget extracts `tv` to $(DEST); the EGET_TOOL macro's stamp
# uses the registered name (`television`).
$(eval $(call EGET_TOOL,television,$(TELEVISION_VERSION),alexpasmantier/television,$(TELEVISION_VERSION),--asset musl,tv))

# --- (2026-06) interactive explorers + git replay ---------------------------
# nnn — the musl-static tarball's internal binary is named `nnn-musl-static`,
# not `nnn`; archive.sh's `src=dst` spec renames it on install. eget can't do
# this cleanly for archive members (its repo-name rename only applies to
# raw-binary assets), so nnn uses TOOL+archive.sh like yazi/ncdu — no eget dep.
$(eval $(call TOOL,nnn,$(NNN_VERSION),\
  $(LIB)/archive.sh nnn-musl-static=nnn https://github.com/jarun/nnn/releases/download/v$(NNN_VERSION)/nnn-musl-static-$(NNN_VERSION).x86_64.tar.gz,nnn))

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
$(eval $(call EGET_TOOL,bottom,$(BOTTOM_VERSION),ClementTsang/bottom,$(BOTTOM_VERSION),--asset musl --file btm,btm))

$(eval $(call EGET_TOOL,systemctl-tui,$(SYSTEMCTL_TUI_VERSION),rgwood/systemctl-tui,,--asset musl))

# age — multi-binary archive with LICENSE + age-inspect + age-plugin-batchpass
# alongside the wanted age + age-keygen. eget's --all would install all 5
# (including LICENSE) into $(DEST). Stays on archive.sh which uses an
# explicit binary spec to extract only the two we want.
$(eval $(call TOOL,age,$(AGE_VERSION),\
  $(LIB)/archive.sh age:age-keygen https://github.com/FiloSottile/age/releases/download/v$(AGE_VERSION)/age-v$(AGE_VERSION)-linux-amd64.tar.gz,age))

# --- (2026-06) gap-fillers ---------------------------------------------------
# search / data-wrangling / structural-diff / network-diag / git-extras / util.
# Added after a deep-research sweep over the toolbelt's remaining gaps; all are
# eget single-binary installs. Versions in versions.mk.

# ripgrep — the recursive content-search (rg) the set was actually missing (fd
# is find, bat is cat, ast-grep is structural — none do literal/regex grep).
# Non-v tag; musl-static. Archive also ships completions/man, but those aren't
# executable so eget unambiguously picks the `rg` binary (same as fd/bat).
$(eval $(call EGET_TOOL,rg,$(RIPGREP_VERSION),BurntSushi/ripgrep,$(RIPGREP_VERSION),--asset musl))

# miller — awk/sed/cut/join/sort for CSV/TSV/tabular-JSON; binary is `mlr`.
# Pure-Go static. amd64 publishes .deb/.rpm/.tar.gz; the .deb/.rpm are dropped
# by eget.sh's anti-match, leaving the single tarball. Default v-tag.
$(eval $(call EGET_TOOL,mlr,$(MILLER_VERSION),johnkerl/miller))

# csvlens — `less` for CSV. tar.xz; both gnu and musl published, prefer musl.
$(eval $(call EGET_TOOL,csvlens,$(CSVLENS_VERSION),YS-L/csvlens,,--asset musl))

# difftastic — structural, syntax-aware (tree-sitter) diff; binary is `difft`.
# Complements rather than replaces the line-based delta. Non-v tag; musl.
$(eval $(call EGET_TOOL,difft,$(DIFFTASTIC_VERSION),Wilfred/difftastic,$(DIFFTASTIC_VERSION),--asset musl))

# trippy — combined traceroute+ping TUI (the mtr gap); binary is `trip`.
# Non-v tag; musl. RUNTIME: ICMP needs CAP_NET_RAW — `sudo trip`, or
# `sudo setcap cap_net_raw+ep $(command -v trip)` once.
$(eval $(call EGET_TOOL,trip,$(TRIPPY_VERSION),fujiapple852/trippy,$(TRIPPY_VERSION),--asset musl))

# doggo — modern `dig` (DoH/DoT/DoQ/DNSCrypt). goreleaser publishes BOTH
# doggo_<v>_Linux_x86_64 and a doggo_web_<v>_linux_amd64 build; both satisfy
# arch+os so eget aborts asking to choose. `--asset ^web` excludes the web one.
$(eval $(call EGET_TOOL,doggo,$(DOGGO_VERSION),mr-karan/doggo,,--asset '^web'))

# scc — fast code-line counter (LoC / complexity / COCOMO); pure-Go single
# binary, one linux x86_64 asset. Default v-tag.
$(eval $(call EGET_TOOL,scc,$(SCC_VERSION),boyter/scc))

# git-absorb — auto-routes staged hunks into fixup! commits (--and-rebase to
# fold). Non-v tag; the only x86_64 linux asset is musl (static libgit2).
$(eval $(call EGET_TOOL,git-absorb,$(GIT_ABSORB_VERSION),tummychow/git-absorb,$(GIT_ABSORB_VERSION),--asset musl))

# miniserve — zero-config HTTP file server. Assets are BARE binaries (no
# archive, like fx), so eget renames the raw binary to the repo name
# `miniserve`. musl and gnu both published → --asset musl.
$(eval $(call EGET_TOOL,miniserve,$(MINISERVE_VERSION),svenstaro/miniserve,,--asset musl))

# numbat — scientific calculator with first-class units (sharkdp). The tarball
# ships an optional modules/ tree + assets/, but the standard library is
# compiled INTO the binary (verified: `echo '2 km + 3 m' | numbat` => 2003 m
# binary-only), so eget's single-executable install is sufficient. musl-static.
$(eval $(call EGET_TOOL,numbat,$(NUMBAT_VERSION),sharkdp/numbat,,--asset musl))

# qsv — high-performance CSV data-wrangling toolkit. The musl .zip ships SIX
# binaries (qsv, qsvdp, qsvlite, qsvp, qsvpdp, qsvplite) — eget would abort on
# the ambiguity, so `--file qsv` extracts only the full-feature `qsv`. Non-v
# tag. (clean-qsv removes only qsv; the other five are never installed.)
$(eval $(call EGET_TOOL,qsv,$(QSV_VERSION),dathere/qsv,$(QSV_VERSION),--asset musl --file qsv))

# grex — generate a regex from example strings/files. musl-static.
$(eval $(call EGET_TOOL,grex,$(GREX_VERSION),pemistahl/grex,,--asset musl))

# jless — interactive read-only JSON/YAML pager. NOTE: upstream is dormant
# (last release v0.9.0, 2023) and ships ONLY a glibc build, linked against an
# old glibc (runs on the AlmaLinux 9 fleet, glibc 2.34). RUNTIME: it also
# dynamically links libxcb (clipboard support), so it needs libX11/libxcb at
# run time — a no-op on headless prod / bare WSL (installs, fails to start
# without an X stack), fine on GUI hosts. Overlaps fx (which is static and
# works headless); kept as a dedicated pager. .zip, one binary.
$(eval $(call EGET_TOOL,jless,$(JLESS_VERSION),PaulJuliusMartinez/jless))

# --- (2026-06) tier-1 lint/security + system/util gap-fillers ----------------
# gitleaks/procs/dust/hexyl/gum are eget single-binary installs (below);
# shfmt + pueue/pueued are raw-binary direct.sh installs (DIRECT section).
# shfmt + gitleaks are ALSO enforced by scripts/check-invariants.sh.

# gitleaks — secret scanner; ALSO enforced in check-invariants.sh (pre-commit +
# make lint + CI). The goreleaser tarball uses the arch token `linux_x64` (not
# x86_64/amd64), which eget won't auto-map to this host — pin it explicitly.
$(eval $(call EGET_TOOL,gitleaks,$(GITLEAKS_VERSION),gitleaks/gitleaks,,--asset linux_x64))

# procs — modern `ps` (process tree / search / colored). Upstream publishes NO
# musl build; the gnu zip runs fine on the glibc-2.34 fleet (verified). --asset
# linux picks the x86_64-linux zip (aarch64 excluded by arch, .rpm by anti-match).
$(eval $(call EGET_TOOL,procs,$(PROCS_VERSION),dalance/procs,,--asset linux))

# dust — intuitive `du` (instant disk-usage tree); complements ncdu. musl-static.
$(eval $(call EGET_TOOL,dust,$(DUST_VERSION),bootandy/dust,,--asset musl))

# hexyl — colored hex viewer (sharkdp). musl-static. Upgrades the dnf-only xxd.
$(eval $(call EGET_TOOL,hexyl,$(HEXYL_VERSION),sharkdp/hexyl,,--asset musl))

# gum — charmbracelet shell-script UI toolkit (choose/input/spin/confirm). The
# tarball ships a .sbom.json side-file (dropped by eget.sh's anti-match), leaving
# the single Linux_x86_64 tarball. Default v-tag.
$(eval $(call EGET_TOOL,gum,$(GUM_VERSION),charmbracelet/gum))

# --- (2026-06) Language servers (single-binary, both-scope) -------------------
# rust-analyzer — date-tagged release; asset rust-analyzer-x86_64-unknown-linux-
# gnu.gz (eget decompresses the .gz to the `rust-analyzer` binary). gnu-only for
# x86_64; tag == the date pin (no `v`).
$(eval $(call EGET_TOOL,rust-analyzer,$(RUST_ANALYZER_VERSION),rust-lang/rust-analyzer,$(RUST_ANALYZER_VERSION),--asset gnu))

# marksman — Markdown LSP. Date-tagged; asset is a BARE binary `marksman-linux-x64`
# (no archive), so eget renames it to the repo name `marksman`. Tag == the date.
$(eval $(call EGET_TOOL,marksman,$(MARKSMAN_VERSION),artempyanykh/marksman,$(MARKSMAN_VERSION),--asset linux-x64))

# taplo — TOML LSP (`taplo lsp stdio`). Non-v tag; asset taplo-linux-x86_64.gz.
# 0.10.0 unified the build: the single binary now bundles the LSP, and the
# separate `taplo-full-*` asset was dropped (0.9.3 was the last to ship it), so
# select linux+x86_64 (NOT `full`). eget decompresses the .gz to `taplo`.
$(eval $(call EGET_TOOL,taplo,$(TAPLO_VERSION),tamasfe/taplo,$(TAPLO_VERSION),--asset linux --asset x86_64))

# =============================================================================
# DEV-ONLY scope tools (MODE-gated) — the only scope tools that aren't both-scope.
# Every EGET_TOOL/TOOL above joins $(SCOPE_TOOLS) unconditionally (dev + prod).
# These three are dev_machine-only (herdr supervises AI coding agents; opencode
# and omp ARE AI coding agents — and Claude Code itself is dev-only-deployed),
# so we wrap the PREFERRED EGET_TOOL macro in a MODE guard: on dev they join
# $(SCOPE_TOOLS) and install with `make tools`/`provision` (auto-registering
# their doctor + check-updates rows); on prod the evals are skipped and a stub
# prints the same friendly "dev_machine tool — skipping" message the bespoke
# dev-only targets (pwndbg/vcpkg) use.
# herdr: textbook single-binary release — bare per-platform assets, eget
#   auto-selects herdr-linux-x86_64 (no --asset needed), tag v$(HERDR_VERSION).
#   It does NOT replace zellij — herdr is the agent-aware addition.
# opencode: tar.gz containing the single binary. Anti-match filters drop the
#   musl/baseline CPU-and-libc variants (EL9 = glibc; fleet CPUs have AVX2 —
#   see the versions.mk caveat) and the opencode-desktop-* app assets.
# omp: bare per-platform binary like herdr, BUT eget would name it after the
#   repo (oh-my-pi) — the trailing `--to $(DEST)/omp` overrides eget.sh's
#   earlier `--to $(DEST)` (later flag wins) to force the real command name.
# (gen-tool-memory.sh greps these call lines regardless of the ifeq, so the
# dev-only machine-memory TOOLS block still lists all three.)
# =============================================================================
ifeq ($(MODE),dev)
$(eval $(call EGET_TOOL,herdr,$(HERDR_VERSION),ogulcancelik/herdr))
$(eval $(call EGET_TOOL,opencode,$(OPENCODE_VERSION),anomalyco/opencode,,--asset '^musl' --asset '^baseline' --asset '^desktop'))
$(eval $(call EGET_TOOL,omp,$(OMP_VERSION),can1357/oh-my-pi,,--to $(DEST)/omp))
else
.PHONY: herdr opencode omp
herdr opencode omp:
	@echo "$@ is a dev_machine tool — skipping (MODE=$(MODE))"
endif

# =============================================================================
# DIRECT  (raw binary URL, no archive)
# =============================================================================

$(eval $(call TOOL,nb,$(NB_VERSION),\
  $(LIB)/direct.sh nb https://raw.githubusercontent.com/xwmx/nb/master/nb))

$(eval $(call TOOL,jq,$(JQ_VERSION),\
  $(LIB)/direct.sh jq https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-amd64,jq))

$(eval $(call TOOL,yq,$(YQ_VERSION),\
  $(LIB)/direct.sh yq https://github.com/mikefarah/yq/releases/download/v$(YQ_VERSION)/yq_linux_amd64,yq))

# tealdeer binary is installed as `tldr` for the canonical command name
$(eval $(call TOOL,tldr,$(TEALDEER_VERSION),\
  $(LIB)/direct.sh tldr https://github.com/tealdeer-rs/tealdeer/releases/download/v$(TEALDEER_VERSION)/tealdeer-linux-x86_64-musl,tldr))

$(eval $(call TOOL,witr,$(WITR_VERSION),\
  $(LIB)/direct.sh witr https://github.com/pranshuparmar/witr/releases/download/v$(WITR_VERSION)/witr-linux-amd64,witr))

# broot has no version pinning — upstream always serves "latest" at this URL
$(eval $(call TOOL,broot,$(BROOT_VERSION),\
  $(LIB)/direct.sh broot https://dystroy.org/broot/download/x86_64-linux/broot,broot))

$(eval $(call TOOL,ctop,$(CTOP_VERSION),\
  $(LIB)/direct.sh ctop https://github.com/bcicen/ctop/releases/download/v$(CTOP_VERSION)/ctop-$(CTOP_VERSION)-linux-amd64,ctop))

$(eval $(call TOOL,sops,$(SOPS_VERSION),\
  $(LIB)/direct.sh sops https://github.com/getsops/sops/releases/download/v$(SOPS_VERSION)/sops-v$(SOPS_VERSION).linux.amd64,sops))

$(eval $(call TOOL,lazyjournal,$(LAZYJOURNAL_VERSION),\
  $(LIB)/direct.sh lazyjournal https://github.com/Lifailon/lazyjournal/releases/download/$(LAZYJOURNAL_VERSION)/lazyjournal-$(LAZYJOURNAL_VERSION)-linux-amd64,lazyjournal))

$(eval $(call TOOL,sysz,$(SYSZ_VERSION),\
  $(LIB)/direct.sh sysz https://raw.githubusercontent.com/joehillen/sysz/$(SYSZ_VERSION)/sysz))

$(eval $(call TOOL,ssh-copy-id,$(SSH_COPY_ID_VERSION),\
  $(LIB)/direct.sh ssh-copy-id https://raw.githubusercontent.com/openssh/openssh-portable/master/contrib/ssh-copy-id))

# shfmt — shell formatter (mvdan/sh); ALSO enforced in check-invariants.sh
# (pre-commit + make lint + CI). The asset is a RAW binary named
# shfmt_v<V>_linux_amd64 — eget would install it under the repo name (`sh`), so
# direct.sh fetches the raw URL and names it `shfmt`. Go-static (glibc-free).
$(eval $(call TOOL,shfmt,$(SHFMT_VERSION),\
  $(LIB)/direct.sh shfmt https://github.com/mvdan/sh/releases/download/v$(SHFMT_VERSION)/shfmt_v$(SHFMT_VERSION)_linux_amd64,shfmt))

# pueue — background job queue: daemon (pueued) + client (pueue), shipped as TWO
# separate raw-binary assets. eget renames any raw binary to the repo name
# (`pueue`), so the daemon would also land as `pueue` — direct.sh fetches each
# under its correct name. musl-static. The daemon runs via the chezmoi-managed
# systemd user unit (chezmoi/dot_config/systemd/user/pueued.service.tmpl),
# auto-enabled on apply.
$(eval $(call TOOL,pueue,$(PUEUE_VERSION),\
  $(LIB)/direct.sh pueue https://github.com/Nukesor/pueue/releases/download/v$(PUEUE_VERSION)/pueue-x86_64-unknown-linux-musl,pueue))
$(eval $(call TOOL,pueued,$(PUEUE_VERSION),\
  $(LIB)/direct.sh pueued https://github.com/Nukesor/pueue/releases/download/v$(PUEUE_VERSION)/pueued-x86_64-unknown-linux-musl,pueued))

# nnd — modern from-scratch TUI debugger for Linux (al13n321/nnd): not built on
# gdb/lldb, single dependency-free binary, async multi-threaded debug-info load
# (snappy on large binaries). Complements gdb/lldb; both scopes. The release
# ships BARE binaries — `nnd` plus a `nnd-dbgo` debug-info-optimized variant —
# with no os/arch tokens, so eget can't auto-select; direct.sh fetches the plain
# `nnd` raw URL (same pattern as jq/shfmt/witr). v-prefixed tag.
$(eval $(call TOOL,nnd,$(NND_VERSION),\
  $(LIB)/direct.sh nnd https://github.com/al13n321/nnd/releases/download/v$(NND_VERSION)/nnd,nnd))

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
# SOFT_TOOL (not TOOL): the cht.sh service has transient outages (5xx), and it's
# the only tool fetched live from a third party at provision time — a blip there
# must not abort the whole `make dev`. Failure warns + skips + retries next run.
$(eval $(call SOFT_TOOL,cht.sh,$(CHTSH_VERSION),\
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
UPDATE_SPECS += usql|$(USQL_VERSION)|xo/usql|v$(USQL_VERSION)
UPDATE_SPECS += yazi|$(YAZI_VERSION)|sxyazi/yazi|v$(YAZI_VERSION)
UPDATE_SPECS += nnn|$(NNN_VERSION)|jarun/nnn|v$(NNN_VERSION)
UPDATE_SPECS += age|$(AGE_VERSION)|FiloSottile/age|v$(AGE_VERSION)
UPDATE_SPECS += jq|$(JQ_VERSION)|jqlang/jq|jq-$(JQ_VERSION)
UPDATE_SPECS += yq|$(YQ_VERSION)|mikefarah/yq|v$(YQ_VERSION)
UPDATE_SPECS += tldr|$(TEALDEER_VERSION)|tealdeer-rs/tealdeer|v$(TEALDEER_VERSION)
UPDATE_SPECS += shfmt|$(SHFMT_VERSION)|mvdan/sh|v$(SHFMT_VERSION)
UPDATE_SPECS += pueue|$(PUEUE_VERSION)|Nukesor/pueue|v$(PUEUE_VERSION)
UPDATE_SPECS += pueued|$(PUEUE_VERSION)|Nukesor/pueue|v$(PUEUE_VERSION)
UPDATE_SPECS += nnd|$(NND_VERSION)|al13n321/nnd|v$(NND_VERSION)
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
# pwndbg + vcpkg — dev-only bespoke targets (Makefile); tags carry no `v` prefix
# (tag == version, so check-updates uses an empty glob prefix → matches all).
UPDATE_SPECS += pwndbg|$(PWNDBG_VERSION)|pwndbg/pwndbg|$(PWNDBG_VERSION)
UPDATE_SPECS += vcpkg|$(VCPKG_VERSION)|microsoft/vcpkg|$(VCPKG_VERSION)
