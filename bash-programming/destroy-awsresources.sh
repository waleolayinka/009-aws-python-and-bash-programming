#!/usr/bin/env bash
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
Usage: destroy-awsresources.sh [project] [environment] [region] [--yes]

Defaults match deploy-awsresources.sh: project=programming, environment=bash,
region=us-east-1. The script removes resources with the deployment's names,
including data in its SSM transfer bucket and database credentials.
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

project_name="programming"
environment_name="bash"
region="us-east-1"
assume_yes=false
positional=()

for argument in "$@"; do
  case "$argument" in
    -h|--help)
      usage
      exit 0
      ;;
    --yes)
      assume_yes=true
      ;;
    -*)
      die "Unknown option: $argument"
      ;;
    *)
      positional+=("$argument")
      ;;
  esac
done

if ((${#positional[@]} > 3)); then
  usage >&2
  exit 2
fi
project_name="${positional[0]:-$project_name}"
environment_name="${positional[1]:-$environment_name}"
region="${positional[2]:-$region}"
name_prefix="${environment_name}-${project_name}"

if [[ ! "$project_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ||
      ! "$environment_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  die "Project and environment must start with a letter or digit and contain only letters, digits, hyphens, or underscores."
fi

for command_name in aws jq; do
  command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done

export AWS_DEFAULT_REGION="$region"

if ! account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  die "AWS credentials are unavailable or expired. Authenticate with AWS CLI/SSO, then rerun."
fi
[[ -n "$account_id" && "$account_id" != "None" ]] || die "Could not determine the AWS account ID."

if [[ "$assume_yes" != true ]]; then
  [[ -t 0 ]] || die "A confirmation prompt needs a terminal. Rerun interactively or pass --yes."
  printf 'This will permanently delete the %s-%s deployment in %s (AWS account %s), including database data and bucket contents.\n' \
    "$project_name" "$environment_name" "$region" "$account_id" >&2
  printf 'Type %s to continue: ' "$name_prefix" >&2
  IFS= read -r confirmation
  [[ "$confirmation" == "$name_prefix" ]] || die "Confirmation did not match; nothing was deleted."
fi

log INFO "Tearing down ${name_prefix} in account ${account_id}, region ${region}."

none_or_empty() {
  [[ -z "$1" || "$1" == "None" || "$1" == "null" ]]
}

find_vpc_id() {
  local vpcs
  vpcs="$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${name_prefix}-vpc" \
    --query "Vpcs[?CidrBlock=='10.1.0.0/16'].VpcId" --output text)"
  if none_or_empty "$vpcs"; then
    printf ''
    return
  fi
  local -a ids=()
  read -r -a ids <<<"$vpcs"
  ((${#ids[@]} == 1)) || die "Expected one matching VPC; found ${#ids[@]}. Refusing ambiguous deletion."
  printf '%s\n' "${ids[0]}"
}

delete_database_resources() {
  banner "Database Resources"
  local cluster_id="${name_prefix}-cluster"
  local instance_id
  local instances
  instances="$(aws rds describe-db-instances \
    --query "DBInstances[?DBInstanceIdentifier=='${name_prefix}-cluster-instance-0' || DBInstanceIdentifier=='${name_prefix}-cluster-instance-1'].[DBInstanceIdentifier,DBInstanceStatus]" \
    --output text)"

  if ! none_or_empty "$instances"; then
    while IFS=$'\t' read -r instance_id status; do
      [[ -n "$instance_id" && "$instance_id" != "None" ]] || continue
      if [[ "$status" != "deleting" ]]; then
        log INFO "Deleting RDS instance ${instance_id}."
        aws rds delete-db-instance --db-instance-identifier "$instance_id" --skip-final-snapshot >/dev/null
      else
        log INFO "RDS instance ${instance_id} is already deleting."
      fi
      aws rds wait db-instance-deleted --db-instance-identifier "$instance_id"
    done <<<"$instances"
  fi

  local cluster
  cluster="$(aws rds describe-db-clusters \
    --query "DBClusters[?DBClusterIdentifier=='${cluster_id}'].[DBClusterIdentifier,Status]" \
    --output text)"
  if ! none_or_empty "$cluster"; then
    local cluster_status
    read -r cluster_id cluster_status <<<"$cluster"
    if [[ "$cluster_status" != "deleting" ]]; then
      log INFO "Deleting Aurora cluster ${cluster_id} without a final snapshot."
      aws rds delete-db-cluster \
        --db-cluster-identifier "$cluster_id" \
        --skip-final-snapshot >/dev/null
    else
      log INFO "Aurora cluster ${cluster_id} is already deleting."
    fi
    aws rds wait db-cluster-deleted --db-cluster-identifier "$cluster_id"
  fi

  local subnet_group="${name_prefix}-rds-dbsubnet-group"
  local subnet_groups
  subnet_groups="$(aws rds describe-db-subnet-groups \
    --query "DBSubnetGroups[?DBSubnetGroupName=='${subnet_group}'].DBSubnetGroupName" \
    --output text)"
  if ! none_or_empty "$subnet_groups"; then
    log INFO "Deleting RDS subnet group ${subnet_group}."
    aws rds delete-db-subnet-group --db-subnet-group-name "$subnet_group"
  fi

  local parameter_group="${name_prefix}-aurora-pg17"
  local parameter_groups
  parameter_groups="$(aws rds describe-db-cluster-parameter-groups \
    --query "DBClusterParameterGroups[?DBClusterParameterGroupName=='${parameter_group}'].DBClusterParameterGroupName" \
    --output text)"
  if ! none_or_empty "$parameter_groups"; then
    log INFO "Deleting RDS cluster parameter group ${parameter_group}."
    aws rds delete-db-cluster-parameter-group \
      --db-cluster-parameter-group-name "$parameter_group"
  fi
}

delete_database_credentials() {
  banner "Database Credentials"
  local secret_name="${name_prefix}-database-credentials"
  local secret_arn
  secret_arn="$(aws secretsmanager list-secrets \
    --query "SecretList[?Name=='${secret_name}'].ARN | [0]" --output text)"
  if ! none_or_empty "$secret_arn"; then
    log INFO "Deleting Secrets Manager secret ${secret_name} immediately."
    aws secretsmanager delete-secret \
      --secret-id "$secret_arn" \
      --force-delete-without-recovery >/dev/null
  fi

  local parameter_name="/${environment_name}/${project_name}/database/password"
  local parameter_names
  parameter_names="$(aws ssm describe-parameters \
    --parameter-filters "Key=Name,Option=Equals,Values=${parameter_name}" \
    --query 'Parameters[].Name' --output text)"
  if ! none_or_empty "$parameter_names"; then
    log INFO "Deleting SSM parameter ${parameter_name}."
    aws ssm delete-parameter --name "$parameter_name"
  fi
}

delete_ec2_instances() {
  banner "Compute Resources"
  local instances
  instances="$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=${name_prefix}-ec2-1,${name_prefix}-ec2-2" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  if none_or_empty "$instances"; then
    return
  fi

  local -a instance_ids=()
  read -r -a instance_ids <<<"$instances"
  log INFO "Terminating EC2 instances: ${instance_ids[*]}."
  aws ec2 terminate-instances --instance-ids "${instance_ids[@]}" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "${instance_ids[@]}"
}

delete_s3_transfer_bucket() {
  banner "SSM Transfer Bucket"
  local bucket_name="${project_name}-${environment_name}-ssm-transfer-${account_id}"
  local buckets
  buckets="$(aws s3api list-buckets \
    --query "Buckets[?Name=='${bucket_name}'].Name | [0]" --output text)"
  if none_or_empty "$buckets"; then
    return
  fi

  log INFO "Removing objects from S3 transfer bucket ${bucket_name}."
  aws s3 rm "s3://${bucket_name}" --recursive
  aws s3api delete-bucket --bucket "$bucket_name"
}

delete_iam_resources() {
  banner "IAM Resources"
  local ec2_role="${name_prefix}-ec2-ssm-role"
  local instance_profile="${name_prefix}-ec2-ssm-instance-profile"
  local monitoring_role="${name_prefix}-rds-enhanced-monitoring"
  local bucket_policy="${name_prefix}-ssm-transfer-bucket-access"
  local policy_arns
  local role_name
  local policy_arn

  local profiles
  profiles="$(aws iam list-instance-profiles \
    --query "InstanceProfiles[?InstanceProfileName=='${instance_profile}'].InstanceProfileName" \
    --output text)"
  if ! none_or_empty "$profiles"; then
    local profile
    profile="$(aws iam get-instance-profile --instance-profile-name "$instance_profile" --output json)"
    while IFS= read -r role_name; do
      [[ -n "$role_name" ]] || continue
      aws iam remove-role-from-instance-profile \
        --instance-profile-name "$instance_profile" --role-name "$role_name"
    done < <(jq -r '.InstanceProfile.Roles[].RoleName' <<<"$profile")
    aws iam delete-instance-profile --instance-profile-name "$instance_profile"
  fi

  for role_name in "$ec2_role" "$monitoring_role"; do
    local existing_role
    existing_role="$(aws iam list-roles \
      --query "Roles[?RoleName=='${role_name}'].RoleName" --output text)"
    if none_or_empty "$existing_role"; then
      continue
    fi
    policy_arns="$(aws iam list-attached-role-policies \
      --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text)"
    if ! none_or_empty "$policy_arns"; then
      local -a attached_policies=()
      read -r -a attached_policies <<<"$policy_arns"
      for policy_arn in "${attached_policies[@]}"; do
        aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
      done
    fi
    log INFO "Deleting IAM role ${role_name}."
    aws iam delete-role --role-name "$role_name"
  done

  policy_arn="$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${bucket_policy}'].Arn | [0]" --output text)"
  if ! none_or_empty "$policy_arn"; then
    log INFO "Deleting IAM policy ${bucket_policy}."
    aws iam delete-policy --policy-arn "$policy_arn"
  fi
}

delete_network_resources() {
  banner "Networking Resources"
  local vpc_id="$1"
  # Must match the zone name deploy creates; the Name tag + VPC checks below
  # ensure only this deployment's zone is removed.
  local hosted_zone_name="db.internal."
  local hosted_zones
  hosted_zones="$(aws route53 list-hosted-zones --output json | jq -r \
    --arg name "$hosted_zone_name" \
    '.HostedZones[] | select(.Name == $name and .Config.PrivateZone) | .Id | split("/")[-1]')"

  local hosted_zone_id zone_tags has_vpc
  while IFS= read -r hosted_zone_id; do
    [[ -n "$hosted_zone_id" ]] || continue
    zone_tags="$(aws route53 list-tags-for-resource \
      --resource-type hostedzone --resource-id "$hosted_zone_id" --output json)"
    if [[ "$(jq -r --arg name "${name_prefix}-db-internal" \
        '.ResourceTagSet.Tags[]? | select(.Key=="Name") | .Value' <<<"$zone_tags")" != "${name_prefix}-db-internal" ]]; then
      continue
    fi
    has_vpc="$(aws route53 get-hosted-zone \
      --id "$hosted_zone_id" --output json |
      jq -r --arg vpc "$vpc_id" --arg region "$region" \
        '[.VPCs[]? | select(.VPCId==$vpc and .VPCRegion==$region)] | length')"
    if [[ "$has_vpc" != "1" ]]; then
      continue
    fi

    local dns_record="${project_name}-${environment_name}-postgresql.db.internal."
    local existing_record
    existing_record="$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$hosted_zone_id" --output json |
      jq -c --arg name "$dns_record" \
        '.ResourceRecordSets[]? | select(.Name==$name and .Type=="CNAME")')"
    if [[ -n "$existing_record" ]]; then
      local change_id
      log INFO "Removing Route 53 record ${dns_record}."
      change_id="$(aws route53 change-resource-record-sets \
        --hosted-zone-id "$hosted_zone_id" \
        --change-batch "$(jq -cn --argjson record "$existing_record" \
          '{Changes:[{Action:"DELETE",ResourceRecordSet:$record}]}')" \
        --query ChangeInfo.Id --output text)"
      change_id="${change_id##*/}"
      aws route53 wait resource-record-sets-changed --id "$change_id"
    fi

    # A private zone's last VPC association can't be removed (LastVPCAssociation);
    # deleting the zone drops it. Only disassociate when other VPCs still use the zone.
    local vpc_count
    vpc_count="$(aws route53 get-hosted-zone --id "$hosted_zone_id" \
      --query 'length(VPCs)' --output text)"
    if [[ "$vpc_count" -gt 1 ]]; then
      log INFO "Detaching ${vpc_id} from hosted zone ${hosted_zone_id}; other VPCs still use it."
      aws route53 disassociate-vpc-from-hosted-zone \
        --hosted-zone-id "$hosted_zone_id" \
        --vpc "VPCRegion=${region},VPCId=${vpc_id}" >/dev/null
    else
      log INFO "Deleting private hosted zone ${hosted_zone_id}."
      aws route53 delete-hosted-zone --id "$hosted_zone_id" >/dev/null
    fi
  done <<<"$hosted_zones"

  local nat_gateways
  nat_gateways="$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${vpc_id}" \
    --query "NatGateways[?Tags[?Key=='Name' && (Value=='${name_prefix}-nat-gateway-${region}a' || Value=='${name_prefix}-nat-gateway-${region}b')]].NatGatewayId" \
    --output text)"
  if ! none_or_empty "$nat_gateways"; then
    local -a nat_gateway_ids=()
    read -r -a nat_gateway_ids <<<"$nat_gateways"
    for nat_gateway_id in "${nat_gateway_ids[@]}"; do
      local nat_state
      nat_state="$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_gateway_id" \
        --query 'NatGateways[0].State' --output text)"
      if [[ "$nat_state" != "deleting" && "$nat_state" != "deleted" ]]; then
        log INFO "Deleting NAT gateway ${nat_gateway_id}."
        aws ec2 delete-nat-gateway --nat-gateway-id "$nat_gateway_id" >/dev/null
      fi
      if [[ "$nat_state" != "deleted" ]]; then
        aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat_gateway_id"
      fi
    done
  fi

  local allocations
  allocations="$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${name_prefix}-nat-${region}a,${name_prefix}-nat-${region}b" \
    --query 'Addresses[].AllocationId' --output text)"
  if ! none_or_empty "$allocations"; then
    local -a allocation_ids=()
    read -r -a allocation_ids <<<"$allocations"
    for allocation_id in "${allocation_ids[@]}"; do
      log INFO "Releasing NAT Elastic IP ${allocation_id}."
      aws ec2 release-address --allocation-id "$allocation_id"
    done
  fi

  local route_tables
  route_tables="$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "RouteTables[?Tags[?Key=='Name' && (Value=='${name_prefix}-public-route-table-public-rtb' || Value=='${name_prefix}-private-route-table-${region}a' || Value=='${name_prefix}-private-route-table-${region}b')]].RouteTableId" \
    --output text)"
  if ! none_or_empty "$route_tables"; then
    local -a route_table_ids=()
    read -r -a route_table_ids <<<"$route_tables"
    for route_table_id in "${route_table_ids[@]}"; do
      local associations
      associations="$(aws ec2 describe-route-tables --route-table-ids "$route_table_id" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
        --output text)"
      if ! none_or_empty "$associations"; then
        local -a association_ids=()
        read -r -a association_ids <<<"$associations"
        for association_id in "${association_ids[@]}"; do
          aws ec2 disassociate-route-table --association-id "$association_id"
        done
      fi
      aws ec2 delete-route-table --route-table-id "$route_table_id"
    done
  fi

  local subnets
  subnets="$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "Subnets[?Tags[?Key=='Name' && (Value=='${name_prefix}-public-${region}a' || Value=='${name_prefix}-public-${region}b' || Value=='${name_prefix}-private-${region}a' || Value=='${name_prefix}-private-${region}b')]].SubnetId" \
    --output text)"
  if ! none_or_empty "$subnets"; then
    local -a subnet_ids=()
    read -r -a subnet_ids <<<"$subnets"
    for subnet_id in "${subnet_ids[@]}"; do
      aws ec2 delete-subnet --subnet-id "$subnet_id"
    done
  fi

  # RDS SG first: its ingress rule references the EC2 SG, which blocks
  # deleting the EC2 SG (DependencyViolation) while the RDS SG still exists.
  local security_groups sg_tag
  for sg_tag in RDSSecurityGroup EC2SecurityGroup; do
    security_groups="$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:Name,Values=${name_prefix}-${sg_tag}" \
      --query 'SecurityGroups[].GroupId' \
      --output text)"
    if ! none_or_empty "$security_groups"; then
      local -a security_group_ids=()
      read -r -a security_group_ids <<<"$security_groups"
      for security_group_id in "${security_group_ids[@]}"; do
        log INFO "Deleting security group ${security_group_id} (${name_prefix}-${sg_tag})."
        aws ec2 delete-security-group --group-id "$security_group_id"
      done
    fi
  done

  local internet_gateways
  internet_gateways="$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query "InternetGateways[?Tags[?Key=='Name' && Value=='${name_prefix}-igw']].InternetGatewayId" \
    --output text)"
  if ! none_or_empty "$internet_gateways"; then
    local -a internet_gateway_ids=()
    read -r -a internet_gateway_ids <<<"$internet_gateways"
    for internet_gateway_id in "${internet_gateway_ids[@]}"; do
      aws ec2 detach-internet-gateway --internet-gateway-id "$internet_gateway_id" --vpc-id "$vpc_id"
      aws ec2 delete-internet-gateway --internet-gateway-id "$internet_gateway_id"
    done
  fi

  log INFO "Deleting VPC ${vpc_id}."
  aws ec2 delete-vpc --vpc-id "$vpc_id"
}

main() {
  local vpc_id
  vpc_id="$(find_vpc_id)"

  delete_ec2_instances
  delete_database_resources
  delete_database_credentials
  delete_iam_resources
  delete_s3_transfer_bucket

  if [[ -n "$vpc_id" ]]; then
    delete_network_resources "$vpc_id"
  else
    log INFO "No matching VPC was found; skipping VPC-dependent networking cleanup."
  fi

  log INFO "Teardown completed."
  banner "Teardown Complete"
}

main