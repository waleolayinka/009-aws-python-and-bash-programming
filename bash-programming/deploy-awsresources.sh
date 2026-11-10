#!/usr/bin/env bash
#
# Provision AWS resources with Bash and the AWS CLI instead of Terraform.
#
# Purpose: test Bash + AWS CLI as an alternative to an IaC tool for building
# AWS infrastructure; see python-programming/ for the same stack in boto3.
#
# Resources created:
#   Networking: VPC (10.1.0.0/16), public/private subnets in two AZs, internet
#               gateway, per-AZ NAT gateways, route tables, security groups,
#               and a private Route 53 zone (db.internal).
#   Compute:    two private EC2 instances reachable only through SSM Session
#               Manager: no key pair, no public IP. IAM role/instance profile
#               and an encrypted S3 transfer bucket.
#   Database:   Aurora PostgreSQL cluster with two instances in private
#               subnets, not publicly accessible; reachable only from the EC2
#               security group. Credentials in Secrets Manager and SSM.

set -Eeuo pipefail

# Windows (Git Bash/MSYS) fixes for the native aws.exe/jq.exe:
#  - they end lines with CRLF; the stray \r ends up inside captured IDs/names and
#    AWS rejects them, so strip it at the source.
#  - Git Bash rewrites args that look like Unix paths (e.g. the SSM name
#    /bash/programming/database/password -> C:/Program Files/Git/bash/...); disable that for aws.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  aws() { MSYS_NO_PATHCONV=1 command aws "$@" | tr -d '\r'; }
  jq() { command jq "$@" | tr -d '\r'; }
fi

usage() {
  cat <<'USAGE'
Usage: deploy-awsresources.sh [project] [environment] [region]

Defaults: project=programming, environment=bash,
region=us-east-1. Set ADDITIONAL_RDS_SECURITY_GROUP_IDS to a comma-separated
list of existing security group IDs if other services need database access.
This provisions new resources; it is not safe to rerun against an existing
deployment, and resources created before a failure are not automatically removed.
USAGE
}

log() {
  printf '[%s] %s\n' "$1" "$2" >&2
}

die() {
  log ERROR "$1"
  exit 1
}

figlet_or_echo() {
  if command -v figlet >/dev/null 2>&1; then
    figlet -f slant "$1"
  elif command -v python >/dev/null 2>&1 && python -c "import pyfiglet" >/dev/null 2>&1; then
    python -m pyfiglet -f slant "$1"
  else
    printf '\n========== %s ==========\n' "$1"
  fi
}

banner() {
  printf '\n'
  figlet_or_echo "$1"
  printf '\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

project_name="${1:-programming}"
environment_name="${2:-bash}"
region="${3:-us-east-1}"
name_prefix="${environment_name}-${project_name}"

if [[ ! "$project_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ||
      ! "$environment_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  die "Project and environment must start with a letter or digit and contain only letters, digits, hyphens, or underscores."
fi

for command_name in aws jq; do
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

export AWS_DEFAULT_REGION="$region"
umask 077
work_dir="$(mktemp -d)"
# aws.exe cannot read Git Bash /tmp paths; use the C:/... form on Windows.
if command -v cygpath >/dev/null 2>&1; then work_dir="$(cygpath -m "$work_dir")"; fi
trap 'rm -rf "$work_dir"' EXIT
trap 'status=$?; log ERROR "Deployment failed at line ${BASH_LINENO[0]:-unknown} (exit ${status}). Resources already created in AWS were not rolled back."; exit "$status"' ERR

ensure_aws_login() {
  if ! account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
    die "AWS credentials are unavailable or expired. Authenticate with AWS CLI/SSO, then rerun."
  fi
  [[ -n "$account_id" && "$account_id" != "None" ]] || die "Could not determine the AWS account ID."
  log INFO "Deploying to account ${account_id} in ${region}."
}

tag_specification() {
  local resource_type="$1"
  local resource_name="$2"
  jq -cn --arg type "$resource_type" --arg name "$resource_name" \
    '[{ResourceType:$type,Tags:[{Key:"Name",Value:$name}]}]'
}

instance_tag_specification() {
  local resource_name="$1"
  jq -cn \
    --arg name "$resource_name" \
    --arg environment "$environment_name" \
    --arg project "$project_name" \
    '[{ResourceType:"instance",Tags:[
      {Key:"Name",Value:$name},
      {Key:"env",Value:$environment},
      {Key:"project_name",Value:$project}
    ]}]'
}

create_networking_resources() {
  banner "Networking Resources"
  log INFO "Creating VPC, public/private subnets, per-AZ NAT gateways, routing, and private DNS."

  vpc_id="$(aws ec2 create-vpc \
    --cidr-block 10.1.0.0/16 \
    --tag-specifications "$(tag_specification vpc "${name_prefix}-vpc")" \
    --query Vpc.VpcId --output text)"
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$vpc_id" --enable-dns-hostnames '{"Value":true}'

  local azs=("${region}a" "${region}b")
  local public_cidrs=("10.1.1.0/24" "10.1.3.0/24")
  local private_cidrs=("10.1.2.0/24" "10.1.4.0/24")
  local public_subnet_ids=()
  local private_subnet_ids=()
  local nat_gateway_ids=()
  local index

  for index in 0 1; do
    public_subnet_ids[index]="$(aws ec2 create-subnet \
      --vpc-id "$vpc_id" \
      --cidr-block "${public_cidrs[index]}" \
      --availability-zone "${azs[index]}" \
      --tag-specifications "$(tag_specification subnet "${name_prefix}-public-${azs[index]}")" \
      --query Subnet.SubnetId --output text)"
    aws ec2 modify-subnet-attribute \
      --subnet-id "${public_subnet_ids[index]}" \
      --map-public-ip-on-launch '{"Value":true}'

    private_subnet_ids[index]="$(aws ec2 create-subnet \
      --vpc-id "$vpc_id" \
      --cidr-block "${private_cidrs[index]}" \
      --availability-zone "${azs[index]}" \
      --tag-specifications "$(tag_specification subnet "${name_prefix}-private-${azs[index]}")" \
      --query Subnet.SubnetId --output text)"
    aws ec2 modify-subnet-attribute \
      --subnet-id "${private_subnet_ids[index]}" \
      --map-public-ip-on-launch '{"Value":false}'
  done

  local internet_gateway_id
  internet_gateway_id="$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tag_specification internet-gateway "${name_prefix}-igw")" \
    --query InternetGateway.InternetGatewayId --output text)"
  aws ec2 attach-internet-gateway --internet-gateway-id "$internet_gateway_id" --vpc-id "$vpc_id"

  local public_route_table_id
  public_route_table_id="$(aws ec2 create-route-table \
    --vpc-id "$vpc_id" \
    --tag-specifications "$(tag_specification route-table "${name_prefix}-public-route-table-public-rtb")" \
    --query RouteTable.RouteTableId --output text)"
  aws ec2 create-route \
    --route-table-id "$public_route_table_id" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$internet_gateway_id" >/dev/null

  for index in 0 1; do
    aws ec2 associate-route-table \
      --route-table-id "$public_route_table_id" \
      --subnet-id "${public_subnet_ids[index]}" >/dev/null

    local allocation_id
    allocation_id="$(aws ec2 allocate-address \
      --domain vpc \
      --tag-specifications "$(tag_specification elastic-ip "${name_prefix}-nat-${azs[index]}")" \
      --query AllocationId --output text)"
    nat_gateway_ids[index]="$(aws ec2 create-nat-gateway \
      --allocation-id "$allocation_id" \
      --subnet-id "${public_subnet_ids[index]}" \
      --tag-specifications "$(tag_specification natgateway "${name_prefix}-nat-gateway-${azs[index]}")" \
      --query NatGateway.NatGatewayId --output text)"
    aws ec2 wait nat-gateway-available --nat-gateway-ids "${nat_gateway_ids[index]}"

    local private_route_table_id
    private_route_table_id="$(aws ec2 create-route-table \
      --vpc-id "$vpc_id" \
      --tag-specifications "$(tag_specification route-table "${name_prefix}-private-route-table-${azs[index]}")" \
      --query RouteTable.RouteTableId --output text)"
    aws ec2 create-route \
      --route-table-id "$private_route_table_id" \
      --destination-cidr-block 0.0.0.0/0 \
      --nat-gateway-id "${nat_gateway_ids[index]}" >/dev/null
    aws ec2 associate-route-table \
      --route-table-id "$private_route_table_id" \
      --subnet-id "${private_subnet_ids[index]}" >/dev/null
  done

  local hosted_zone_name="${project_name}-${environment_name}-postgresql.db.internal"
  local hosted_zone_id
  hosted_zone_id="$(aws route53 create-hosted-zone \
    --name db.internal \
    --caller-reference "$(date +%s)-$$-${RANDOM}" \
    --hosted-zone-config "Comment=Stable database names for ${name_prefix},PrivateZone=true" \
    --vpc "VPCRegion=${region},VPCId=${vpc_id}" \
    --query HostedZone.Id --output text)"
  hosted_zone_id="${hosted_zone_id##*/}"
  aws route53 change-tags-for-resource \
    --resource-type hostedzone \
    --resource-id "$hosted_zone_id" \
    --add-tags "Key=Name,Value=${name_prefix}-db-internal"

  printf '%s\n' "$vpc_id" >"$work_dir/vpc_id"
  printf '%s\n' "${public_subnet_ids[@]}" >"$work_dir/public_subnet_ids"
  printf '%s\n' "${private_subnet_ids[@]}" >"$work_dir/private_subnet_ids"
  printf '%s\n' "$hosted_zone_id" >"$work_dir/hosted_zone_id"
}

create_compute_resources() {
  local vpc_id="$1"
  local private_subnet_id="$2"
  banner "Compute Resources"
  log INFO "Creating the SSM instance role/profile, transfer bucket, security group, and two private EC2 instances."

  local role_name="${name_prefix}-ec2-ssm-role"
  local profile_name="${name_prefix}-ec2-ssm-instance-profile"
  local bucket_name="${project_name}-${environment_name}-ssm-transfer-${account_id}"

  jq -cn '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Service:"ec2.amazonaws.com"},
      Action:"sts:AssumeRole"
    }]
  }' >"$work_dir/ec2-trust-policy.json"
  aws iam create-role \
    --role-name "$role_name" \
    --assume-role-policy-document "file://$work_dir/ec2-trust-policy.json" \
    --tags "Key=Name,Value=${environment_name}-${project_name}-SSMRole" >/dev/null
  aws iam create-instance-profile \
    --instance-profile-name "$profile_name" \
    --tags "Key=Name,Value=${profile_name}" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$profile_name" \
    --role-name "$role_name"

  local policy_arn
  for policy_arn in \
    arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    arn:aws:iam::aws:policy/AmazonSSMFullAccess \
    arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM \
    arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy; do
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
  done

  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket_name" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$bucket_name" \
      --create-bucket-configuration "LocationConstraint=${region}" >/dev/null
  fi
  aws s3api put-public-access-block \
    --bucket "$bucket_name" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption \
    --bucket "$bucket_name" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  local bucket_policy_arn
  jq -cn --arg bucket "arn:aws:s3:::${bucket_name}" '{
    Version:"2012-10-17",
    Statement:[
      {Effect:"Allow",Action:["s3:GetEncryptionConfiguration","s3:GetBucketLocation"],Resource:$bucket},
      {Effect:"Allow",Action:["s3:GetObject","s3:PutObject"],Resource:($bucket+"/*")}
    ]
  }' >"$work_dir/ssm-transfer-policy.json"
  bucket_policy_arn="$(aws iam create-policy \
    --policy-name "${name_prefix}-ssm-transfer-bucket-access" \
    --policy-document "file://$work_dir/ssm-transfer-policy.json" \
    --query Policy.Arn --output text)"
  aws iam attach-role-policy --role-name "$role_name" --policy-arn "$bucket_policy_arn"

  local ec2_security_group_id
  ec2_security_group_id="$(aws ec2 create-security-group \
    --group-name "${name_prefix}-ec2-sg" \
    --description "Security group for EC2 instances in the ASG" \
    --vpc-id "$vpc_id" \
    --tag-specifications "$(tag_specification security-group "${name_prefix}-EC2SecurityGroup")" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress \
    --group-id "$ec2_security_group_id" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress \
    --group-id "$ec2_security_group_id" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null

  cat >"$work_dir/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash -e
sudo yum update -y amazon-ssm-agent python3
sudo systemctl enable --now amazon-ssm-agent
BOOTSTRAP
  jq -cn \
    --arg subnet "$private_subnet_id" \
    --arg group "$ec2_security_group_id" \
    '[{DeviceIndex:0,SubnetId:$subnet,Groups:[$group],AssociatePublicIpAddress:false,DeleteOnTermination:true}]' \
    >"$work_dir/network-interface.json"

  local instance_ids=()
  local instance_index instance_id
  for instance_index in 1 2; do
    instance_id="$(aws ec2 run-instances \
      --image-id ami-0de716d6197524dd9 \
      --count 1 \
      --instance-type t2.micro \
      --iam-instance-profile "Name=${profile_name}" \
      --network-interfaces "file://$work_dir/network-interface.json" \
      --user-data "file://$work_dir/bootstrap.sh" \
      --tag-specifications "$(instance_tag_specification "${name_prefix}-ec2-${instance_index}")" \
      --query 'Instances[0].InstanceId' --output text)"
    instance_ids+=("$instance_id")
  done

  printf '%s\n' "$ec2_security_group_id" >"$work_dir/ec2_security_group_id"
  printf '%s\n' "${instance_ids[@]}" >"$work_dir/instance_ids"
  log INFO "EC2 instances launched: ${instance_ids[*]}"
}

create_database_resources() {
  local vpc_id="$1"
  local hosted_zone_id="$2"
  local ec2_security_group_id="$3"
  local private_subnet_ids=()
  local subnet_id
  while IFS= read -r subnet_id; do
    private_subnet_ids+=("$subnet_id")
  done <"$work_dir/private_subnet_ids"
  banner "Database Resources"
  log INFO "Creating the private Aurora PostgreSQL cluster, credentials, and internal DNS record."

  local db_subnet_group="${name_prefix}-rds-dbsubnet-group"
  aws rds create-db-subnet-group \
    --db-subnet-group-name "$db_subnet_group" \
    --db-subnet-group-description "Private database subnets for ${name_prefix}" \
    --subnet-ids "${private_subnet_ids[@]}" \
    --tags "Key=Name,Value=My DB Subnet Group in ${name_prefix}" >/dev/null

  local db_security_group_id
  db_security_group_id="$(aws ec2 create-security-group \
    --group-name "${name_prefix}-rds-sg" \
    --description "Security group for RDS instances" \
    --vpc-id "$vpc_id" \
    --tag-specifications "$(tag_specification security-group "${name_prefix}-RDSSecurityGroup")" \
    --query GroupId --output text)"
  aws ec2 authorize-security-group-ingress \
    --group-id "$db_security_group_id" \
    --protocol tcp --port 5432 --source-group "$ec2_security_group_id" >/dev/null

  local extra_security_group
  local -a extra_security_groups=()
  if [[ -n "${ADDITIONAL_RDS_SECURITY_GROUP_IDS:-}" ]]; then
    IFS=',' read -r -a extra_security_groups <<<"$ADDITIONAL_RDS_SECURITY_GROUP_IDS"
    for extra_security_group in "${extra_security_groups[@]}"; do
      [[ "$extra_security_group" =~ ^sg-[a-fA-F0-9]+$ ]] ||
        die "Invalid security group ID in ADDITIONAL_RDS_SECURITY_GROUP_IDS: ${extra_security_group}"
      aws ec2 authorize-security-group-ingress \
        --group-id "$db_security_group_id" \
        --protocol tcp --port 5432 --source-group "$extra_security_group" >/dev/null
    done
  fi

  local password_parameter="/${environment_name}/${project_name}/database/password"
  local db_password
  db_password="$(aws secretsmanager get-random-password \
    --password-length 16 \
    --exclude-punctuation \
    --require-each-included-type \
    --query RandomPassword --output text)"
  jq -cn \
    --arg name "$password_parameter" \
    --arg value "$db_password" \
    '{Name:$name,Type:"SecureString",Value:$value,Overwrite:false}' \
    >"$work_dir/ssm-parameter.json"
  aws ssm put-parameter --cli-input-json "file://$work_dir/ssm-parameter.json" >/dev/null

  local secret_name="${name_prefix}-database-credentials"
  local secret_arn
  secret_arn="$(aws secretsmanager create-secret \
    --name "$secret_name" \
    --description "Aurora PostgreSQL master credentials for ${name_prefix} (RDS Data API)" \
    --tags "Key=Name,Value=${secret_name}" \
    --query ARN --output text)"
  jq -cn \
    --arg username db_admin_user \
    --arg password "$db_password" \
    '{username:$username,password:$password}' \
    >"$work_dir/db-credentials.json"
  aws secretsmanager put-secret-value \
    --secret-id "$secret_arn" \
    --secret-string "file://$work_dir/db-credentials.json" >/dev/null

  local parameter_group="${name_prefix}-aurora-pg17"
  aws rds create-db-cluster-parameter-group \
    --db-cluster-parameter-group-name "$parameter_group" \
    --db-parameter-group-family aurora-postgresql17 \
    --description "Cluster parameter group for Aurora PostgreSQL" \
    --tags "Key=Name,Value=${parameter_group}" >/dev/null
  jq -cn '[
    {ParameterName:"log_connections",ParameterValue:"1",ApplyMethod:"pending-reboot"},
    {ParameterName:"log_disconnections",ParameterValue:"1",ApplyMethod:"pending-reboot"},
    {ParameterName:"log_statement",ParameterValue:"all",ApplyMethod:"pending-reboot"},
    {ParameterName:"rds.logical_replication",ParameterValue:"1",ApplyMethod:"pending-reboot"},
    {ParameterName:"max_wal_senders",ParameterValue:"28",ApplyMethod:"pending-reboot"},
    {ParameterName:"max_logical_replication_workers",ParameterValue:"10",ApplyMethod:"pending-reboot"},
    {ParameterName:"max_worker_processes",ParameterValue:"28",ApplyMethod:"pending-reboot"},
    {ParameterName:"shared_preload_libraries",ParameterValue:"pg_stat_statements,pgaudit",ApplyMethod:"pending-reboot"}
  ]' >"$work_dir/cluster-parameters.json"
  aws rds modify-db-cluster-parameter-group \
    --db-cluster-parameter-group-name "$parameter_group" \
    --parameters "file://$work_dir/cluster-parameters.json" >/dev/null

  local monitoring_role="${name_prefix}-rds-enhanced-monitoring"
  jq -cn '{
    Version:"2012-10-17",
    Statement:[{
      Effect:"Allow",
      Principal:{Service:"monitoring.rds.amazonaws.com"},
      Action:"sts:AssumeRole"
    }]
  }' >"$work_dir/monitoring-trust-policy.json"
  aws iam create-role \
    --role-name "$monitoring_role" \
    --assume-role-policy-document "file://$work_dir/monitoring-trust-policy.json" >/dev/null
  aws iam attach-role-policy \
    --role-name "$monitoring_role" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole
  local monitoring_role_arn
  monitoring_role_arn="$(aws iam get-role --role-name "$monitoring_role" --query Role.Arn --output text)"

  local cluster_id="${name_prefix}-cluster"
  jq -cn \
    --arg cluster "$cluster_id" \
    --arg password "$db_password" \
    --arg subnet_group "$db_subnet_group" \
    --arg security_group "$db_security_group_id" \
    --arg parameter_group "$parameter_group" \
    --arg name "$cluster_id" '{
      DBClusterIdentifier:$cluster,
      Engine:"aurora-postgresql",
      EngineVersion:"17.11",
      EngineMode:"provisioned",
      DatabaseName:"lustrous",
      MasterUsername:"db_admin_user",
      MasterUserPassword:$password,
      Port:5432,
      BackupRetentionPeriod:5,
      PreferredBackupWindow:"07:00-09:00",
      PreferredMaintenanceWindow:"sun:09:00-sun:10:00",
      DBSubnetGroupName:$subnet_group,
      VpcSecurityGroupIds:[$security_group],
      EnablePerformanceInsights:true,
      EnableHttpEndpoint:false,
      DBClusterParameterGroupName:$parameter_group,
      Tags:[{Key:"Name",Value:$name}]
    }' >"$work_dir/db-cluster.json"
  aws rds create-db-cluster --cli-input-json "file://$work_dir/db-cluster.json" >/dev/null
  aws rds wait db-cluster-available --db-cluster-identifier "$cluster_id"

  local instance_index instance_id
  for instance_index in 0 1; do
    instance_id="${name_prefix}-cluster-instance-${instance_index}"
    aws rds create-db-instance \
      --db-instance-identifier "$instance_id" \
      --db-instance-class db.t3.medium \
      --engine aurora-postgresql \
      --engine-version 17.11 \
      --db-cluster-identifier "$cluster_id" \
      --no-publicly-accessible \
      --enable-performance-insights \
      --monitoring-interval 60 \
      --monitoring-role-arn "$monitoring_role_arn" \
      --no-auto-minor-version-upgrade \
      --tags "Key=Name,Value=${instance_id}" >/dev/null
    aws rds wait db-instance-available --db-instance-identifier "$instance_id"
  done

  local cluster_endpoint
  cluster_endpoint="$(aws rds describe-db-clusters \
    --db-cluster-identifier "$cluster_id" \
    --query 'DBClusters[0].Endpoint' --output text)"
  local dns_record="${project_name}-${environment_name}-postgresql.db.internal"
  jq -cn \
    --arg name "$dns_record" \
    --arg endpoint "${cluster_endpoint}." '{
      Changes:[{
        Action:"UPSERT",
        ResourceRecordSet:{
          Name:$name,
          Type:"CNAME",
          TTL:30,
          ResourceRecords:[{Value:$endpoint}]
        }
      }]
    }' >"$work_dir/db-dns-change.json"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$hosted_zone_id" \
    --change-batch "file://$work_dir/db-dns-change.json" >/dev/null

  printf 'Aurora endpoint: %s\n' "$cluster_endpoint"
  printf 'Private database DNS: %s\n' "$dns_record"
  printf 'Credentials: Secrets Manager secret %s\n' "$secret_arn"
  printf 'SSM password parameter: %s\n' "$password_parameter"
}

main() {
  ensure_aws_login
  create_networking_resources
  local vpc_id private_subnet_id hosted_zone_id
  vpc_id="$(<"$work_dir/vpc_id")"
  private_subnet_id="$(head -n 1 "$work_dir/private_subnet_ids")"
  hosted_zone_id="$(<"$work_dir/hosted_zone_id")"
  create_compute_resources "$vpc_id" "$private_subnet_id"
  local ec2_security_group_id
  ec2_security_group_id="$(<"$work_dir/ec2_security_group_id")"
  create_database_resources "$vpc_id" "$hosted_zone_id" "$ec2_security_group_id"
  log INFO "Deployment completed. No SSH key or public EC2 address was created."
  banner "Deployment Complete"
}

main "$@"
