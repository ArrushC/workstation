---
name: project-windows-nerdfont-activation
description: Windows Terminal/DirectWrite needs the Win32 family name "JetBrainsMono NFM"; per-user fonts must be activated in-session, and WezTerm masks a missing one.
metadata:
  type: project
---

If a Windows DirectWrite app (Windows Terminal, Zed, VS Code) reports
**"Unable to find the following fonts: …"** for the repo's Nerd Font, two
distinct things can be wrong — check BOTH:

1. **Wrong family name.** The pinned JetBrainsMono Nerd Font (3.4.0,
   `JetBrainsMonoNerdFontMono-*.ttf`) exposes its **Win32 family name (the one
   WT/GDI/DirectWrite match) as `JetBrainsMono NFM`** (+ `JetBrainsMono NFM
   Medium`). `JetBrainsMono Nerd Font Mono` is only the *typographic* family
   name (name ID 16). So **Windows Terminal profiles must use `JetBrainsMono
   NFM`**. (Confirm names from the file, session-independently:
   `(New-Object System.Windows.Media.GlyphTypeface $ttf).Win32FamilyNames.Values`.)
   `wezterm.lua` keeps the long name on purpose — WezTerm matches the
   typographic name, and fontconfig exposes the long name on Linux.

2. **Font not activated in the session.** Per-user fonts (in
   `%LOCALAPPDATA%\Microsoft\Windows\Fonts`, registered in
   `HKCU\…\Fonts`) are only auto-loaded **at next logon**. To make them live in
   the current session without a relog, `install-nerd-fonts.ps1`'s
   `Invoke-FontActivation` runs `AddFontResourceW` + a `WM_FONTCHANGE` broadcast
   — and it runs on *every* bootstrap. So if `bootstrap.ps1` **aborts before its
   font step (step 7)** — e.g. it died at the `chezmoi` step (see
   [[project-windows-apply-via-wsl-gotchas]]) — the font is registered but NOT
   live, and apps can't find it under any name until a logon or manual
   activation.

**`works in WezTerm` ≠ `installed for the system`.** WezTerm reads the `.ttf`
directly via `config.font_dirs` AND ships its own Nerd Font glyph fallback, so
it renders fine even when the font is misnamed or not session-activated — it
masks both failures. Don't use WezTerm as proof the system has the font.

**Diagnosis recipe:** `InstalledFontCollection().Families` (run in the *user's*
session — a WSL-spawned powershell shares SessionId 1) shows what's actually
loaded; if JetBrains is absent there, it's #2 (activation), not #1 (name).
Manual fix without relog: `AddFontResourceW` each ttf + broadcast `WM_FONTCHANGE`
(0x001D) to `HWND_BROADCAST` (0xffff) from a session-1 process; verify a *fresh*
process then sees it (proves session-wide persistence).
