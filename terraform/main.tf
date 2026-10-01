terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {}

data "azuread_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}"
  location = var.location
}

resource "azuread_group" "admins" {
  display_name     = "${var.project}-admins"
  security_enabled = true
}

resource "azuread_group" "readers" {
  display_name     = "${var.project}-readers"
  security_enabled = true
}

resource "azuread_group_member" "current_user_admin" {
  group_object_id  = azuread_group.admins.object_id
  member_object_id = data.azuread_client_config.current.object_id
}

resource "azurerm_public_ip" "main" {
  name                = "${var.dns_label}-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.dns_label
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = var.dns_label

  role_based_access_control_enabled = true
  local_account_disabled            = false

  default_node_pool {
    name       = "system"
    vm_size    = var.node_vm_size
    node_count = var.node_count
    zones      = var.node_zones
  }

  identity {
    type = "SystemAssigned"
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azuread_client_config.current.tenant_id
    admin_group_object_ids = [azuread_group.admins.object_id]
    azure_rbac_enabled     = true
  }
}

resource "azurerm_role_assignment" "admins_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_group.admins.object_id
}

resource "azurerm_role_assignment" "readers_reader" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Reader"
  principal_id         = azuread_group.readers.object_id
}

# Affectation directe, independante du jeton AAD en cache qui ne contient pas encore le nouveau groupe
resource "azurerm_role_assignment" "current_user_cluster_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azuread_client_config.current.object_id
}

# Identite du control plane, pas kubelet. Sans elle le Service LoadBalancer reste en Pending
resource "azurerm_role_assignment" "control_plane_network_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}
