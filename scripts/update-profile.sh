#!/usr/bin/env bash
# update-profile.sh
# Fetches repository information for the Armchair-Software GitHub organisation
# and updates the projects table in profile/README.md.
#
# Required environment variables:
#   GITHUB_TOKEN  – a token with read:org and repo access (a PAT is required
#                   to include private repositories and search their issues)
#
# Optional environment variables:
#   ORG           – GitHub organisation name (default: Armchair-Software)
#   README        – path to the README to update (default: profile/README.md)

set -euo pipefail

ORG="${ORG:-Armchair-Software}"
README="${README:-profile/README.md}"
API="https://api.github.com"
PER_PAGE=100

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

gh_api() {
  local path="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/${path}"
}

# Fetch all non-archived, non-fork repositories for the org (public and private)
fetch_repos() {
  local page=1
  while :; do
    local chunk
    chunk=$(gh_api "orgs/${ORG}/repos?type=all&sort=full_name&per_page=${PER_PAGE}&page=${page}")
    echo "${chunk}" | jq -c '.[]'
    local count
    count=$(echo "${chunk}" | jq 'length')
    if [ "${count}" -lt "${PER_PAGE}" ]; then
      break
    fi
    page=$((page + 1))
  done
}

# Return base64-encoded JSON objects for each *real* workflow file in a repo.
# Synthetic GitHub-managed workflows (Copilot, Dependabot, etc.) are excluded
# because they have no corresponding file path in .github/workflows/ and their
# badge/action URLs do not resolve correctly.
# The regex matches only top-level .yml/.yaml files directly inside .github/workflows/
# and deliberately excludes subdirectories (which would contain a second slash).
get_workflows() {
  local repo="$1"
  gh_api "repos/${ORG}/${repo}/actions/workflows?per_page=${PER_PAGE}" 2>/dev/null \
    | jq -r '.workflows[] | select(.path | test("^\\.github/workflows/[^/]+\\.ya?ml$")) | @base64' 2>/dev/null || true
}

# Return the html_url of the GitHub Pages site for a repo, or empty string
get_pages_url() {
  local repo="$1"
  local body_file http_code
  body_file=$(mktemp)
  chmod 600 "${body_file}"
  http_code=$(curl -sSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "${body_file}" \
    -w "%{http_code}" \
    "${API}/repos/${ORG}/${repo}/pages" 2>/dev/null) || true
  if [ "${http_code}" = "200" ]; then
    jq -r '.html_url // ""' < "${body_file}" 2>/dev/null || true
  fi
  rm -f "${body_file}"
}

# Return the total count of issues or PRs matching the given search query.
# Uses the GitHub search API which supports filtering by type:issue / type:pr.
# Usage: search_count REPO TYPE STATE
#   TYPE:  issue | pr
#   STATE: open | closed | "" (all states)
search_count() {
  local repo="$1"
  local type="$2"
  local state="$3"
  local q="repo:${ORG}/${repo} type:${type}"
  [ -n "${state}" ] && q+=" state:${state}"
  local encoded_q
  encoded_q=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "${q}")
  local result
  result=$(gh_api "search/issues?q=${encoded_q}&per_page=1" 2>/dev/null) || true
  echo "${result}" | jq '.total_count // 0' 2>/dev/null || echo "0"
}

# ---------------------------------------------------------------------------
# Build the projects table
# ---------------------------------------------------------------------------

build_table() {
  local table=""
  table+="| Project | Description | Build Status | Issues | PRs | Stars | Forks | Pages |\n"
  table+="| ------- | ----------- | :----------: | :----: | :-: | :---: | :---: | :---: |\n"

  local repos_json
  mapfile -t repos_json < <(fetch_repos)

  for repo_json in "${repos_json[@]}"; do
    local name fork archived private description has_pages stars forks
    name=$(echo "${repo_json}" | jq -r '.name')
    fork=$(echo "${repo_json}" | jq -r '.fork')
    archived=$(echo "${repo_json}" | jq -r '.archived')
    private=$(echo "${repo_json}" | jq -r '.private')
    description=$(echo "${repo_json}" | jq -r '.description // ""')
    has_pages=$(echo "${repo_json}" | jq -r '.has_pages')
    stars=$(echo "${repo_json}" | jq -r '.stargazers_count // 0')
    forks=$(echo "${repo_json}" | jq -r '.forks_count // 0')

    # Skip the .github repo itself and any forks / archived repos
    if [ "${name}" = ".github" ] || [ "${fork}" = "true" ] || [ "${archived}" = "true" ]; then
      continue
    fi

    # ---- Description (sanitized for Markdown table) -------------------------
    local desc_col
    if [ "${private}" = "true" ]; then
      desc_col="*[Private]*"
    else
      # Replace newlines with spaces and escape pipe characters
      desc_col=$(printf '%s' "${description}" | tr '\n\r' '  ' | sed 's/|/\\|/g')
      [ -z "${desc_col}" ] && desc_col="—"
    fi

    # ---- Build status badges ------------------------------------------------
    local badges=""
    local default_branch
    default_branch=$(echo "${repo_json}" | jq -r '.default_branch')
    # URL-encode the branch name once per repo so special characters don't break badge URLs
    local encoded_branch
    encoded_branch=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "${default_branch}")

    while IFS= read -r workflow_json_b64; do
      [ -z "${workflow_json_b64}" ] && continue
      local workflow_json workflow_path workflow_name workflow_name_md workflow_file
      workflow_json=$(printf '%s' "${workflow_json_b64}" | base64 --decode)
      workflow_path=$(echo "${workflow_json}" | jq -r '.path // empty')
      workflow_name=$(echo "${workflow_json}" | jq -r '.name // "CI"')
      # Escape characters that would break Markdown alt text or table cells
      workflow_name_md="${workflow_name//\\/\\\\}"
      workflow_name_md="${workflow_name_md//]/\\]}"
      workflow_name_md="${workflow_name_md//|/\\|}"
      [ -z "${workflow_path}" ] && continue
      workflow_file=$(basename "${workflow_path}")
      local badge_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}/badge.svg?branch=${encoded_branch}"
      local workflow_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}"
      badges+="[![${workflow_name_md}](${badge_url})](${workflow_url}) "
    done < <(get_workflows "${name}")

    badges="${badges% }"  # trim trailing space
    [ -z "${badges}" ] && badges="—"

    # ---- Issue and PR counts ------------------------------------------------
    local open_issues total_issues open_prs total_prs
    open_issues=$(search_count "${name}" "issue" "open")
    total_issues=$(search_count "${name}" "issue" "")
    open_prs=$(search_count "${name}" "pr" "open")
    total_prs=$(search_count "${name}" "pr" "")
    local issues_col="${open_issues} / ${total_issues}"
    local prs_col="${open_prs} / ${total_prs}"

    # ---- GitHub Pages -------------------------------------------------------
    local pages_col="—"
    if [ "${has_pages}" = "true" ]; then
      local pages_url
      pages_url=$(get_pages_url "${name}")
      if [ -n "${pages_url}" ]; then
        pages_col="[Pages](${pages_url})"
      fi
    fi

    # ---- Assemble row -------------------------------------------------------
    local project_link="[**\`${name}\`**](https://github.com/${ORG}/${name})"
    table+="| ${project_link} | ${desc_col} | ${badges} | ${issues_col} | ${prs_col} | ${stars} | ${forks} | ${pages_col} |\n"
  done

  printf '%b' "${table}"
}

# ---------------------------------------------------------------------------
# Inject the table between markers in the README
# ---------------------------------------------------------------------------

update_readme() {
  local table="$1"
  local table_file
  table_file=$(mktemp)
  chmod 600 "${table_file}"
  # Ensure the temp file is removed on function exit (normal or error)
  trap 'rm -f "${table_file}"' RETURN
  printf '%s' "${table}" > "${table_file}"

  python3 - "${README}" "${table_file}" << 'PYEOF'
import sys, re

readme_path = sys.argv[1]
table_file  = sys.argv[2]

with open(table_file, 'r') as f:
    table = f.read()

with open(readme_path, 'r') as f:
    content = f.read()

new_section = (
    '<!-- PROJECTS-START -->\n'
    + table + '\n'
    + '<!-- PROJECTS-END -->'
)

updated, count = re.subn(
    r'<!-- PROJECTS-START -->.*?<!-- PROJECTS-END -->',
    new_section,
    content,
    flags=re.DOTALL,
)

if count != 1:
    if count == 0:
        error = (
            f"ERROR: markers <!-- PROJECTS-START --> / <!-- PROJECTS-END --> not found in {readme_path}"
        )
    else:
        error = (
            f"ERROR: expected exactly one <!-- PROJECTS-START --> / <!-- PROJECTS-END --> block in {readme_path}, found {count}"
        )
    print(error, file=sys.stderr)
    sys.exit(1)

with open(readme_path, 'w') as f:
    f.write(updated)

print(f"Updated {readme_path}")
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Building projects table for org: ${ORG}"
TABLE=$(build_table)
echo "Updating ${README}…"
update_readme "${TABLE}"
echo "Done."
