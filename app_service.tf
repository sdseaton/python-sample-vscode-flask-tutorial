variable "web_app_name" {
    type = string
    description = "name of the Azure web app"
    default = "testapp"
}

variable "docker_registry_name" {
    type = string
    description = "docker registry name in Azure, must be globally unique..."
    default = ""
}

variable "docker_image_name" {
    type = string
    description = "name of the docker image to run (including version) as webapp (name:version)"
}

variable "resource_group_location" {
    type = string
    default = "eastus"
}

variable "subscription" {
    type = string
}

# this bit is to help generate a globally unique ACR for each subscription webapp pair
resource "random_integer" "acr_id" {
    min = 100000
    max = 999999
    keepers = {
        subscription = "${var.subscription}"
        web_app_name = "${var.web_app_name}"
    }
}

# the final ACR name is either the one explicitly passed in or built up from the webapp name and a rand id
locals {
    unsafe_registry_name = var.docker_registry_name != "" ? var.docker_registry_name : join(
        "", ["${var.web_app_name}", "githubacr", "${random_integer.acr_id.result}"]
    )
    registry_name = replace(local.unsafe_registry_name, "-", "")
}


# Configure the Azure provider
provider "azurerm" {
    version = "~>2.0"
    subscription_id = var.subscription
    features {}
}

# to save terraform state to azure, configure this bit appropriately
# https://docs.microsoft.com/en-us/azure/developer/terraform/store-state-in-azure-storage
#terraform {
#  backend "azurerm" {
#    resource_group_name   = "tfstate"
#    storage_account_name  = "tfstate22894"
#    container_name        = "tfstate"
#    key                   = "terraform.tfstate"
#  }
#}

# Create the resources we need:
# - Resource group as a namespace for the app resources
# - ACR for the docker images
# - App service plan to back our webapp
# - App service to define our webapp
resource "azurerm_resource_group" "main" {
    name = "${var.web_app_name}-resources"
    location = var.resource_group_location
}

resource "azurerm_container_registry" "acr" {
  name                     = local.registry_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  sku                      = "Basic"
  admin_enabled            = true
}

resource "azurerm_app_service_plan" "main" {
    name                = "${var.web_app_name}-appserviceplan"
    location            = azurerm_resource_group.main.location
    resource_group_name = azurerm_resource_group.main.name
    kind                = "Linux"
    reserved            = true
    sku {
        tier = "Standard"
        size = "S1"
    }
}

resource "azurerm_app_service" "main" {
    name                = "${var.web_app_name}-appservice"
    location            = azurerm_resource_group.main.location
    resource_group_name = azurerm_resource_group.main.name
    app_service_plan_id = azurerm_app_service_plan.main.id

    # TODO: get this Managed Identity to have proper creds to the created ACR so we don't have to pass
    # admin creds through the app setting
    identity {
        type = "SystemAssigned"
    }

    site_config {
        app_command_line = ""
        linux_fx_version = "DOCKER|${azurerm_container_registry.acr.name}/${var.docker_image_name}"
        always_on        = true
    }

    # TODO: remove the admin username / password once we get managed identity assigned correct RBAC
    app_settings = {
        "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
        "DOCKER_REGISTRY_SERVER_URL"          = "https://${azurerm_container_registry.acr.login_server}"
        "DOCKER_REGISTRY_SERVER_USERNAME"     = "${azurerm_container_registry.acr.admin_username}"
        "DOCKER_REGISTRY_SERVER_PASSWORD"     = "${azurerm_container_registry.acr.admin_password}"
    }

    # This will be changed by GitHub action as it pushes new versions, terraform should ignore
    lifecycle {
        ignore_changes = [
            site_config
        ]
    }
}

data "azurerm_subscription" "current" {
}


# These next resources create scripts in the repo configured to create Service Principals for GitHub actions to push
# docker images to ACR and configure / restart the webapp on deploy
resource "local_file" "gh_actions_sp" {
    content = templatefile("${path.module}/.script_templates/gh_actions_sp.tpl", {
        subscription = data.azurerm_subscription.current.subscription_id,
        resource_group = azurerm_resource_group.main.name,
        app_service_name = azurerm_app_service.main.name
    })
    filename = "${path.module}/.generated_scripts/${terraform.workspace}/generate_service_principal_for_gh_actions.sh"
    file_permission = "0700"
}

resource "local_file" "gh_actions_acr_sp" {
    content = templatefile("${path.module}/.script_templates/gh_actions_acr_sp.tpl", {
        acr_name = azurerm_container_registry.acr.name
    })
    filename = "${path.module}/.generated_scripts/${terraform.workspace}/generate_service_principal_for_gh_actions_acr_push.sh"
    file_permission = "0700"
}

resource "local_file" "gh_actions_workflow" {
    content = templatefile("${path.module}/.script_templates/gh_actions_workflow.tpl", {
        web_app_name = var.web_app_name,
        app_service_name = azurerm_app_service.main.name,
        docker_image_name = var.docker_image_name,
        ds = "$",
        ob = "{{",
        cb = "}}"
    })
    filename = "${path.module}/.generated_scripts/${terraform.workspace}/.github/workflows/docker_webapp_deploy_to_azure.yml"
    file_permission = "0700"
}

# Output data for visibility
output "subscription" {
    value = data.azurerm_subscription.current.subscription_id
}

output "acr" {
    value = azurerm_container_registry.acr.login_server
}

output "resource_group" {
    value = azurerm_resource_group.main.name
}

output "app_name" {
    value = var.web_app_name
}
