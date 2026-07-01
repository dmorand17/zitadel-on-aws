# ALB: accepts HTTPS from allowed CIDRs and HTTP (redirect only).
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Zitadel ALB ingress."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS from allowed CIDR."
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP (redirected to HTTPS) from allowed CIDR."
}

resource "aws_vpc_security_group_egress_rule" "alb_to_fargate" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.fargate.id
  from_port                    = local.container_port
  to_port                      = local.container_port
  ip_protocol                  = "tcp"
  description                  = "To Fargate container port."
}

# Fargate: accepts container traffic from the ALB only; egress open for image
# pull, Secrets Manager, and DB.
resource "aws_security_group" "fargate" {
  name        = "${local.name_prefix}-fargate"
  description = "Zitadel Fargate tasks."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name_prefix}-fargate" })
}

resource "aws_vpc_security_group_ingress_rule" "fargate_from_alb" {
  security_group_id            = aws_security_group.fargate.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.container_port
  to_port                      = local.container_port
  ip_protocol                  = "tcp"
  description                  = "Container port from ALB."
}

resource "aws_vpc_security_group_egress_rule" "fargate_all" {
  security_group_id = aws_security_group.fargate.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress (image pull, Secrets Manager, DB)."
}

# RDS: accepts PostgreSQL from Fargate only.
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Zitadel RDS ingress."
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.name_prefix}-rds" })
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_fargate" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.fargate.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from Fargate."
}
