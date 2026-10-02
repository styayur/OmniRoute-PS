@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        # The CLI intentionally writes user-facing status to the host.
        'PSAvoidUsingWriteHost'
        # Cleanup catches intentionally suppress disposal errors.
        'PSAvoidUsingEmptyCatchBlock'
        # These functions mutate only in-process router state and are not system-changing commands.
        'PSUseShouldProcessForStateChangingFunctions'
        # Collection-oriented function names are clearer for routing APIs.
        'PSUseSingularNouns'
        # Start-ThreadJob argument params are bound through -ArgumentList.
        'PSUseUsingScopeModifierInNewRunspaces'
    )
}
