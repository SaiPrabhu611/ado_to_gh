#!/usr/bin/env bash

urlencode() {
  printf '%s' "$1" | jq -Rr @uri
}

parse_csv_line() {
    local line="${1//$'\r'/}"
    local -a fields=()
    local field=""
    local in_quotes=false
    local i

    for ((i=0; i<${#line}; i++)); do
        char="${line:$i:1}"
        if [[ "$char" == '"' ]]; then
            if [[ "$in_quotes" == true ]]; then
                # Check if next char is also quote (escaped quote)
                if [[ "${line:$((i+1)):1}" == '"' ]]; then
                    field+="$char"
                    ((i++))
                else
                    in_quotes=false
                fi
            else
                in_quotes=true
            fi
        elif [[ "$char" == ',' && "$in_quotes" == false ]]; then
            fields+=("$field")
            field=""
        else
            field+="$char"
        fi
    done
    fields+=("$field")

    # Return fields array
    printf '%s\n' "${fields[@]}"
}


ADO_PAT="${ADO_PAT:-$1}"
if [ -z "$ADO_PAT" ]; then
    echo -e "\033[31m[ERROR] ADO_PAT environment variable is not set.\033[0m"
    echo -e "\033[33mExport it using: export ADO_PAT=\"your-pat-token-here\"\033[0m"
    exit 1
fi

# Declare arrays for validation results and flags for REST API failures
active_pr_summary=()
running_build_summary=()
running_build_links=()
running_release_summary=()
build_check_failed=false
release_check_failed=false
pr_check_failed=false

# Associative array to store repo IDs per project (key: "org|project", value: space-separated repo IDs)
declare -A PROJECT_REPO_IDS
# Associative array to store repo names per project for release pipeline filtering
declare -A PROJECT_REPO_NAMES

# Read CSV file
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
csv_path="$script_dir/repos.csv"
if [ ! -f "$csv_path" ]; then
    echo -e "\033[31m[ERROR] CSV file '$csv_path' not found. Exiting...\033[0m"
    exit 1
else
    echo -e "\nReading input from file: '$csv_path'"
    header_line="$(head -n 1 "$csv_path" | tr -d '\r' | sed $'s/^\xef\xbb\xbf//')"
    if [[ -z "${header_line//[[:space:]]/}" ]]; then
        echo -e "\033[31m[ERROR] CSV header validation failed. File does not contain a valid header row.\033[0m"
        echo -e "\033[33mExpected columns: org, teamproject, repo\033[0m"
        exit 1
    fi

    # Parse header
    readarray -t header_fields < <(parse_csv_line "$header_line")

    # Normalize header fields
    norm_headers=()
    for h in "${header_fields[@]}"; do
        h="$(echo "$h" | sed 's/^"//;s/"$//' | xargs | tr '[:upper:]' '[:lower:]')"
        norm_headers+=("$h")
    done

    required_cols=("org" "teamproject" "repo")
    missing_cols=()
    for req in "${required_cols[@]}"; do
    found=false
    for h in "${norm_headers[@]}"; do
        [[ "$h" == "$req" ]] && found=true && break
    done
    [[ "$found" == false ]] && missing_cols+=("$req")
    done

    if [[ ${#missing_cols[@]} -gt 0 ]]; then
        echo -e "\033[31m[ERROR] CSV header validation failed. Missing required column(s): ${missing_cols[*]}\033[0m"
        echo -e "\033[33mExpected columns: org, teamproject, repo\033[0m"
        exit 1
    fi

    # Determine column indices from header
    col_org=-1
    col_teamproject=-1
    col_repo=-1
    for idx in "${!norm_headers[@]}"; do
        case "${norm_headers[$idx]}" in
            org)         col_org=$idx ;;
            teamproject) col_teamproject=$idx ;;
            repo)        col_repo=$idx ;;
        esac
    done

    # Ensure at least one data row exists
    if ! tail -n +2 "$csv_path" | grep -q '[^[:space:]]'; then
        echo -e "\033[31m[ERROR] CSV file contains valid headers but no repository entries.\033[0m"
        exit 1
    fi
fi

# Test ADO PAT token with the first organization
declare -A unique_orgs
line_num=0
while IFS= read -r line; do
  ((line_num++))
  [[ $line_num -eq 1 ]] && continue

  readarray -t fields < <(parse_csv_line "$line")
  [[ ${#fields[@]} -lt 1 ]] && continue

  ado_org="$(echo "${fields[$col_org]}" | sed 's/^"//;s/"$//' | xargs)"
  [[ -z "$ado_org" ]] && continue

  unique_orgs["$ado_org"]=1
done < "$csv_path"

for org in "${!unique_orgs[@]}"; do
  test_uri="https://dev.azure.com/$(urlencode "$org")/_apis/projects?api-version=7.1"
  statusCode=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" -X GET "$test_uri")

  if [[ "$statusCode" -lt 200 || "$statusCode" -ge 300 ]]; then
    case "$statusCode" in
      401|403)
        echo -e "\033[31m[ERROR] ADO PAT validation failed for org '$org' (HTTP $statusCode).\033[0m"
        echo -e "\033[33mVerify org name in repos.csv and PAT permissions.\033[0m"
        ;;
      404)
        echo -e "\033[31m[ERROR] ADO org not found: '$org' (HTTP 404).\033[0m"
        echo -e "\033[33mVerify org name in repos.csv and PAT permissions.\033[0m"
        ;;
      000)
        echo -e "\033[31m[ERROR] Network/DNS/TLS issue while calling Azure DevOps (HTTP 000).\033[0m"
        echo -e "\033[33mVerify connectivity from this machine.\033[0m"
        ;;
      *)
        echo -e "\033[31m[ERROR] ADO PAT validation failed for org '$org' (HTTP $statusCode).\033[0m"
        ;;
    esac
    exit 1
  fi
done
# ---------------- end PAT validation ----------------

echo -e "\nScanning repositories for active pull requests..."

# Function to parse CSV line properly (handles quoted fields)


# Get active pull requests
line_num=0
while IFS= read -r line; do
    ((line_num++))

    # Skip header line
    if [ $line_num -eq 1 ]; then
        continue
    fi

    # Parse the CSV line
    readarray -t fields < <(parse_csv_line "$line")

    if [ ${#fields[@]} -ge 3 ]; then
        # Clean up quotes if present
        ado_org=$(echo "${fields[$col_org]}" | sed 's/^"//;s/"$//')
        ado_project=$(echo "${fields[$col_teamproject]}" | sed 's/^"//;s/"$//')
        selected_repo_name=$(echo "${fields[$col_repo]}" | sed 's/^"//;s/"$//')

        enc_ado_org="$(urlencode "$ado_org")"
        enc_ado_project="$(urlencode "$ado_project")"
        enc_selected_repo_name="$(urlencode "$selected_repo_name")"

        # Get repository ID
        repo_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/git/repositories/${enc_selected_repo_name}?api-version=7.1"
        repo_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$repo_uri" 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$repo_response" ]; then
            repo_id=$(echo "$repo_response" | jq -r '.id // empty' 2>/dev/null)
            repo_name=$(echo "$repo_response" | jq -r '.name // empty' 2>/dev/null)

            if [ -n "$repo_id" ] && [ "$repo_id" != "null" ]; then
                # Get active pull requests using repository ID
                pr_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/git/repositories/${repo_id}/pullrequests?searchCriteria.status=active&api-version=7.1"
                pr_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$pr_uri" 2>/dev/null)

                if [ $? -eq 0 ] && [ -n "$pr_response" ]; then
                    # Parse PR response and add to summary
                    pr_count=$(echo "$pr_response" | jq -r '.count // 0' 2>/dev/null)
                    if [ "$pr_count" -gt 0 ]; then
                        # Use process substitution to avoid subshell issue
                        while IFS='|' read -r title status prId; do
                            if [ -n "$title" ] && [ "$title" != "null" ]; then
                                prUrl="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_git/$enc_selected_repo_name/pullrequest/$prId"
                                active_pr_summary+=("$ado_project|$repo_name|$title|$status|$prUrl")
                            fi
                        done < <(echo "$pr_response" | jq -r '.value[]? | "\(.title)|\(.status)|\(.pullRequestId)"' 2>/dev/null)
                    fi
                else
                    pr_check_failed=true
                    echo -e "\033[31m[ERROR] Failed to process PRs for repository '$selected_repo_name' in project '$ado_project'.\033[0m"
                fi
            else
                pr_check_failed=true
                echo -e "\033[31m[ERROR] Failed to process PRs for repository '$selected_repo_name' in project '$ado_project'.\033[0m"
            fi
        else
            pr_check_failed=true
            echo -e "\033[31m[ERROR] Failed to process PRs for repository '$selected_repo_name' in project '$ado_project'.\033[0m"
        fi
    fi
done < "$csv_path"

# Get unique projects and collect repo IDs/names for pipeline filtering
unique_projects=()
line_num=0
while IFS= read -r line; do
    ((line_num++))

    # Skip header line
    if [ $line_num -eq 1 ]; then
        continue
    fi

    # Parse the CSV line
    readarray -t fields < <(parse_csv_line "$line")

    if [ ${#fields[@]} -ge 3 ]; then
        ado_org=$(echo "${fields[$col_org]}" | sed 's/^"//;s/"$//')
        ado_project=$(echo "${fields[$col_teamproject]}" | sed 's/^"//;s/"$//')
        repo_name=$(echo "${fields[$col_repo]}" | sed 's/^"//;s/"$//')
        project_combo="$ado_org|$ado_project"

        # Check if already exists
        if [[ ! " ${unique_projects[*]} " =~ " ${project_combo} " ]]; then
            unique_projects+=("$project_combo")
        fi

        # Get repo ID and add to PROJECT_REPO_IDS
        enc_ado_org="$(urlencode "$ado_org")"
        enc_ado_project="$(urlencode "$ado_project")"
        enc_repo_name="$(urlencode "$repo_name")"
        
        repo_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/git/repositories/${enc_repo_name}?api-version=7.1"
        repo_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$repo_uri" 2>/dev/null)
        
        if [ $? -eq 0 ] && [ -n "$repo_response" ]; then
            repo_id=$(echo "$repo_response" | jq -r '.id // empty' 2>/dev/null)
            if [ -n "$repo_id" ] && [ "$repo_id" != "null" ]; then
                # Append repo ID to the project's list (space-separated)
                if [ -n "${PROJECT_REPO_IDS[$project_combo]}" ]; then
                    PROJECT_REPO_IDS[$project_combo]="${PROJECT_REPO_IDS[$project_combo]} $repo_id"
                else
                    PROJECT_REPO_IDS[$project_combo]="$repo_id"
                fi
                # Append repo name to the project's list (space-separated, lowercase for comparison)
                repo_name_lower=$(echo "$repo_name" | tr '[:upper:]' '[:lower:]')
                if [ -n "${PROJECT_REPO_NAMES[$project_combo]}" ]; then
                    PROJECT_REPO_NAMES[$project_combo]="${PROJECT_REPO_NAMES[$project_combo]} $repo_name_lower"
                else
                    PROJECT_REPO_NAMES[$project_combo]="$repo_name_lower"
                fi
            fi
        fi
    fi
done < "$csv_path"

echo -e "\nScanning projects for active running build and release pipelines..."

for project in "${unique_projects[@]}"; do
    IFS='|' read -r ado_org ado_project <<< "$project"

    enc_ado_org="$(urlencode "$ado_org")"
    enc_ado_project="$(urlencode "$ado_project")"

    # Check active build pipelines
    builds_uri="https://dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/build/builds?api-version=7.1"
    builds_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$builds_uri" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$builds_response" ]; then
        repo_ids="${PROJECT_REPO_IDS["$ado_org|$ado_project"]}"

        # Parse builds and filter for running/queued ones that belong to repos in CSV
        while IFS='|' read -r repo_name pipeline_name status runUrl; do
            if [[ -n "$pipeline_name" && "$pipeline_name" != "null" ]]; then
                running_build_summary+=("$ado_project|$repo_name|$pipeline_name|$status")
                running_build_links+=("$runUrl")
            fi
        done < <(echo "$builds_response" | jq -r --arg repos "$repo_ids" '
            .value[]? | 
            select(.status == "inProgress" or .status == "notStarted") | 
            select(.repository.id as $rid | ($repos | split(" ") | map(select(. != "")) | index($rid)) != null) | 
            "\(.repository.name)|\(.definition.name)|In Progress/Queued|\(._links.web.href)"
        ' 2>/dev/null)

    else
        build_check_failed=true
        echo -e "\033[31m[ERROR] Failed to retrieve builds for project '$ado_project'.\033[0m"
    fi

    # Check active release pipelines
    releases_uri="https://vsrm.dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/release/releases?api-version=7.1"
    releases_response=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$releases_uri" 2>/dev/null)
    
    # Get repo names for this project (for release artifact filtering)
    repo_names="${PROJECT_REPO_NAMES["$ado_org|$ado_project"]}"

    if [ $? -eq 0 ] && [ -n "$releases_response" ]; then
        # Get release IDs
        while read -r release_id; do
            if [ -n "$release_id" ] && [ "$release_id" != "null" ]; then
                release_details_uri="https://vsrm.dev.azure.com/$enc_ado_org/$enc_ado_project/_apis/release/releases/${release_id}?api-version=7.1"
                release_details=$(curl -s -H "Authorization: Bearer $ADO_PAT" -H "Content-Type: application/json" "$release_details_uri" 2>/dev/null)

                if [ $? -eq 0 ] && [ -n "$release_details" ]; then
                    # Check if any environments are in progress
                    running_envs=$(echo "$release_details" | jq -r '.environments[]? | select(.status == "inProgress") | "\(.name): \(.status)"' 2>/dev/null)
                    if [ -n "$running_envs" ]; then
                        # Check if this release is linked to any of our repos via artifacts
                        # Release artifacts can have definitionReference.repository.name or be linked to build artifacts
                        artifact_repos=$(echo "$release_details" | jq -r '
                            .artifacts[]? | 
                            (
                                .definitionReference.repository.name // 
                                .definitionReference.definition.name // 
                                .alias // 
                                ""
                            ) | ascii_downcase
                        ' 2>/dev/null | tr '\n' ' ')
                        
                        # Check if any artifact repo matches our CSV repos
                        release_matches_repo=false
                        for artifact_repo in $artifact_repos; do
                            for csv_repo in $repo_names; do
                                if [[ "$artifact_repo" == "$csv_repo" ]]; then
                                    release_matches_repo=true
                                    break 2
                                fi
                            done
                        done
                        
                        # Only add to summary if release is linked to a repo in our CSV
                        if [ "$release_matches_repo" = true ]; then
                            release_name=$(echo "$release_details" | jq -r '.name // ""' 2>/dev/null)
                            env_statuses=$(echo "$running_envs" | tr '\n' ',' | sed 's/,$//')
                            releaseUrl=$(echo "$release_details" | jq -r '._links.web.href // ""' 2>/dev/null)
                            running_release_summary+=("$ado_project|$release_name|In Progress ($env_statuses)|$releaseUrl")
                        fi
                    fi
                else
                    release_check_failed=true
                    echo -e "\033[31m[ERROR] Failed to retrieve release ID $release_id.\033[0m"
                fi
            fi
        done < <(echo "$releases_response" | jq -r '.value[]?.id' 2>/dev/null)
    else
        release_check_failed=true
        echo -e "\033[31m[ERROR] Failed to retrieve release list for project '$ado_project'.\033[0m"
    fi
done

# Final Summary
echo -e "\nPre-Migration Validation Summary"
echo "================================"

if [ "$pr_check_failed" != true ]; then
    if [ ${#active_pr_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Active Pull Request(s):\033[0m"
        for entry in "${active_pr_summary[@]}"; do
            IFS='|' read -r project repository title status prUrl <<< "$entry"
            echo "Project: $project | Repository: $repository | Title: $title | Status: $status"
            echo "PR URL: $prUrl"
            echo ""
        done
    else
        echo -e "\n\033[32mPull Request Summary --> No Active Pull Requests\033[0m"
    fi
fi

if [ "$build_check_failed" != true ]; then
    if [ ${#running_build_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Running Build Pipeline(s):\033[0m"

    for idx in "${!running_build_summary[@]}"; do
        IFS='|' read -r project repo pipeline status <<< "${running_build_summary[$idx]}"
        IFS='|' read -r runUrl <<< "${running_build_links[$idx]}"

        echo "Project: $project | Repository: $repo | Pipeline: $pipeline | Status: $status"
        echo "Run URL: $runUrl"
        echo ""
    done
    else
        echo -e "\n\033[32mBuild Pipeline Summary --> No Active Running Builds\033[0m"
    fi
fi

if [ "$release_check_failed" != true ]; then
    if [ ${#running_release_summary[@]} -gt 0 ]; then
        echo -e "\n\033[33m[WARNING] Detected Running Release Pipeline(s):\033[0m"
        for entry in "${running_release_summary[@]}"; do
        IFS='|' read -r project name status releaseUrl <<< "$entry"
        echo "Project: $project | Release Name: $name | Status: $status"
        echo "Release URL: $releaseUrl"
        echo ""
        done
    else
        echo -e "\n\033[32mRelease Pipeline Summary --> No Active Running Releases\033[0m"
    fi
fi


# ---- PowerShell-style final roll-up (4 outcomes) ----
hasActiveItems=false
if [ ${#active_pr_summary[@]} -gt 0 ] || [ ${#running_build_summary[@]} -gt 0 ] || [ ${#running_release_summary[@]} -gt 0 ]; then
    hasActiveItems=true
fi

hasFailures=false
if [ "$pr_check_failed" = true ] || [ "$build_check_failed" = true ] || [ "$release_check_failed" = true ]; then
    hasFailures=true
fi

if [ "$hasFailures" = true ] && [ "$hasActiveItems" = false ]; then
    # Failures only (no active PR/build/release)
    echo -e "\n\033[31mValidation checks could not be completed due to API failures. Please review errors before proceeding.\033[0m\n"
elif [ "$hasFailures" = true ] && [ "$hasActiveItems" = true ]; then
    # Failures + active items
    echo -e "\n\033[33mActive items detected, but some validation checks failed. Review warnings and errors before proceeding.\033[0m\n"
elif [ "$hasFailures" = false ] && [ "$hasActiveItems" = true ]; then
    # Active items only (no failures)
    echo -e "\n\033[33mActive Pull request or pipelines found. Continue with migration if you have reviewed and are comfortable proceeding.\033[0m\n"
else
    # Clean: no failures, no active items
    echo -e "\n\033[32mNo active pull requests or pipelines detected. You can proceed with migration.\033[0m\n"
fi
