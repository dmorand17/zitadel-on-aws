# Empty S3 backend — configured per environment via `-backend-config`.
# See envs/<env>/backend.config for the bucket/key/region values.
terraform {
  backend "s3" {}
}
