@{
    # Mirror the shellcheck gate's rigor: fail on Warning and Error.
    Severity = @('Error', 'Warning')

    # Rules excluded because they fight an intentional, documented style choice.
    # Expand this list ONLY for confirmed intentional-style false positives,
    # each with a one-line reason (see the CI-iteration step in the plan).
    ExcludeRules = @(
        # The scripts use Write-Host extensively for colored, interactive UX.
        'PSAvoidUsingWriteHost'
        # False positive on script-level CLI flags: every flagged param
        # (SkipToolInstall, ForceInstaller, Yes, ...) is referenced 4-10x — the
        # rule misses usage inside nested functions / scriptblocks.
        'PSReviewUnusedParameter'
        # Write-Log/Write-Ok/... are intentional local logging helpers, not the
        # module-provided built-ins of the same name.
        'PSAvoidOverwritingBuiltInCmdlets'
        # Internal helper functions (Update-SessionPath, Remove-HostEntry, ...)
        # are not user-facing cmdlets; -WhatIf/-Confirm is not part of the design.
        'PSUseShouldProcessForStateChangingFunctions'
        # Internal functions named after inherently-plural domains (Read-Hosts,
        # Show-Hosts, Invoke-CheckForUpdates, ...). Singularizing Read-Hosts would
        # collide with the built-in Read-Host.
        'PSUseSingularNouns'
    )
}
