locals {
  name_prefix             = var.name_prefix
  keycloak_admin_username = "admin"
  container_port          = 8080
  management_port         = 9000

  tags = merge(
    {
      environment = "dev"
      component   = "keycloak"
    },
    var.tags,
  )
}
