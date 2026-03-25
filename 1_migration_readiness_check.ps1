#Requires -Version 5.1

param(
    [Parameter(Mandatory=$false)]
    [string]$AdoPat
)

function Get-UrlEncoded {
    param([string]$Value)
    return [System.Uri]::EscapeDataString($Value)
}

# Get ADO PAT from parameter or environment variable
$ADO_PAT = if ($AdoPat) { $AdoPat } else { $env:ADO_PAT }

if ([string]::IsNullOrEmpty($ADO_PAT)) {
    Write-Host "[ERROR] ADO_PAT environment variable is not set." -ForegroundColor Red
    Write-Host 'Set it using: $env:ADO_PAT = "your-pat-token-here"' -ForegroundColor Yellow
    exit 1
}

# Declare arrays for validation results and flags for REST API failures
$activePrSummary = @()
$runningBuildSummary = @()
$runningReleaseSummary = @()
$buildCheckFailed = $false
$releaseCheckFailed = $false
$prCheckFailed = $false

# Hashtables to store repo IDs and names per project (key: "org|project")
$PROJECT_REPO_IDS = @{}
$PROJECT_REPO_NAMES = @{}

# Read CSV file
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$csvPath = Join-Path $scriptDir "repos.csv"

if (-not (Test-Path $csvPath)) {
    Write-Host "[ERROR] CSV file '$csvPath' not found. Exiting..." -ForegroundColor Red
    exit 1
}

Write-Host "`nReading input from file: '$csvPath'"

try {
    $csvData = Import-Csv -Path $csvPath
} catch {
    Write-Host "[ERROR] Failed to parse CSV file: $_" -ForegroundColor Red
    exit 1
}

# Validate CSV headers
$headers = $csvData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
$normalizedHeaders = $headers | ForEach-Object { $_.Trim().ToLower() }

$requiredCols = @("org", "teamproject", "repo")
$missingCols = @()

foreach ($req in $requiredCols) {
    if ($req -notin $normalizedHeaders) {
        $missingCols += $req
    }
}

if ($missingCols.Count -gt 0) {
    Write-Host "[ERROR] CSV header validation failed. Missing required column(s): $($missingCols -join ', ')" -ForegroundColor Red
    Write-Host "Expected columns: org, teamproject, repo" -ForegroundColor Yellow
    exit 1
}

if ($csvData.Count -eq 0) {
    Write-Host "[ERROR] CSV file contains valid headers but no repository entries." -ForegroundColor Red
    exit 1
}

# Find actual column names (case-insensitive mapping)
$colOrg = $headers | Where-Object { $_.Trim().ToLower() -eq "org" } | Select-Object -First 1
$colTeamProject = $headers | Where-Object { $_.Trim().ToLower() -eq "teamproject" } | Select-Object -First 1
$colRepo = $headers | Where-Object { $_.Trim().ToLower() -eq "repo" } | Select-Object -First 1

# Set up headers for API calls
$apiHeaders = @{
    "Authorization" = "Bearer $ADO_PAT"
    "Content-Type" = "application/json"
}

# Test ADO PAT token with each unique organization
$uniqueOrgs = $csvData | ForEach-Object { $_.$colOrg.Trim() } | Select-Object -Unique

foreach ($org in $uniqueOrgs) {
    if ([string]::IsNullOrEmpty($org)) { continue }
    
    $encOrg = Get-UrlEncoded $org
    $testUri = "https://dev.azure.com/$encOrg/_apis/projects?api-version=7.1"
    
    try {
        $null = Invoke-RestMethod -Uri $testUri -Headers $apiHeaders -Method Get -ErrorAction Stop
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        switch ($statusCode) {
            { $_ -in @(401, 403) } {
                Write-Host "[ERROR] ADO PAT validation failed for org '$org' (HTTP $statusCode)." -ForegroundColor Red
                Write-Host "Verify org name in repos.csv and PAT permissions." -ForegroundColor Yellow
            }
            404 {
                Write-Host "[ERROR] ADO org not found: '$org' (HTTP 404)." -ForegroundColor Red
                Write-Host "Verify org name in repos.csv and PAT permissions." -ForegroundColor Yellow
            }
            default {
                Write-Host "[ERROR] ADO PAT validation failed for org '$org' (HTTP $statusCode)." -ForegroundColor Red
                if ($_.Exception.Message) {
                    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
        exit 1
    }
}
# ---------------- end PAT validation ----------------

Write-Host "`nScanning repositories for active pull requests..."

# Get active pull requests
foreach ($row in $csvData) {
    $adoOrg = $row.$colOrg.Trim()
    $adoProject = $row.$colTeamProject.Trim()
    $selectedRepoName = $row.$colRepo.Trim()
    
    if ([string]::IsNullOrEmpty($adoOrg) -or [string]::IsNullOrEmpty($adoProject) -or [string]::IsNullOrEmpty($selectedRepoName)) {
        continue
    }
    
    $encAdoOrg = Get-UrlEncoded $adoOrg
    $encAdoProject = Get-UrlEncoded $adoProject
    $encSelectedRepoName = Get-UrlEncoded $selectedRepoName
    
    # Get repository ID
    $repoUri = "https://dev.azure.com/$encAdoOrg/$encAdoProject/_apis/git/repositories/$encSelectedRepoName`?api-version=7.1"
    
    try {
        $repoResponse = Invoke-RestMethod -Uri $repoUri -Headers $apiHeaders -Method Get -ErrorAction Stop
        $repoId = $repoResponse.id
        $repoName = $repoResponse.name
        
        if ($repoId) {
            # Get active pull requests using repository ID
            $prUri = "https://dev.azure.com/$encAdoOrg/$encAdoProject/_apis/git/repositories/$repoId/pullrequests?searchCriteria.status=active&api-version=7.1"
            
            try {
                $prResponse = Invoke-RestMethod -Uri $prUri -Headers $apiHeaders -Method Get -ErrorAction Stop
                
                if ($prResponse.count -gt 0) {
                    foreach ($pr in $prResponse.value) {
                        $prUrl = "https://dev.azure.com/$encAdoOrg/$encAdoProject/_git/$encSelectedRepoName/pullrequest/$($pr.pullRequestId)"
                        $activePrSummary += [PSCustomObject]@{
                            Project    = $adoProject
                            Repository = $repoName
                            Title      = $pr.title
                            Status     = $pr.status
                            PrUrl      = $prUrl
                        }
                    }
                }
            } catch {
                $prCheckFailed = $true
                Write-Host "[ERROR] Failed to process PRs for repository '$selectedRepoName' in project '$adoProject'." -ForegroundColor Red
            }
        } else {
            $prCheckFailed = $true
            Write-Host "[ERROR] Failed to process PRs for repository '$selectedRepoName' in project '$adoProject'." -ForegroundColor Red
        }
    } catch {
        $prCheckFailed = $true
        Write-Host "[ERROR] Failed to process PRs for repository '$selectedRepoName' in project '$adoProject'." -ForegroundColor Red
    }
}

# Get unique projects and collect repo IDs/names for pipeline filtering
$uniqueProjects = @{}

foreach ($row in $csvData) {
    $adoOrg = $row.$colOrg.Trim()
    $adoProject = $row.$colTeamProject.Trim()
    $repoName = $row.$colRepo.Trim()
    
    if ([string]::IsNullOrEmpty($adoOrg) -or [string]::IsNullOrEmpty($adoProject) -or [string]::IsNullOrEmpty($repoName)) {
        continue
    }
    
    $projectCombo = "$adoOrg|$adoProject"
    
    if (-not $uniqueProjects.ContainsKey($projectCombo)) {
        $uniqueProjects[$projectCombo] = $true
    }
    
    # Get repo ID and add to PROJECT_REPO_IDS
    $encAdoOrg = Get-UrlEncoded $adoOrg
    $encAdoProject = Get-UrlEncoded $adoProject
    $encRepoName = Get-UrlEncoded $repoName
    
    $repoUri = "https://dev.azure.com/$encAdoOrg/$encAdoProject/_apis/git/repositories/$encRepoName`?api-version=7.1"
    
    try {
        $repoResponse = Invoke-RestMethod -Uri $repoUri -Headers $apiHeaders -Method Get -ErrorAction Stop
        $repoId = $repoResponse.id
        
        if ($repoId) {
            # Append repo ID to the project's list
            if ($PROJECT_REPO_IDS.ContainsKey($projectCombo)) {
                $PROJECT_REPO_IDS[$projectCombo] += $repoId
            } else {
                $PROJECT_REPO_IDS[$projectCombo] = @($repoId)
            }
            
            # Append repo name to the project's list (lowercase for comparison)
            $repoNameLower = $repoName.ToLower()
            if ($PROJECT_REPO_NAMES.ContainsKey($projectCombo)) {
                $PROJECT_REPO_NAMES[$projectCombo] += $repoNameLower
            } else {
                $PROJECT_REPO_NAMES[$projectCombo] = @($repoNameLower)
            }
        }
    } catch {
        # Silently continue - repo might not exist or not accessible
    }
}

Write-Host "`nScanning projects for active running build and release pipelines..."

foreach ($project in $uniqueProjects.Keys) {
    $parts = $project -split '\|'
    $adoOrg = $parts[0]
    $adoProject = $parts[1]
    
    $encAdoOrg = Get-UrlEncoded $adoOrg
    $encAdoProject = Get-UrlEncoded $adoProject
    
    # Check active build pipelines
    $buildsUri = "https://dev.azure.com/$encAdoOrg/$encAdoProject/_apis/build/builds?api-version=7.1"
    
    try {
        $buildsResponse = Invoke-RestMethod -Uri $buildsUri -Headers $apiHeaders -Method Get -ErrorAction Stop
        $repoIds = $PROJECT_REPO_IDS[$project]
        
        if ($repoIds) {
            foreach ($build in $buildsResponse.value) {
                if ($build.status -in @("inProgress", "notStarted")) {
                    # Filter by repo ID
                    if ($build.repository.id -in $repoIds) {
                        $runningBuildSummary += [PSCustomObject]@{
                            Project   = $adoProject
                            Repository = $build.repository.name
                            Pipeline  = $build.definition.name
                            Status    = "In Progress/Queued"
                            RunUrl    = $build._links.web.href
                        }
                    }
                }
            }
        }
    } catch {
        $buildCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve builds for project '$adoProject'." -ForegroundColor Red
    }
    
    # Check active release pipelines
    $releasesUri = "https://vsrm.dev.azure.com/$encAdoOrg/$encAdoProject/_apis/release/releases?api-version=7.1"
    $repoNames = $PROJECT_REPO_NAMES[$project]
    
    try {
        $releasesResponse = Invoke-RestMethod -Uri $releasesUri -Headers $apiHeaders -Method Get -ErrorAction Stop
        
        foreach ($release in $releasesResponse.value) {
            $releaseId = $release.id
            
            if ($releaseId) {
                $releaseDetailsUri = "https://vsrm.dev.azure.com/$encAdoOrg/$encAdoProject/_apis/release/releases/$releaseId`?api-version=7.1"
                
                try {
                    $releaseDetails = Invoke-RestMethod -Uri $releaseDetailsUri -Headers $apiHeaders -Method Get -ErrorAction Stop
                    
                    # Check if any environments are in progress
                    $runningEnvs = $releaseDetails.environments | Where-Object { $_.status -eq "inProgress" }
                    
                    if ($runningEnvs) {
                        # Check if this release is linked to any of our repos via artifacts
                        $releaseMatchesRepo = $false
                        
                        if ($repoNames -and $releaseDetails.artifacts) {
                            foreach ($artifact in $releaseDetails.artifacts) {
                                $artifactRepo = $null
                                
                                # Try different paths to get the repo/definition name
                                if ($artifact.definitionReference.repository.name) {
                                    $artifactRepo = $artifact.definitionReference.repository.name.ToLower()
                                } elseif ($artifact.definitionReference.definition.name) {
                                    $artifactRepo = $artifact.definitionReference.definition.name.ToLower()
                                } elseif ($artifact.alias) {
                                    $artifactRepo = $artifact.alias.ToLower()
                                }
                                
                                if ($artifactRepo -and ($artifactRepo -in $repoNames)) {
                                    $releaseMatchesRepo = $true
                                    break
                                }
                            }
                        }
                        
                        # Only add to summary if release is linked to a repo in our CSV
                        if ($releaseMatchesRepo) {
                            $envStatuses = ($runningEnvs | ForEach-Object { "$($_.name): $($_.status)" }) -join ", "
                            $runningReleaseSummary += [PSCustomObject]@{
                                Project     = $adoProject
                                ReleaseName = $releaseDetails.name
                                Status      = "In Progress ($envStatuses)"
                                ReleaseUrl  = $releaseDetails._links.web.href
                            }
                        }
                    }
                } catch {
                    $releaseCheckFailed = $true
                    Write-Host "[ERROR] Failed to retrieve release ID $releaseId." -ForegroundColor Red
                }
            }
        }
    } catch {
        $releaseCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve release list for project '$adoProject'." -ForegroundColor Red
    }
}

# Final Summary
Write-Host "`nPre-Migration Validation Summary"
Write-Host "================================"

if (-not $prCheckFailed) {
    if ($activePrSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Active Pull Request(s):" -ForegroundColor Yellow
        foreach ($entry in $activePrSummary) {
            Write-Host "Project: $($entry.Project) | Repository: $($entry.Repository) | Title: $($entry.Title) | Status: $($entry.Status)"
            Write-Host "PR URL: $($entry.PrUrl)"
            Write-Host ""
        }
    } else {
        Write-Host "`nPull Request Summary --> No Active Pull Requests" -ForegroundColor Green
    }
}

if (-not $buildCheckFailed) {
    if ($runningBuildSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Running Build Pipeline(s):" -ForegroundColor Yellow
        foreach ($entry in $runningBuildSummary) {
            Write-Host "Project: $($entry.Project) | Repository: $($entry.Repository) | Pipeline: $($entry.Pipeline) | Status: $($entry.Status)"
            Write-Host "Run URL: $($entry.RunUrl)"
            Write-Host ""
        }
    } else {
        Write-Host "`nBuild Pipeline Summary --> No Active Running Builds" -ForegroundColor Green
    }
}

if (-not $releaseCheckFailed) {
    if ($runningReleaseSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Running Release Pipeline(s):" -ForegroundColor Yellow
        foreach ($entry in $runningReleaseSummary) {
            Write-Host "Project: $($entry.Project) | Release Name: $($entry.ReleaseName) | Status: $($entry.Status)"
            Write-Host "Release URL: $($entry.ReleaseUrl)"
            Write-Host ""
        }
    } else {
        Write-Host "`nRelease Pipeline Summary --> No Active Running Releases" -ForegroundColor Green
    }
}

# ---- Final roll-up (4 outcomes) ----
$hasActiveItems = ($activePrSummary.Count -gt 0) -or ($runningBuildSummary.Count -gt 0) -or ($runningReleaseSummary.Count -gt 0)
$hasFailures = $prCheckFailed -or $buildCheckFailed -or $releaseCheckFailed

if ($hasFailures -and -not $hasActiveItems) {
    # Failures only (no active PR/build/release)
    Write-Host "`nValidation checks could not be completed due to API failures. Please review errors before proceeding.`n" -ForegroundColor Red
} elseif ($hasFailures -and $hasActiveItems) {
    # Failures + active items
    Write-Host "`nActive items detected, but some validation checks failed. Review warnings and errors before proceeding.`n" -ForegroundColor Yellow
} elseif (-not $hasFailures -and $hasActiveItems) {
    # Active items only (no failures)
    Write-Host "`nActive Pull request or pipelines found. Continue with migration if you have reviewed and are comfortable proceeding.`n" -ForegroundColor Yellow
} else {
    # Clean: no failures, no active items
    Write-Host "`nNo active pull requests or pipelines detected. You can proceed with migration.`n" -ForegroundColor Green
}
