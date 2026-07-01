# Keycloak on AWS (Off-EC2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Keycloak on AWS as a cheap dev/demo IdP using ECS Fargate + RDS PostgreSQL behind an ALB, with a Terraform-managed realm and Cognito SAML client — no EC2.

**Architecture:** A flat root Terraform configuration consumes an existing VPC/subnets and stands up: ACM (DNS-validated) + Route53 + ALB → ECS Fargate (official Keycloak container) → RDS PostgreSQL. Secrets Manager holds admin and DB credentials. A separate `keycloak.tf` uses the Keycloak provider to create the realm + Cognito SAML client in a documented stage-2 apply.

**Tech Stack:** Terraform ~> 1.15, AWS provider ~> 5.0, Keycloak provider (`keycloak/keycloak` ~> 5.0), `random` provider, official `quay.io/keycloak/keycloak` container image, PostgreSQL 16.

## Global Constraints

- **Scope:** dev/demo only — NOT production-hardened. Single Fargate task, single-AZ RDS, dev-friendly teardown.
- **Networking is consumed, never created:** VPC and subnets come from variables (`vpc_id`, `public_subnet_ids`, `private_subnet_ids`). Do NOT create VPC/subnets/NAT/IGW.
- **Terraform binary:** `~> 1.15`. AWS provider pinned major: `~> 5.0`. Keycloak provider: `~> 5.0`. `random` provider: `~> 3.6`.
- **Secrets:** never plaintext vars. Use Secrets Manager + `random_password`. Mark sensitive outputs `sensitive = true`.
- **Security groups:** no `0.0.0.0/0` ingress except HTTP:80-redirect and only where `allowed_cidrs` is explicitly supplied. RDS reachable only from the Fargate SG.
- **Encryption:** RDS `storage_encrypted = true`.
- **Naming:** singleton resources named `"this"`; descriptive names (`"alb"`, `"fargate"`, `"rds"`) where multiple of a type exist. Tag keys/values kebab-case. Use `default_tags` on the AWS provider.
- **Block ordering:** `count`/`for_each` → required args → optional args → `tags` → `depends_on` → `lifecycle`. Variables: `description` → `type` → `default` → `validation` → `nullable`.
- **Layout deviation:** guidelines default to `modules/`+`envs/`; this project intentionally uses a FLAT ROOT config (single demo, no reuse). Documented in the spec.
- **Keycloak URL:** `https://<domain_name>` everywhere (KC_HOSTNAME, outputs, provider endpoint).
- **Per-task verification:** every task ends with `terraform fmt -check`, `terraform validate`, and (where present) `terraform test`. `tflint` / `trivy config .` run before commits where installed; note if unavailable.

**Spec:** `docs/superpowers/specs/2026-07-01-keycloak-on-aws-serverless-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `providers.tf` | terraform block, provider version constraints, AWS + random providers, `default_tags` |
| `variables.tf` | all input variables |
| `locals.tf` | computed name prefix, common tags, derived values |
| `secrets.tf` | `random_password` + Secrets Manager secrets (admin, DB) |
| `network.tf` | security groups only (ALB, Fargate, RDS) |
| `rds.tf` | DB subnet group + RDS PostgreSQL instance |
| `alb.tf` | ACM cert + validation, Route53 records, ALB, target group, listeners |
| `iam.tf` | ECS task execution role + task role |
| `ecs.tf` | CloudWatch log group, ECS cluster, task definition, service |
| `outputs.tf` | URLs, secret ARN, metadata URL, ALB DNS, RDS endpoint |
| `keycloak.tf` | Keycloak provider + realm + Cognito SAML client (stage-2) |
| `tests/variables.tftest.hcl` | native `terraform test` for variable validation |
| `terraform.tfvars.example` | sample inputs (committed; real `*.tfvars` gitignored) |
| `README.md` | prerequisites, two-stage apply, Cognito + AD/LDAP setup, cost notes |

Task order builds bottom-up so each task is independently `validate`-able: providers/vars → secrets → SGs → RDS → ALB → IAM → ECS → outputs → keycloak → tests → README.

---

### Task 1: Providers, Variables, and Locals

**Files:**
- Create: `providers.tf`, `variables.tf`, `locals.tf`, `terraform.tfvars.example`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: all `var.*` inputs, `local.name_prefix`, `local.tags` used by every later task. Variable names are exactly: `aws_region`, `name_prefix`, `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `domain_name`, `route53_zone_id`, `allowed_cidrs`, `keycloak_image_tag`, `db_instance_class`, `db_allocated_storage`, `db_engine_version`, `realm_name`, `cognito_acs_url`, `cognito_sp_entity_id`, `log_retention_days`, `tags`.

- [ ] **Step 1: Write `providers.tf`**

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
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      managed-by = "terraform"
      project    = "keycloak-on-aws"
    }
  }
}

# Configured with the ALB endpoint + bootstrap admin creds. Only usable in the
# stage-2 apply, after the Fargate service is healthy. See keycloak.tf / README.
provider "keycloak" {
  client_id = "admin-cli"
  username  = local.keycloak_admin_username
  password  = random_password.keycloak_admin.result
  url       = "https://${var.domain_name}"
}
```

- [ ] **Step 2: Write `variables.tf`**

```hcl
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to resource names and Name tags."
  type        = string
  default     = "keycloak"
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
  description = "FQDN for Keycloak, e.g. keycloak.example.com. Must be within the Route53 hosted zone."
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

variable "keycloak_image_tag" {
  description = "Tag of the official quay.io/keycloak/keycloak image."
  type        = string
  default     = "26.0"
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

variable "realm_name" {
  description = "Name of the Keycloak realm created in the stage-2 apply."
  type        = string
  default     = "demo"
}

variable "cognito_acs_url" {
  description = "Cognito SAML assertion consumer service URL. Placeholder allowed until Cognito exists."
  type        = string
  default     = "https://example.auth.us-east-1.amazoncognito.com/saml2/idpresponse"
}

variable "cognito_sp_entity_id" {
  description = "Cognito SAML service-provider entity ID (urn:amazon:cognito:sp:<user-pool-id>). Placeholder allowed."
  type        = string
  default     = "urn:amazon:cognito:sp:us-east-1_EXAMPLE"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Keycloak container."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags merged into all resources."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 3: Write `locals.tf`**

```hcl
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
```

- [ ] **Step 4: Write `terraform.tfvars.example`**

```hcl
aws_region         = "us-east-1"
name_prefix        = "keycloak"
vpc_id             = "vpc-0123456789abcdef0"
public_subnet_ids  = ["subnet-aaa1", "subnet-aaa2"]
private_subnet_ids = ["subnet-bbb1", "subnet-bbb2"]
domain_name        = "keycloak.example.com"
route53_zone_id    = "Z0123456789ABCDEFGHIJ"
allowed_cidrs      = ["203.0.113.4/32"]
```

- [ ] **Step 5: Init and validate**

Run: `terraform init -backend=false && terraform fmt -check && terraform validate`
Expected: providers install; `validate` reports "Success! The configuration is valid." (References to `random_password.keycloak_admin` resolve once Task 2 exists — if validating Task 1 alone, temporarily expect an "unresolved reference" and proceed; it is satisfied after Task 2. To validate Task 1 in isolation, comment out the `keycloak` provider block's `password`/`username` lines, then restore in Task 2.)

- [ ] **Step 6: Commit**

```bash
git add providers.tf variables.tf locals.tf terraform.tfvars.example
git commit -m "feat: add providers, variables, and locals"
```

---

### Task 2: Secrets (admin + DB credentials)

**Files:**
- Create: `secrets.tf`

**Interfaces:**
- Consumes: `local.name_prefix`, `local.tags`, `local.keycloak_admin_username`.
- Produces: `random_password.keycloak_admin`, `random_password.db`, `aws_secretsmanager_secret.keycloak_admin`, `aws_secretsmanager_secret.db`. Later tasks read `aws_secretsmanager_secret.keycloak_admin.arn` and `aws_secretsmanager_secret.db.arn` (JSON secrets with keys `username`/`password`).

- [ ] **Step 1: Write `secrets.tf`**

```hcl
resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "keycloak_admin" {
  name        = "${local.name_prefix}-admin"
  description = "Keycloak bootstrap admin credentials."

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = jsonencode({
    username = local.keycloak_admin_username
    password = random_password.keycloak_admin.result
  })
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${local.name_prefix}-db"
  description = "RDS PostgreSQL master credentials for Keycloak."

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "keycloak"
    password = random_password.db.result
  })
}
```

- [ ] **Step 2: Validate**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid." The `keycloak` provider reference to `random_password.keycloak_admin.result` now resolves.

- [ ] **Step 3: Commit**

```bash
git add secrets.tf
git commit -m "feat: add Secrets Manager secrets for admin and DB credentials"
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
  description = "Keycloak ALB ingress."
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
  description = "Keycloak Fargate tasks."
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
  description = "Keycloak RDS ingress."
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
- Produces: `aws_db_instance.this`. Later tasks read `aws_db_instance.this.address`, `.port`, and DB name `keycloak`.

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

  db_name  = "keycloak"
  username = "keycloak"
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
- Consumes: `var.domain_name`, `var.route53_zone_id`, `var.vpc_id`, `var.public_subnet_ids`, `aws_security_group.alb.id`, `local.container_port`, `local.management_port`, `local.name_prefix`, `local.tags`.
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

resource "aws_lb_target_group" "this" {
  name        = "${local.name_prefix}-tg"
  port        = local.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path     = "/health/ready"
    port     = local.management_port
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
- Consumes: `aws_secretsmanager_secret.keycloak_admin.arn`, `aws_secretsmanager_secret.db.arn`, `local.name_prefix`, `local.tags`.
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
      aws_secretsmanager_secret.keycloak_admin.arn,
      aws_secretsmanager_secret.db.arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# Task role: Keycloak needs no AWS API access; role kept minimal for clarity.
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
- Consumes: `var.keycloak_image_tag`, `var.domain_name`, `var.private_subnet_ids`, `var.aws_region`, `var.log_retention_days`, `aws_iam_role.task_execution.arn`, `aws_iam_role.task.arn`, `aws_security_group.fargate.id`, `aws_lb_target_group.this.arn`, `aws_lb_listener.https`, `aws_db_instance.this.address`/`.port`, `aws_secretsmanager_secret.keycloak_admin.arn`, `aws_secretsmanager_secret.db.arn`, `local.container_port`, `local.management_port`.
- Produces: `aws_ecs_service.this`. Terminal compute resource; nothing downstream depends on it except the stage-2 Keycloak provider (runtime dependency, not a Terraform reference).

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
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "keycloak"
      image     = "quay.io/keycloak/keycloak:${var.keycloak_image_tag}"
      essential = true
      command   = ["start"]

      portMappings = [
        { containerPort = local.container_port, protocol = "tcp" },
        { containerPort = local.management_port, protocol = "tcp" },
      ]

      environment = [
        { name = "KC_DB", value = "postgres" },
        { name = "KC_DB_URL", value = "jdbc:postgresql://${aws_db_instance.this.address}:${aws_db_instance.this.port}/keycloak" },
        { name = "KC_DB_USERNAME", value = "keycloak" },
        { name = "KC_HOSTNAME", value = "https://${var.domain_name}" },
        { name = "KC_PROXY_HEADERS", value = "xforwarded" },
        { name = "KC_HTTP_ENABLED", value = "true" },
        { name = "KC_HEALTH_ENABLED", value = "true" },
      ]

      secrets = [
        { name = "KC_DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db.arn}:password::" },
        { name = "KEYCLOAK_ADMIN", valueFrom = "${aws_secretsmanager_secret.keycloak_admin.arn}:username::" },
        { name = "KEYCLOAK_ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.keycloak_admin.arn}:password::" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "keycloak"
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
    container_name   = "keycloak"
    container_port   = local.container_port
  }

  # Allow Keycloak time to start and pass health checks before the ALB
  # considers the task unhealthy.
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
git commit -m "feat: add ECS cluster, Keycloak task definition, and service"
```

---

### Task 8: Outputs

**Files:**
- Create: `outputs.tf`

**Interfaces:**
- Consumes: `aws_lb.this.dns_name`, `aws_db_instance.this.address`, `aws_secretsmanager_secret.keycloak_admin.arn`, `var.domain_name`, `var.realm_name`.
- Produces: outputs `keycloak_url`, `admin_console_url`, `admin_credentials_secret_arn`, `realm_saml_metadata_url`, `alb_dns_name`, `rds_endpoint`.

- [ ] **Step 1: Write `outputs.tf`**

```hcl
output "keycloak_url" {
  description = "Base Keycloak URL."
  value       = "https://${var.domain_name}"
}

output "admin_console_url" {
  description = "Keycloak admin console URL."
  value       = "https://${var.domain_name}/admin/"
}

output "admin_credentials_secret_arn" {
  description = "Secrets Manager ARN holding the Keycloak admin username/password."
  value       = aws_secretsmanager_secret.keycloak_admin.arn
}

output "realm_saml_metadata_url" {
  description = "SAML IdP metadata URL for the realm; paste into Cognito."
  value       = "https://${var.domain_name}/realms/${var.realm_name}/protocol/saml/descriptor"
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

### Task 9: Keycloak Realm and Cognito SAML Client (stage-2)

**Files:**
- Create: `keycloak.tf`

**Interfaces:**
- Consumes: `var.realm_name`, `var.cognito_acs_url`, `var.cognito_sp_entity_id`, the `keycloak` provider (configured in Task 1).
- Produces: `keycloak_realm.this`, `keycloak_saml_client.cognito`. These only apply successfully in the stage-2 apply (after Fargate is healthy).

- [ ] **Step 1: Write `keycloak.tf`**

```hcl
# STAGE-2 RESOURCES.
# These require the Keycloak service to be running and reachable at
# https://<domain_name>. Apply infra first (stage 1), then apply these:
#   terraform apply                                  # stage 1: everything else
#   terraform apply -target=keycloak_realm.this \
#                   -target=keycloak_saml_client.cognito   # stage 2
# See README "Two-stage apply".

resource "keycloak_realm" "this" {
  realm   = var.realm_name
  enabled = true
}

resource "keycloak_saml_client" "cognito" {
  realm_id  = keycloak_realm.this.id
  client_id = var.cognito_sp_entity_id
  name      = "cognito"
  enabled   = true

  sign_documents          = true
  sign_assertions         = true
  include_authn_statement = true

  valid_redirect_uris = [var.cognito_acs_url]

  assertion_consumer_post_url = var.cognito_acs_url

  name_id_format = "email"
}
```

- [ ] **Step 2: Validate (schema only — no apply without a live server)**

Run: `terraform fmt -check && terraform validate`
Expected: "Success! The configuration is valid." NOTE: `terraform plan`/`apply` against these resources requires a reachable Keycloak; that happens only in the real stage-2 apply. If the exact attribute names differ in Keycloak provider `~> 5.0`, consult `terraform providers schema -json` — the required fields are `realm_id`, `client_id`; the ACS URL argument may be named `assertion_consumer_post_url` (verify against the installed provider version and adjust).

- [ ] **Step 3: Commit**

```bash
git add keycloak.tf
git commit -m "feat: add Keycloak realm and Cognito SAML client (stage-2)"
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
mock_provider "keycloak" {}

variables {
  aws_region         = "us-east-1"
  vpc_id             = "vpc-123"
  public_subnet_ids  = ["subnet-a", "subnet-b"]
  private_subnet_ids = ["subnet-c", "subnet-d"]
  domain_name        = "keycloak.example.com"
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
Expected: `3 passed, 0 failed`. If mock providers cannot resolve computed attributes used in resource args (e.g. cert validation `for_each`), those runs still exercise variable validation because validation happens before provider calls; if a run errors for a non-validation reason, narrow it with an override or `-verbose` and adjust the mock.

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
# 🔐 Keycloak on AWS (Off-EC2)

Deploy [Keycloak](https://www.keycloak.org/) as a dev/demo identity provider on
AWS using ECS Fargate + RDS PostgreSQL behind an Application Load Balancer — no
EC2 instances to manage. Terraform also provisions a realm and a SAML client for
federating with Amazon Cognito.

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
  chosen FQDN (e.g. `keycloak.example.com`).

This project does **not** create networking — you supply `vpc_id`,
`public_subnet_ids`, `private_subnet_ids`.

## 🚀 Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit values
terraform init

# Stage 1 — infrastructure (ALB, Fargate, RDS, cert, DNS)
terraform apply

# Wait until the service is healthy (see "Two-stage apply"), then:
# Stage 2 — Keycloak realm + Cognito SAML client
terraform apply -target=keycloak_realm.this -target=keycloak_saml_client.cognito
```

Retrieve the admin password:

```bash
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw admin_credentials_secret_arn)" \
  --query SecretString --output text | jq .
```

Open the admin console at the `admin_console_url` output and log in as `admin`.

## 🔁 Two-stage apply (why)

The Keycloak Terraform provider configures Keycloak over its REST API, so it can
only run **after** the Fargate service is up and reachable at
`https://<domain_name>`. Terraform cannot natively wait for ALB health, so:

1. **Stage 1:** `terraform apply` creates all infrastructure. The
   `keycloak_realm`/`keycloak_saml_client` resources will error if applied now —
   that's expected; use `-target` to exclude them, or apply and let only those
   two fail, then continue.
2. **Wait** for the ECS service to reach a healthy target in the ALB target group
   (check the ECS console or `aws elbv2 describe-target-health`). First boot also
   creates the database schema.
3. **Stage 2:** `terraform apply -target=keycloak_realm.this -target=keycloak_saml_client.cognito`.
   Subsequent `terraform apply` (no `-target`) will then work cleanly.

## 🔗 Configure Amazon Cognito (SAML federation)

Keycloak is the SAML **IdP**; Cognito is the **SP**. After stage 2:

1. Get the realm SAML metadata URL: `terraform output -raw realm_saml_metadata_url`.
2. In the Cognito User Pool → **Sign-in experience → Federated identity provider
   sign-in → Add identity provider → SAML**.
3. Set the metadata document via the URL from step 1.
4. Note the User Pool's **SP entity ID** (`urn:amazon:cognito:sp:<pool-id>`) and
   the **ACS URL** (`https://<domain>.auth.<region>.amazoncognito.com/saml2/idpresponse`).
5. Set `cognito_sp_entity_id` and `cognito_acs_url` in `terraform.tfvars` to those
   real values and re-run stage 2 so the Keycloak SAML client matches.
6. Map SAML attributes (email, name) in Cognito to user-pool attributes.
7. Create test users directly in the Keycloak realm (admin console → Users) and
   log in through the Cognito hosted UI to verify.

## 🗂️ Optional: AD/LDAP user federation

Not managed by Terraform. To source users from Active Directory/LDAP instead of
(or in addition to) local Keycloak users:

1. Admin console → your realm → **User federation → Add LDAP provider**.
2. Set the connection URL (`ldaps://...`), bind DN + credentials, users DN, and
   `Edit mode` (use `READ_ONLY` to mirror the RES sample).
3. Configure the username/RDN/UUID/object-class mappings for your directory.
4. **Test connection** and **Test authentication**, then **Save** and **Sync
   users**.

## 💲 Cost notes

Baseline runs even when idle: RDS `db.t4g.micro` (~$12–15/mo), one Fargate task
(0.5 vCPU/1 GB), and the ALB (~$16/mo + LCU). `terraform destroy` removes
everything (dev settings skip the final RDS snapshot).

## 🧪 Testing

```bash
terraform fmt -check
terraform validate
terraform test        # variable validation (mock providers, offline)
```

## 📄 License

See `LICENSE`.
````

- [ ] **Step 2: Verify README renders and commands are accurate**

Run: `terraform fmt -check && terraform validate`
Expected: still valid; confirm output names in the README match `outputs.tf` exactly (`admin_credentials_secret_arn`, `realm_saml_metadata_url`, `admin_console_url`).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README with prerequisites, two-stage apply, Cognito and LDAP setup"
```

---

## Self-Review

**1. Spec coverage:**

| Spec item | Task |
|-----------|------|
| Consume VPC/subnets via vars, no networking created | Task 1 (vars), Task 3/4/5/7 (consume) |
| Security groups (ALB/Fargate/RDS) | Task 3 |
| ALB + HTTPS listener + HTTP redirect + health check | Task 5 |
| ACM DNS-validated cert + Route53 alias | Task 5 |
| ECS Fargate cluster/task/service, Keycloak env config | Task 7 |
| CloudWatch logs, 7-day retention | Task 7 |
| RDS PostgreSQL db.t4g.micro, encrypted, dev teardown | Task 4 |
| Secrets Manager (admin + DB), random_password | Task 2 |
| IAM execution + task roles | Task 6 |
| Keycloak provider realm + Cognito SAML client, stage-2 | Task 9 |
| Outputs (URLs, secret ARN, metadata URL, endpoints) | Task 8 |
| Flat root layout | File Structure |
| README: prereqs, two-stage, Cognito, LDAP, cost | Task 11 |
| Variable validation testing | Task 10 |

No gaps.

**2. Placeholder scan:** No TBD/TODO/"add error handling". Cognito values are
intentional documented placeholders (spec allows). All code blocks are complete.

**3. Type consistency:** Resource names consistent across tasks —
`aws_db_instance.this` (`.address`/`.port`), `aws_lb_target_group.this.arn`,
`aws_security_group.{alb,fargate,rds}.id`, `aws_secretsmanager_secret.{keycloak_admin,db}.arn`,
`keycloak_realm.this` / `keycloak_saml_client.cognito`, `local.container_port` (8080),
`local.management_port` (9000). Container name `"keycloak"` matches between task
definition and service `load_balancer` block. DB name/username `keycloak`
consistent across secrets, RDS, and ECS env.

**Version-verify flags for the implementer** (noted inline in tasks):
- Task 9: confirm `keycloak_saml_client` argument names against provider `~> 5.0`
  (`terraform providers schema -json`).
- Task 1: `keycloak_image_tag` default `26.0` — confirm a current tag exists at
  build time.
- Task 4: `db_engine_version = "16"` — confirm PostgreSQL 16 is offered for
  `db.t4g.micro` in the target region.
