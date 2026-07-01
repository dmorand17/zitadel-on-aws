# Zitadel on AWS (Off-EC2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Zitadel on AWS as a cheap dev/demo IdP using ECS Fargate + RDS PostgreSQL behind an ALB, with a Terraform-managed project and Cognito OIDC application — no EC2.

**Architecture:** A flat root Terraform configuration consumes an existing VPC/subnets and stands up: ACM (DNS-validated) + Route53 + ALB → ECS Fargate (official Zitadel container) → RDS PostgreSQL. Secrets Manager holds the masterkey, admin, and DB credentials. A separate `zitadel.tf` uses the Zitadel provider to create the project + Cognito OIDC application in a documented stage-2 apply.

**Tech Stack:** Terraform ~> 1.15, AWS provider ~> 5.0, Zitadel provider (`zitadel/zitadel` ~> 2.0), `random` provider, official `ghcr.io/zitadel/zitadel` container image, PostgreSQL 16.

## Global Constraints

- **Scope:** dev/demo only — NOT production-hardened. Single Fargate task, single-AZ RDS, dev-friendly teardown.
- **Networking is consumed, never created:** VPC and subnets come from variables (`vpc_id`, `public_subnet_ids`, `private_subnet_ids`). Do NOT create VPC/subnets/NAT/IGW.
- **Terraform binary:** `~> 1.15`. AWS provider pinned major: `~> 5.0`. Zitadel provider: `~> 2.0`. `random` provider: `~> 3.6`.
- **Secrets:** never plaintext vars. Use Secrets Manager + `random_password`. Mark sensitive outputs `sensitive = true`. Zitadel masterkey MUST be exactly 32 characters.
- **Security groups:** no `0.0.0.0/0` ingress except HTTP:80-redirect and only where `allowed_cidrs` is explicitly supplied. RDS reachable only from the Fargate SG. Zitadel uses a SINGLE container port 8080 (HTTP + gRPC) — there is no separate management port.
- **Encryption:** RDS `storage_encrypted = true`.
- **Naming:** singleton resources named `"this"`; descriptive names (`"alb"`, `"fargate"`, `"rds"`) where multiple of a type exist. Tag keys/values kebab-case. Use `default_tags` on the AWS provider.
- **Block ordering:** `count`/`for_each` → required args → optional args → `tags` → `depends_on` → `lifecycle`. Variables: `description` → `type` → `default` → `validation` → `nullable`.
- **Layout deviation:** guidelines default to `modules/`+`envs/`; this project intentionally uses a FLAT ROOT config (single demo, no reuse). Documented in the spec.
- **Zitadel URL / issuer:** `https://<domain_name>` everywhere (ZITADEL_EXTERNALDOMAIN, outputs, provider endpoint). TLS terminates at the ALB: `ZITADEL_EXTERNALSECURE=true`, `ZITADEL_EXTERNALPORT=443`, container run with `--tlsMode external`.
- **Per-task verification:** every task ends with `terraform fmt -check`, `terraform validate`, and (where present) `terraform test`. `tflint` / `trivy config .` run before commits where installed; note if unavailable.

**Spec:** `docs/superpowers/specs/2026-07-01-zitadel-on-aws-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `providers.tf` | terraform block, provider version constraints, AWS + random + zitadel providers, `default_tags` |
| `variables.tf` | all input variables |
| `locals.tf` | computed name prefix, common tags, derived values |
| `secrets.tf` | `random_password` + Secrets Manager secrets (masterkey, admin, DB) |
| `network.tf` | security groups only (ALB, Fargate, RDS) |
| `rds.tf` | DB subnet group + RDS PostgreSQL instance |
| `alb.tf` | ACM cert + validation, Route53 records, ALB, target group, listeners |
| `iam.tf` | ECS task execution role + task role |
| `ecs.tf` | CloudWatch log group, ECS cluster, task definition, service |
| `outputs.tf` | URLs, secret ARNs, client ID, ALB DNS, RDS endpoint |
| `zitadel.tf` | Zitadel provider + project + Cognito OIDC application (stage-2) |
| `tests/variables.tftest.hcl` | native `terraform test` for variable validation |
| `terraform.tfvars.example` | sample inputs (committed; real `*.tfvars` gitignored) |
| `README.md` | prerequisites, two-stage apply, Cognito OIDC + LDAP setup, cost notes |

Task order builds bottom-up so each task is independently `validate`-able: providers/vars → secrets → SGs → RDS → ALB → IAM → ECS → outputs → zitadel → tests → README.

**Migration note:** Task 1 was already committed for the Keycloak variant (commit 2106c23). It is being revised, not created fresh — Task 1 below is a rewrite-in-place of `providers.tf`, `variables.tf`, `locals.tf`, `terraform.tfvars.example` to the Zitadel shape.

---

### Task 1: Providers, Variables, and Locals (rewrite for Zitadel)

**Files:**
- Modify (rewrite in place): `providers.tf`, `variables.tf`, `locals.tf`, `terraform.tfvars.example`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: all `var.*` inputs, `local.name_prefix`, `local.tags`, `local.container_port`. Variable names are exactly: `aws_region`, `name_prefix`, `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `domain_name`, `route53_zone_id`, `allowed_cidrs`, `zitadel_image_tag`, `db_instance_class`, `db_allocated_storage`, `db_engine_version`, `project_name`, `cognito_callback_url`, `log_retention_days`, `tags`.

- [ ] **Step 1: Overwrite `providers.tf`**

```hcl
terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed-by = "terraform"
      project    = "zitadel-on-aws"
    }
  }
}

# Configured against the ALB endpoint. Only usable in the stage-2 apply, after
# the Fargate service is healthy AND a service-user key exists. Authentication
# details (jwt_profile_file / PAT) are finalized in zitadel.tf / README.
# Left with the domain + insecure=false; credentials supplied at stage-2.
provider "zitadel" {
  domain           = var.domain_name
  insecure         = "false"
  port             = "443"
  jwt_profile_file = "zitadel-admin-sa.json"
}
```

NOTE: the `zitadel` provider block references a `jwt_profile_file` that is created
out-of-band during the stage-2 workflow (documented in the README). It is inert
during stage-1 plan/apply because no `zitadel_*` resources are targeted then.
Confirm the exact provider argument names against `zitadel/zitadel ~> 2.0`
(`terraform providers schema -json`) during implementation and adjust if needed.

- [ ] **Step 2: Overwrite `variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names and Name tags."
  type        = string
  default     = "zitadel"
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy into."
  type        = string
}

variable "public_subnet_ids" {
  description = "Existing internet-facing subnet IDs for the ALB (>= 2, different AZs)."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "Provide at least two public subnet IDs in different AZs for the ALB."
  }
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs for Fargate and RDS (>= 2, with egress via NAT or VPC endpoints)."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnet IDs in different AZs (RDS subnet group needs 2 AZs)."
  }
}

variable "domain_name" {
  description = "FQDN for Zitadel, e.g. id.example.com. Must be within the Route53 hosted zone."
  type        = string
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS validation and the alias record."
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach the ALB on HTTPS."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "Provide at least one CIDR block; do not leave the ALB open to 0.0.0.0/0 unintentionally."
  }
}

variable "zitadel_image_tag" {
  description = "Tag of the official ghcr.io/zitadel/zitadel image."
  type        = string
  default     = "v2.71.12"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB."
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "PostgreSQL engine major version."
  type        = string
  default     = "16"
}

variable "project_name" {
  description = "Name of the Zitadel project created in the stage-2 apply."
  type        = string
  default     = "demo"
}

variable "cognito_callback_url" {
  description = "Cognito OIDC callback (redirect) URL for the Zitadel OIDC app. Placeholder allowed until Cognito exists."
  type        = string
  default     = "https://example.auth.us-east-1.amazoncognito.com/oauth2/idpresponse"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Zitadel container."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags merged into all resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 3: Overwrite `locals.tf`**

```hcl
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
```

- [ ] **Step 4: Overwrite `terraform.tfvars.example`**

```hcl
aws_region         = "us-east-1"
name_prefix        = "zitadel"
vpc_id             = "vpc-0123456789abcdef0"
public_subnet_ids  = ["subnet-aaa1", "subnet-aaa2"]
private_subnet_ids = ["subnet-bbb1", "subnet-bbb2"]
domain_name        = "id.example.com"
route53_zone_id    = "Z0123456789ABCDEFGHIJ"
allowed_cidrs      = ["203.0.113.4/32"]
```

- [ ] **Step 5: Init and validate**

Run: `terraform init -backend=false && terraform fmt -check && terraform validate`
Expected: providers install (aws, random, zitadel); `validate` reports "Success! The configuration is valid." The `zitadel` provider block is self-contained (no cross-resource references), so validation passes with only Task 1 present.

- [ ] **Step 6: Commit**

```bash
git add providers.tf variables.tf locals.tf terraform.tfvars.example
git commit -m "refactor: retarget providers, variables, and locals to Zitadel"
```

---

### Task 2: Secrets (masterkey + admin + DB credentials)

**Files:**
- Create: `secrets.tf`

**Interfaces:**
- Consumes: `local.name_prefix`, `local.tags`.
- Produces: `random_password.masterkey` (32 chars), `random_password.admin`, `random_password.db`, and secrets `aws_secretsmanager_secret.masterkey`, `.admin`, `.db`. Later tasks read `.arn` of each. The `admin` secret JSON has keys `username`/`password`; the `db` secret JSON has keys `username`/`password`; the `masterkey` secret is a raw 32-char string.

- [ ] **Step 1: Write `secrets.tf`**

```hcl
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
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add secrets.tf
git commit -m "feat: add Secrets Manager secrets for masterkey, admin, and DB"
```

---

### Task 3: Security Groups

**Files:**
- Create: `network.tf`

**Interfaces:**
- Consumes: `var.vpc_id`, `var.allowed_cidrs`, `local.container_port`, `local.name_prefix`, `local.tags`.
- Produces: `aws_security_group.alb`, `aws_security_group.fargate`, `aws_security_group.rds`. Later tasks reference `.id` of each.

- [ ] **Step 1: Write `network.tf`**

```hcl
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
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add network.tf
git commit -m "feat: add ALB, Fargate, and RDS security groups"
```

---

### Task 4: RDS PostgreSQL

**Files:**
- Create: `rds.tf`

**Interfaces:**
- Consumes: `var.private_subnet_ids`, `var.db_instance_class`, `var.db_allocated_storage`, `var.db_engine_version`, `aws_security_group.rds.id`, `random_password.db.result`, `local.name_prefix`, `local.tags`.
- Produces: `aws_db_instance.this`. Later tasks read `aws_db_instance.this.address`, `.port`, and DB name `zitadel`.

- [ ] **Step 1: Write `rds.tf`**

```hcl
resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.tags, { Name = "${local.name_prefix}-db" })
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name_prefix}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "zitadel"
  username = "zitadel"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = false
  publicly_accessible    = false

  # Dev-only: friction-free teardown. Do NOT use these in production.
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-db" })
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add rds.tf
git commit -m "feat: add RDS PostgreSQL instance and subnet group"
```

---

### Task 5: ACM Certificate, Route53, and ALB

**Files:**
- Create: `alb.tf`

**Interfaces:**
- Consumes: `var.domain_name`, `var.route53_zone_id`, `var.vpc_id`, `var.public_subnet_ids`, `aws_security_group.alb.id`, `local.container_port`, `local.name_prefix`, `local.tags`.
- Produces: `aws_lb.this` (read `.dns_name`, `.zone_id`), `aws_lb_target_group.this` (read `.arn`), `aws_lb_listener.https`, `aws_acm_certificate_validation.this`. The ECS service (Task 7) attaches to `aws_lb_target_group.this.arn`.

- [ ] **Step 1: Write `alb.tf`**

```hcl
resource "aws_acm_certificate" "this" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = merge(local.tags, { Name = "${local.name_prefix}-alb" })
}

# Zitadel serves HTTP + gRPC on the single container port; a standard HTTP target
# group handles the console and OIDC endpoints. Health check uses /debug/healthz.
resource "aws_lb_target_group" "this" {
  name        = "${local.name_prefix}-tg"
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path     = "/debug/healthz"
    port     = "traffic-port"
    protocol = "HTTP"
    matcher  = "200"
  }

  tags = local.tags
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = local.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = local.tags
}

resource "aws_route53_record" "alb" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add alb.tf
git commit -m "feat: add ACM cert, Route53 records, and ALB with HTTPS listener"
```

---

### Task 6: IAM Roles

**Files:**
- Create: `iam.tf`

**Interfaces:**
- Consumes: `aws_secretsmanager_secret.masterkey.arn`, `aws_secretsmanager_secret.admin.arn`, `aws_secretsmanager_secret.db.arn`, `local.name_prefix`, `local.tags`.
- Produces: `aws_iam_role.task_execution` (read `.arn`), `aws_iam_role.task` (read `.arn`).

- [ ] **Step 1: Write `iam.tf`**

```hcl
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pulls the image, reads secrets, writes logs.
resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.masterkey.arn,
      aws_secretsmanager_secret.admin.arn,
      aws_secretsmanager_secret.db.arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# Task role: Zitadel needs no AWS API access; role kept minimal for clarity.
resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = local.tags
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add iam.tf
git commit -m "feat: add ECS task execution and task IAM roles"
```

---

### Task 7: ECS Cluster, Task Definition, and Service

**Files:**
- Create: `ecs.tf`

**Interfaces:**
- Consumes: `var.zitadel_image_tag`, `var.domain_name`, `var.private_subnet_ids`, `var.aws_region`, `var.log_retention_days`, `aws_iam_role.task_execution.arn`, `aws_iam_role.task.arn`, `aws_security_group.fargate.id`, `aws_lb_target_group.this.arn`, `aws_lb_listener.https`, `aws_db_instance.this.address`/`.port`, `aws_secretsmanager_secret.masterkey.arn`, `aws_secretsmanager_secret.admin.arn`, `aws_secretsmanager_secret.db.arn`, `local.container_port`, `local.name_prefix`.
- Produces: `aws_ecs_service.this`. Terminal compute resource; nothing downstream depends on it except the stage-2 Zitadel provider (runtime dependency, not a Terraform reference).

**IMPORTANT (verify during implementation):** confirm Zitadel env-var names and the `start-from-init` masterkey flag against the pinned image tag (`docker run --rm ghcr.io/zitadel/zitadel:<tag> start-from-init --help`). The masterkey can be passed via the `ZITADEL_MASTERKEY` env var instead of the `--masterkey` CLI flag; this plan uses the env var so it can be injected from Secrets Manager without embedding it in the command. Adjust names if the pinned version differs.

- [ ] **Step 1: Write `ecs.tf`**

```hcl
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.tags
}

resource "aws_ecs_cluster" "this" {
  name = local.name_prefix

  tags = local.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "zitadel"
      image     = "ghcr.io/zitadel/zitadel:${var.zitadel_image_tag}"
      essential = true
      command   = ["start-from-init", "--tlsMode", "external"]

      portMappings = [
        { containerPort = local.container_port, protocol = "tcp" },
      ]

      environment = [
        { name = "ZITADEL_EXTERNALDOMAIN", value = var.domain_name },
        { name = "ZITADEL_EXTERNALPORT", value = "443" },
        { name = "ZITADEL_EXTERNALSECURE", value = "true" },
        { name = "ZITADEL_PORT", value = tostring(local.container_port) },
        { name = "ZITADEL_DATABASE_POSTGRES_HOST", value = aws_db_instance.this.address },
        { name = "ZITADEL_DATABASE_POSTGRES_PORT", value = tostring(aws_db_instance.this.port) },
        { name = "ZITADEL_DATABASE_POSTGRES_DATABASE", value = "zitadel" },
        { name = "ZITADEL_DATABASE_POSTGRES_USER_USERNAME", value = "zitadel" },
        { name = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE", value = "require" },
        { name = "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME", value = "zitadel" },
        { name = "ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE", value = "require" },
        { name = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME", value = "zitadel-admin" },
      ]

      secrets = [
        { name = "ZITADEL_MASTERKEY", valueFrom = aws_secretsmanager_secret.masterkey.arn },
        { name = "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
        { name = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
        { name = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.admin.arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "zitadel"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_service" "this" {
  name            = local.name_prefix
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "zitadel"
    container_port   = local.container_port
  }

  # Allow Zitadel time to init the DB and pass health checks on first boot.
  health_check_grace_period_seconds = 180

  depends_on = [aws_lb_listener.https]

  tags = local.tags
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add ecs.tf
git commit -m "feat: add ECS cluster, Zitadel task definition, and service"
```

---

### Task 8: Outputs

**Files:**
- Create: `outputs.tf`

**Interfaces:**
- Consumes: `aws_lb.this.dns_name`, `aws_db_instance.this.address`, `aws_secretsmanager_secret.admin.arn`, `var.domain_name`.
- Produces: outputs `zitadel_url`, `issuer_url`, `console_url`, `admin_credentials_secret_arn`, `discovery_url`, `alb_dns_name`, `rds_endpoint`.

- [ ] **Step 1: Write `outputs.tf`**

```hcl
output "zitadel_url" {
  description = "Base Zitadel URL."
  value       = "https://${var.domain_name}"
}

output "issuer_url" {
  description = "OIDC issuer URL (enter into Cognito as the OIDC provider issuer)."
  value       = "https://${var.domain_name}"
}

output "console_url" {
  description = "Zitadel admin console URL."
  value       = "https://${var.domain_name}/ui/console"
}

output "discovery_url" {
  description = "OIDC discovery document URL."
  value       = "https://${var.domain_name}/.well-known/openid-configuration"
}

output "admin_credentials_secret_arn" {
  description = "Secrets Manager ARN holding the first-instance admin username/password."
  value       = aws_secretsmanager_secret.admin.arn
}

output "alb_dns_name" {
  description = "ALB DNS name (for the Route53 alias / debugging)."
  value       = aws_lb.this.dns_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint address."
  value       = aws_db_instance.this.address
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid."

- [ ] **Step 3: Commit**

```bash
git add outputs.tf
git commit -m "feat: add outputs for URLs, secret ARN, and endpoints"
```

---

### Task 9: Zitadel Project and Cognito OIDC Application (stage-2)

**Files:**
- Create: `zitadel.tf`

**Interfaces:**
- Consumes: `var.project_name`, `var.cognito_callback_url`, the `zitadel` provider (configured in Task 1).
- Produces: `zitadel_project.this`, `zitadel_application_oidc.cognito`. Read-only attributes `zitadel_application_oidc.cognito.client_id` and `.client_secret` (both sensitive) are consumed by the stage-2 outputs added here.

**Verify during implementation** (against `zitadel/zitadel ~> 2.0`, `terraform providers schema -json`):
- Whether `zitadel_project`/`zitadel_application_oidc` require an explicit `org_id`. If required, add a `data "zitadel_org" "default" {}` lookup and set `org_id = data.zitadel_org.default.id` on both resources. The v2 migration guide notes `org_id` became required on `zitadel_project_v2` — confirm which resource name the pinned provider exposes and use the current (non-deprecated) one.
- Confirm `auth_method_type`/`response_types`/`grant_types` enum values match the schema (values below come from the provider docs).

- [ ] **Step 1: Write `zitadel.tf`**

```hcl
# STAGE-2 RESOURCES.
# These require the Zitadel service to be running and reachable at
# https://<domain_name> AND a service-user key file (zitadel-admin-sa.json)
# present for the provider (see README "Two-stage apply"). Apply infra first,
# then apply these:
#   terraform apply                                        # stage 1
#   terraform apply -target=zitadel_project.this \
#                   -target=zitadel_application_oidc.cognito   # stage 2

resource "zitadel_project" "this" {
  name = var.project_name
}

# OIDC application representing the external Cognito User Pool. Cognito uses the
# authorization-code flow with a confidential (client-secret) web app.
resource "zitadel_application_oidc" "cognito" {
  project_id = zitadel_project.this.id
  name       = "cognito"

  redirect_uris    = [var.cognito_callback_url]
  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
}

output "cognito_oidc_client_id" {
  description = "Client ID for the Cognito OIDC application (enter into Cognito)."
  value       = zitadel_application_oidc.cognito.client_id
  sensitive   = true
}

output "cognito_oidc_client_secret" {
  description = "Client secret for the Cognito OIDC application (enter into Cognito)."
  value       = zitadel_application_oidc.cognito.client_secret
  sensitive   = true
}
```

- [ ] **Step 2: Validate (schema only — no apply without a live server)**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid." NOTE: `terraform plan`/`apply` against these resources requires a reachable Zitadel and the service-user key file; that happens only in the real stage-2 apply.

- [ ] **Step 3: Commit**

```bash
git add zitadel.tf
git commit -m "feat: add Zitadel project and Cognito OIDC application (stage-2)"
```

---

### Task 10: Variable Validation Tests

**Files:**
- Create: `tests/variables.tftest.hcl`

**Interfaces:**
- Consumes: the root module variables and their `validation` blocks.
- Produces: nothing consumed downstream; a `terraform test` suite.

- [ ] **Step 1: Write `tests/variables.tftest.hcl`**

```hcl
# Uses command = plan so validation runs without creating resources.
# Mock providers keep the test cost-free and offline.

mock_provider "aws" {}
mock_provider "random" {}
mock_provider "zitadel" {}

variables {
  aws_region         = "us-east-1"
  vpc_id             = "vpc-123"
  public_subnet_ids  = ["subnet-a", "subnet-b"]
  private_subnet_ids = ["subnet-c", "subnet-d"]
  domain_name        = "id.example.com"
  route53_zone_id    = "Z123"
  allowed_cidrs      = ["203.0.113.4/32"]
}

run "valid_inputs_plan_succeeds" {
  command = plan
}

run "rejects_single_public_subnet" {
  command = plan

  variables {
    public_subnet_ids = ["subnet-only-one"]
  }

  expect_failures = [var.public_subnet_ids]
}

run "rejects_empty_allowed_cidrs" {
  command = plan

  variables {
    allowed_cidrs = []
  }

  expect_failures = [var.allowed_cidrs]
}
```

- [ ] **Step 2: Run the test suite**

Run: `terraform test`
Expected: `3 passed, 0 failed`. Note: the `zitadel` provider block uses `jwt_profile_file = "zitadel-admin-sa.json"`; with `mock_provider "zitadel"` the file is not read during `plan`, so tests stay offline. If a run errors for a non-validation reason, narrow it with `-verbose` and adjust the mock.

- [ ] **Step 3: Commit**

```bash
git add tests/variables.tftest.hcl
git commit -m "test: add variable validation tests"
```

---

### Task 11: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything (documents the whole project).
- Produces: user-facing docs.

- [ ] **Step 1: Write `README.md`** (follow README guidelines: emoji section headers, copy-pasteable commands)

````markdown
# 🔐 Zitadel on AWS (Off-EC2)

Deploy [Zitadel](https://zitadel.com/) as a dev/demo identity provider on AWS
using ECS Fargate + RDS PostgreSQL behind an Application Load Balancer — no EC2
instances to manage. Terraform also provisions a project and an OIDC application
for federating with Amazon Cognito.

> **Dev/demo only.** Single Fargate task, single-AZ RDS, and friction-free
> teardown settings. Not production-hardened.

## 📋 Prerequisites

- Terraform `~> 1.15` and AWS credentials with permissions for ECS, RDS, ELBv2,
  ACM, Route53, IAM, Secrets Manager, and CloudWatch Logs.
- An **existing VPC** with:
  - At least 2 **public** subnets (internet-facing) for the ALB.
  - At least 2 **private** subnets with **outbound internet** (NAT gateway or VPC
    endpoints) for Fargate (image pull + Secrets Manager) and RDS.
- A **Route53 hosted zone** for the domain you'll use (e.g. `example.com`), and a
  chosen FQDN (e.g. `id.example.com`).

This project does **not** create networking — you supply `vpc_id`,
`public_subnet_ids`, `private_subnet_ids`.

## 🚀 Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit values
terraform init

# Stage 1 — infrastructure (ALB, Fargate, RDS, cert, DNS)
terraform apply

# Wait until the service is healthy (see "Two-stage apply"), then stage 2 below.
```

Retrieve the admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw admin_credentials_secret_arn)" \
  --query SecretString --output text | jq .
```

Open the console at the `console_url` output and log in as `zitadel-admin`.

## 🔁 Two-stage apply (why)

The Zitadel Terraform provider configures Zitadel over its API, so it can only
run **after** the Fargate service is up and reachable at `https://<domain_name>`.
Terraform cannot natively wait for ALB health, so:

1. **Stage 1:** `terraform apply` creates all infrastructure. The
   `zitadel_project`/`zitadel_application_oidc` resources will error if applied
   now — exclude them with `-target` on the ALB/ECS resources, or apply and let
   only those two fail, then continue.
2. **Wait** for the ECS service to reach a healthy target in the ALB target group
   (`aws elbv2 describe-target-health`). First boot also initializes the DB.
3. **Create a service user for the provider:** log into the console as
   `zitadel-admin`, create a Service User with Org Owner (or Instance) manager
   role, generate a **JSON key**, and save it as `zitadel-admin-sa.json` in the
   project directory (the path referenced by the `zitadel` provider block). This
   file is gitignored.
4. **Stage 2:** `terraform apply -target=zitadel_project.this -target=zitadel_application_oidc.cognito`.
   Subsequent `terraform apply` (no `-target`) will then work cleanly.

## 🔗 Configure Amazon Cognito (OIDC federation)

Zitadel is the OIDC **provider**; Cognito is the **relying party**. After stage 2:

1. Collect the values Cognito needs:
   - Issuer: `terraform output -raw issuer_url`
   - Client ID: `terraform output -raw cognito_oidc_client_id`
   - Client secret: `terraform output -raw cognito_oidc_client_secret`
2. In the Cognito User Pool → **Sign-in experience → Federated identity provider
   sign-in → Add identity provider → OpenID Connect (OIDC)**.
3. Enter the issuer URL, client ID, and client secret from step 1. Cognito reads
   the discovery document at `<issuer>/.well-known/openid-configuration`.
4. Set authorized scopes to `openid profile email`.
5. Note Cognito's callback URL
   (`https://<domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse`), set
   `cognito_callback_url` in `terraform.tfvars` to it, and re-run stage 2 so the
   Zitadel app's redirect URI matches.
6. Map OIDC claims (email, name) to Cognito user-pool attributes.
7. Create test users in the Zitadel console and log in through the Cognito hosted
   UI to verify.

## 🗂️ Optional: AD/LDAP identity provider

Not managed by Terraform. Zitadel can authenticate users against an existing
Active Directory / LDAP directory (inbound federation):

1. Console → your org → **Identity Providers → LDAP**.
2. Set the server URL (`ldaps://...`), bind DN + password, base DN, and the user
   filters / attribute mappings for your directory.
3. Configure creation/linking options, then save.
4. Users authenticate against LDAP; Zitadel brokers them to Cognito via the same
   OIDC app.

Note: Zitadel federates against LDAP inbound — it is not itself an LDAP server.

## 💲 Cost notes

Baseline runs even when idle: RDS `db.t4g.micro` (~$12–15/mo), one Fargate task
(0.25 vCPU/0.5 GB, ~$9/mo), and the ALB (~$16/mo + LCU). `terraform destroy`
removes everything (dev settings skip the final RDS snapshot).

## 🧪 Testing

```bash
terraform fmt -check
terraform validate
terraform test        # variable validation (mock providers, offline)
```

## 📄 License

See `LICENSE`.
````

- [ ] **Step 2: Verify README and add gitignore entry for the SA key**

Confirm output names in the README match `outputs.tf` and `zitadel.tf` exactly
(`admin_credentials_secret_arn`, `issuer_url`, `console_url`,
`cognito_oidc_client_id`, `cognito_oidc_client_secret`). Ensure `.gitignore`
excludes the service-account key:

Run: `grep -q 'zitadel-admin-sa.json' .gitignore || echo 'zitadel-admin-sa.json' >> .gitignore`
Then: `terraform fmt -check && terraform validate`
Expected: valid; `.gitignore` contains `zitadel-admin-sa.json`.

- [ ] **Step 3: Commit**

```bash
git add README.md .gitignore
git commit -m "docs: add README with prerequisites, two-stage apply, Cognito OIDC and LDAP setup"
```

---

## Self-Review

**1. Spec coverage:**

| Spec item | Task |
|-----------|------|
| Consume VPC/subnets via vars, no networking created | Task 1 (vars), Task 3/4/5/7 (consume) |
| Security groups (ALB/Fargate/RDS), single port 8080 | Task 3 |
| ALB + HTTPS listener + HTTP redirect + /debug/healthz health check | Task 5 |
| ACM DNS-validated cert + Route53 alias | Task 5 |
| ECS Fargate, Zitadel start-from-init, EXTERNAL* + masterkey config | Task 7 |
| CloudWatch logs, 7-day retention | Task 7 |
| RDS PostgreSQL db.t4g.micro, encrypted, dev teardown | Task 4 |
| Secrets Manager (masterkey 32-char + admin + DB), random_password | Task 2 |
| IAM execution (3 secrets) + task roles | Task 6 |
| Zitadel provider project + Cognito OIDC app, stage-2 | Task 9 |
| Outputs (issuer/console/discovery URLs, secret ARN, client id/secret, endpoints) | Task 8, Task 9 |
| Flat root layout | File Structure |
| README: prereqs, two-stage, Cognito OIDC, LDAP, cost | Task 11 |
| Variable validation testing | Task 10 |

No gaps.

**2. Placeholder scan:** No TBD/TODO/"add error handling". `cognito_callback_url`
is an intentional documented placeholder (spec allows). All code blocks complete.

**3. Type consistency:** Resource names consistent across tasks —
`aws_db_instance.this` (`.address`/`.port`), `aws_lb_target_group.this.arn`,
`aws_security_group.{alb,fargate,rds}.id`,
`aws_secretsmanager_secret.{masterkey,admin,db}.arn`, `zitadel_project.this` /
`zitadel_application_oidc.cognito`, `local.container_port` (8080, single port).
Container name `"zitadel"` matches between task definition and service
`load_balancer` block. DB name/username `zitadel` consistent across secrets, RDS,
and ECS env. Admin username `zitadel-admin` consistent between the admin secret
(Task 2) and `ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME` (Task 7).

**Version-verify flags for the implementer** (noted inline in tasks):
- Task 1/9: confirm `zitadel/zitadel ~> 2.0` provider auth args
  (`jwt_profile_file`) and whether `org_id` is required on project/app resources;
  use the current non-deprecated resource names.
- Task 7: confirm Zitadel env-var names and `start-from-init` masterkey handling
  against the pinned image tag; masterkey injected via `ZITADEL_MASTERKEY`.
- Task 1: `zitadel_image_tag` default `v2.71.12` — confirm a current tag exists.
- Task 4: `db_engine_version = "16"` — confirm PostgreSQL 16 is offered for
  `db.t4g.micro` in the target region.

**4. Migration note:** Task 1 is a rewrite-in-place of the already-committed
Keycloak Task 1; the branch was renamed to `feat/zitadel-on-aws-terraform`.
