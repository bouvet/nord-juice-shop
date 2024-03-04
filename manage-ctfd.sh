#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

### Required variables ###
# Key used to generate the challenge flags. Should be rotated between CTF-events
CTF_KEY="${CTF_KEY:?Missing required environment variable.}"
# FQDN (Fully Qualified Domain Name) at which the setup is accessible
JUICE_FQDN="${JUICE_FQDN:?Missing required environment variable.}"
# Password for the CTFd admin user (CTFD_ADMIN_USERNAME)
CTFD_ADMIN_PASSWORD="${CTFD_ADMIN_PASSWORD:?Missing required environment variable}"

### Optional variables ###
# CTFd configuration - see https://docs.ctfd.io/docs/settings/overview/ for details.
# Name of the CTF event. Displayed in the CTFd instance.
CTF_NAME="${CTF_NAME:-nord-juice-shop}"
# Description of the CTF event. Displayed in the CTFd instance.
CTF_DESC="${CTF_DESC:-Nord JuiceShop CTF Event}"
# User mode for the CTFd instance. Must be one of 'teams' or 'user'. See https://docs.ctfd.io/docs/settings/user-modes/
CTF_USER_MODE="${CTF_USER_MODE:-teams}"
# Visibility of challenges in the CTFd instance. Must be one of 'private' or 'public'. See https://docs.ctfd.io/docs/settings/visibility-settings#challenge-visibility
CTF_CHALLENGE_VISIBILITY="${CTF_CHALLENGE_VISIBILITY:-private}"
# Visibility of accounts in the CTFd instance. Must be one of 'private' or 'public'. See https://docs.ctfd.io/docs/settings/visibility-settings#account-visibility
CTF_ACCOUNT_VISIBILITY="${CTF_ACCOUNT_VISIBILITY:-public}"
# Visibility of scores in the CTFd instance. Must be one of 'private' or 'public'. See https://docs.ctfd.io/docs/settings/visibility-settings#score-visibility
CTF_SCORE_VISIBILITY="${CTF_SCORE_VISIBILITY:-public}"
# Visibility of account registration in the CTFd instance. Must be one of 'private' or 'public'. See https://docs.ctfd.io/docs/settings/visibility-settings#registration-visibility
CTF_REGISTRATION_VISIBILITY="${CTF_REGISTRATION_VISIBILITY:-public}"
# Setting a registration code will ask users on the registration page for the code that will enable them to register.
CTFD_REGISTRATION_CODE="${CTFD_REGISTRATION_CODE:-}"
# Whether to confirm emails of registered users. Must be one of 'true' or 'false'.
CTF_VERIFY_EMAILS="${CTF_VERIFY_EMAILS:-false}"
# Max. number of participants in a team. Only applicable if 'CTF_USER_MODE' is set to 'teams'.
CTF_TEAM_SIZE="${CTF_TEAM_SIZE:-4}"
# Username of the admin user for the CTFd instance.
CTFD_ADMIN_USERNAME="${CTFD_ADMIN_USERNAME:-admin}"
# Email address of the admin user for the CTFd instance.
CTFD_ADMIN_EMAIL="${CTFD_ADMIN_EMAIL:-admin@juice-sh.op}"
# Theme used in the CTFd instance. See https://docs.ctfd.io/docs/settings/themes
CTFD_THEME="${CTFD_THEME:-core-beta}"
# Theme color used in the CTFd instance.
CTFD_THEME_COLOR="${CTFD_THEME_COLOR:-}"
# Set the CTFd instance to "Paused" - will stop users from being able to submit answers. See https://docs.ctfd.io/docs/settings/competition-times/#pausing-a-ctf
CTFD_PAUSED="${CTFD_PAUSED:-false}"
# TODO: Remove to avoid handling conversion?
# Start date of the CTF event, i.e. the date/time when competition content will be accessible. See https://docs.ctfd.io/docs/settings/competition-times
CTF_START_DATETIME="${CTF_START_DATETIME:-}"
# End date of the CTF event, i.e. the date/time when competition content will be inaccessible.
CTF_END_DATETIME="${CTF_END_DATETIME:-}"

# JuiceShop CLI command
_JUICESHOP_CLI_BINARY="juice-shop-ctf"
_JUICESHOP_CLI_PACKAGE="$_JUICESHOP_CLI_BINARY-cli"
_JUICESHOP_CLI_VERSION="10.0.1"

# Check if juice-shop-ctf-cli is installed
if ! command -v "$_JUICESHOP_CLI_BINARY" &> /dev/null; then
  echo "Missing required dependency '$_JUICESHOP_CLI_BINARY'. Install it by running:"
  echo "npm install -g $_JUICESHOP_CLI_PACKAGE@$_JUICESHOP_CLI_VERSION"
  exit 1
fi
__REQUIRED_BINARIES=(
    "kubectl"
    "curl"
    "jq"
)
# Check that all required binaries are present
for __REQ_PKG in "${__REQUIRED_BINARIES[@]}"; do
    if ! which "$__REQ_PKG" &> /dev/null ; then
        echo "ERROR: Missing required package '$__REQ_PKG'"
        exit 1
    fi
done

# Variables
_CTFD_CONFIG_GEN_TEAM_NAME="ctfd-config-gen"
_CTF_CFG_PATH="/tmp/juice-shop-cli-config.yaml"
_PORT_LOCAL="8808"
_PIDFILE_PATH="/tmp/.juice-shop-portforward.pid"
_CTF_CHALLENGES_OUT_PATH="ctfd-challenges-$(date +%FT%H%M%S).csv"
CTF_URL="http://localhost:$_PORT_LOCAL"
_CTFD_URL="https://$JUICE_FQDN/ctfd"
_CURL_COOKIE_JAR="/tmp/.ctfd-cookies.out"
# Shared extra arguments to pass to curl
_CURL_SHARED_ARGS=()
# Allow passing the --insecure flag to curl
if [ "${CURL_INSECURE:-0}" -eq 1 ]; then
  _CURL_SHARED_ARGS+=("--insecure")
fi
_PAGES_DIRECTORIES=("pages")

function usage() {
  echo -e "Usage: ./$SCRIPT_NAME COMMAND

  Commands:
      cfg\tConfigures the CTFd instance
      gen\tGenerates the CTFd challenges CSV
      import\tImport a CTFd challenges CSV to the CTFd instance
      pages\tImport the custom pages to the CTFd instance
      run\tRuns all of the above, i.e. configures CTFd, and generates and imports the challenges
  "
  exit 0
}

function setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    # shellcheck disable=SC2034
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

setup_colors

info() {
  echo >&2 -e "${CYAN}$1${NOFORMAT}"
}

success() {
  echo >&2 -e "${GREEN}    SUCCESS${NOFORMAT}"
}

failure() {
  echo >&2 -e "${RED}${1:-\tERROR}${NOFORMAT}"
}

fatal() {
  failure "${1:-\tFATAL}"
  cleanup
  exit 1
}

ARGS=("$@")

# Command to execute
COMMAND="${ARGS[0]:-run}"

function juice_shop_instance_exists() {
  _matches=$(kubectl get pod -l "app.kubernetes.io/name=juice-shop" -o name | wc -l)
  # Check if the length of matches is exactly zero
  if [ "$_matches" -eq 0 ]; then
    return 1
  fi
}

function create_juice_shop_instance() {
  _MULTI_JUICER_BASE_URL="balancer"
  _MULTI_JUICER_CREATE_TEAM_URL="teams/$_CTFD_CONFIG_GEN_TEAM_NAME/join"
  info "Creating juice-shop instance for CTFd config creation ('$_CTFD_CONFIG_GEN_TEAM_NAME')"
  __juiceshop_instance=$(curl -s "https://$JUICE_FQDN/$_MULTI_JUICER_BASE_URL/$_MULTI_JUICER_CREATE_TEAM_URL" \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-raw '{}' \
    "${_CURL_SHARED_ARGS[@]}"
  )
  if [ "$?" -eq 60 ]; then
    fatal "The TLS certificate for '$JUICE_FQDN' is invalid - if you recently deployed the services, please wait for TLS certificate acqusition to complete before retrying, or set the environment variable 'CURL_INSECURE=1'."
  fi
}

function wait_for_instance() {
  # Wait for juice-shop instance to be ready
  info "Waiting for juice-shop instance to be ready..."
  # Wait for node creation
  sleep 2
  # Wait for Ready condition
  kubectl wait pod --for=condition=Ready --timeout=60s -l "app.kubernetes.io/name=juice-shop"
}

function create_tunnel_to_pod() {
  # Forward traffic from this device to the juice-shop pod
  info "Opening temporary tunnel to a juice-shop pod"
  # Get the name of a pod running an instance of juice-shop
  POD_NAME=$(kubectl get pods -l "app.kubernetes.io/name=juice-shop" -o name | head -1)
  if [ -z "$POD_NAME" ]; then
    failure "ERROR: In order to import the challenges from juice-shop, an instance of juice-shop must be running."
    fatal "Please navigate to the multi-juicer instance and create a new team to deploy a new instance, then re-run this script once the instance is ready."
  fi
  (kubectl port-forward "$POD_NAME" "$_PORT_LOCAL:3000" &> /dev/null)&
  echo $! > "$_PIDFILE_PATH"
}

function write_config_to_file() {
  # Write temp. config to file, used by the juice-shop-ctf-cli
  info "Writing juice-shop-ctf config to file"
  # Ref. https://github.com/juice-shop/juice-shop-ctf#configuration-file
  cat <<EOF > $_CTF_CFG_PATH
ctfFramework: CTFd
juiceShopUrl: $CTF_URL
ctfKey: $CTF_KEY
countryMapping: https://raw.githubusercontent.com/bkimminich/juice-shop/master/config/fbctf.yml
insertHints: free
insertHintUrls: free
insertHintSnippets: free
EOF
}

function run_cli() {
  info "Importing challenges from JuiceShop"
  juice-shop-ctf --config "$_CTF_CFG_PATH" --output "$_CTF_CHALLENGES_OUT_PATH"
  if [[ -f "$_CTF_CHALLENGES_OUT_PATH" ]]; then
    info "Wrote CTFd challenges to '$_CTF_CHALLENGES_OUT_PATH'."
  else
    failure "ERROR: $_JUICESHOP_CLI_PACKAGE failed to generate the CTFd config file"
    return 1
  fi
}

function _get_ctfd_nonce() {
  # Allow optional sub-path specification
  _PATH="${1:-}"
  # Build the URL from which to retrieve the nonce.
  _NONCE_URL="$_CTFD_URL$_PATH"
  # Load the CTFd page
  _ctfd_res=$(
    curl -sSL "$_NONCE_URL" \
      --cookie "$_CURL_COOKIE_JAR" \
      --cookie-jar "$_CURL_COOKIE_JAR" \
      --write-out "%{http_code}" \
      "${_CURL_SHARED_ARGS[@]}"
  )
  # Find the line matching 'csrfNonce'
  _csrfNonce=$(echo "$_ctfd_res" | grep "csrfNonce")
  # Split the line, extracting the value
  _nonce=$(echo "$_csrfNonce" | awk -F"'csrfNonce':" '{ print $2 }')
  # Strip out unwanted characters
  _CTFD_NONCE=$(echo "$_nonce" | tr -d '," ')
  # Fail if the length is not exactly 64 characters
  if [ ! ${#_CTFD_NONCE} -eq 64 ]; then
    return 1
  fi
  echo "$_CTFD_NONCE"
}

function _ctfd_is_configured() {
  HEAD_RES_REDIR=$(
    curl -so /dev/null "$_CTFD_URL/login" \
      --head \
      --write-out "%{redirect_url}" \
      "${_CURL_SHARED_ARGS[@]}"
  )
  # Check if /ctfd/setup is in the redirect url. If so, the instance is unconfigured
  case "$HEAD_RES_REDIR" in
    */ctfd/setup*)
      return 1
  esac
}

function setup_ctfd() {
  info "Configuring the CTFd instance"

  if _ctfd_is_configured; then
    failure "The CTFd instance has already been configured. Skipping."
    return 0
  fi

  # Retrieve the nonce (and session cookie)
  _CTFD_NONCE=$(_get_ctfd_nonce)
  # Send the request to configure the CTFd instance
  SETUP_RES_STATUS_CODE=$(
    curl -sLo /dev/null "$_CTFD_URL/setup" \
      --cookie "$_CURL_COOKIE_JAR" \
      --cookie-jar "$_CURL_COOKIE_JAR" \
      --write-out "%{http_code}" \
      -F "ctf_name=$CTF_NAME" \
      -F "ctf_description=$CTF_DESC" \
      -F "user_mode=$CTF_USER_MODE" \
      -F "challenge_visibility=$CTF_CHALLENGE_VISIBILITY" \
      -F "account_visibility=$CTF_ACCOUNT_VISIBILITY" \
      -F "score_visibility=$CTF_SCORE_VISIBILITY" \
      -F "registration_visibility=$CTF_REGISTRATION_VISIBILITY" \
      -F "registration_code=$CTFD_REGISTRATION_CODE" \
      -F "verify_emails=$CTF_VERIFY_EMAILS" \
      -F "team_size=$CTF_TEAM_SIZE" \
      -F "name=$CTFD_ADMIN_USERNAME" \
      -F "email=$CTFD_ADMIN_EMAIL" \
      -F "password=$CTFD_ADMIN_PASSWORD" \
      -F "ctf_theme=$CTFD_THEME" \
      -F "theme_color=$CTFD_THEME_COLOR" \
      -F "paused=$CTFD_PAUSED" \
      -F "start=$CTF_START_DATETIME" \
      -F "end=$CTF_END_DATETIME" \
      -F "_submit=Finish" \
      -F "nonce=$_CTFD_NONCE" \
      "${_CURL_SHARED_ARGS[@]}"
  )
  
  if [ ! "$SETUP_RES_STATUS_CODE" -eq 200 ]; then
    failure "Failed to configure CTFd automatically. Please navigate to $_CTFD_URL to set up the instance manually."
    return 1
  fi
  success
}

function ctfd_authenticate() {
  if ! _ctfd_is_configured; then
    fatal "The CTFd instance has not been configured. Either configure it manually prior to running, or run the 'cfg' command first."
  fi
  # Retrieve the nonce (and session cookie)
  _CTFD_NONCE=$(_get_ctfd_nonce "/login")
  AUTH_RES_STATUS_CODE=$(
    curl -sLo /dev/null "$_CTFD_URL/login" \
      --cookie "$_CURL_COOKIE_JAR" \
      --cookie-jar "$_CURL_COOKIE_JAR" \
      --write-out "%{http_code}" \
      -d "name=$CTFD_ADMIN_USERNAME" \
      -d "password=$CTFD_ADMIN_PASSWORD" \
      -d "_submit=Submit" \
      -d "nonce=$_CTFD_NONCE" \
      "${_CURL_SHARED_ARGS[@]}"
  )
  if [ ! "$AUTH_RES_STATUS_CODE" -eq 200 ]; then
    return 1
  fi
}

function import_challenges() {
  info "Importing the challenges CSV '$_CTF_CHALLENGES_OUT_PATH' to CTFd"
  if [[ ! -f "$_CTF_CHALLENGES_OUT_PATH" ]]; then
    failure "The challenges CSV '$_CTF_CHALLENGES_OUT_PATH' does not exist. Skipping the automated challenge import." 
    return 1
  fi
  if ctfd_authenticate; then
    # Retrieve the nonce (and session cookie)
    _CTFD_NONCE=$(_get_ctfd_nonce "/admin/config")
    IMPORT_RES_STATUS_CODE=$(
      curl -sLo /dev/null "$_CTFD_URL/admin/import/csv" \
        --cookie "$_CURL_COOKIE_JAR" \
        --write-out "%{http_code}" \
        -F "csv_file=@$_CTF_CHALLENGES_OUT_PATH" \
        -F "csv_type=challenges" \
        -F "nonce=$_CTFD_NONCE" \
        "${_CURL_SHARED_ARGS[@]}"
    )
    if [ ! "$IMPORT_RES_STATUS_CODE" -eq 200 ]; then
      failure "Automated import of the CTFd challenges CSV failed due to an unexpected error."
      return 1
    fi
  else
    failure "Failed to authenticate against CTFd. Skipping the automated challenge import."
    return 1
  fi
}

function _delete_default_index_page() {
  if ctfd_authenticate; then
    # Retrieve the nonce (and session cookie)
    _CTFD_NONCE=$(_get_ctfd_nonce "/admin/config")
    DELETE_RES_STATUS_CODE=$(
    curl -sLo /dev/null "$JUICE_FQDN/api/v1/pages/1" \
      --cookie "$_CURL_COOKIE_JAR" \
      --write-out "%{http_code}" \
      -X DELETE \
      -H "CSRF-Token: $_CTFD_NONCE"
    )
    if [ ! "$DELETE_RES_STATUS_CODE" -eq 200 ]; then
      failure "Failed to delete the default index page due to an unexpected error."
      return 1
    fi
  else
    failure "Failed to authenticate against CTFd. Skipping default index page deletion."
    return 1
  fi
}

function _find_pages() {
  pages=()
  for _dir in "${_PAGES_DIRECTORIES[@]}"; do
    _pages=()
    # Find all files named "*.md"
    mapfile -t _pages < <(/usr/bin/find "$_dir" -type f -name "*.md")
    pages+=("${_pages[@]}")
  done
}

function _upload_page() {
  _fp="${1:?Missing required parameter 'page_filepath'}"
  _title="${2:?Missing required parameter 'page_title'}"
  _route="${3:?Missing required parameter 'page_route'}"

  if ctfd_authenticate; then
    # Retrieve the nonce (and session cookie)
    _CTFD_NONCE=$(_get_ctfd_nonce "/admin/pages/new")
    # Write payload to temp. file using jq
    _payload_fp=".payload.json.tmp"
    jq -nRs --rawfile content "$_fp" \
      --arg title "$_title" \
      --arg route "$_route" \
      --arg nonce "$_CTFD_NONCE" \
      '{title: $title, route: $route, format: "markdown", content: $content, nonce: $nonce, draft: false, hidden: false, auth_required: false}' \
      > "$_payload_fp"

    if [ ! -f "$_payload_fp" ]; then
      failure "Failed to create custom-page upload payload with jq. Skipping."
      return 1
    fi
    UPLOAD_RES_STATUS_CODE=$(
      curl -sLo /dev/null "$_CTFD_URL/api/v1/pages" \
        --cookie "$_CURL_COOKIE_JAR" \
        --write-out "%{http_code}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "CSRF-Token: $_CTFD_NONCE" \
        --data "@$_payload_fp" \
        "${_CURL_SHARED_ARGS[@]}"
    )
    rm "$_payload_fp"

    if [ ! "$UPLOAD_RES_STATUS_CODE" -eq 200 ]; then
      failure "Failed to upload the custom-page '$_fp' due to an unexpected error. Check the CTFd logs for more information."
      return 1
    fi
  else
    failure "Failed to authenticate against CTFd. Skipping custom-page upload."
    return 1
  fi
}

function import_pages() {
  info "Importing the custom pages to CTFd"
  _delete_default_index_page
  _find_pages
  for page_fp in "${pages[@]}"; do
    # Get the name of the page, removing the directory and suffix
    _page_filename=$(basename "$page_fp" .md)
    # Sanitize the name (keeping only alphanumerical chars and dash/underscore)
    page_name="${_page_filename//[!A-Za-z0-9-_]}"
    page_route="$page_name"
    # Replace dash/underscore with space
    _page_title="${page_name//[-_]/ }"
    page_title="${_page_title^}"
    _upload_page "$page_fp" "$page_title" "$page_route"
  done
  return 0
}

function cleanup() {
  info "Cleaning up"
  if [[ -f "$_CTF_CFG_PATH" ]]; then
    # Delete temp config file
    rm "$_CTF_CFG_PATH"
  fi
  if [[ -f "$_PIDFILE_PATH" ]]; then
    if pgrep -F "$_PIDFILE_PATH" &> /dev/null; then
      # Stop port forwarding
      kill -9 "$(cat $_PIDFILE_PATH)"
    fi
    # Delete pidfile
    rm "$_PIDFILE_PATH"
  fi
  if [[ -f "$_CURL_COOKIE_JAR" ]]; then
    # Delete the cookie jar
    rm "$_CURL_COOKIE_JAR"
  fi
}

function gen() {
  # Generate challenges CSV
  if ! juice_shop_instance_exists; then
    create_juice_shop_instance && success
  fi
  wait_for_instance
  create_tunnel_to_pod && success 
  write_config_to_file && success
  run_cli && success
}

function run() {
  gen
  if setup_ctfd; then
    import_challenges && success
  fi
}

case "$COMMAND" in
  "-h" | "--help")
    usage
    ;;
  "cfg")
    ./manage-multijuicer.sh set-namespace
    setup_ctfd
    ;;
  "gen" | "generate")
    ./manage-multijuicer.sh set-namespace
    gen
    info "Upload this file to CTFd at https://$JUICE_FQDN/ctfd/admin/import"
    cleanup
    ;;
  "import")
    _CTF_CHALLENGES_OUT_PATH="${2:-}"
    if [ -z "$_CTF_CHALLENGES_OUT_PATH" ]; then
      fatal "Missing required argument to 'import': The filepath of the challenges CSV to import must be specified."
    fi
    ./manage-multijuicer.sh set-namespace
    import_challenges && success
    cleanup
    ;;
  "pages")
    ./manage-multijuicer.sh set-namespace
    import_pages && success
    cleanup
    ;;
  "run")
    ./manage-multijuicer.sh set-namespace
    run
    cleanup
    ;;
  *)
    failure "Invalid argument '$COMMAND'\n"
    usage
    ;;
esac
