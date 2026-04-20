param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "repos.csv"
)

$ADO_PAT = $env:ADO_PAT
if (-not $ADO_PAT) {
    Write-Host "[ERROR] ADO_PAT environment variable is not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:ADO_PAT = 'your-pat-token-here'" -ForegroundColor Yellow
    exit 1
}

# Declare arrays for validation results and flags for REST API failures
$activePRSummary = @()
$runningBuildSummary = @()
$runningReleaseSummary = @()
$buildCheckFailed = $false
$releaseCheckFailed = $false
$prCheckFailed = $false

# Read CSV file
if (-not (Test-Path $CsvPath)) {
    Write-Host "[ERROR] CSV file '$CsvPath' not found. Exiting..." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`nReading input from file: '$CsvPath'"
}

# Import CSV
try {
    $orgRepoList = Import-Csv -LiteralPath $CsvPath -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] CSV header validation failed." -ForegroundColor Red
    Write-Host "Expected columns: org, teamproject, repo" -ForegroundColor Yellow
    Write-Host "Reason: Header row is missing or invalid." -ForegroundColor Yellow
    exit 1
}

# Validate required columns
$requiredColumns = @('org', 'teamproject', 'repo')

if ($orgRepoList.Count -eq 0) {

    # Read header line
    $headerLine = Get-Content -LiteralPath $CsvPath -TotalCount 1 -ErrorAction SilentlyContinue

    # Verify headers are present
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        Write-Host "[ERROR] CSV header validation failed. File does not contain a valid header row." -ForegroundColor Red
        Write-Host "Expected columns: org, teamproject, repo" -ForegroundColor Yellow
        exit 1
    }

    $csvColumns = $headerLine.Split(',') | ForEach-Object { $_.Trim() }
    $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

    if ($missingColumns.Count -gt 0) {
        Write-Host "[ERROR] CSV header validation failed. Missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
        Write-Host "Expected columns: org, teamproject, repo" -ForegroundColor Yellow
        exit 1
    }

    # Verify atleast one row with data present
    Write-Host "[ERROR] CSV file contains valid headers but no repository entries." -ForegroundColor Red
    exit 1
}

$csvColumns = $orgRepoList[0].PSObject.Properties.Name
$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

if ($missingColumns.Count -gt 0) {
    Write-Host "[ERROR] CSV header validation failed. Missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host "Expected columns: org, teamproject, repo" -ForegroundColor Yellow
    exit 1
}

# Validate ADO PAT for all unique orgs in CSV
$uniqueOrgs = $orgRepoList | Select-Object -ExpandProperty org -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

foreach ($org in $uniqueOrgs) {
    try {
        $testUri = "https://dev.azure.com/$org/_apis/projects?api-version=7.1"
        $resp = Invoke-WebRequest -Uri $testUri -Headers @{ Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

        if ($resp.StatusCode -ne 200) {
            Write-Host "[ERROR] ADO PAT validation failed for org: $org (StatusCode: $($resp.StatusCode))" -ForegroundColor Red
            exit 1
        }
    }
    catch {
        $statusCode = $null
        $reason = $null

        # Extract HTTP status from the exception
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode.value__
                $reason = $_.Exception.Response.StatusDescription
            }
        }
        catch { }

        # Parse error message, example: "404 (Not Found)"
        if (-not $statusCode -and $_.Exception.Message -match '(\d{3})\s*\(([^)]+)\)') {
            $statusCode = [int]$Matches[1]
            $reason = $Matches[2]
        }

        if ($statusCode) {
            Write-Host "[ERROR] ADO PAT validation failed for org '$org' (HTTP $statusCode $reason)" -ForegroundColor Red
            Write-Host "Verify org name in repos.csv and PAT permissions." -ForegroundColor Yellow
            exit 1
        }
        else {
            Write-Host "[ERROR] ADO PAT validation failed for org: $org" -ForegroundColor Red
            Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
        Write-Host "Verify org name is correct in repos.csv and PAT has access to this org." -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "`nScanning repositories for active pull requests..."
# Get active pull requests
foreach ($entry in $orgRepoList) {
    $ADO_ORG = $entry.org
    $ADO_PROJECT = $entry.teamproject
    $selectedRepoName = $entry.repo
    try {
        # Get repository ID
        $repoUri = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/git/repositories/${selectedRepoName}?api-version=7.1"
        $repo = Invoke-RestMethod -Method GET -Uri $repoUri -Headers @{Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

        $repoId = $repo.id
        $repoName = $repo.name

        # Get active pull requests using repository ID
        $prUri = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/git/repositories/${repoId}/pullrequests?searchCriteria.status=active&api-version=7.1"
        $prs = Invoke-RestMethod -Method GET -Uri $prUri -Headers @{Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

        $orgEnc = [System.Uri]::EscapeDataString($ADO_ORG)
        $projEnc = [System.Uri]::EscapeDataString($ADO_PROJECT)
        $repoEnc = [System.Uri]::EscapeDataString($repoName)

        foreach ($pr in $prs.value) {
            $activePRSummary += @{
                Project    = $ADO_PROJECT
                Repository = $repoName
                Title      = $pr.title
                Status     = $pr.status
                Url        = "https://dev.azure.com/$orgEnc/$projEnc/_git/$repoEnc/pullrequest/$($pr.pullRequestId)"
            }
        }
    }
    catch {
        $prCheckFailed = $true
        Write-Host "[ERROR] Failed to process PRs for repository '$selectedRepoName' in project '$ADO_PROJECT'." -ForegroundColor Red
    }
}

$uniqueProjects = $orgRepoList | Select-Object org, teamproject -Unique
Write-Host "`nScanning projects for active running build and release pipelines..."
foreach ($project in $uniqueProjects) {
    $ADO_ORG = $project.org
    $ADO_PROJECT = $project.teamproject

    $orgEnc = [System.Uri]::EscapeDataString($ADO_ORG)
    $projEnc = [System.Uri]::EscapeDataString($ADO_PROJECT)

    # Check active build pipelines
    try {
        $buildsUri = "https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/build/builds?api-version=7.1"
        $allBuilds = Invoke-RestMethod -Method GET -Uri $buildsUri -Headers @{Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

        $notCompletedBuilds = $allBuilds.value | Where-Object { $_.status -eq "inProgress" -or $_.status -eq "notStarted" }
        # Note: This step filters build pipelines that are currently running or in a queued state.
        # Reference: List of available build status values – https://learn.microsoft.com/en-us/rest/api/azure/devops/build/builds/list?view=azure-devops-rest-7.1#buildstatus

        foreach ($build in $notCompletedBuilds) {
            $runningBuildSummary += @{
                Project  = $ADO_PROJECT
                Pipeline = $build.definition.name
                Status   = "In Progress/ Queued"
                RunUrl   = $build._links.web.href
            }
        }
    }
    catch {
        $buildCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve builds for project '$ADO_PROJECT'." -ForegroundColor Red
    }

    # Check active release pipelines
    try {
        $releasesUri = "https://vsrm.dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/release/releases?api-version=7.1"
        $releaseIds = Invoke-RestMethod -Method GET -Uri $releasesUri -Headers @{Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

        foreach ($releaseId in $releaseIds.value.id) {
            try {
                $releaseDetailsUri = "https://vsrm.dev.azure.com/$ADO_ORG/$ADO_PROJECT/_apis/release/releases/${releaseId}?api-version=7.1"
                $releaseDetails = Invoke-RestMethod -Method GET -Uri $releaseDetailsUri -Headers @{Authorization = "Bearer $ADO_PAT"; "Content-Type" = "application/json" } -ErrorAction Stop

                # Check if any environments in the release are still running
                # A release is considered "running" if any of its environments are in progress
                $runningEnvironments = $releaseDetails.environments | Where-Object {
                    $_.status -eq "inProgress"
                }
                # Note: This checks individual environment statuses within the release
                # Reference: Environment status values – https://learn.microsoft.com/en-us/rest/api/azure/devops/release/releases/get-release?view=azure-devops-rest-7.1&tabs=HTTP#environmentstatus

                if ($runningEnvironments -and @($runningEnvironments).Count -gt 0) {
                    $environmentStatuses = ($runningEnvironments | ForEach-Object { "$($_.name): $($_.status)" }) -join ", "
                    $runningReleaseSummary += @{
                        Project = $ADO_PROJECT
                        Name    = $releaseDetails.name
                        Status  = "In Progress ($environmentStatuses)"
                        Url     = $releaseDetails._links.web.href
                    }
                }
            }
            catch {
                $releaseCheckFailed = $true
                Write-Host "[ERROR] Failed to retrieve release ID $releaseId." -ForegroundColor Red
            }
        }
    }
    catch {
        $releaseCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve release list for project '$ADO_PROJECT'." -ForegroundColor Red
    }
}

# Final Summary
Write-Host "`nPre-Migration Validation Summary"
Write-Host "================================"

if (-not $prCheckFailed) {
    if ($activePRSummary.Count -gt 0) {
        Write-Host "[WARNING] Detected Active Pull Request(s):" -ForegroundColor Yellow
        foreach ($entry in $activePRSummary) {
            Write-Host "Project: $($entry.Project) | Repository: $($entry.Repository) | Title: $($entry.Title) | Status: $($entry.Status)"
            Write-Host "PR URL: $($entry.Url)`n"
        }
    }
    else {
        Write-Host "`nPull Request Summary --> No Active Pull Requests" -ForegroundColor Green
    }
}

if (-not $buildCheckFailed) {
    if ($runningBuildSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Running Build Pipeline(s):" -ForegroundColor Yellow
        foreach ($entry in $runningBuildSummary) {
            Write-Host "Project: $($entry.Project) | Pipeline: $($entry.Pipeline) | Status: $($entry.Status)"
            Write-Host "Run URL: $($entry.RunUrl)`n"
        }
    }
    else {
        Write-Host "`nBuild Pipeline Summary --> No Active Running Builds" -ForegroundColor Green
    }
}
if (-not $releaseCheckFailed) {
    if ($runningReleaseSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Running Release Pipeline(s):" -ForegroundColor Yellow
        foreach ($entry in $runningReleaseSummary) {
            Write-Host "Project: $($entry.Project) | Release Name: $($entry.Name) | Status: $($entry.Status)"
            Write-Host "Run URL: $($entry.Url)`n"
        }
    }
    else {
        Write-Host "`nRelease Pipeline Summary --> No Active Running Releases" -ForegroundColor Green
    }
}

$hasActiveItems = ($activePRSummary.Count -gt 0) -or ($runningBuildSummary.Count -gt 0) -or ($runningReleaseSummary.Count -gt 0)
$hasFailures = $prCheckFailed -or $buildCheckFailed -or $releaseCheckFailed

if ($hasFailures -and -not $hasActiveItems) {
    $finalMessage = "Validation checks could not be completed due to API failures. Please review errors before proceeding."
    $finalColor = "Red"
}
elseif ($hasFailures -and $hasActiveItems) {
    $finalMessage = "Active items detected, but some validation checks failed. Review warnings and errors before proceeding."
    $finalColor = "Yellow"
}
elseif (-not $hasFailures -and $hasActiveItems) {
    $finalMessage = "Active Pull request or pipelines found. Continue with migration if you have reviewed and are comfortable proceeding."
    $finalColor = "Yellow"
}
else {
    $finalMessage = "No active pull requests or pipelines detected. You can proceed with migration."
    $finalColor = "Green"
}
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor
