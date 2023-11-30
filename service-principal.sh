#! /usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")

### Required variables ###
# The subscription ID (required)
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:?Missing required environment variable.}"
# Name of the resource group (required)
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?Missing required environment variable.}"
# Name of the service principal (required)
AZURE_SERVICE_PRINCIPAL_NAME="${AZURE_SERVICE_PRINCIPAL_NAME:?Missing required environment variable.}"

### Default variables ###
# The Github repository in which the code is stored. Used to create a federated credential for the service principal. In the format <USER|ORGANIZATION>/<REPOSITORY_NAME>.
GIT_REPO=""

function usage() {
    echo -e "Usage: ./$SCRIPT_NAME COMMAND

    Commands:
        new\tCreate a new service principal
        wipe\tDelete the service principal
    "
    exit 0
}

function setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
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

warn() {
    echo >&2 -e "${ORANGE}  ${1:-}${NOFORMAT}"
}

failure() {
  echo >&2 -e "${RED}${1:-\tERROR}${NOFORMAT}"
}

ARGS=("$@")
[[ ${#ARGS[@]} -eq 0 ]] && usage

# Command to execute
COMMAND="${ARGS[0]}"

function create_app_registration() {
    info "Creating app registration '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Create the app registration
    az ad app create --display-name "$AZURE_SERVICE_PRINCIPAL_NAME"
}

function destroy_app_registration() {
    info "Deleting the app registration (and service principal) '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Get the app registration ID
    APP_ID=$(az ad app list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].id" -o tsv)

    # Delete the app registration
    az ad app delete --id "$APP_ID"
}

function create_service_principal() {
    info "Creating the service principal '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Get the app (client) ID
    APP_ID=$(az ad app list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].appId" -o tsv)

    # Create the service principal
    az ad sp create --id "$APP_ID"
}

function set_owners() {
    # Get the app (client) ID
    APP_ID=$(az ad app list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].appId" -o tsv)
    OBJECT_ID=$(az ad sp list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].id" -o tsv)

    info "Getting members from AAD group '$AZURE_ADMIN_AAD_GROUP'"
    # Gets the owners and converts the multiline output to an array
    SAVEIFS="$IFS"
    IFS=$'\n'
    OWNERS=($(az ad group member list -g "$AZURE_ADMIN_AAD_GROUP" --query "[].id" -o tsv))
    IFS="$SAVEIFS"

    info "Setting owners for service principal '$AZURE_SERVICE_PRINCIPAL_NAME' - will give Bad Request error if owner is already present"
    for OWNER in "${OWNERS[@]}"; do
        info "  owner with ID $OWNER"
        # Add owner to app registration
        az ad app owner add --id "$APP_ID" --owner-object-id "$OWNER"

        # Add owner to service principal, using rest as it is not yet supported in az cli
        az rest \
            --method POST \
            --uri 'https://graph.microsoft.com/beta/servicePrincipals/'"$OBJECT_ID"'/owners/\$ref' \
            --headers Content-Type=application/json \
            --body "{\"@odata.id\": \"https://graph.microsoft.com/beta/users/$OWNER\"}"
    done
}

function create_role_assignment() {
    info "Assigning role 'contributor' on resource group '$AZURE_RESOURCE_GROUP' to '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Get the service principal object ID
    SERVICE_PRINCIPAL_OBJECT_ID=$(az ad sp list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].id" -o tsv)

    # Create the role assignment
    az role assignment create \
        --role contributor \
        --assignee-object-id "$SERVICE_PRINCIPAL_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal \
        --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP"
}

function destroy_role_assignment() {
    info "Deleting the 'contributor' role assignment on '$AZURE_RESOURCE_GROUP' for '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Get the service principal object ID
    SERVICE_PRINCIPAL_OBJECT_ID=$(az ad sp list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].id" -o tsv)

    # Deleting the role assignment
    az role assignment delete \
        --role contributor \
        --assignee "$SERVICE_PRINCIPAL_OBJECT_ID" \
        --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP"
}

function create_federated_credential() {
    info "Creating federated credential for '$AZURE_SERVICE_PRINCIPAL_NAME'"

    if [ -z "$GIT_REPO" ]; then
        warn "WARNING: Unable to create federated credential due to missing variable 'GIT_REPO'."
    else
        # Get the app registration object ID
        APP_OBJECT_ID=$(az ad app list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].id" -o tsv)

        # Create the federated credential
        az rest --method POST \
            --uri "https://graph.microsoft.com/beta/applications/$APP_OBJECT_ID/federatedIdentityCredentials" \
            --body '{"name": "nord-juice-shop-main",'\
    '"issuer": "https://token.actions.githubusercontent.com",'\
    '"subject": "repo:'"$GIT_REPO"':ref:refs/heads/main",'\
    '"description": "main",'\
    '"audiences": ["api://AzureADTokenExchange"]}'
    fi
}

function print_app_registration_id() {
    info "Getting the app registration client ID for '$AZURE_SERVICE_PRINCIPAL_NAME'"
    # Get the app (client) ID
    APP_ID=$(az ad app list --filter "displayname eq '$AZURE_SERVICE_PRINCIPAL_NAME'" --query "[].appId" -o tsv)

    info "################################################################"
    info "## App client ID is '$APP_ID'    ##"
    info "## NB! Remember to update the GitHub secret 'AZURE_CLIENT_ID' ##"
    info "################################################################"
}

function new() {
    create_app_registration && success || failure
    create_service_principal && success || failure
    set_owners && success || failure
    create_role_assignment && success || failure
    create_federated_credential && success || failure
    print_app_registration_id
    info "DONE"
}

function wipe() {
    destroy_role_assignment && success || failure
    destroy_app_registration && success || failure
    info "DONE"
}

case "$COMMAND" in
    "-h" | "--help")
        usage
        ;;
    "new")
        new
        ;;
    "wipe")
        wipe
        ;;
    *)
        failure "Invalid argument '$COMMAND'\n"
        usage
        ;;
esac
