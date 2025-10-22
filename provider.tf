###
# Depending on how you handle privledge escalation you will need to either uncomment line for role_arn and session_name
# or lines shared_credentials_file, and profile
###
provider "aws" {
    region = var.region
}