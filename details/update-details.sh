#!/usr/bin/env bash

###############################################################################
# Author: Amin Abbaspour
# Date: 2025-09-17
# License: LGPL 2.1 (https://github.com/abbaspour/auth0-myorg-bash/blob/master/LICENSE)
#
# Description: Update Organization details (name, display_name, branding)
# Reference:
# - Postman sample: My-Organization-API.postman_collection.json -> Organization Details -> Update Organization Details
# - OpenAPI: /spec/my-org-openapi.json (operationId: UpdateOrganizationDetails)
###############################################################################

set -euo pipefail

command -v curl >/dev/null || { echo >&2 "error: curl not found"; exit 3; }
command -v jq >/dev/null || { echo >&2 "error: jq not found"; exit 3; }

readonly DIR=$(dirname "${BASH_SOURCE[0]}")

function usage() {
  cat <<END >&2
USAGE: $0 [-e env] [-a access_token] [-f json_file | -J json_string | flags] [-h|-v]
        -e file        # .env file location (default cwd)
        -a token       # MyOrg access_token
        -f file        # JSON file containing PATCH body
        -J json        # Raw JSON string for PATCH body
        -n name        # Organization name
        -d display     # Organization display_name
        -u logo-url    # Branding logo_url
        -p primary     # Branding colors.primary (hex or css color)
        -b background  # Branding colors.page_background (hex or css color)
        -h|?           # usage
        -v             # verbose

Notes:
  - You can use -f or -J to provide a base JSON payload, and combine with -n, -d, -u, -p, -b to override specific fields.
  - If neither -f nor -J is provided, the payload will be built solely from the provided flags.

Examples:
  $0 -f body.json
  $0 -J '{"display_name":"Test Organization"}'
  $0 -n acme -d "Acme Inc" -u https://example.com/logo.png -p "#000000" -b "#FFFFFF"
  $0 -f body.json -p "#222222" -d "New Display"
END
  exit $1
}

[[ -f "${DIR}/.env" ]] && . "${DIR}/.env"

declare opt_verbose=''
declare curl_verbose='-s'
declare token="${access_token:-}"

# Base payload sources
declare body_file=""
declare body_json=""

# Convenience flags
declare name=""
declare display_name=""
declare logo_url=""
declare primary_color=""
declare background_color=""

# shellcheck disable=SC1090
while getopts "e:a:f:J:n:d:u:p:b:hv?" opt; do
  case ${opt} in
    e) source "${OPTARG}" ;;
    a) token="$OPTARG" ;;
    f) body_file="$OPTARG" ;;
    J) body_json="$OPTARG" ;;
    n) name="$OPTARG" ;;
    d) display_name="$OPTARG" ;;
    u) logo_url="$OPTARG" ;;
    p) primary_color="$OPTARG" ;;
    b) background_color="$OPTARG" ;;
    v) opt_verbose=1; curl_verbose='-s' ;;
    h|?) usage 0 ;;
    *) usage 1 ;;
  esac
done

[[ -z "${token:-}" ]] && { echo >&2 "Error: access_token is required. Provide with -a or env var."; usage 2; }

# Validate that we have some input to send
if [[ -z "$body_file" && -z "$body_json" && -z "$name" && -z "$display_name" && -z "$logo_url" && -z "$primary_color" && -z "$background_color" ]]; then
  echo >&2 "Error: provide one of -f, -J, or at least one of -n, -d, -u, -p, -b"; usage 2
fi

# Build initial JSON payload
if [[ -n "$body_file" ]]; then
  [[ -f "$body_file" ]] || { echo >&2 "Error: JSON file '$body_file' not found"; exit 2; }
  jq empty "$body_file" 2>/dev/null || { echo >&2 "Error: '$body_file' does not contain valid JSON"; exit 2; }
  payload=$(cat "$body_file")
elif [[ -n "$body_json" ]]; then
  echo "$body_json" | jq -e . >/dev/null 2>&1 || { echo >&2 "Error: provided -J json string is not valid JSON"; exit 2; }
  payload="$body_json"
else
  payload="{}"
fi

# Merge convenience flags into payload using jq
jq_filter='.'
declare -a jq_args

if [[ -n "$name" ]]; then
  jq_filter+=' | .name = $name'
  jq_args+=(--arg name "$name")
fi
if [[ -n "$display_name" ]]; then
  jq_filter+=' | .display_name = $display_name'
  jq_args+=(--arg display_name "$display_name")
fi
if [[ -n "$logo_url" ]]; then
  jq_filter+=' | .branding.logo_url = $logo_url'
  jq_args+=(--arg logo_url "$logo_url")
fi
if [[ -n "$primary_color" ]]; then
  jq_filter+=' | .branding.colors.primary = $primary_color'
  jq_args+=(--arg primary_color "$primary_color")
fi
if [[ -n "$background_color" ]]; then
  jq_filter+=' | .branding.colors.page_background = $background_color'
  jq_args+=(--arg background_color "$background_color")
fi

payload=$(echo "$payload" | jq -c ${jq_args[@]:+"${jq_args[@]}"} "$jq_filter")

# Extract available scopes from JWT access token
# Note: token must be in JWT format and contain a 'scope' claim
declare -r AVAILABLE_SCOPES=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .scope' <<< "${token}")
declare -r EXPECTED_SCOPE="update:my_org:details"
[[ " $AVAILABLE_SCOPES " == *" $EXPECTED_SCOPE "* ]] || {
  echo >&2 "ERROR: Insufficient scope in Access Token. Expected: '$EXPECTED_SCOPE', Available: '$AVAILABLE_SCOPES'";
  exit 1
}

# Extract issuer and derive host
declare -r iss=$(jq -Rr 'split(".") | .[1] | @base64d | fromjson | .iss // empty' <<< "${token}")
[[ -z "$iss" ]] || [[ "$iss" == "null" ]] && { echo >&2 "Error: 'iss' claim not found in access token payload"; exit 1; }

# Trim trailing slash from iss if present
declare host="${iss%/}"

# Perform request
declare url="${host}/my-org/details"
[[ -n "${opt_verbose}" ]] && echo "PATCH ${url}" && echo "Payload:" && echo "$payload" | jq .

curl ${curl_verbose} --url "$url" \
  -X PATCH \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "Authorization: Bearer $token" \
  --data "$payload" | jq .
