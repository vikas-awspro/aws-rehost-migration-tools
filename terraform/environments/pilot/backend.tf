terraform {
  required_version = ">= 1.6"

  required_providers {
    aws  = { source = "hashicorp/aws",  version = ">= 5.30" }
    null = { source = "hashicorp/null", version = ">= 3.2"  }
  }

  backend "s3" {
    bucket         = "rehost-migration-tfstate-pilot"
    key            = "pilot/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "rehost-migration-tfstate-lock"
    encrypt        = true
    kms_key_id     = "alias/rehost-migration-tfstate"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "aws-rehost-migration-tools"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
