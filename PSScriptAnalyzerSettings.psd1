@{
    # Mirror the shellcheck gate's rigor: fail on Warning and Error.
    Severity = @('Error', 'Warning')

    # Rules excluded because they fight an intentional, documented style choice.
    # Expand this list ONLY for confirmed intentional-style false positives,
    # each with a one-line reason (see the CI-iteration step in the plan).
    ExcludeRules = @(
        # The scripts use Write-Host extensively for colored, interactive UX.
        'PSAvoidUsingWriteHost'
    )
}
