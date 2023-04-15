terraform {
  required_version = "~>1.3.6"
  required_providers {
    aws = {
        source = "hashicorp/aws"
        version = "~>4.45.0"
    }
  }

  backend "s3" {
    bucket = "cloudmagic-terraform-state-bucket"
    key = "ecsapp/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "terraform_lock"
  }

}
provider "aws" {
  region = var.aws_region
}