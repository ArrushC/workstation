# Command-line syntax colours that mirror zsh's (ZSH_HIGHLIGHT_STYLES and
# ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE in dotfiles/zshrc.tera), so a line reads the same in
# Nushell here and in zsh on the Linux hosts: commands green, unknown commands red bold,
# arguments plain, quoted strings yellow, flags peach, paths underlined.
# Autoload runs files in name order, so this loads after the vendored catppuccin_mocha.nu
# and overrides only the shape_* keys that have a zsh twin; table and value colours,
# variables, numbers and closures stay Catppuccin's.
# $zsh's keys are zsh's style names; check_shell_highlight_parity holds them equal.
# One gap zsh doesn't have: Nushell's parser gives every argument of an external command
# (ssh, git) the one shape externalarg (nu-parser flatten.rs), so a flag, quoted string or
# glob there draws as plain text; Nushell's own commands colour them as zsh does.
let zsh = {
  default: "#cdd6f4"
  "unknown-token": { fg: "#f38ba8" attr: b }
  "reserved-word": "#f9e2af"
  command: "#a6e3a1"
  commandseparator: "#94e2d5"
  path: { fg: "#cdd6f4" attr: u }
  globbing: "#89b4fa"
  "double-hyphen-option": "#fab387"
  "single-quoted-argument": "#f9e2af"
  "double-quoted-argument": "#f9e2af"
  redirection: "#89dceb"
  autosuggest: "#6c7086"
}

$env.config.color_config = ($env.config.color_config | merge {
  shape_internalcall: $zsh.command
  shape_external_resolved: $zsh.command
  shape_custom: $zsh.command
  shape_external: $zsh."unknown-token"
  shape_garbage: $zsh."unknown-token"
  shape_externalarg: $zsh.default
  shape_keyword: $zsh."reserved-word"
  shape_flag: $zsh."double-hyphen-option"
  shape_string: $zsh."double-quoted-argument"
  shape_string_interpolation: $zsh."double-quoted-argument"
  shape_raw_string: $zsh."single-quoted-argument"
  shape_filepath: $zsh.path
  shape_directory: $zsh.path
  shape_globpattern: $zsh.globbing
  shape_glob_interpolation: $zsh.globbing
  shape_pipe: $zsh.commandseparator
  shape_redirection: $zsh.redirection
  hints: $zsh.autosuggest
})
