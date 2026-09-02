# Uses command = plan so validation runs without creating resources.
# Mock providers keep the test cost-free and offline.

mock_provider "aws" {
  # The aws_iam_policy_document data source feeds assume_role_policy, which
  # rejects the mock's default (non-JSON) value. Return a valid JSON policy.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # The cert_validation record's for_each keys derive from the ACM certificate's
  # computed domain_validation_options. Override the resource so those values
  # are known at plan time and the for_each can resolve.
  override_resource {
    target          = aws_acm_certificate.this
    override_during = plan
    values = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/abcd1234-ef56-7890-ab12-cd34ef567890"
      domain_validation_options = [
        {
          domain_name           = "id.example.com"
          resource_record_name  = "_acme.id.example.com."
          resource_record_type  = "CNAME"
          resource_record_value = "_validation.acm-validations.aws."
        }
      ]
    }
  }

  # The HTTPS listener validates certificate_arn as a real ARN; supply one so
  # the plan does not fail on the mock's generated placeholder.
  override_resource {
    target          = aws_acm_certificate_validation.this
    override_during = plan
    values = {
      certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/abcd1234-ef56-7890-ab12-cd34ef567890"
    }
  }
}

mock_provider "random" {}

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
