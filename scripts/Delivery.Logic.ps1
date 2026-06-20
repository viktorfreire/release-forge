function Build-Description {
    param(
        [object[]]$workItems,
        [string]$teamName,
        [string]$releaseDate
    )

    $features = @($workItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Feature' })
    $defects  = @($workItems | Where-Object { $_.fields.'System.WorkItemType' -eq 'Defect'  })

    function Format-Features {
        param([object[]]$items)
        if (-not $items -or $items.Count -eq 0) { return "" }

        $snBase             = $ticketingSystemBaseUrl.TrimEnd('/')
        $initiativeListPath = "now/nav/ui/classic/params/target/x_u4bsh_initiati_0_initiative_list.do%3Fsysparm_query%3Dnumber%3D"

        $sorted = $items | Sort-Object { [int]($_.fields.'Microsoft.VSTS.Common.Priority' -as [int]) }

        $rows = $sorted | ForEach-Object {
            $title        = [System.Web.HttpUtility]::HtmlEncode((Sanitize $_.fields.'System.Title'))
            $bj           = Sanitize $_.fields.$businessJustificationField
            $initiativeId = Sanitize $_.fields.'Custom.InitiativeID'
            $sponsor      = [System.Web.HttpUtility]::HtmlEncode((Sanitize $_.fields.'Custom.PointofContactSponsor'))

            $bjHtml = if ([string]::IsNullOrWhiteSpace($bj)) {
                "<em>No business justification provided.</em>"
            } else {
                [System.Web.HttpUtility]::HtmlEncode($bj)
            }

            $initiativeHtml = if ([string]::IsNullOrWhiteSpace($initiativeId)) {
                "<em>N/A</em>"
            } else {
                $url = "$snBase/$initiativeListPath$([Uri]::EscapeDataString($initiativeId))"
                "<a href='$url'>$([System.Web.HttpUtility]::HtmlEncode($initiativeId))</a>"
            }

            $sponsorHtml = if ([string]::IsNullOrWhiteSpace($sponsor)) { "<em>N/A</em>" } else { $sponsor }

            "<li><strong>$title</strong><br>$bjHtml<br>Initiative Number: $initiativeHtml<br>Sponsor: $sponsorHtml</li>"
        }

        return "<h3>Features</h3><ul>$($rows -join '')</ul>"
    }

    function Format-Defects {
        param([object[]]$items)
        if (-not $items -or $items.Count -eq 0) { return "" }

        $snBase         = $ticketingSystemBaseUrl.TrimEnd('/')
        $defectListPath = "now/nav/ui/classic/params/target/rm_defect_list.do%3Fsysparm_query%3Dnumber%3D"

        $sorted = $items | Sort-Object { [int]($_.fields.'Microsoft.VSTS.Common.Priority' -as [int]) }

        $rows = $sorted | ForEach-Object {
            $title     = [System.Web.HttpUtility]::HtmlEncode((Sanitize $_.fields.'System.Title'))
            $refNumber = Sanitize $_.fields.'Custom.ReferenceNumber'

            $incidentHtml = if ([string]::IsNullOrWhiteSpace($refNumber)) {
                "<em>N/A</em>"
            } else {
                $url = "$snBase/$defectListPath$([Uri]::EscapeDataString($refNumber))"
                "<a href='$url'>$([System.Web.HttpUtility]::HtmlEncode($refNumber))</a>"
            }

            "<li><strong>$title</strong><br>Incident Number: $incidentHtml</li>"
        }

        return "<h3>Defects</h3><ul>$($rows -join '')</ul>"
    }

    $featureCount = $features.Count
    $defectCount  = $defects.Count
    $summary      = "This release includes <strong>$featureCount feature(s)</strong> and <strong>$defectCount defect(s)</strong>."

    $featuresHtml = Format-Features -items $features
    $defectsHtml  = Format-Defects  -items $defects

    $html = "<h2>$([System.Web.HttpUtility]::HtmlEncode($teamName))</h2>" +
            "<p><em>Release date: $releaseDate</em></p><hr>" +
            "<p>$summary</p><hr>" +
            $featuresHtml +
            $defectsHtml

    return $html
}

function Get-TargetReleaseState {
    param([object[]]$items)

    $featureActiveStates = @('In Progress','In IST','In QA test','In UAT','Live in Hypercare','Ready for Deployment')
    $defectActiveStates  = @('In Progress','In Test','In UAT','Ready for Deployment')

    $nonCancelled = @($items | Where-Object { $_.fields.'System.State' -ne 'Cancelled' })
    if ($nonCancelled.Count -eq 0) { return $null }

    $anyActive = ($nonCancelled | Where-Object {
        $s = $_.fields.'System.State'
        $w = $_.fields.'System.WorkItemType'
        ($w -eq 'Feature' -and $featureActiveStates -contains $s) -or
        ($w -eq 'Defect'  -and $defectActiveStates  -contains $s)
    }).Count -gt 0

    $allDone = ($nonCancelled | Where-Object { $_.fields.'System.State' -ne 'Done' }).Count -eq 0

    if ($allDone)   { return 'Done'       }
    if ($anyActive) { return 'In Progress' }
    return $null
}

function Sync-Team {
    param(
        [string]$teamAreaPath,
        [string]$teamName,
        [string]$assignedTo
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Team      : $teamName"
    Write-Host "Area Path : $teamAreaPath"
    Write-Host "========================================"

    $escapedAreaPath = $teamAreaPath -replace "'", "''"

    # STEP 1 - WIQL query
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE " +
            "[System.TeamProject] = '$escapedProject' " +
            "AND [System.WorkItemType] IN ('Feature','Defect') " +
            "AND [System.AreaPath] UNDER '$escapedAreaPath' " +
            "AND [$releaseDateField] <> ''"

    $result = Invoke-RestMethod `
        -Uri     "$baseUrl/_apis/wit/wiql?api-version=7.1" `
        -Method  POST `
        -Headers $headers `
        -Body    (@{ query = $wiql } | ConvertTo-Json)

    $ids = $result.workItems.id

    if (-not $ids -or $ids.Count -eq 0) {
        Write-Host "No items found. Skipping."
        return
    }

    Write-Host "Found $($ids.Count) work item(s)."

    # STEP 2 - Get work item details (batched)
    $items = Get-WorkItemsInBatches -ids $ids

    # STEP 3 - Group by release date picklist value
    $groups = @{}
    foreach ($item in $items) {
        $rd = $item.fields.$releaseDateField
        if (-not [string]::IsNullOrWhiteSpace($rd)) {
            if (-not $groups.ContainsKey($rd)) { $groups[$rd] = @() }
            $groups[$rd] += $item
        }
    }

    # STEP 4 - Process each release group
    foreach ($releasePicklist in $groups.Keys) {
        try {
            $releaseDate  = Convert-Date $releasePicklist
            $releaseTitle = "[$teamName] - $releaseDate"
            $childItems   = $groups[$releasePicklist]
            $childIds     = $childItems | ForEach-Object { $_.id }
            $description  = Build-Description -workItems $childItems -teamName $teamName -releaseDate $releaseDate

            Write-Host ""
            Write-Host "  Processing: $releaseTitle ($($childIds.Count) item(s))"

            # Find existing Release WI
            $escapedTitle = $releaseTitle -replace "'", "''"
            $findWiql = "SELECT [System.Id] FROM WorkItems WHERE " +
                        "[System.TeamProject] = '$escapedProject' " +
                        "AND [System.WorkItemType] = '$releaseWit' " +
                        "AND [System.Title] = '$escapedTitle'"

            $findResponse = Invoke-RestMethod `
                -Uri     "$baseUrl/_apis/wit/wiql?api-version=7.1" `
                -Method  POST `
                -Headers $headers `
                -Body    (@{ query = $findWiql } | ConvertTo-Json)

            # Create Release WI if it does not exist
            if ($findResponse.workItems.Count -eq 0) {

                Write-Host "    Creating new Release WI..."

                $createBody = @(
                    @{ op = "add"; path = "/fields/System.Title";           value = $releaseTitle   },
                    @{ op = "add"; path = "/fields/System.Description";     value = $description    },
                    @{ op = "add"; path = "/fields/$releaseDateField";      value = $releasePicklist },
                    @{ op = "add"; path = "/fields/Custom.ReleaseDate";     value = $releaseDate    },
                    @{ op = "add"; path = "/fields/System.AreaPath";        value = $teamAreaPath   },
                    @{ op = "add"; path = "/fields/System.AssignedTo";      value = $assignedTo     },
                    @{ op = "add"; path = "/fields/Custom.DeliveryTeam";  value = $teamName       }
                )

                $createUri = $baseUrl + '/_apis/wit/workitems/$' + $releaseWit + '?api-version=7.1'

                $release = Invoke-RestMethod `
                    -Method  PATCH `
                    -Uri     $createUri `
                    -Headers $patchHeaders `
                    -Body    (ConvertTo-Json -InputObject @($createBody) -Depth 10)

                $releaseId        = $release.id
                $existingChildIds = @()

                Write-Host "    Created Release ID: $releaseId"
            }
            else {
                $releaseId = $findResponse.workItems[0].id
                Write-Host "    Found existing Release ID: $releaseId"

                # Fetch full release detail (state + relations) before doing anything
                $releaseDetail       = Invoke-RestMethod `
                    -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?`$expand=relations&api-version=7.1" `
                    -Headers $headers
                $currentReleaseState = $releaseDetail.fields.'System.State'
                Write-Host "    Current state: $currentReleaseState"

                # Skip closed releases entirely — no updates, no new links
                if ($currentReleaseState -eq 'Done') {
                    Write-Host "    Release is Done. Skipping."
                    continue
                }

                # Update assignedTo and DeliveryTeam
                $assignBody = @(
                    @{ op = "add"; path = "/fields/System.AssignedTo";     value = $assignedTo },
                    @{ op = "add"; path = "/fields/Custom.DeliveryTeam"; value = $teamName   }
                )

                Invoke-RestMethod `
                    -Method  PATCH `
                    -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?api-version=7.1" `
                    -Headers $patchHeaders `
                    -Body    (ConvertTo-Json -InputObject @($assignBody) -Depth 10) | Out-Null

                Write-Host "    Updated assignee and delivery team."

                # Update description separately so a failure here does not block linking
                try {
                    $descBody = @(
                        @{ op = "add"; path = "/fields/System.Description"; value = $description }
                    )

                    Invoke-RestMethod `
                        -Method  PATCH `
                        -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?api-version=7.1" `
                        -Headers $patchHeaders `
                        -Body    (ConvertTo-Json -InputObject @($descBody) -Depth 10) | Out-Null

                    Write-Host "    Updated description."
                }
                catch {
                    Write-Warning "    Could not update description for Release $releaseId - skipping. Error: $_"
                }

                $existingChildIds = @(
                    $releaseDetail.relations |
                    Where-Object { $_.rel -eq "System.LinkTypes.Related" } |
                    ForEach-Object { [int]( $_.url -split '/' )[-1] }
                )

                # Remove stale links — items still linked but no longer assigned to this release date
                $toUnlink = @($existingChildIds | Where-Object { $childIds -notcontains $_ })

                if ($toUnlink.Count -gt 0) {
                    $removeIndices = @()
                    for ($i = 0; $i -lt $releaseDetail.relations.Count; $i++) {
                        $rel      = $releaseDetail.relations[$i]
                        $linkedId = [int]( $rel.url -split '/' )[-1]
                        if ($rel.rel -eq "System.LinkTypes.Related" -and $toUnlink -contains $linkedId) {
                            $removeIndices += $i
                        }
                    }

                    # Process in reverse index order so removals don't shift remaining indices
                    $removeOps = @($removeIndices | Sort-Object -Descending | ForEach-Object {
                        @{ op = "remove"; path = "/relations/$_" }
                    })

                    Invoke-RestMethod `
                        -Method  PATCH `
                        -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?api-version=7.1" `
                        -Headers $patchHeaders `
                        -Body    (ConvertTo-Json -InputObject @($removeOps) -Depth 10) | Out-Null

                    Write-Host "    Removed $($toUnlink.Count) stale link(s): $($toUnlink -join ', ')"
                }

                # Evaluate and update Release state
                $targetState = Get-TargetReleaseState -items $childItems
                if ($targetState -and $currentReleaseState -ne $targetState) {
                    $stateBody = @(@{ op = "add"; path = "/fields/System.State"; value = $targetState })
                    Invoke-RestMethod `
                        -Method  PATCH `
                        -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?api-version=7.1" `
                        -Headers $patchHeaders `
                        -Body    (ConvertTo-Json -InputObject @($stateBody) -Depth 10) | Out-Null
                    Write-Host "    Updated Release state: $currentReleaseState -> $targetState"
                }
            }

            # Link children not already attached
            $toLink = @( $childIds | Where-Object { $existingChildIds -notcontains $_ } )

            if ($toLink.Count -eq 0) {
                Write-Host "    All items already linked. Nothing to do."
                continue
            }

            $linkOps = @( $toLink | ForEach-Object {
                @{
                    op    = "add"
                    path  = "/relations/-"
                    value = @{
                        rel        = "System.LinkTypes.Related"
                        url        = "https://dev.azure.com/$organisation/_apis/wit/workitems/$_"
                        attributes = @{ comment = "" }
                    }
                }
            })

            Invoke-RestMethod `
                -Method  PATCH `
                -Uri     "$baseUrl/_apis/wit/workitems/$($releaseId)?api-version=7.1" `
                -Headers $patchHeaders `
                -Body    (ConvertTo-Json -InputObject @($linkOps) -Depth 10) | Out-Null

            Write-Host "    Linked $($toLink.Count) item(s): $($toLink -join ', ')"
        }
        catch {
            Write-Warning "Failed to process release '$releasePicklist' for team '$teamName': $_"
        }
    }
}
