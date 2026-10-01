variable "subscription_id" {
  description = "Identifiant de la souscription Azure"
  type        = string
}

variable "location" {
  description = "Region Azure"
  type        = string
  default     = "francecentral"
}

variable "project" {
  description = "Prefixe des ressources et des groupes Entra ID"
  type        = string
  default     = "tp-steve-le-art-ce-l-heure"
}

variable "dns_label" {
  description = "Label DNS de l'IP publique, identique a l'annotation azure-dns-label-name du Service"
  type        = string
  default     = "steveleharceleur"
}

variable "node_vm_size" {
  description = "SKU des noeuds. Standard_D2s_v5 n'a aucun quota sur la souscription du TP"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "node_zones" {
  description = "Zones de disponibilite des noeuds. La zone 3 est restreinte sur la souscription du TP"
  type        = list(string)
  default     = ["1", "2"]
}

variable "node_count" {
  description = "Nombre de noeuds du pool systeme"
  type        = number
  default     = 3
}

variable "resource_group_name" {
  description = "Resource group existant, lu et jamais cree ni modifie par Terraform"
  type        = string
  default     = "msaidiRG"
}

variable "cluster_name" {
  description = "Nom du cluster AKS, prefixe pour le distinguer des autres TP du resource group"
  type        = string
  default     = "tp-steve-aks"
}

variable "node_resource_group_name" {
  description = "Node resource group fixe pour eviter une collision avec un autre AKS du meme resource group"
  type        = string
  default     = "MC-tp-steve-aks"
}
