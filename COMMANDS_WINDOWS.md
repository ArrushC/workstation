### Windows
# Create the wezterm config dir if it doesn't exist
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.config\wezterm"

# Create a hard link — wezterm reads from here, git tracks from the repo
New-Item -ItemType HardLink `
    -Path "$env:USERPROFILE\.config\wezterm\wezterm.lua" `
    -Target "C:\Git\workstation\wezterm.lua"