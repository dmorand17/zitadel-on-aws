# Keycloak on AWS (Off-EC2) — Design

**Date:** 2026-07-01
**Status:** Approved design, pending implementation plan

## Purpose

Deploy Keycloak on AWS as a cheap dev/demo identity provider, off EC2 and off
instance management. Inspired by the RES demo CloudFormation template
(`aws-hpc-recipes/.../keycloak.yaml`), which ran Keycloak's dev server with an
embedded H2 database on a single EC2 instance. This project replaces that with a
managed, container-based deployment while keeping state persistent across
restarts.

**Scope:** dev/demo only. Not production-hardened (single task, single-AZ DB,
dev-friendly teardown settings).

## Why not truly "serverless"

Keycloak is a stateful, long-running Quarkus application — there is no
Lambda-style version. The practical "off-EC2" answer is **ECS Fargate** running
the official Keycloak container. This removes all instance management (no
patching, no SSH, no self-healing scripts) while remaining a supported way to
run Keycloak.

## Scope Decisions

- **RES-specific machinery dropped:** no AD/LDAP user federation, no user-sync or
  password-rotation cron jobs. Users are created directly in Keycloak.
- **Cognito SAML federation:** Keycloak acts as a SAML IdP for an *external*
  Cognito User Pool. This project manages the Keycloak side (realm + SAML client)
  only; the Cognito side is configured manually (documented in the README).
- **AD/LDAP:** not managed by Terraform. README documents how to add it manually
  in the admin console as an optional follow-on.
- **Networking is provided, not created:** the project consumes an existing VPC
  and subnets via variables. It does not create a VPC, subnets, NAT, or IGW.

## Architecture

```
Internet
   │
   ▼
Route53 A (alias) → [Application Load Balancer]  (public subnets)
                        │  HTTPS:443 (ACM cert, DNS-validated)
                        │  HTTP:80 → redirect to 443
                        ▼
                    [ECS Fargate service]  (private subnets, no public IP)
                        │  official quay.io/keycloak/keycloak container
                        ▼
                    [RDS PostgreSQL db.t4g.micro]  (private subnets, persistent)

Secrets Manager: Keycloak admin creds + DB master password
Terraform Keycloak provider → realm + Cognito SAML client (stage-2 apply)
```

### Networking (consumed, not created)

Inputs: `vpc_id`, `public_subnet_ids` (ALB), `private_subnet_ids` (Fargate + RDS).

Prerequisites (documented, not validated):
- Private subnets must have outbound internet access (NAT gateway or VPC
  endpoints) so Fargate can pull the container image and reach Secrets Manager.
- Public subnets must be internet-facing for the ALB.

### Security Groups

- **ALB SG:** ingress 443 from `allowed_cidrs`; ingress 80 (redirect only). Egress
  to Fargate SG.
- **Fargate SG:** ingress on container port 8080 from ALB SG only. Egress all
  (image pull, Secrets Manager, DB).
- **RDS SG:** ingress 5432 from Fargate SG only. No public access.

### Load Balancer & TLS

- Internet-facing ALB in `public_subnet_ids`.
- HTTPS listener (443) using the ACM cert → Keycloak target group.
- HTTP listener (80) → redirect to 443.
- Target group health check against Keycloak health endpoint (`/health/ready`).
- **ACM certificate:** `aws_acm_certificate` for `domain_name`, **DNS-validated**
  via `aws_route53_record` + `aws_acm_certificate_validation` in
  `route53_zone_id`. Publicly trusted, auto-renewing.
- **Route53:** alias A record for `domain_name` → ALB.

### Compute (ECS Fargate)

- One Fargate cluster (no EC2 capacity providers).
- Task definition: `quay.io/keycloak/keycloak:<pinned-tag>`, 0.5 vCPU / 1 GB.
  Container ports 8080 (HTTP) and 9000 (management/health). Command: `start`.
- Key config:
  - `KC_DB=postgres`, `KC_DB_URL`, `KC_DB_USERNAME`, `KC_DB_PASSWORD` (password
    from Secrets Manager).
  - `KC_HOSTNAME=https://<domain_name>`, `KC_PROXY_HEADERS=xforwarded`,
    `KC_HTTP_ENABLED=true` (standard behind a TLS-terminating ALB).
  - `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` (bootstrap admin) from Secrets
    Manager.
  - `KC_HEALTH_ENABLED=true` for ALB health checks.
- Service: desired count = 1 (dev/demo, no autoscaling). Runs in private subnets,
  registered to the ALB target group. Brief downtime on deploys is acceptable.
- Logging: CloudWatch Logs group, `awslogs` driver, ~7-day retention.
- IAM: execution role (pull image, read the two secrets, write logs); task role
  minimal/empty (Keycloak needs no AWS API access).
- Keycloak creates its schema in the empty RDS on first boot.

### Database (RDS PostgreSQL)

- `db.t4g.micro`, single-AZ, PostgreSQL (recent major version, pinned), ~20 GB
  gp3, `storage_encrypted = true`, not publicly accessible.
- DB subnet group across `private_subnet_ids`; RDS SG (5432 from Fargate only).
- Dev-only settings (flagged in README/comments): `skip_final_snapshot = true`,
  `deletion_protection = false`, backup retention ~1 day — so `terraform destroy`
  is clean.
- Purpose: persists realms, clients (incl. the Cognito SAML client), users,
  credentials, roles, and sessions across container restarts.

### Secrets Manager

- Two secrets: Keycloak admin credentials (username + password), and DB master
  password.
- Passwords generated via `random_password`, stored in the secrets, injected into
  the container as secret references. Nothing sensitive in plaintext Terraform.

### Keycloak realm + Cognito SAML client (Keycloak Terraform provider)

- Provider authenticates to `https://<domain_name>` using bootstrap admin creds.
- Creates: one realm (`realm_name`, default `demo`), and one **SAML client**
  representing Cognito, configured with `cognito_acs_url` and
  `cognito_sp_entity_id` (placeholders acceptable until Cognito exists).
- **Two-stage apply** (the one rough edge): the Keycloak provider can only run
  after the Fargate service is healthy, and Terraform cannot natively wait for
  ALB health. Keycloak-provider resources live in their own file (`keycloak.tf`)
  so stage 1 (infra) and stage 2 (Keycloak config) are cleanly separable via
  `-target` or a documented two-step. Documented in README.

## Variables (inputs)

- `vpc_id`, `public_subnet_ids`, `private_subnet_ids`
- `domain_name` (FQDN for Keycloak, e.g. `keycloak.example.com`)
- `route53_zone_id` (hosted zone for cert validation + alias record)
- `allowed_cidrs` (who can reach the ALB)
- `keycloak_image_tag`, `db_instance_class` (default `db.t4g.micro`),
  `realm_name` (default `demo`)
- `cognito_acs_url`, `cognito_sp_entity_id` (SAML client; placeholders allowed)
- `aws_region`, `name_prefix` / tags

## Outputs

- Keycloak URL (`https://<domain_name>`) and admin console URL
- Admin-credentials secret ARN
- Realm SAML IdP metadata URL (to paste into Cognito)
- ALB DNS name
- RDS endpoint

## File Layout (flat root configuration)

Single root Terraform configuration (no module wrapper — YAGNI for a single
domain-bound demo):

- `providers.tf` — AWS + Keycloak + tls providers
- `variables.tf`
- `network.tf` — security groups only (VPC/subnets are inputs)
- `alb.tf` — ALB, listeners, target group, ACM cert + validation, Route53 records
- `ecs.tf` — cluster, task definition, service, CloudWatch log group
- `rds.tf` — RDS instance + subnet group
- `secrets.tf` — Secrets Manager secrets + random passwords
- `iam.tf` — task execution / task roles
- `keycloak.tf` — provider-managed realm + SAML client (isolated for stage-2 apply)
- `outputs.tf`
- `README.md`

## README Contents

- Prerequisites (VPC/subnet egress requirements, existing hosted zone/domain).
- Two-stage apply instructions.
- Cognito SAML setup: create User Pool SAML IdP from the metadata URL, attribute
  mapping, ACS URL / SP entity ID values.
- Optional AD/LDAP federation: how to add it in the admin console (not
  Terraform-managed).
- Cost note and dev-only caveats.

## Verification

- `terraform validate` + `terraform plan` clean.
- Stage 1 apply → ALB healthy, admin console loads over HTTPS at `domain_name`,
  login with generated admin creds.
- Stage 2 apply → realm + SAML client exist; SAML metadata URL resolves.
- `terraform destroy` cleanly tears everything down.

## Non-Goals

- Production hardening (HA/multi-AZ, autoscaling, WAF, session replication).
- Creating networking (VPC/subnets/NAT).
- Managing the Cognito User Pool or AD/LDAP directory.
- A reusable Terraform module.
