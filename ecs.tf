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
