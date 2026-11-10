#!/usr/bin/env python3
"""Provision AWS resources with Python and boto3 instead of Terraform.

Purpose: test Python (boto3) as an alternative to an IaC tool for building
AWS infrastructure; see bash-programming/ for the same stack in Bash + AWS CLI.

Resources created:
  Networking: VPC (10.2.0.0/16), public/private subnets in two AZs, internet
              gateway, per-AZ NAT gateways, route tables, security groups,
              and a private Route 53 zone (db.internal).
  Compute:    two private EC2 instances reachable only through SSM Session
              Manager: no key pair, no public IP. IAM role/instance profile
              and an encrypted S3 transfer bucket.
  Database:   Aurora PostgreSQL cluster with two instances in private
              subnets, not publicly accessible; reachable only from the EC2
              security group. Credentials in Secrets Manager and SSM.
"""

from __future__ import annotations

import argparse
import importlib
import json
import logging
import os
import re
import sys
import time
from typing import Any

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError as exc:
    raise SystemExit(
        "Install boto3 before running this script: python -m pip install boto3") from exc


LOG = logging.getLogger("deploy-awsresources")
SSM_POLICIES = (
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonSSMFullAccess",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
    "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy",
)
ADDITIONAL_RDS_SECURITY_GROUP_IDS = os.environ.get(
    "ADDITIONAL_RDS_SECURITY_GROUP_IDS", ""
)


def banner(title: str) -> None:
    """Print a large section heading, falling back to plain text."""
    print()
    try:
        pyfiglet = importlib.import_module("pyfiglet")
        print(pyfiglet.figlet_format(title, font="slant"), end="")
    except ImportError:
        print(f"========== {title} ==========")
    print()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deploy the networking, compute, and database AWS resources."
    )
    parser.add_argument("project", nargs="?", default="programming")
    parser.add_argument("environment", nargs="?", default="python")
    parser.add_argument("region", nargs="?", default="us-east-1")
    return parser.parse_args()


def validate_name(value: str, label: str) -> None:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", value):
        raise ValueError(
            f"{label} must start with a letter or digit and contain only "
            "letters, digits, hyphens, or underscores."
        )


def tags(name: str, **extra: str) -> list[dict[str, str]]:
    return [{"Key": key, "Value": value} for key, value in {"Name": name, **extra}.items()]


def create_networking(
    ec2: Any,
    route53: Any,
    project: str,
    environment: str,
    region: str,
) -> dict[str, Any]:
    prefix = f"{environment}-{project}"
    banner("Networking Resources")
    LOG.info("Creating VPC, subnets, gateways, routes, and private DNS.")

    vpc_id = ec2.create_vpc(
        CidrBlock="10.2.0.0/16",
        TagSpecifications=[
            {"ResourceType": "vpc", "Tags": tags(f"{prefix}-vpc")}
        ],
    )["Vpc"]["VpcId"]
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsSupport={"Value": True})
    ec2.modify_vpc_attribute(VpcId=vpc_id, EnableDnsHostnames={"Value": True})

    azs = (f"{region}a", f"{region}b")
    public_cidrs = ("10.2.1.0/24", "10.2.3.0/24")
    private_cidrs = ("10.2.2.0/24", "10.2.4.0/24")
    public_subnet_ids: list[str] = []
    private_subnet_ids: list[str] = []
    for index, az in enumerate(azs):
        public_subnet_id = ec2.create_subnet(
            VpcId=vpc_id,
            CidrBlock=public_cidrs[index],
            AvailabilityZone=az,
            TagSpecifications=[
                {"ResourceType": "subnet", "Tags": tags(
                    f"{prefix}-public-{az}")}
            ],
        )["Subnet"]["SubnetId"]
        ec2.modify_subnet_attribute(
            SubnetId=public_subnet_id, MapPublicIpOnLaunch={"Value": True}
        )
        public_subnet_ids.append(public_subnet_id)

        private_subnet_id = ec2.create_subnet(
            VpcId=vpc_id,
            CidrBlock=private_cidrs[index],
            AvailabilityZone=az,
            TagSpecifications=[
                {"ResourceType": "subnet", "Tags": tags(
                    f"{prefix}-private-{az}")}
            ],
        )["Subnet"]["SubnetId"]
        ec2.modify_subnet_attribute(
            SubnetId=private_subnet_id, MapPublicIpOnLaunch={"Value": False}
        )
        private_subnet_ids.append(private_subnet_id)

    internet_gateway_id = ec2.create_internet_gateway(
        TagSpecifications=[
            {
                "ResourceType": "internet-gateway",
                "Tags": tags(f"{prefix}-igw"),
            }
        ]
    )["InternetGateway"]["InternetGatewayId"]
    ec2.attach_internet_gateway(
        InternetGatewayId=internet_gateway_id, VpcId=vpc_id
    )
    public_route_table_id = ec2.create_route_table(
        VpcId=vpc_id,
        TagSpecifications=[
            {
                "ResourceType": "route-table",
                "Tags": tags(f"{prefix}-public-route-table-public-rtb"),
            }
        ],
    )["RouteTable"]["RouteTableId"]
    ec2.create_route(
        RouteTableId=public_route_table_id,
        DestinationCidrBlock="0.0.0.0/0",
        GatewayId=internet_gateway_id,
    )

    for index, az in enumerate(azs):
        ec2.associate_route_table(
            RouteTableId=public_route_table_id, SubnetId=public_subnet_ids[index]
        )
        allocation_id = ec2.allocate_address(
            Domain="vpc",
            TagSpecifications=[
                {
                    "ResourceType": "elastic-ip",
                    "Tags": tags(f"{prefix}-nat-{az}"),
                }
            ],
        )["AllocationId"]
        nat_gateway_id = ec2.create_nat_gateway(
            AllocationId=allocation_id,
            SubnetId=public_subnet_ids[index],
            TagSpecifications=[
                {
                    "ResourceType": "natgateway",
                    "Tags": tags(f"{prefix}-nat-gateway-{az}"),
                }
            ],
        )["NatGateway"]["NatGatewayId"]
        ec2.get_waiter("nat_gateway_available").wait(
            NatGatewayIds=[nat_gateway_id]
        )
        private_route_table_id = ec2.create_route_table(
            VpcId=vpc_id,
            TagSpecifications=[
                {
                    "ResourceType": "route-table",
                    "Tags": tags(f"{prefix}-private-route-table-{az}"),
                }
            ],
        )["RouteTable"]["RouteTableId"]
        ec2.create_route(
            RouteTableId=private_route_table_id,
            DestinationCidrBlock="0.0.0.0/0",
            NatGatewayId=nat_gateway_id,
        )
        ec2.associate_route_table(
            RouteTableId=private_route_table_id,
            SubnetId=private_subnet_ids[index],
        )

    hosted_zone = route53.create_hosted_zone(
        Name="db.internal",
        CallerReference=f"{int(time.time())}-{os.getpid()}",
        HostedZoneConfig={
            "Comment": f"Stable database names for {prefix}",
            "PrivateZone": True,
        },
        VPC={"VPCRegion": region, "VPCId": vpc_id},
    )["HostedZone"]
    hosted_zone_id = hosted_zone["Id"].rsplit("/", 1)[-1]
    route53.change_tags_for_resource(
        ResourceType="hostedzone",
        ResourceId=hosted_zone_id,
        AddTags=tags(f"{prefix}-db-internal"),
    )

    return {
        "vpc_id": vpc_id,
        "public_subnet_ids": public_subnet_ids,
        "private_subnet_ids": private_subnet_ids,
        "hosted_zone_id": hosted_zone_id,
    }


def create_compute(
    session: Any,
    network: dict[str, Any],
    project: str,
    environment: str,
    account_id: str,
) -> dict[str, Any]:
    prefix = f"{environment}-{project}"
    region = session.region_name
    ec2 = session.client("ec2")
    iam = session.client("iam")
    s3 = session.client("s3")
    banner("Compute Resources")
    LOG.info(
        "Creating SSM roles, transfer bucket, security group, and two private EC2 instances.")

    role_name = f"{prefix}-ec2-ssm-role"
    profile_name = f"{prefix}-ec2-ssm-instance-profile"
    iam.create_role(
        RoleName=role_name,
        AssumeRolePolicyDocument=(
            '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",'
            '"Principal":{"Service":"ec2.amazonaws.com"},'
            '"Action":"sts:AssumeRole"}]}'
        ),
        Tags=tags(f"{environment}-{project}-SSMRole"),
    )
    iam.create_instance_profile(
        InstanceProfileName=profile_name, Tags=tags(profile_name)
    )
    iam.add_role_to_instance_profile(
        InstanceProfileName=profile_name, RoleName=role_name
    )
    for policy_arn in SSM_POLICIES:
        iam.attach_role_policy(RoleName=role_name, PolicyArn=policy_arn)

    bucket_name = f"{project}-{environment}-ssm-transfer-{account_id}"
    if region == "us-east-1":
        s3.create_bucket(Bucket=bucket_name)
    else:
        s3.create_bucket(
            Bucket=bucket_name,
            CreateBucketConfiguration={"LocationConstraint": region},
        )
    s3.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    s3.put_bucket_encryption(
        Bucket=bucket_name,
        ServerSideEncryptionConfiguration={
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    }
                }
            ]
        },
    )
    bucket_policy_name = f"{prefix}-ssm-transfer-bucket-access"
    bucket_policy = iam.create_policy(
        PolicyName=bucket_policy_name,
        PolicyDocument=json.dumps(
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:GetEncryptionConfiguration",
                            "s3:GetBucketLocation",
                        ],
                        "Resource": f"arn:aws:s3:::{bucket_name}",
                    },
                    {
                        "Effect": "Allow",
                        "Action": ["s3:GetObject", "s3:PutObject"],
                        "Resource": f"arn:aws:s3:::{bucket_name}/*",
                    },
                ],
            }
        ),
    )["Policy"]["Arn"]
    iam.attach_role_policy(RoleName=role_name, PolicyArn=bucket_policy)

    security_group_id = ec2.create_security_group(
        GroupName=f"{prefix}-ec2-sg",
        Description="Security group for EC2 instances in the ASG",
        VpcId=network["vpc_id"],
        TagSpecifications=[
            {
                "ResourceType": "security-group",
                "Tags": tags(f"{prefix}-EC2SecurityGroup"),
            }
        ],
    )["GroupId"]
    for port in (443, 80):
        ec2.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": port,
                    "ToPort": port,
                    "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
                }
            ],
        )

    user_data = (
        "#!/bin/bash -e\n"
        "sudo yum update -y amazon-ssm-agent python3\n"
        "sudo systemctl enable --now amazon-ssm-agent\n"
    )
    time.sleep(10)
    instance_ids: list[str] = []
    for index in (1, 2):
        response = ec2.run_instances(
            ImageId="ami-0de716d6197524dd9",
            MinCount=1,
            MaxCount=1,
            InstanceType="t2.micro",
            IamInstanceProfile={"Name": profile_name},
            NetworkInterfaces=[
                {
                    "DeviceIndex": 0,
                    "SubnetId": network["private_subnet_ids"][0],
                    "Groups": [security_group_id],
                    "AssociatePublicIpAddress": False,
                    "DeleteOnTermination": True,
                }
            ],
            UserData=user_data,
            TagSpecifications=[
                {
                    "ResourceType": "instance",
                    "Tags": tags(
                        f"{prefix}-ec2-{index}",
                        env=environment,
                        project_name=project,
                    ),
                }
            ],
        )
        instance_ids.append(response["Instances"][0]["InstanceId"])
    LOG.info("EC2 instances launched: %s", ", ".join(instance_ids))
    return {
        "security_group_id": security_group_id,
        "instance_ids": instance_ids,
    }


def create_database(
    session: Any,
    network: dict[str, Any],
    compute: dict[str, Any],
    project: str,
    environment: str,
    extra_security_group_ids: list[str],
) -> dict[str, str]:
    prefix = f"{environment}-{project}"
    ec2 = session.client("ec2")
    rds = session.client("rds")
    iam = session.client("iam")
    ssm = session.client("ssm")
    secrets = session.client("secretsmanager")
    route53 = session.client("route53")
    banner("Database Resources")
    LOG.info("Creating private Aurora PostgreSQL, credentials, and internal DNS.")

    subnet_group = f"{prefix}-rds-dbsubnet-group"
    rds.create_db_subnet_group(
        DBSubnetGroupName=subnet_group,
        DBSubnetGroupDescription=f"Private database subnets for {prefix}",
        SubnetIds=network["private_subnet_ids"],
        Tags=tags(f"My DB Subnet Group in {prefix}"),
    )
    db_security_group_id = ec2.create_security_group(
        GroupName=f"{prefix}-rds-sg",
        Description="Security group for RDS instances",
        VpcId=network["vpc_id"],
        TagSpecifications=[
            {
                "ResourceType": "security-group",
                "Tags": tags(f"{prefix}-RDSSecurityGroup"),
            }
        ],
    )["GroupId"]
    ingress_groups = [
        compute["security_group_id"],
        *extra_security_group_ids,
    ]
    for source_group_id in ingress_groups:
        ec2.authorize_security_group_ingress(
            GroupId=db_security_group_id,
            IpPermissions=[
                {
                    "IpProtocol": "tcp",
                    "FromPort": 5432,
                    "ToPort": 5432,
                    "UserIdGroupPairs": [{"GroupId": source_group_id}],
                }
            ],
        )

    password_parameter = f"/{environment}/{project}/database/password"
    password = secrets.get_random_password(
        PasswordLength=16,
        ExcludePunctuation=True,
        RequireEachIncludedType=True,
    )["RandomPassword"]
    ssm.put_parameter(
        Name=password_parameter,
        Type="SecureString",
        Value=password,
        Overwrite=False,
    )
    secret_name = f"{prefix}-database-credentials"
    secret_arn = secrets.create_secret(
        Name=secret_name,
        Description=f"Aurora PostgreSQL master credentials for {prefix} (RDS Data API)",
        Tags=tags(secret_name),
    )["ARN"]
    secrets.put_secret_value(
        SecretId=secret_arn,
        SecretString=json.dumps(
            {"username": "db_admin_user", "password": password}
        ),
    )

    parameter_group = f"{prefix}-aurora-pg17"
    rds.create_db_cluster_parameter_group(
        DBClusterParameterGroupName=parameter_group,
        DBParameterGroupFamily="aurora-postgresql17",
        Description="Cluster parameter group for Aurora PostgreSQL",
        Tags=tags(parameter_group),
    )
    rds.modify_db_cluster_parameter_group(
        DBClusterParameterGroupName=parameter_group,
        Parameters=[
            {
                "ParameterName": name,
                "ParameterValue": value,
                "ApplyMethod": "pending-reboot",
            }
            for name, value in (
                ("log_connections", "1"),
                ("log_disconnections", "1"),
                ("log_statement", "all"),
                ("rds.logical_replication", "1"),
                ("max_wal_senders", "28"),
                ("max_logical_replication_workers", "10"),
                ("max_worker_processes", "28"),
                ("shared_preload_libraries", "pg_stat_statements,pgaudit"),
            )
        ],
    )

    monitoring_role = f"{prefix}-rds-enhanced-monitoring"
    iam.create_role(
        RoleName=monitoring_role,
        AssumeRolePolicyDocument=(
            '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",'
            '"Principal":{"Service":"monitoring.rds.amazonaws.com"},'
            '"Action":"sts:AssumeRole"}]}'
        ),
    )
    iam.attach_role_policy(
        RoleName=monitoring_role,
        PolicyArn="arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole",
    )
    monitoring_role_arn = iam.get_role(RoleName=monitoring_role)["Role"]["Arn"]

    cluster_id = f"{prefix}-cluster"
    cluster = rds.create_db_cluster(
        DBClusterIdentifier=cluster_id,
        Engine="aurora-postgresql",
        EngineVersion="17.11",
        EngineMode="provisioned",
        DatabaseName="lustrous",
        MasterUsername="db_admin_user",
        MasterUserPassword=password,
        Port=5432,
        BackupRetentionPeriod=5,
        PreferredBackupWindow="07:00-09:00",
        PreferredMaintenanceWindow="sun:09:00-sun:10:00",
        DBSubnetGroupName=subnet_group,
        VpcSecurityGroupIds=[db_security_group_id],
        EnablePerformanceInsights=True,
        EnableHttpEndpoint=False,
        DBClusterParameterGroupName=parameter_group,
        Tags=tags(cluster_id),
    )["DBCluster"]
    rds.get_waiter("db_cluster_available").wait(
        DBClusterIdentifier=cluster_id
    )
    for index in (0, 1):
        instance_id = f"{prefix}-cluster-instance-{index}"
        rds.create_db_instance(
            DBInstanceIdentifier=instance_id,
            DBInstanceClass="db.t3.medium",
            Engine="aurora-postgresql",
            EngineVersion="17.11",
            DBClusterIdentifier=cluster_id,
            PubliclyAccessible=False,
            EnablePerformanceInsights=True,
            MonitoringInterval=60,
            MonitoringRoleArn=monitoring_role_arn,
            AutoMinorVersionUpgrade=False,
            Tags=tags(instance_id),
        )
        rds.get_waiter("db_instance_available").wait(
            DBInstanceIdentifier=instance_id
        )

    dns_name = f"{project}-{environment}-postgresql.db.internal"
    route53.change_resource_record_sets(
        HostedZoneId=network["hosted_zone_id"],
        ChangeBatch={
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": dns_name,
                        "Type": "CNAME",
                        "TTL": 30,
                        "ResourceRecords": [
                            {"Value": f"{cluster['Endpoint']}."}
                        ],
                    },
                }
            ]
        },
    )
    return {
        "cluster_endpoint": cluster["Endpoint"],
        "dns_name": dns_name,
        "secret_arn": secret_arn,
        "password_parameter": password_parameter,
    }


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(message)s",
        stream=sys.stderr,
    )
    args = parse_args()
    try:
        validate_name(args.project, "Project")
        validate_name(args.environment, "Environment")
        extra_groups = [
            group.strip()
            for group in ADDITIONAL_RDS_SECURITY_GROUP_IDS.split(",")
            if group.strip()
        ]
        for group_id in extra_groups:
            if not re.fullmatch(r"sg-[a-fA-F0-9]+", group_id):
                raise ValueError(
                    "Invalid security group ID in ADDITIONAL_RDS_SECURITY_GROUP_IDS: "
                    f"{group_id}"
                )
        session = boto3.Session(region_name=args.region)
        account_id = session.client("sts").get_caller_identity()["Account"]
        LOG.info("Deploying to account %s in %s.", account_id, args.region)
        network = create_networking(
            session.client("ec2"),
            session.client("route53"),
            args.project,
            args.environment,
            args.region,
        )
        compute = create_compute(
            session, network, args.project, args.environment, account_id
        )
        database = create_database(
            session,
            network,
            compute,
            args.project,
            args.environment,
            extra_groups,
        )
        print(f"Aurora endpoint: {database['cluster_endpoint']}")
        print(f"Private database DNS: {database['dns_name']}")
        print(f"Credentials: Secrets Manager secret {database['secret_arn']}")
        print(f"SSM password parameter: {database['password_parameter']}")
        LOG.info(
            "Deployment completed. No SSH key or public EC2 address was created.")
        banner("Deployment Complete")
        return 0
    except (ValueError, BotoCoreError, ClientError) as exc:
        LOG.error("Deployment failed: %s", exc)
        LOG.error(
            "Resources already created in AWS were not automatically rolled back.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
