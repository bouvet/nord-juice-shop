#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

### Required variables ###
# Key used to generate the challenge flags. Should be rotated between CTF-events
CTF_KEY="${CTF_KEY:?Missing required environment variable.}"

# JuiceShop CLI command
_JUICESHOP_CLI_BINARY="juice-shop-ctf"
_JUICESHOP_CLI_PACKAGE="$_JUICESHOP_CLI_BINARY-cli"

# Check if juice-shop-ctf-cli is installed
if ! command -v "$_JUICESHOP_CLI_BINARY" &> /dev/null; then
  echo "Missing required dependency '$_JUICESHOP_CLI_BINARY'. Install it by running:"
  echo "npm install -g $_JUICESHOP_CLI_PACKAGE"
  exit 1
fi
# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
  echo "Missing required package kubectl."
  exit 1
fi

# Variables
_CTF_CFG_PATH="/tmp/juice-shop-cli-config.yaml"
_PORT_LOCAL="8808"
_PIDFILE_PATH="/tmp/.juice-shop-portforward.pid"
CTF_URL="http://localhost:$_PORT_LOCAL"

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
  _CTF_CHALLENGES_OUT_PATH="ctfd-challenges-$(date +%FT%H%M%S).csv"
  juice-shop-ctf --config "$_CTF_CFG_PATH" --output "$_CTF_CHALLENGES_OUT_PATH" && info "Wrote CTFd challenges to '$_CTF_CHALLENGES_OUT_PATH'. Upload this file to CTFd at https://$JUICE_FQDN/ctfd/admin/import"
}

function cleanup() {
  info "Cleaning up"
  # Delete temp config file
  rm "$_CTF_CFG_PATH"
  # Stop port forwarding
  kill -9 "$(cat $_PIDFILE_PATH)"
  # Delete pidfile
  rm "$_PIDFILE_PATH"
}

function run() {
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
