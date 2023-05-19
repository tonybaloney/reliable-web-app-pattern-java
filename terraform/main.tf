provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  // If an environment is set up (dev, test, prod...), it is used in the application name
  environment = var.environment == "" ? "dev" : var.environment
  telemetryId = "92141f6a-c03e-4141-bc1c-2113e4772c8d-${var.location}"
}

data "azurerm_client_config" "current" {}

//data "azuread_user" "current_user" {
//  object_id = data.azurerm_client_config.current.object_id
//}

resource "azurecaf_name" "resource_group" {
  name          = var.application_name
  resource_type = "azurerm_resource_group"
  suffixes      = [local.environment]
}

resource "azurerm_resource_group" "main" {
  name     = azurecaf_name.resource_group.result
  location = var.location

  tags = {
    "terraform"        = "true"
    "environment"      = local.environment
    "application-name" = var.application_name
    "nubesgen-version" = "0.13.0"
    "airsonic-version" = "1.0"
    "azd-env-name"     = var.application_name
  }
}

module "network" {
  source             = "./modules/network"
  resource_group     = azurerm_resource_group.main.name
  application_name   = var.application_name
  environment        = local.environment
  location           = var.location
}

module "app_insights" {
  source = "./modules/app-insights"
  resource_group     = azurerm_resource_group.main.name
  application_name   = var.application_name
  environment        = local.environment
  location           = var.location
}

module "storage" {
  source             = "./modules/storage"
  resource_group     = azurerm_resource_group.main.name
  application_name   = var.application_name
  environment        = local.environment
  location           = var.location
  virtual_network_id = module.network.vnet_id
  subnet_network_id  = module.network.app_subnet_id
}

module "postresql_database" {
  source                      = "./modules/postresql"
  azure_ad_tenant_id          = data.azurerm_client_config.current.tenant_id
  resource_group              = azurerm_resource_group.main.name
  application_name            = var.application_name
  environment                 = local.environment
  location                    = var.location
  virtual_network_id          = module.network.vnet_id
  subnet_network_id           = module.network.postgresql_subnet_id
  administrator_password      = var.database_administrator_password
  log_analytics_workspace_id  = module.app_insights.log_analytics_workspace_id
}

module "key-vault" {
  source           = "./modules/key-vault"
  resource_group   = azurerm_resource_group.main.name
  application_name = var.application_name
  environment      = local.environment
  location         = var.location

  log_analytics_workspace_id     = module.app_insights.log_analytics_workspace_id

  virtual_network_id         = module.network.vnet_id
  private_endpoint_subnet_id = module.network.private_endpoint_subnet_id

  network_acls = {
    bypass                     = "None"
    default_action             = "Deny"
    ip_rules                   = [local.myip]
    virtual_network_subnet_ids = [module.network.app_subnet_id]
  }

  azure_ad_tenant_id = data.azurerm_client_config.current.tenant_id
}

# For demo purposes, allow current user access to the key vault
resource azurerm_role_assignment kv_contributor_user_role_assignement {
  scope                 = module.key-vault.vault_id
  role_definition_name  = "Key Vault Contributor"
  principal_id          = data.azurerm_client_config.current.object_id
}
resource azurerm_role_assignment kv_administrator_user_role_assignement {
  scope                 = module.key-vault.vault_id
  role_definition_name  = "Key Vault Administrator"
  principal_id          = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "airsonic_database_admin" {
  name         = "airsonic-database-admin"
  value        = module.postresql_database.database_username
  key_vault_id = module.key-vault.vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource "azurerm_key_vault_secret" "airsonic_database_admin_password" {
  name         = "airsonic-database-admin-password"
  value        = var.database_administrator_password
  key_vault_id = module.key-vault.vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource "azurerm_key_vault_secret" "airsonic_application_client_secret" {
  name         = "airsonic-application-client-secret"
  value        = module.application.application_client_secret
  key_vault_id = module.key-vault.vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource "azurerm_key_vault_secret" "airsonic_cache_secret" {
  name         = "airsonic-redis-password"
  value        = module.cache.cache_secret
  key_vault_id = module.key-vault.vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

# Give the app access to the key vault secrets - https://learn.microsoft.com/azure/key-vault/general/rbac-guide?tabs=azure-cli#secret-scope-role-assignment
resource azurerm_role_assignment app_database_admin_rbac_assignment {
  scope                 = "${module.key-vault.vault_id}/secrets/${azurerm_key_vault_secret.airsonic_database_admin.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application.application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource azurerm_role_assignment app_database_admin_password_rbac_assignment {
  scope                 = "${module.key-vault.vault_id}/secrets/${azurerm_key_vault_secret.airsonic_database_admin_password.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application.application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource azurerm_role_assignment app_client_secret_rbac_assignment {
  scope                 = "${module.key-vault.vault_id}/secrets/${azurerm_key_vault_secret.airsonic_application_client_secret.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application.application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

resource azurerm_role_assignment app_redis_password_rbac_assignment {
  scope                 = "${module.key-vault.vault_id}/secrets/${azurerm_key_vault_secret.airsonic_cache_secret.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application.application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

# The application needs Key Vault Reader role in order to read the key vault meta data
resource azurerm_role_assignment app_key_vault_reader_rbac_assignment {
  scope                 = module.key-vault.vault_id
  role_definition_name  = "Key Vault Reader"
  principal_id          = module.application.application_principal_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement,
    azurerm_role_assignment.kv_administrator_user_role_assignement
  ]
}

module "cache" {
  source                      = "./modules/cache"
  resource_group              = azurerm_resource_group.main.name
  environment                 = local.environment
  location                    = var.location
  private_endpoint_vnet_id    = module.network.vnet_id
  private_endpoint_subnet_id  = module.network.private_endpoint_subnet_id
  log_analytics_workspace_id  = module.app_insights.log_analytics_workspace_id
}

module "application" {
  source             = "./modules/app-service"
  resource_group     = azurerm_resource_group.main.name
  application_name   = var.application_name
  environment        = local.environment
  location           = var.location
  subnet_id          = module.network.app_subnet_id

  app_insights_connection_string = module.app_insights.connection_string
  log_analytics_workspace_id     = module.app_insights.log_analytics_workspace_id

  database_id      = module.postresql_database.database_id
  database_fqdn    = module.postresql_database.database_fqdn
  database_name    = module.postresql_database.database_name

  redis_host       = module.cache.cache_hostname
  redis_port       = module.cache.cache_ssl_port

  key_vault_uri    = module.key-vault.vault_uri

  storage_account_name               = module.storage.storage_account_name
  storage_account_primary_access_key = module.storage.storage_primary_access_key

  frontdoor_host_name     = module.frontdoor.host_name
  frontdoor_profile_uuid  = module.frontdoor.resource_guid
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "airsonic-ad-admin" {
  server_name         = module.postresql_database.database_server_name
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = data.azurerm_client_config.current.object_id
  principal_name      = data.azurerm_client_config.current.object_id
  principal_type      = "User"
}

module "frontdoor" {
  source           = "./modules/frontdoor"
  resource_group   = azurerm_resource_group.main.name
  application_name = var.application_name
  environment      = local.environment
  location         = var.location
  host_name        = module.application.application_fqdn
  host_name2       = length(var.location2) > 0 ? module.application2[0].application_fqdn : ""
}

resource "azurerm_resource_group_template_deployment" "deploymenttelemetry" {
  count               = var.enable_telemetry ? 1 : 0
  name                = local.telemetryId
  resource_group_name = azurerm_resource_group.main.name
  deployment_mode     = "Incremental"
  
  template_content = <<TEMPLATE
  {
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {},
    "variables": {},
    "resources": []
  }
  TEMPLATE
}

data "http" "myip" {
  url = "http://whatismyip.akamai.com"
}

locals {
  myip = chomp(data.http.myip.body)
}

resource "azurerm_storage_account_network_rules" "airsonic-storage-network-rules" {
  storage_account_id = module.storage.storage_account_id

  default_action             = "Deny"
  virtual_network_subnet_ids = [module.network.app_subnet_id]
  ip_rules                   = [local.myip]

  depends_on = [
    module.storage
  ]
}

# Set Azure AD Application ID URI.
resource "null_resource" "setup-application-uri" {
  depends_on = [
    module.application
  ]

  provisioner "local-exec" {
    command = "az ad app update --id ${module.application.application_registration_id} --identifier-uris api://${module.application.application_registration_id}"
  }
}

resource "null_resource" "app_service_startup_script" {
  depends_on = [
    module.application
  ]

  provisioner "local-exec" {
    command = "az webapp deploy --name ${module.application.application_name} --resource-group ${azurerm_resource_group.main.name} --src-path scripts/startup.sh --type=startup"
  }
}

# ----------------------------------------------------------------------------------------------
#  Everything below this comment is for provisioning the 2nd region (if AZURE_LOCATION2 was set)
# ----------------------------------------------------------------------------------------------

#
# Create 2nd region resource group name by appending "s".
#
resource "azurecaf_name" "resource_group2" {
  name          = "${var.application_name}s"
  resource_type = "azurerm_resource_group"
  suffixes      = [local.environment]
}

#
# Create 2nd resource group.
#
resource "azurerm_resource_group" "main2" {
  count    = length(var.location2) > 0 ? 1 : 0
  name     = azurecaf_name.resource_group2.result
  location = var.location2

  tags = {
    "terraform"        = "true"
    "environment"      = local.environment
    "application-name" = var.application_name
    "nubesgen-version" = "0.13.0"
    "airsonic-version" = "1.0"
    "azd-env-name"     = var.application_name
  }
}

module "network2" {
  count              = length(var.location2) > 0 ? 1 : 0
  source             = "./modules/network"
  resource_group     = azurerm_resource_group.main2[0].name
  application_name   = var.application_name
  environment        = local.environment
  location           = var.location2
}

module "storage2" {
  count              = length(var.location2) > 0 ? 1 : 0
  source             = "./modules/storage"
  resource_group     = azurerm_resource_group.main2[0].name
  application_name   = "${var.application_name}s"
  environment        = local.environment
  location           = var.location2
  virtual_network_id = module.network2[0].vnet_id
  subnet_network_id  = module.network2[0].app_subnet_id
}

module "postresql_database2" {
  count                       = length(var.location2) > 0 ? 1 : 0
  source                      = "./modules/postresql"
  azure_ad_tenant_id          = data.azurerm_client_config.current.tenant_id
  resource_group              = azurerm_resource_group.main2[0].name
  application_name            = "${var.application_name}s"
  environment                 = local.environment
  location                    = var.location2
  virtual_network_id          = module.network2[0].vnet_id
  subnet_network_id           = module.network2[0].postgresql_subnet_id
  administrator_password      = var.database_administrator_password
  log_analytics_workspace_id  = module.app_insights.log_analytics_workspace_id
}

module "key-vault2" {
  count            = length(var.location2) > 0 ? 1 : 0
  source           = "./modules/key-vault"
  resource_group   = azurerm_resource_group.main2[0].name
  application_name = var.application_name
  environment      = local.environment
  location         = var.location2

  log_analytics_workspace_id     = module.app_insights.log_analytics_workspace_id

  virtual_network_id         = module.network2[0].vnet_id
  private_endpoint_subnet_id = module.network2[0].private_endpoint_subnet_id

  network_acls = {
    bypass                     = "None"
    default_action             = "Deny"
    ip_rules                   = [local.myip]
    virtual_network_subnet_ids = [module.network2[0].app_subnet_id]
  }

  azure_ad_tenant_id = data.azurerm_client_config.current.tenant_id
}

module "cache2" {
  count                       = length(var.location2) > 0 ? 1 : 0
  source                      = "./modules/cache"
  resource_group              = azurerm_resource_group.main2[0].name
  environment                 = local.environment
  location                    = var.location2
  private_endpoint_vnet_id    = module.network2[0].vnet_id
  private_endpoint_subnet_id  = module.network2[0].private_endpoint_subnet_id
  log_analytics_workspace_id  = module.app_insights.log_analytics_workspace_id
}

module "application2" {
  count               = length(var.location2) > 0 ? 1 : 0
  source              = "./modules/app-service"
  resource_group      = azurerm_resource_group.main2[0].name
  application_name    = "${var.application_name}s"
  environment         = local.environment
  location            = var.location2
  subnet_id           = module.network2[0].app_subnet_id

  app_insights_connection_string = module.app_insights.connection_string
  log_analytics_workspace_id     = module.app_insights.log_analytics_workspace_id

  database_id      = module.postresql_database2[0].database_id
  database_fqdn    = module.postresql_database2[0].database_fqdn
  database_name    = module.postresql_database2[0].database_name

  redis_host       = module.cache2[0].cache_hostname
  redis_port       = module.cache2[0].cache_ssl_port

  key_vault_uri    = module.key-vault2[0].vault_uri

  storage_account_name               = module.storage2[0].storage_account_name
  storage_account_primary_access_key = module.storage2[0].storage_primary_access_key

  frontdoor_host_name = module.frontdoor.host_name
  frontdoor_profile_uuid  = module.frontdoor.resource_guid
}

# For demo purposes, allow current user access to the key vault
resource azurerm_role_assignment kv_contributor_user_role_assignement2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = module.key-vault2[0].vault_id
  role_definition_name  = "Key Vault Contributor"
  principal_id          = data.azurerm_client_config.current.object_id
}
resource azurerm_role_assignment kv_administrator_user_role_assignement2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = module.key-vault2[0].vault_id
  role_definition_name  = "Key Vault Administrator"
  principal_id          = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "airsonic_database_admin2" {
  count        = length(var.location2) > 0 ? 1 : 0
  name         = "airsonic-database-admin"
  value        = module.postresql_database2[0].database_username
  key_vault_id = module.key-vault2[0].vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource "azurerm_key_vault_secret" "airsonic_database_admin_password2" {
  count        = length(var.location2) > 0 ? 1 : 0
  name         = "airsonic-database-admin-password"
  value        = var.database_administrator_password
  key_vault_id = module.key-vault2[0].vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource "azurerm_key_vault_secret" "airsonic_application_client_secret2" {
  count        = length(var.location2) > 0 ? 1 : 0
  name         = "airsonic-application-client-secret"
  value        = module.application2[0].application_client_secret
  key_vault_id = module.key-vault2[0].vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource "azurerm_key_vault_secret" "airsonic_cache_secret2" {
  count        = length(var.location2) > 0 ? 1 : 0
  name         = "airsonic-redis-password"
  value        = module.cache2[0].cache_secret
  key_vault_id = module.key-vault2[0].vault_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

# Give the app access to the key vault secrets - https://learn.microsoft.com/azure/key-vault/general/rbac-guide?tabs=azure-cli#secret-scope-role-assignment
resource azurerm_role_assignment app_database_admin_rbac_assignment2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = "${module.key-vault2[0].vault_id}/secrets/${azurerm_key_vault_secret.airsonic_database_admin.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application2[0].application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource azurerm_role_assignment app_database_admin_password_rbac_assignment2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = "${module.key-vault2[0].vault_id}/secrets/${azurerm_key_vault_secret.airsonic_database_admin_password.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application2[0].application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource azurerm_role_assignment app_client_secret_rbac_assignment2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = "${module.key-vault2[0].vault_id}/secrets/${azurerm_key_vault_secret.airsonic_application_client_secret.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application2[0].application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

resource azurerm_role_assignment app_redis_password_rbac_assignment2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = "${module.key-vault2[0].vault_id}/secrets/${azurerm_key_vault_secret.airsonic_cache_secret.name}"
  role_definition_name  = "Key Vault Secrets User"
  principal_id          = module.application2[0].application_principal_id

   depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}

# The application needs Key Vault Reader role in order to read the key vault meta data
resource azurerm_role_assignment app_key_vault_reader_rbac_assignment2 {
  count                 = length(var.location2) > 0 ? 1 : 0
  scope                 = module.key-vault2[0].vault_id
  role_definition_name  = "Key Vault Reader"
  principal_id          = module.application2[0].application_principal_id

  depends_on = [
    azurerm_role_assignment.kv_contributor_user_role_assignement2,
    azurerm_role_assignment.kv_administrator_user_role_assignement2
  ]
}
