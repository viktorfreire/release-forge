function Resolve-AccessToken {
    if ($env:ACCESS_TOKEN)       { return $env:ACCESS_TOKEN       }
    if ($env:SYSTEM_ACCESSTOKEN) { return $env:SYSTEM_ACCESSTOKEN }
    Write-Error "No access token found. Set ACCESS_TOKEN (GitHub Actions) or SYSTEM_ACCESSTOKEN (Azure DevOps)."
    exit 1
}

function Convert-Date {
    param([string]$value)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parsed  = [datetime]::ParseExact(
        $value.Trim(), "dd-MMM-yy", $culture,
        [System.Globalization.DateTimeStyles]::None
    )
    return $parsed.ToString("yyyy-MM-dd")
}

function Get-WorkItemsInBatches {
    param([int[]]$ids)
    $all       = @()
    $batchSize = 200
    for ($i = 0; $i -lt $ids.Count; $i += $batchSize) {
        $batch    = $ids[$i .. ([Math]::Min($i + $batchSize - 1, $ids.Count - 1))]
        $response = Invoke-RestMethod `
            -Uri     "$baseUrl/_apis/wit/workitems?ids=$($batch -join ',')&api-version=7.1" `
            -Headers $headers
        $all += $response.value
    }
    return $all
}

function Sanitize {
    param([string]$value)
    if ([string]::IsNullOrWhiteSpace($value)) { return "" }

    # Decode all HTML entities (&amp;, &nbsp;, &lt;, &#39;, &#160; etc.)
    # Two passes handles double-encoded content e.g. &amp;lt; -> &lt; -> <
    $clean = [System.Web.HttpUtility]::HtmlDecode($value)
    $clean = [System.Web.HttpUtility]::HtmlDecode($clean)

    # Strip all HTML tags
    $clean = $clean -replace "<[^>]*>", ""

    # Normalise whitespace — including non-breaking space produced by &nbsp;
    $clean = $clean -replace "[ \r\n\t]", " "
    $clean = $clean -replace "\s{2,}",    " "

    # Keep only printable ASCII
    $clean = $clean -replace "[^\x20-\x7E]", ""

    return $clean.Trim()
}