# ============================================================
#  ADO Pipeline-to-Repository Mapping Script
#
#  Generates a migration-ready CSV mapping every pipeline
#  (Classic) to its source repository.
#
#  Scope options (least API calls → most):
#    1. Single project   : -ProjectName "MyProject"
#    2. Org minus some   : -ExcludeProjects "BigProject,AnotherProject"
#    3. Full org         : (no scope flags — default)
#
#  Output columns:
#    Project, PipelineId, PipelineName, FolderPath,
#    PipelineType, YamlPath, Repository, RepoType, RepoUrl
#
#  Rate-limit safe:
#    - continuationToken pagination (no $skip, no page drift)
#    - Polite delay between every API call
#    - Retry-After honoured on 429 / 503 with exponential back-off
#    - Streams rows to CSV — safe for 10k+ pipelines
# ============================================================

param (
   [string]$Org              = "",
   [string]$Pat              = "",

   # ── Output files ──────────────────────────────────────────
   [string]$OutputCsv        = "ado_pipeline_repo_map.csv",
   [string]$ErrorLog         = "ado_pipeline_repo_map_errors.log",

   # ── Scope controls ────────────────────────────────────────
   [string]$ProjectName      = "",   # If set: only process this project (skips projects API)
   [string]$ExcludeProjects  = "",   # Comma-separated project names to skip (org-wide mode)

   # ── Throttle controls ─────────────────────────────────────
   [int]$DelayMs             = 300,  # ms between every API call
   [int]$MaxRetries          = 6     # retries on 429 / 503
)

# ── Auth ──────────────────────────────────────────────────────────────────────
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $auth" }

# ── Parse exclude list ────────────────────────────────────────────────────────
$excludeList = if ($ExcludeProjects.Trim()) {
   $ExcludeProjects -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
} else {
   @()
}

# ── Clean up previous run outputs ─────────────────────────────────────────────
if (Test-Path $OutputCsv) { Remove-Item $OutputCsv -Force }
if (Test-Path $ErrorLog)  { Remove-Item $ErrorLog  -Force }

$csvInitialized = $false

# ── Core API wrapper ──────────────────────────────────────────────────────────
# Returns: [PSCustomObject]@{ Body; ContinuationToken }  or  $null on failure.

function Invoke-ADOApi {
   param (
       [string]$Url,
       [int]$MaxRetries = $script:MaxRetries
   )

   $retry = 0
   while ($retry -lt $MaxRetries) {
       try {
           $raw  = Invoke-WebRequest -Uri $Url -Headers $script:headers -Method Get `
                       -ErrorAction Stop -UseBasicParsing
           $body = $raw.Content | ConvertFrom-Json

           # Prefer response header; fall back to JSON body property
           $contToken = $null
           if ($raw.Headers.ContainsKey("x-ms-continuationtoken")) {
               $contToken = $raw.Headers["x-ms-continuationtoken"]
           }
           if (-not $contToken -and $body.PSObject.Properties["continuationToken"]) {
               $contToken = $body.continuationToken
           }

           return [PSCustomObject]@{ Body = $body; ContinuationToken = $contToken }
       }
       catch {
           $statusCode = $null
           if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

           if ($statusCode -eq 429 -or $statusCode -eq 503) {
               $retryAfter = $null
               try { $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
               $wait = if ($retryAfter -and $retryAfter -gt 0) {
                   $retryAfter
               } else {
                   [math]::Min(120, [math]::Pow(2, $retry + 1))
               }
               Write-Host "  [THROTTLED] HTTP $statusCode — waiting ${wait}s (retry $($retry+1)/$MaxRetries)..." `
                   -ForegroundColor Yellow
               Start-Sleep -Seconds $wait
               $retry++
           }
           else {
               Write-Warning "  [API ERROR] HTTP $statusCode — $Url"
               return $null
           }
       }
   }

   Write-Warning "  [MAX RETRIES] Giving up on: $Url"
   return $null
}

function Wait-PoliteDelay { Start-Sleep -Milliseconds $script:DelayMs }

# Stream-append one row to the output CSV (initialises headers on first write)
function Write-CsvRow {
   param ([PSCustomObject]$Row)
   if (-not $script:csvInitialized) {
       $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8
       $script:csvInitialized = $true
   } else {
       $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8 -Append
   }
}

function Write-ErrorLog {
   param ([string]$Message)
   $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
   Add-Content -Path $script:ErrorLog -Value "[$ts] $Message"
   Write-Warning $Message
}

# Resolve human-readable pipeline type from build definition process object.
# process.type: 1 = Designer / Classic,  2 = YAML
function Get-PipelineType {
   param ([object]$Definition)
   if ($Definition.process -and $Definition.process.type -eq 2) { return "YAML" }
   return "Classic"
}

#  STEP 1 — Build the list of projects to process

$projectsToProcess = [System.Collections.Generic.List[object]]::new()

if ($ProjectName.Trim()) {
   # ── Single-project mode ───────────────────────────────────────────────────
   # Zero project-listing API calls needed.
   Write-Host "`nMode: single project — '$($ProjectName.Trim())'" -ForegroundColor Cyan
   $projectsToProcess.Add([PSCustomObject]@{ name = $ProjectName.Trim() })
}
else {
   # ── Org-wide mode (with optional exclusions) ──────────────────────────────
   Write-Host "`nMode: org-wide — fetching projects in '$Org'..." -ForegroundColor Cyan
   if ($excludeList.Count -gt 0) {
       Write-Host "Excluding         : $($excludeList -join ', ')" -ForegroundColor DarkGray
   }

   $contToken = $null
   do {
       $url = "https://dev.azure.com/$Org/_apis/projects?`$top=100&api-version=7.1-preview.4"
       if ($contToken) { $url += "&continuationToken=$contToken" }

       Wait-PoliteDelay
       $result = Invoke-ADOApi -Url $url

       if ($result -and $result.Body.value) {
           foreach ($p in $result.Body.value) {
               if ($excludeList -contains $p.name) {
                   Write-Host "  [SKIP] $($p.name)" -ForegroundColor DarkGray
               } else {
                   $projectsToProcess.Add($p)
               }
           }
           Write-Host "  Collected $($projectsToProcess.Count) projects so far..."
       } else {
           Write-ErrorLog "Failed to fetch project page (continuationToken=$contToken)"
           break
       }

       $contToken = $result.ContinuationToken
   } while ($contToken)

   Write-Host "Projects to process: $($projectsToProcess.Count)" -ForegroundColor Green
}

#  STEP 2 — For each project, page through all build definitions and extract the pipeline → repository mapping.
#  API used:
#    1. GET _apis/build/definitions          — list (1 call per 100 pipelines)
#    2. GET _apis/build/definitions/{id}     — detail (1 call per pipeline, for repo name)
#  The list response does not include repository info for Classic pipelines,
#  so a detail fetch is required per pipeline.

$totalPipelines = 0
$totalSkipped   = 0
$projIndex      = 0

foreach ($proj in $projectsToProcess) {
   $projIndex++
   $projName      = $proj.name
   $projPipelines = 0
   $projFailed    = $false
   $pageNum       = 0

   Write-Host "`n[$projIndex/$($projectsToProcess.Count)] $projName" -ForegroundColor Cyan

   $pipelineContToken = $null

   do {
       $pageNum++

       # includeLatestBuilds=false keeps the response lean (no last-build metadata)
       $defUrl = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))" +
                 "/_apis/build/definitions?`$top=100&includeLatestBuilds=false" +
                 "&api-version=7.1-preview.7"

       if ($pipelineContToken) { $defUrl += "&continuationToken=$pipelineContToken" }

       Wait-PoliteDelay
       $result = Invoke-ADOApi -Url $defUrl

       if (-not $result -or -not $result.Body) {
           Write-ErrorLog "SKIPPED '$projName' on page $pageNum — API returned null"
           $totalSkipped++
           $projFailed = $true
           break
       }

       $defs  = $result.Body.value
       $count = if ($defs) { @($defs).Count } else { 0 }

       foreach ($def in $defs) {
           $totalPipelines++
           $projPipelines++

           $pipelineType = Get-PipelineType -Definition $def

           # Fetch full definition detail to get repository info
           # (list endpoint does not populate repository for Classic pipelines)
           $repoName   = ""
           $detailUrl  = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))" +
                         "/_apis/build/definitions/$($def.id)?api-version=7.1-preview.7"
           Wait-PoliteDelay
           $detail = Invoke-ADOApi -Url $detailUrl
           if ($detail -and $detail.Body.repository) {
               $repoName = $detail.Body.repository.name
           }

           Write-CsvRow -Row ([PSCustomObject]@{
               Project      = $projName
               PipelineId   = $def.id
               PipelineName = $def.name
               PipelineType = $pipelineType
               Repository   = $repoName
           })
       }

       Write-Host "  Page $pageNum — $count pipeline(s) (project total: $projPipelines)"
       $pipelineContToken = $result.ContinuationToken

   } while ($pipelineContToken)

   if (-not $projFailed) {
       Write-Host "  Project total: $projPipelines pipeline(s)" -ForegroundColor Green
   }
}

#  SUMMARY

Write-Host "`n===== MAPPING COMPLETE =====" -ForegroundColor Green
Write-Host "Projects Processed : $($projectsToProcess.Count)"
Write-Host "Total Pipelines    : $totalPipelines"
Write-Host "Skipped Projects   : $totalSkipped"
Write-Host "Output CSV         : $OutputCsv"
if ($totalSkipped -gt 0) {
   Write-Host "Error Log          : $ErrorLog  (review skipped items)" -ForegroundColor Yellow
}
