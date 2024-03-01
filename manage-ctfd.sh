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
# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
  echo "Missing required package kubectl."
  exit 1
fi

# Variables
_CTFD_CONFIG_GEN_TEAM_NAME="ctfd-config-gen"
_CTF_CFG_PATH="/tmp/juice-shop-cli-config.yaml"
_PORT_LOCAL="8808"
_PIDFILE_PATH="/tmp/.juice-shop-portforward.pid"
_CTF_CHALLENGES_OUT_PATH="ctfd-challenges-$(date +%FT%H%M%S).csv"
CTF_URL="http://localhost:$_PORT_LOCAL"
_CTFD_URL="https://$JUICE_FQDN/ctfd"
_CURL_COOKIE_JAR="/tmp/.ctfd-cookies.out"

function usage() {
  echo -e "Usage: ./$SCRIPT_NAME
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

ARGS=("$@")

# Command to execute
COMMAND="${ARGS[0]:-gen}"

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
    --data-raw '{}'
  )
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
    failure "Please navigate to the multi-juicer instance and create a new team to deploy a new instance, then re-run this script once the instance is ready."
    exit 1
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
      --write-out "%{http_code}"
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
      --write-out "%{redirect_url}"
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
      -F "nonce=$_CTFD_NONCE"
  )
  
  if [ ! "$SETUP_RES_STATUS_CODE" -eq 200 ]; then
    failure "Failed to configure CTFd automatically. Please navigate to $_CTFD_URL to set up the instance manually."
    return 1
  fi
  success
}

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

function run() {
  # Generate challenges CSV
  if ! juice_shop_instance_exists; then
    create_juice_shop_instance && success
  fi
  wait_for_instance
  create_tunnel_to_pod && success 
  write_config_to_file && success
  run_cli && success
  cleanup && success
  info "DONE"
}

case "$COMMAND" in
  "-h" | "--help")
    usage
    ;;
  "gen" | "generate")
    run
    ;;
  *)
    failure "Invalid argument '$COMMAND'\n"
    usage
    ;;
esac
