region      = "ap-south-1"
environment = "pilot"

# These reference resources in the Application VPC, provisioned separately
# (see the AWS Landing Zone repo).
target_app_subnet_id           = "subnet-replace-me"
target_app_sg_id               = "sg-replace-me"
target_db_subnet_group_name    = "app-db-subnet-group"
target_db_sg_id                = "sg-replace-me"
target_efs_sg_id               = "sg-replace-me"
target_fsx_active_directory_id = "d-replace-me"

on_prem_cidrs     = ["10.10.0.0/16"]
email_subscribers = []
