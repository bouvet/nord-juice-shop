#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

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
    echo -e "Usage: ./$SCRIPT_NAME [JUICE-SHOP URL]
    "
    exit 0
}

function create_tunnel_to_pod() {
    # Forward traffic from this device to the juice-shop pod
    echo "Opening temporary tunnel to a juice-shop pod"
    # Get the name of a pod running an instance of juice-shop
    POD_NAME=$(kubectl get pods -l "app.kubernetes.io/name=juice-shop" -o name | head -1)
    if [ -z "$POD_NAME" ]; then
        echo "ERROR: In order to import the challenges from juice-shop, an instance of juice-shop must be running."
        echo "Please navigate to the multi-juicer instance and create a new team to deploy a new instance, then re-run this script once the instance is ready."
        exit 1
    fi
    (kubectl port-forward "$POD_NAME" "$_PORT_LOCAL:3000" &> /dev/null)&
    echo $! > "$_PIDFILE_PATH"
}

function write_config_to_file() {
    # Write temp. config to file, used by the juice-shop-ctf-cli
    echo "Writing juice-shop-ctf config to file"
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
    echo "Importing challenges from JuiceShop"
    _CTF_CHALLENGES_OUT_PATH="ctfd-challenges-$(date +%FT%H%M%S).zip"
    juice-shop-ctf --config "$_CTF_CFG_PATH" --output "$_CTF_CHALLENGES_OUT_PATH" && echo "Wrote CTFd challenges to '$_CTF_CHALLENGES_OUT_PATH'"
}

function cleanup() {
    echo "Cleaning up"
    # Delete temp config file
    rm "$_CTF_CFG_PATH"
    # Stop port forwarding
    kill -9 "$(cat $_PIDFILE_PATH)"
    # Delete pidfile
    rm "$_PIDFILE_PATH"
}

function main() {
    create_tunnel_to_pod
    write_config_to_file
    run_cli
    cleanup
    echo "DONE"
}

main
