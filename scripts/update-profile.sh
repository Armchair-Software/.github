#!/usr/bin/env bash
# update-profile.sh
# Fetches repository information for the Armchair-Software GitHub organisation
# and updates the projects table in profile/README.md.
#
# Required environment variables:
#   GITHUB_TOKEN  – a token with read access to the organisation's repositories
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

# Fetch all public, non-archived, non-fork repositories for the org
fetch_repos() {
  local page=1
  while :; do
    local chunk
    chunk=$(gh_api "orgs/${ORG}/repos?type=public&sort=full_name&per_page=${PER_PAGE}&page=${page}")
    echo "${chunk}" | jq -c '.[]'
    local count
    count=$(echo "${chunk}" | jq 'length')
    if [ "${count}" -lt "${PER_PAGE}" ]; then
      break
    fi
    page=$((page + 1))
  done
}

# Return the first workflow file name for a repo, or empty string
get_workflows() {
  local repo="$1"
  gh_api "repos/${ORG}/${repo}/actions/workflows?per_page=${PER_PAGE}" 2>/dev/null \
    | jq -r '.workflows[].path' 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# Build the projects table
# ---------------------------------------------------------------------------

build_table() {
  local table=""
  table+="| Project | Description | Build Status | Pages |\n"
  table+="| ------- | ----------- | :----------: | :---: |\n"

  local repos_json
  mapfile -t repos_json < <(fetch_repos)

  for repo_json in "${repos_json[@]}"; do
    local name fork archived description has_pages
    name=$(echo "${repo_json}" | jq -r '.name')
    fork=$(echo "${repo_json}" | jq -r '.fork')
    archived=$(echo "${repo_json}" | jq -r '.archived')
    description=$(echo "${repo_json}" | jq -r '.description // ""')
    has_pages=$(echo "${repo_json}" | jq -r '.has_pages')

    # Skip the .github repo itself and any forks / archived repos
    if [ "${name}" = ".github" ] || [ "${fork}" = "true" ] || [ "${archived}" = "true" ]; then
      continue
    fi

    # ---- Build status badges ------------------------------------------------
    local badges=""
    local default_branch
    default_branch=$(echo "${repo_json}" | jq -r '.default_branch')

    while IFS= read -r workflow_path; do
      [ -z "${workflow_path}" ] && continue
      local workflow_file
      workflow_file=$(basename "${workflow_path}")
      local badge_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}/badge.svg?branch=${default_branch}"
      local workflow_url="https://github.com/${ORG}/${name}/actions/workflows/${workflow_file}"
      badges+="[![CI](${badge_url})](${workflow_url}) "
    done < <(get_workflows "${name}")

    badges="${badges% }"  # trim trailing space
    [ -z "${badges}" ] && badges="—"

    # ---- GitHub Pages -------------------------------------------------------
    local pages_col="—"
    if [ "${has_pages}" = "true" ]; then
      local pages_url
      pages_url=$(get_pages_url "${name}")
      if [ -n "${pages_url}" ]; then
        pages_col="[🌐 Live demo](${pages_url})"
      fi
    fi

    # ---- Description --------------------------------------------------------
    local desc_col="${description:-—}"

    # ---- Assemble row -------------------------------------------------------
    local project_link="[**\`${name}\`**](https://github.com/${ORG}/${name})"
    table+="| ${project_link} | ${desc_col} | ${badges} | ${pages_col} |\n"
  done

  printf '%b' "${table}"
}

# ---------------------------------------------------------------------------
# Inject the table between markers in the README
# ---------------------------------------------------------------------------

update_readme() {
  local table="$1"

  python3 - "${README}" "${table}" << 'PYEOF'
import sys, re

readme_path = sys.argv[1]
table       = sys.argv[2]

with open(readme_path, 'r') as f:
    content = f.read()

new_section = (
    '<!-- PROJECTS-START -->\n'
    + table + '\n'
    + '<!-- PROJECTS-END -->'
)

updated = re.sub(
    r'<!-- PROJECTS-START -->.*?<!-- PROJECTS-END -->',
    new_section,
    content,
    flags=re.DOTALL,
)

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
