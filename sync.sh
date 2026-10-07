#!/usr/bin/env bash
set -e

CONFIG_FILE="lua-definitions.json"
MANIFEST_NAME=".lua-definitions-sync"

WARNINGS=0
ERRORS=0

log_info() { echo -e "  [i] $1"; }
log_success() { echo -e "  [+] $1"; }
log_warning() { echo -e "  [!] WARNING: $1" >&2; WARNINGS=$((WARNINGS+1)); }
log_error() { echo -e "  [X] ERROR: $1" >&2; ERRORS=$((ERRORS+1)); }

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    log_error "'jq' and 'curl' are required to run this script."
    exit 1
fi

TARGET_DIR=$(jq -r '.target_dir // "./definitions_vendor"' "$CONFIG_FILE")
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
MANIFEST_FILE="${TARGET_DIR}/${MANIFEST_NAME}"

mkdir -p "$TARGET_DIR"
STAGING_ROOT=$(mktemp -d "${TARGET_DIR}/.sync-XXXXXX")
trap 'rm -rf "$STAGING_ROOT"' EXIT

github_api_req() {
    local url="$1"
    local headers=(-s -H "Accept: application/vnd.github.v3+json" -H "User-Agent: Lua-Definitions-Sync")
    if [ -n "$GITHUB_TOKEN" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    curl "${headers[@]}" "$url"
}

download_file() {
    local url="$1"
    local dest="$2"
    mkdir -p "$(dirname "$dest")"
    local headers=(-sfL -H "User-Agent: Lua-Definitions-Sync")
    if [ -n "$GITHUB_TOKEN" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    if curl "${headers[@]}" -o "$dest" "$url"; then
        log_success "Downloaded: $dest"
    else
        log_error "Failed to download: $url"
    fi
}

match_pattern() {
    local pattern="$1"
    local filename="$2"
    if [ -z "$pattern" ] || [ "$pattern" = "null" ]; then
        return 0
    fi
    # Bash glob match against pattern
    [[ "$filename" == $pattern ]]
}

# Prints the normalized dest, or fails if it could escape or wipe TARGET_DIR
normalize_dest() {
    local d="${1//\\//}"
    while [[ "$d" == ./* ]]; do d="${d#./}"; done
    while [[ "$d" == */ ]]; do d="${d%/}"; done
    if [ -z "$d" ] || [ "$d" = "null" ] || [[ "$d" == /* ]] || [[ "$d" == [A-Za-z]:* ]]; then
        return 1
    fi
    local segs seg
    IFS='/' read -ra segs <<< "$d"
    for seg in "${segs[@]}"; do
        case "$seg" in ''|.|..) return 1 ;; esac
    done
    echo "$d"
}

# True if dest paths $1 and $2 are equal or one contains the other
dests_overlap() {
    [ "$1" = "$2" ] || [[ "$1" == "$2"/* ]] || [[ "$2" == "$1"/* ]]
}

process_entry() {
    local owner="$1"
    local repo="$2"
    local ref="$3"
    local dest_dir="$4"
    local pattern="$5"
    local recursive="$6"
    local path="$7"

    local url="https://api.github.com/repos/${owner}/${repo}/contents/${path}?ref=${ref}"
    local response
    if ! response=$(github_api_req "$url") || ! echo "$response" | jq -e . &> /dev/null; then
        log_error "Request failed ($path)"
        return
    fi

    # Handle errors/rate limits
    local msg
    msg=$(echo "$response" | jq -r 'if type == "object" then .message // empty else empty end')
    if [ -n "$msg" ]; then
        log_error "$msg ($path)"
        return
    fi

    local type
    type=$(echo "$response" | jq -r 'if type == "array" then "array" else .type end')

    if [ "$type" = "file" ]; then
        local name
        name=$(echo "$response" | jq -r '.name')
        if match_pattern "$pattern" "$name"; then
            local dl_url
            dl_url=$(echo "$response" | jq -r '.download_url')
            download_file "$dl_url" "${dest_dir}/${name}"
        fi
    elif [ "$type" = "array" ]; then
        # Parse the JSON array and loop over items safely
        while IFS=$'\t' read -r item_type item_name item_path item_dl_url; do
            if [ "$item_type" = "file" ]; then
                if match_pattern "$pattern" "$item_name"; then
                    download_file "$item_dl_url" "${dest_dir}/${item_name}"
                fi
            elif [ "$item_type" = "dir" ] && [ "$recursive" = "true" ]; then
                process_entry "$owner" "$repo" "$ref" "${dest_dir}/${item_name}" "$pattern" "$recursive" "$item_path"
            fi
        done < <(echo "$response" | jq -r '.[] | [.type, .name, .path, (.download_url // "")] | @tsv')
    fi
}

# Loops read from process substitution (not a pipe) so ERRORS/WARNINGS updates persist
CURRENT_DESTS=()
index=0
while read -r source; do
    index=$((index+1))
    id=$(echo "$source" | jq -r '.id')
    owner=$(echo "$source" | jq -r '.owner')
    repo=$(echo "$source" | jq -r '.repo')
    ref=$(echo "$source" | jq -r '.ref // "main"')
    raw_dest=$(echo "$source" | jq -r '.dest // .id')

    if ! dest=$(normalize_dest "$raw_dest"); then
        log_error "Skipping $id: invalid dest '$raw_dest' (must be a relative path inside target_dir)"
        continue
    fi

    overlap=""
    for existing in "${CURRENT_DESTS[@]}"; do
        if dests_overlap "$dest" "$existing"; then overlap="$existing"; fi
    done
    if [ -n "$overlap" ]; then
        log_error "Skipping $id: dest '$dest' overlaps another source's dest '$overlap'"
        continue
    fi
    CURRENT_DESTS+=("$dest")

    dest_folder="${TARGET_DIR}/${dest}"
    staging_folder="${STAGING_ROOT}/${index}"
    mkdir -p "$staging_folder"
    errors_before=$ERRORS

    log_info "Fetching $id ($owner/$repo @ $ref)..."

    # Parse nested paths array for the current source
    while read -r path_item; do
        item_path=$(echo "$path_item" | jq -r '.path')
        pattern=$(echo "$path_item" | jq -r '.pattern // "*.lua"')
        recursive=$(echo "$path_item" | jq -r '.recursive // false')

        process_entry "$owner" "$repo" "$ref" "$staging_folder" "$pattern" "$recursive" "$item_path"
    done < <(echo "$source" | jq -c '.paths[]')

    # Only replace the previous files once everything downloaded cleanly
    if [ $ERRORS -gt $errors_before ]; then
        log_warning "Keeping previous files for $id in $dest_folder due to errors."
    else
        rm -rf "$dest_folder"
        mkdir -p "$(dirname "$dest_folder")"
        mv "$staging_folder" "$dest_folder"
        log_success "Updated: $dest_folder"
    fi
done < <(jq -c '.sources[]' "$CONFIG_FILE")

# Remove folders from sources that were dropped from the config since the last sync
if [ -f "$MANIFEST_FILE" ]; then
    while IFS= read -r old_raw || [ -n "$old_raw" ]; do
        old=$(normalize_dest "$old_raw") || continue
        keep=""
        for current in "${CURRENT_DESTS[@]}"; do
            if dests_overlap "$old" "$current"; then keep=1; fi
        done
        if [ -z "$keep" ] && [ -e "${TARGET_DIR}/${old}" ]; then
            rm -rf "${TARGET_DIR:?}/${old}"
            log_success "Removed stale source folder: ${TARGET_DIR}/${old}"
            parent=$(dirname "$old")
            while [ "$parent" != "." ] && rmdir "${TARGET_DIR}/${parent}" 2> /dev/null; do
                parent=$(dirname "$parent")
            done
        fi
    done < "$MANIFEST_FILE"
fi
if [ ${#CURRENT_DESTS[@]} -gt 0 ]; then
    printf '%s\n' "${CURRENT_DESTS[@]}" > "$MANIFEST_FILE"
else
    : > "$MANIFEST_FILE"
fi

if [ $ERRORS -gt 0 ]; then
    log_error "Sync completed with $ERRORS error(s) and $WARNINGS warning(s)."
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    log_warning "Sync completed with $WARNINGS warning(s)."
else
    log_success "Sync completed successfully!"
fi
