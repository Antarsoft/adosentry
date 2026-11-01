function Resolve-AdoCollectionUrl {
    <#
    .SYNOPSIS
        Returns the Azure DevOps collection URL that REST calls are built on, without a trailing slash.

    .DESCRIPTION
        Pass the pipeline's $(System.CollectionUri) as CollectionUri. It already has the right shape
        for every host: https://dev.azure.com/<org>/, https://<org>.visualstudio.com/ and Azure DevOps
        Server (https://<server>/tfs/<collection>/). Organization is a fallback for callers that only
        know the organization name; it assumes the Azure DevOps Services host dev.azure.com.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [parameter()]
        [string]
        $CollectionUri = '',

        [parameter()]
        [string]
        $Organization = ''
    )

    # An unset pipeline variable reaches the script as its own macro text, for example
    # '$(System.CollectionUri)'. Treat that the same as an empty value.
    if ($CollectionUri.StartsWith('$(')) { $CollectionUri = '' }
    if ($Organization.StartsWith('$(')) { $Organization = '' }

    if (-not [string]::IsNullOrWhiteSpace($CollectionUri)) {
        $parsed = $null
        if (-not [uri]::TryCreate($CollectionUri.Trim(), [UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -notin @('https', 'http')) {
            throw "CollectionUri '$CollectionUri' is not an absolute http(s) URL. Pass the pipeline's `$(System.CollectionUri)."
        }
        return $parsed.AbsoluteUri.TrimEnd('/')
    }

    if (-not [string]::IsNullOrWhiteSpace($Organization)) {
        return "https://dev.azure.com/$($Organization.Trim().Trim('/'))"
    }

    throw 'Pass CollectionUri (the pipeline''s $(System.CollectionUri)) or Organization.'
}
