#!/bin/bash
# AWS Bash script to build AWS resources using AWS CLI commands instead of Terraform.
# Purpose intended is to assume bash and aws cli as infrastructure as code tool to build AWS resources.
# Networking Resources to be created: VPC, Subnets, Internet Gateway, Route Tables, Security Groups, IAM Roles and Policies and KMS.
# Elastic Compute Resources to be created: EC2 Instances with SSM tunnel that goes through it, no key pair, and no public IP.
# Database Resources to be created:  Aurora PostgreSQL Cluster with a single instance, and private subnets. No public access to the database, and no public IP. Database will be accessible only through the EC2 instance.
                   #usage: ./bash-awsresources.sh <project> <environment> <region>

# project name and environment name are required parameters to be passed to the script. Region is optional, default is us-east-1.
project_name="$1"
environment_name="$2"
region="${3:-us-east-1}"  # Default region is us-east-1 if not provided

# define project name: project name is "programming" and environment name is "bash" and "python"
project_name="programming"
environment_name=(bash python)
# Define variables
env-lc=$(echo "$environment_name" | tr '[:upper:]' '[:lower:]')  # Convert environment name to lowercase
env-uc=$(echo "$environment_name" | tr '[:lower:]' '[:upper:]')  # Convert environment name to uppercase
project-lc=$(echo "$project_name" | tr '[:upper:]' '[:lower:]')  # Convert project name to lowercase
project-uc=$(echo "$project_name" | tr '[:lower:]' '[:upper:]')  # Convert project name to uppercase


set -euo pipefail

# Define logging functions
log()   { echo -e "\e[30;47m ${1} \e[0m ${@:2}"; }        # $1 background white
info()  { echo -e "\e[48;5;28m ${1} \e[0m ${@:2}"; }      # $1 background green
warn()  { echo -e "\e[48;5;202m ${1} \e[0m ${@:2}" >&2; } # $1 background orange
error() { echo -e "\e[48;5;196m ${1} \e[0m ${@:2}" >&2; } # $1 background red


# From https://patorjk.com/software/taag - big "slant" banner if figlet or pyfiglet is installed
figlet_or_echo() {
  if command -v figlet &>/dev/null; then figlet -f slant "$1"
  elif command python -c "import pyfiglet" &>/dev/null; then command python -m pyfiglet -f slant "$1"
  else echo "=== $1 ==="; fi
}

# banner [name] - prints the project banner, or the given name (e.g. `banner done`)
banner() {
    case $1:-$project_name in
        bash)    figlet_or_echo "Bash";;
        python)  figlet_or_echo "Python";;
        Networking) figlet_or_echo "Networking";;
        EC2)       figlet_or_echo "EC2";;
        Database)   figlet_or_echo "Database";;
        "done")    figlet_or_echo "Done";;
       
    esac
}

# AWS SSO login check (ensure_aws_login) aws sso login --profile wale.olayinka
profile_name="wale.olayinka"  # Replace with your AWS SSO profile name
ensure_aws_login() {
    if ! aws sts get-caller-identity &>/dev/null; then
        echo "You are not logged in to AWS. Please log in using AWS SSO."
        echo "Run the following command to log in:"
        echo "aws sso login --profile $profile_name"
        exit 1
    fi
}

# Create Networking Resources: VPC, Subnets, Internet Gateway, Route Tables, Security Groups, IAM Roles and Policies and KMS.
create_networking_resources() {
    local project_name="$1"
    local environment_name="$2"
    local region="$3"

    banner Networking
    info "--------------------------------------------------------------------"
    info "Creating Networking Resources for project: $project_name, environment: $environment_name, region: $region"
    info "--------------------------------------------------------------------"

 #   # Create VPC
    vpc_id=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region $region)  
    info "VPC created with ID: $vpc_id"
    # Create Subnets
    subnet_id=$(aws ec2 create-subnet --vpc-id $vpc_id --cidr-block 10.0.1.0/24 --availability-zone $region"a" --region $region)
    info "Subnet created with ID: $subnet_id"
    # Create Internet Gateway
    igw_id=$(aws ec2 create-internet-gateway --region $region)
    info "Internet Gateway created with ID: $igw_id"
    # Attach Internet Gateway to VPC
    aws ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id --region $region
    info "Internet Gateway attached to VPC"
    # Create Route Table
    route_table_id=$(aws ec2 create-route-table --vpc-id $vpc_id --region $region)
    info "Route Table created with ID: $route_table_id"
    # Create Security Group
    security_group_id=$(aws ec2 create-security-group --group-name "$project_name-$environment_name-sg" --description "Security group for $project_name-$environment_name" --vpc-id $vpc_id --region $region)
    info "Security Group created with ID: $security_group_id"
    # Create IAM Role
    iam_role_arn=$(aws iam create-role --role-name "$project_name-$environment_name-role" --assume-role-policy-document file://trust-policy.json --region $region)
    info "IAM Role created with ARN: $iam_role_arn"
    # Create KMS Key
    kms_key_id=$(aws kms create-key --description "KMS key for $project_name-$environment_name" --region $region)
    info "KMS Key created with ID: $kms_key_id"
    info "Networking Resources created successfully"
}

# Create EC2 Resources: EC2 Instances with SSM tunnel that goes through it, no key pair, and no public IP.
create_ec2_resources() {
    local project_name="$1"
    local environment_name="$2"
    local region="$3"

    banner EC2
    info "--------------------------------------------------------------------"
    info "Creating EC2 Resources for project: $project_name, environment: $environment_name, region: $region"
    info "--------------------------------------------------------------------"

    # Create EC2 Instance with SSM tunnel, no key pair, and no public IP
    ec2_instance_id=$(aws ec2 run-instances --image-id ami-0c55b159cbfafe1d0 --count 1 --instance-type t2.micro --security-group-ids $security_group_id --subnet-id $subnet_id --iam-instance-profile Name="$project_name-$environment_name-role" --region $region)
    info "EC2 Instance created with ID: $ec2_instance_id"
    info "EC2 Resources created successfully"
}

# Create Database Resources:  Aurora PostgreSQL Cluster with a single instance, and private subnets. No public access to the database, and no public IP. Database will be accessible only through the EC2 instance.
create_database_resources() {
    local project_name="$1"
    local environment_name="$2"
    local region="$3"

    banner Database
    info "--------------------------------------------------------------------"
    info "Creating Database Resources for project: $project_name, environment: $environment_name, region: $region"
    info "--------------------------------------------------------------------"

    # Create Aurora PostgreSQL Cluster with a single instance, and private subnets. No public access to the database, and no public IP. Database will be accessible only through the EC2 instance.
    aurora_cluster_id=$(aws rds create-db-cluster --engine aurora-postgresql --master-username postgres --master-user-password password --db-cluster-identifier "$project_name-$environment_name-aurora" --region $region)
    info "Aurora PostgreSQL Cluster created with ID: $aurora_cluster_id"
    info "Database Resources created successfully"
}

# Main execution
main() {
    ensure_aws_login
    create_networking_resources "$project_name" "$environment_name" "$region"
    create_database_resources "$project_name" "$environment_name" "$region"
    create_ec2_resources "$project_name" "$environment_name" "$region"
    banner done
}
main
