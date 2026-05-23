# tools.mk — per-tool install rules.
#
# Each tool is one $(eval $(call ...,)) line. Both macros are defined in
# the Makefile; pick the one that matches the tool's destination semantics:
#
#   TOOL       — scope-aware install. Honors $(DEST). Joins $(SCOPE_TOOLS).
#                Used by `make all`. Run under become when system scope.
#   USER_TOOL  — installs to the dev user's ~/.local (pip user-site).
#                Joins $(USER_TOOLS). Used by `make user-tools`. Never sudo.
#
# Helpers (all under lib/):
#   archive.sh  <binary[:other:...]> <url>     tar.gz/tar.bz2/tar.xz/zip
#   direct.sh   <name> <url>                   raw binary URL (no archive)
#   pip.sh      <pkg>                          Python user-site
#   helix.sh    <version>                      multi-file special case
#   pipe.sh     <name> <url> [-- <args>]       curl-piped installer
#
# Adding a tool:
#   1. <NAME>_VERSION := ...   in versions.mk
#   2. one $(eval $(call ...)) line below, in the right section
#   3. If the URL is unusual (no v prefix, weird tag format), check the
#      tool's GitHub Releases page — the URL template here must match
#      exactly what upstream publishes.

# =============================================================================
# ARCHIVE single-binary  (tar.gz / tar.bz2 / tar.xz / zip)
# archive.sh walks the extracted tree with `find -name <binary>` and installs
# the first match, so the internal layout doesn't matter — top-level,
# ./prefix, wrapper dir, nested bin/, all handled identically.
# =============================================================================

# --- Tier-0 ------------------------------------------------------------------
$(eval $(call TOOL,fzf,$(FZF_VERSION),\
  $(LIB)/archive.sh fzf https://github.com/junegunn/fzf/releases/download/v$(FZF_VERSION)/fzf-$(FZF_VERSION)-linux_amd64.tar.gz))

$(eval $(call TOOL,zoxide,$(ZOXIDE_VERSION),\
  $(LIB)/archive.sh zoxide https://github.com/ajeetdsouza/zoxide/releases/download/v$(ZOXIDE_VERSION)/zoxide-$(ZOXIDE_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,starship,$(STARSHIP_VERSION),\
  $(LIB)/archive.sh starship https://github.com/starship/starship/releases/download/v$(STARSHIP_VERSION)/starship-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,zellij,$(ZELLIJ_VERSION),\
  $(LIB)/archive.sh zellij https://github.com/zellij-org/zellij/releases/download/v$(ZELLIJ_VERSION)/zellij-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,glow,$(GLOW_VERSION),\
  $(LIB)/archive.sh glow https://github.com/charmbracelet/glow/releases/download/v$(GLOW_VERSION)/glow_$(GLOW_VERSION)_Linux_x86_64.tar.gz))

# --- Tier-1 ------------------------------------------------------------------
$(eval $(call TOOL,fd,$(FD_VERSION),\
  $(LIB)/archive.sh fd https://github.com/sharkdp/fd/releases/download/v$(FD_VERSION)/fd-v$(FD_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,bat,$(BAT_VERSION),\
  $(LIB)/archive.sh bat https://github.com/sharkdp/bat/releases/download/v$(BAT_VERSION)/bat-v$(BAT_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,btop,$(BTOP_VERSION),\
  $(LIB)/archive.sh btop https://github.com/aristocratos/btop/releases/download/v$(BTOP_VERSION)/btop-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,ncdu,$(NCDU_VERSION),\
  $(LIB)/archive.sh ncdu https://dev.yorhel.nl/download/ncdu-$(NCDU_VERSION)-linux-x86_64.tar.gz))

$(eval $(call TOOL,bandwhich,$(BANDWHICH_VERSION),\
  $(LIB)/archive.sh bandwhich https://github.com/imsnif/bandwhich/releases/download/v$(BANDWHICH_VERSION)/bandwhich-v$(BANDWHICH_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,usql,$(USQL_VERSION),\
  $(LIB)/archive.sh usql https://github.com/xo/usql/releases/download/v$(USQL_VERSION)/usql-$(USQL_VERSION)-linux-amd64.tar.bz2))

$(eval $(call TOOL,lazydocker,$(LAZYDOCKER_VERSION),\
  $(LIB)/archive.sh lazydocker https://github.com/jesseduffield/lazydocker/releases/download/v$(LAZYDOCKER_VERSION)/lazydocker_$(LAZYDOCKER_VERSION)_Linux_x86_64.tar.gz))

$(eval $(call TOOL,dive,$(DIVE_VERSION),\
  $(LIB)/archive.sh dive https://github.com/wagoodman/dive/releases/download/v$(DIVE_VERSION)/dive_$(DIVE_VERSION)_linux_amd64.tar.gz))

$(eval $(call TOOL,lnav,$(LNAV_VERSION),\
  $(LIB)/archive.sh lnav https://github.com/tstack/lnav/releases/download/v$(LNAV_VERSION)/lnav-$(LNAV_VERSION)-linux-musl-x86_64.zip))

$(eval $(call TOOL,gopass,$(GOPASS_VERSION),\
  $(LIB)/archive.sh gopass https://github.com/gopasspw/gopass/releases/download/v$(GOPASS_VERSION)/gopass-$(GOPASS_VERSION)-linux-amd64.tar.gz))

$(eval $(call TOOL,fastfetch,$(FASTFETCH_VERSION),\
  $(LIB)/archive.sh fastfetch https://github.com/fastfetch-cli/fastfetch/releases/download/$(FASTFETCH_VERSION)/fastfetch-musl-amd64.tar.gz))

# --- Second-wave -------------------------------------------------------------
$(eval $(call TOOL,gitui,$(GITUI_VERSION),\
  $(LIB)/archive.sh gitui https://github.com/gitui-org/gitui/releases/download/v$(GITUI_VERSION)/gitui-linux-x86_64.tar.gz))

$(eval $(call TOOL,lazygit,$(LAZYGIT_VERSION),\
  $(LIB)/archive.sh lazygit https://github.com/jesseduffield/lazygit/releases/download/v$(LAZYGIT_VERSION)/lazygit_$(LAZYGIT_VERSION)_linux_x86_64.tar.gz))

$(eval $(call TOOL,jj,$(JUJUTSU_VERSION),\
  $(LIB)/archive.sh jj https://github.com/jj-vcs/jj/releases/download/v$(JUJUTSU_VERSION)/jj-v$(JUJUTSU_VERSION)-x86_64-unknown-linux-musl.tar.gz))

# yazi ships two binaries (yazi + ya) in the same zip — colon-separated spec
$(eval $(call TOOL,yazi,$(YAZI_VERSION),\
  $(LIB)/archive.sh yazi:ya https://github.com/sxyazi/yazi/releases/download/v$(YAZI_VERSION)/yazi-x86_64-unknown-linux-musl.zip))

# ast-grep ships two binaries (sg + ast-grep)
$(eval $(call TOOL,ast-grep,$(AST_GREP_VERSION),\
  $(LIB)/archive.sh sg:ast-grep https://github.com/ast-grep/ast-grep/releases/download/$(AST_GREP_VERSION)/app-x86_64-unknown-linux-gnu.zip))

$(eval $(call TOOL,television,$(TELEVISION_VERSION),\
  $(LIB)/archive.sh tv https://github.com/alexpasmantier/television/releases/download/$(TELEVISION_VERSION)/tv-$(TELEVISION_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,xh,$(XH_VERSION),\
  $(LIB)/archive.sh xh https://github.com/ducaale/xh/releases/download/v$(XH_VERSION)/xh-v$(XH_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,gping,$(GPING_VERSION),\
  $(LIB)/archive.sh gping https://github.com/orf/gping/releases/download/gping-v$(GPING_VERSION)/gping-Linux-musl-x86_64.tar.gz))

$(eval $(call TOOL,atuin,$(ATUIN_VERSION),\
  $(LIB)/archive.sh atuin https://github.com/atuinsh/atuin/releases/download/v$(ATUIN_VERSION)/atuin-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,delta,$(DELTA_VERSION),\
  $(LIB)/archive.sh delta https://github.com/dandavison/delta/releases/download/$(DELTA_VERSION)/delta-$(DELTA_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,micro,$(MICRO_VERSION),\
  $(LIB)/archive.sh micro https://github.com/zyedidia/micro/releases/download/v$(MICRO_VERSION)/micro-$(MICRO_VERSION)-linux64-static.tar.gz))

$(eval $(call TOOL,eza,$(EZA_VERSION),\
  $(LIB)/archive.sh eza https://github.com/eza-community/eza/releases/download/v$(EZA_VERSION)/eza_x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,sd,$(SD_VERSION),\
  $(LIB)/archive.sh sd https://github.com/chmln/sd/releases/download/v$(SD_VERSION)/sd-v$(SD_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,k9s,$(K9S_VERSION),\
  $(LIB)/archive.sh k9s https://github.com/derailed/k9s/releases/download/v$(K9S_VERSION)/k9s_Linux_amd64.tar.gz))

$(eval $(call TOOL,rclone,$(RCLONE_VERSION),\
  $(LIB)/archive.sh rclone https://github.com/rclone/rclone/releases/download/v$(RCLONE_VERSION)/rclone-v$(RCLONE_VERSION)-linux-amd64.zip))

$(eval $(call TOOL,croc,$(CROC_VERSION),\
  $(LIB)/archive.sh croc https://github.com/schollz/croc/releases/download/v$(CROC_VERSION)/croc_v$(CROC_VERSION)_Linux-64bit.tar.gz))

$(eval $(call TOOL,hyperfine,$(HYPERFINE_VERSION),\
  $(LIB)/archive.sh hyperfine https://github.com/sharkdp/hyperfine/releases/download/v$(HYPERFINE_VERSION)/hyperfine-v$(HYPERFINE_VERSION)-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,mise,$(MISE_VERSION),\
  $(LIB)/archive.sh mise https://github.com/jdx/mise/releases/download/v$(MISE_VERSION)/mise-v$(MISE_VERSION)-linux-x64-musl.tar.gz))

# uv ships uv + uvx in the same tarball
$(eval $(call TOOL,uv,$(UV_VERSION),\
  $(LIB)/archive.sh uv:uvx https://github.com/astral-sh/uv/releases/download/$(UV_VERSION)/uv-x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,dsq,$(DSQ_VERSION),\
  $(LIB)/archive.sh dsq https://github.com/multiprocessio/dsq/releases/download/v$(DSQ_VERSION)/dsq-linux-x64-v$(DSQ_VERSION).zip))

# --- Robustness gap-fillers --------------------------------------------------
$(eval $(call TOOL,gh,$(GH_VERSION),\
  $(LIB)/archive.sh gh https://github.com/cli/cli/releases/download/v$(GH_VERSION)/gh_$(GH_VERSION)_linux_amd64.tar.gz))

$(eval $(call TOOL,htmlq,$(HTMLQ_VERSION),\
  $(LIB)/archive.sh htmlq https://github.com/mgdm/htmlq/releases/download/v$(HTMLQ_VERSION)/htmlq-x86_64-linux.tar.gz))

$(eval $(call TOOL,ouch,$(OUCH_VERSION),\
  $(LIB)/archive.sh ouch https://github.com/ouch-org/ouch/releases/download/$(OUCH_VERSION)/ouch-x86_64-unknown-linux-musl.tar.gz))

# bottom's binary is named `btm` — that's what find looks for
$(eval $(call TOOL,bottom,$(BOTTOM_VERSION),\
  $(LIB)/archive.sh btm https://github.com/ClementTsang/bottom/releases/download/$(BOTTOM_VERSION)/bottom_x86_64-unknown-linux-musl.tar.gz))

$(eval $(call TOOL,systemctl-tui,$(SYSTEMCTL_TUI_VERSION),\
  $(LIB)/archive.sh systemctl-tui https://github.com/rgwood/systemctl-tui/releases/download/v$(SYSTEMCTL_TUI_VERSION)/systemctl-tui-x86_64-unknown-linux-musl.tar.gz))

# age ships age + age-keygen
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
