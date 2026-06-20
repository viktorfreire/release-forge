param(
    [string]$organisation,
    [string]$project,
    [string]$mappingsFile,
    [string]$releaseDateField,
    [string]$releaseWit,
    [string]$businessJustificationField,
    [string]$ticketingSystemBaseUrl
)

Write-Host "Starting Release Sync..."

. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Delivery.Logic.ps1"

# -------------------------------------------------------------
# Setup
# -------------------------------------------------------------
$accessToken    = Resolve-AccessToken
$encodedProject = [Uri]::EscapeDataString($project)
$baseUrl        = "https://dev.azure.com/$organisation/$encodedProject"

$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

$patchHeaders = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json-patch+json"
}

$escapedProject = $project -replace "'", "''"

# -------------------------------------------------------------
# Load team mappings
# -------------------------------------------------------------
if (-not (Test-Path $mappingsFile)) {
    Write-Error "Mappings file not found: $mappingsFile"
    exit 1
}

$mappings = Get-Content $mappingsFile -Raw | ConvertFrom-Json

if (-not $mappings -or $mappings.Count -eq 0) {
    Write-Error "No team mappings found in: $mappingsFile"
    exit 1
}

Write-Host "Loaded $($mappings.Count) team mapping(s)."

# -------------------------------------------------------------
# Run sync for every team in the mappings file
# -------------------------------------------------------------
foreach ($mapping in $mappings) {
    Sync-Team -teamAreaPath $mapping.areaPath -teamName $mapping.teamName -assignedTo $mapping.assignedTo
}

Write-Host ""
Write-Host "Release Sync completed successfully."
