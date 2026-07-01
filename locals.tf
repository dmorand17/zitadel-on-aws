locals {
  name_prefix    = var.name_prefix
  container_port = 8080

  tags = merge(
    {
      environment = "dev"
      component   = "zitadel"
    },
    var.tags,
  )
}
