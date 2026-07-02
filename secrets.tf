# Zitadel masterkey: MUST be exactly 32 characters (encrypts secrets at rest).
resource "random_password" "masterkey" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "masterkey" {
  name        = "${local.name_prefix}-masterkey"
  description = "Zitadel masterkey (32 chars) for encrypting secrets at rest."

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "masterkey" {
  secret_id     = aws_secretsmanager_secret.masterkey.id
  secret_string = random_password.masterkey.result
}

resource "aws_secretsmanager_secret" "admin" {
  name        = "${local.name_prefix}-admin"
  description = "Zitadel first-instance admin credentials."

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    username = "zitadel-admin"
    password = random_password.admin.result
  })
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${local.name_prefix}-db"
  description = "RDS PostgreSQL master credentials for Zitadel."

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "zitadel"
    password = random_password.db.result
  })
}
