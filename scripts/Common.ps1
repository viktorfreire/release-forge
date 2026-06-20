function Resolve-AccessToken {
    if ($env:ACCESS_TOKEN)      { return $env:ACCESS_TOKEN      }
    if ($env:SYSTEM_ACCESSTOKEN){ return $env:SYSTEM_ACCESSTOKEN }
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
    $clean = $value -replace "&nbsp;",       " "
    $clean = $clean -replace "&amp;",        "&"
    $clean = $clean -replace "&lt;",         "<"
    $clean = $clean -replace "&gt;",         ">"
    $clean = $clean -replace "&quot;",       '"'
    $clean = $clean -replace "&#39;",        "'"
    $clean = $clean -replace "&[a-zA-Z]+;",  ""
    $clean = $clean -replace "<[^>]*>",      ""
    $clean = $clean -replace "[\r\n]+",      " "
    $clean = $clean -replace "\s{2,}",       " "
    $clean = $clean -replace "[^\x20-\x7E]", ""
    return $clean.Trim()
}
