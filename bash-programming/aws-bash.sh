#!/bin/bash
# AWS Bash script to build AWS resources using AWS CLI commands instead of Terraform.
# Purpose intended is to assume bash and aws cli as infrastructure as code tool to build AWS resources.
# Networking Resources to be created: VPC, Subnets, Internet Gateway, Route Tables, Security Groups, IAM Roles and Policies and KMS.
# Elastic Compute Resources to be created: EC2 Instances with SSM tunnel that goes through it, no key pair, and no public IP.
# Database Resources to be created:  Aurora PostgreSQL Cluster with a single instance, and private subnets. No public access to the database, and no public IP. Database will be accessible only through the EC2 instance.







# Set AWS region
AWS_REGION="us-east-1"
AWS_PROFILE="default"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    print_status "AWS CLI found: $(aws --version)"
}

# Function to validate AWS credentials
validate_credentials() {
    if ! aws sts get-caller-identity --profile "$AWS_PROFILE" &> /dev/null; then
        print_error "AWS credentials are not configured properly."
        exit 1
    fi
    print_status "AWS credentials validated successfully."
}

# Function to create VPC
create_vpc() {
    local vpc_name="$1"
    local cidr_block="$2"
    
    print_status "Creating VPC: $vpc_name with CIDR: $cidr_block"
    
    vpc_id=$(aws ec2 create-vpc \
        --cidr-block "$cidr_block" \
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$vpc_name}]" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --query 'Vpc.VpcId' \
        --output text)
    
    if [ -z "$vpc_id" ]; then
        print_error "Failed to create VPC"
        return 1
    fi
    
    print_status "VPC created successfully with ID: $vpc_id"