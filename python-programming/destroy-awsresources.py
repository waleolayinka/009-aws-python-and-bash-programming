#!/usr/bin/env python3
"""Delete the AWS resources created by deploy-awsresources.py."""

from __future__ import annotations

import argparse
import importlib
import logging
import re
import sys
from typing import Any

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError as exc:
    raise SystemExit("Install boto3 before running this script: python -m pip install boto3") from exc


LOG = logging.getLogger("destroy-awsresources")
SSM_POLICIES = (
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonSSMFullAccess",
    "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
    "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy",
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
        description="Tear down resources created by deploy-awsresources.py."
    )
    parser.add_argument("project", nargs="?", default="programming")
    parser.add_argument("environment", nargs="?", default="python")
    parser.add_argument("region", nargs="?", default="us-east-1")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="skip the interactive confirmation prompt",
    )
    return parser.parse_args()


def validate_name(value: str, label: str) -> None:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]*", value):
        raise ValueError(
            f"{label} must start with a letter or digit and contain only "
            "letters, digits, hyphens, or underscores."
        )


def is_not_found(exc: ClientError) -> bool:
    code = exc.response.get("Error", {}).get("Code", "")
    return code in {
        "NoSuchEntity",
        "NoSuchBucket",
        "NoSuchHostedZone",
        "DBClusterNotFoundFault",
        "DBInstanceNotFound",
        "DBSubnetGroupNotFoundFault",
        "DBClusterParameterGroupNotFoundFault",
        "DBParameterGroupNotFound",
        "DBSubnetGroupNotFound",
        "ParameterNotFound",
        "ResourceNotFoundException",
    }


def list_named_vpc(ec2: Any, prefix: str) -> str | None:
    response = ec2.describe_vpcs(
        Filters=[
            {"Name": "tag:Name", "Values": [f"{prefix}-vpc"]},
            {"Name": "cidr-block", "Values": ["10.2.0.0/16"]},
        ]
    )
    vpcs = response["Vpcs"]
    if len(vpcs) > 1:
        raise RuntimeError(
            f"Found {len(vpcs)} VPCs matching {prefix}; refusing ambiguous deletion."
        )
    return vpcs[0]["VpcId"] if vpcs else None


def delete_database(rds: Any, prefix: str) -> None:
    banner("Database Resources")
    instance_ids = [
        f"{prefix}-cluster-instance-{index}" for index in (0, 1)
    ]
    for instance_id in instance_ids:
        try:
            response = rds.describe_db_instances(
                DBInstanceIdentifier=instance_id
            )["DBInstances"][0]
        except ClientError as exc:
            if is_not_found(exc):
                continue
            raise
        if response["DBInstanceStatus"] != "deleting":
            LOG.info("Deleting RDS instance %s.", instance_id)
            rds.delete_db_instance(
                DBInstanceIdentifier=instance_id, SkipFinalSnapshot=True
            )
        else:
            LOG.info("RDS instance %s is already deleting.", instance_id)

    for instance_id in instance_ids:
        try:
            rds.get_waiter("db_instance_deleted").wait(
                DBInstanceIdentifier=instance_id
            )
        except ClientError as exc:
            if not is_not_found(exc):
                raise

    cluster_id = f"{prefix}-cluster"
    try:
        clusters = rds.describe_db_clusters(
            DBClusterIdentifier=cluster_id
        )["DBClusters"]
    except ClientError as exc:
        if is_not_found(exc):
            clusters = []
        else:
            raise
    if clusters:
        if clusters[0]["Status"] != "deleting":
            LOG.info("Deleting Aurora cluster %s without a final snapshot.", cluster_id)
            rds.delete_db_cluster(
                DBClusterIdentifier=cluster_id, SkipFinalSnapshot=True
            )
        else:
            LOG.info("Aurora cluster %s is already deleting.", cluster_id)
        rds.get_waiter("db_cluster_deleted").wait(DBClusterIdentifier=cluster_id)

    for operation, name, delete_operation, argument_name in (
        (
            rds.describe_db_subnet_groups,
            f"{prefix}-rds-dbsubnet-group",
            rds.delete_db_subnet_group,
            "DBSubnetGroupName",
        ),
        (
            rds.describe_db_cluster_parameter_groups,
            f"{prefix}-aurora-pg17",
            rds.delete_db_cluster_parameter_group,
            "DBClusterParameterGroupName",
        ),
    ):
        try:
            operation(**{argument_name: name})
        except ClientError as exc:
            if is_not_found(exc):
                continue
            raise
        delete_operation(**{argument_name: name})


def delete_database_credentials(
    secrets: Any, ssm: Any, project: str, environment: str, prefix: str
) -> None:
    banner("Database Credentials")
    secret_name = f"{prefix}-database-credentials"
    paginator = secrets.get_paginator("list_secrets")
    for page in paginator.paginate(
        Filters=[{"Key": "name", "Values": [secret_name]}]
    ):
        for secret in page.get("SecretList", []):
            if secret["Name"] == secret_name:
                LOG.info("Deleting Secrets Manager secret %s immediately.", secret_name)
                secrets.delete_secret(
                    SecretId=secret["ARN"], ForceDeleteWithoutRecovery=True
                )

    parameter_name = f"/{environment}/{project}/database/password"
    try:
        ssm.delete_parameter(Name=parameter_name)
        LOG.info("Deleted SSM parameter %s.", parameter_name)
    except ClientError as exc:
        if not is_not_found(exc):
            raise


def delete_compute(ec2: Any, prefix: str) -> None:
    banner("Compute Resources")
    paginator = ec2.get_paginator("describe_instances")
    instance_ids: list[str] = []
    for page in paginator.paginate(
        Filters=[
            {
                "Name": "tag:Name",
                "Values": [f"{prefix}-ec2-1", f"{prefix}-ec2-2"],
            },
            {
                "Name": "instance-state-name",
                "Values": [
                    "pending",
                    "running",
                    "stopping",
                    "stopped",
                    "shutting-down",
                ],
            },
        ]
    ):
        instance_ids.extend(
            instance["InstanceId"]
            for reservation in page.get("Reservations", [])
            for instance in reservation.get("Instances", [])
        )
    if instance_ids:
        LOG.info("Terminating EC2 instances: %s.", ", ".join(instance_ids))
        ec2.terminate_instances(InstanceIds=instance_ids)
        ec2.get_waiter("instance_terminated").wait(InstanceIds=instance_ids)


def delete_transfer_bucket(s3: Any, bucket_name: str) -> None:
    banner("SSM Transfer Bucket")
    try:
        s3.head_bucket(Bucket=bucket_name)
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in {"404", "NoSuchBucket", "NotFound"}:
            return
        raise

    LOG.info("Removing objects and versions from S3 bucket %s.", bucket_name)
    key_marker: str | None = None
    version_id_marker: str | None = None
    while True:
        request: dict[str, Any] = {"Bucket": bucket_name}
        if key_marker:
            request["KeyMarker"] = key_marker
        if version_id_marker:
            request["VersionIdMarker"] = version_id_marker
        page = s3.list_object_versions(**request)
        objects = [
            {"Key": item["Key"], "VersionId": item["VersionId"]}
            for item in page.get("Versions", []) + page.get("DeleteMarkers", [])
        ]
        for start in range(0, len(objects), 1000):
            result = s3.delete_objects(
                Bucket=bucket_name,
                Delete={"Objects": objects[start : start + 1000], "Quiet": True},
            )
            if result.get("Errors"):
                raise RuntimeError(
                    f"Could not remove all objects from {bucket_name}: "
                    f"{result['Errors']}"
                )
        if not page.get("IsTruncated"):
            break
        key_marker = page.get("NextKeyMarker")
        version_id_marker = page.get("NextVersionIdMarker")

    upload_key_marker: str | None = None
    upload_id_marker: str | None = None
    while True:
        request = {"Bucket": bucket_name}
        if upload_key_marker:
            request["KeyMarker"] = upload_key_marker
        if upload_id_marker:
            request["UploadIdMarker"] = upload_id_marker
        page = s3.list_multipart_uploads(**request)
        for upload in page.get("Uploads", []):
            s3.abort_multipart_upload(
                Bucket=bucket_name,
                Key=upload["Key"],
                UploadId=upload["UploadId"],
            )
        if not page.get("IsTruncated"):
            break
        upload_key_marker = page.get("NextKeyMarker")
        upload_id_marker = page.get("NextUploadIdMarker")
    s3.delete_bucket(Bucket=bucket_name)


def delete_iam(iam: Any, prefix: str) -> None:
    banner("IAM Resources")
    ec2_role = f"{prefix}-ec2-ssm-role"
    profile_name = f"{prefix}-ec2-ssm-instance-profile"
    monitoring_role = f"{prefix}-rds-enhanced-monitoring"
    policy_name = f"{prefix}-ssm-transfer-bucket-access"

    try:
        profile = iam.get_instance_profile(
            InstanceProfileName=profile_name
        )["InstanceProfile"]
    except ClientError as exc:
        if not is_not_found(exc):
            raise
        profile = None
    if profile:
        for role in profile.get("Roles", []):
            iam.remove_role_from_instance_profile(
                InstanceProfileName=profile_name,
                RoleName=role["RoleName"],
            )
        iam.delete_instance_profile(InstanceProfileName=profile_name)

    owned_policies = set(SSM_POLICIES)
    policy_arns: set[str] = set()
    try:
        role = iam.get_role(RoleName=ec2_role)["Role"]
        paginator = iam.get_paginator("list_attached_role_policies")
        for page in paginator.paginate(RoleName=ec2_role):
            policy_arns.update(
                item["PolicyArn"] for item in page.get("AttachedPolicies", [])
            )
        policy_arns.update(owned_policies)
    except ClientError as exc:
        if not is_not_found(exc):
            raise
        role = None
    if role:
        for policy_arn in policy_arns:
            try:
                iam.detach_role_policy(RoleName=ec2_role, PolicyArn=policy_arn)
            except ClientError as exc:
                if exc.response.get("Error", {}).get("Code") != "NoSuchEntity":
                    raise
        LOG.info("Deleting IAM role %s.", ec2_role)
        iam.delete_role(RoleName=ec2_role)

    for policy_arn in (
        "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole",
    ):
        try:
            iam.detach_role_policy(
                RoleName=monitoring_role, PolicyArn=policy_arn
            )
        except ClientError as exc:
            if not is_not_found(exc):
                raise
    try:
        iam.delete_role(RoleName=monitoring_role)
    except ClientError as exc:
        if not is_not_found(exc):
            raise

    paginator = iam.get_paginator("list_policies")
    for page in paginator.paginate(Scope="Local"):
        for policy in page.get("Policies", []):
            if policy["PolicyName"] != policy_name:
                continue
            policy_arn = policy["Arn"]
            versions = iam.list_policy_versions(PolicyArn=policy_arn)["Versions"]
            for version in versions:
                if not version["IsDefaultVersion"]:
                    iam.delete_policy_version(
                        PolicyArn=policy_arn,
                        VersionId=version["VersionId"],
                    )
            iam.delete_policy(PolicyArn=policy_arn)
            LOG.info("Deleted IAM policy %s.", policy_name)


def delete_networking(
    ec2: Any,
    route53: Any,
    prefix: str,
    project: str,
    environment: str,
    region: str,
    vpc_id: str,
) -> None:
    banner("Networking Resources")
    # Must match the zone name deploy creates; the Name tag + VPC checks
    # ensure only this deployment's zone is removed.
    expected_zone_name = "db.internal."

    def delete_hosted_zone(zone: dict[str, Any]) -> None:
        if zone["Name"] != expected_zone_name or not zone["Config"]["PrivateZone"]:
            return
        zone_id = zone["Id"].rsplit("/", 1)[-1]
        tags_response = route53.list_tags_for_resource(
            ResourceType="hostedzone", ResourceId=zone_id
        )
        zone_tags = {
            item["Key"]: item["Value"]
            for item in tags_response["ResourceTagSet"].get("Tags", [])
        }
        if zone_tags.get("Name") != f"{prefix}-db-internal":
            return

        zone_info = route53.get_hosted_zone(Id=zone_id)
        associated_vpcs = zone_info.get("VPCs", [])
        if not any(
            vpc["VPCId"] == vpc_id and vpc["VPCRegion"] == region
            for vpc in associated_vpcs
        ):
            return
        dns_record = f"{project}-{environment}-postgresql.db.internal."
        records = route53.list_resource_record_sets(
            HostedZoneId=zone_id, StartRecordName=dns_record, MaxItems="1"
        )["ResourceRecordSets"]
        if records and records[0]["Name"] == dns_record and records[0]["Type"] == "CNAME":
            change = route53.change_resource_record_sets(
                HostedZoneId=zone_id,
                ChangeBatch={
                    "Changes": [
                        {"Action": "DELETE", "ResourceRecordSet": records[0]}
                    ]
                },
            )
            route53.get_waiter("resource_record_sets_changed").wait(
                Id=change["ChangeInfo"]["Id"].rsplit("/", 1)[-1]
            )
        # A private zone's last VPC association can't be removed
        # (LastVPCAssociation); deleting the zone drops it. Only disassociate
        # when other VPCs still use the zone.
        if len(associated_vpcs) > 1:
            route53.disassociate_vpc_from_hosted_zone(
                HostedZoneId=zone_id, VPC={"VPCRegion": region, "VPCId": vpc_id}
            )
            LOG.warning(
                "Kept hosted zone %s because other VPCs are still associated.",
                zone_id,
            )
        else:
            route53.delete_hosted_zone(Id=zone_id)
            LOG.info("Deleted private hosted zone %s.", zone_id)

    for page in route53.get_paginator("list_hosted_zones").paginate():
        for zone in page["HostedZones"]:
            delete_hosted_zone(zone)

    nat_gateways: list[dict[str, Any]] = []
    paginator = ec2.get_paginator("describe_nat_gateways")
    for page in paginator.paginate(
        Filter=[{"Name": "vpc-id", "Values": [vpc_id]}]
    ):
        for gateway in page.get("NatGateways", []):
            gateway_tags = {tag["Key"]: tag["Value"] for tag in gateway.get("Tags", [])}
            expected_names = {
                f"{prefix}-nat-gateway-{region}a",
                f"{prefix}-nat-gateway-{region}b",
            }
            if gateway_tags.get("Name") in expected_names:
                nat_gateways.append(gateway)
    for gateway in nat_gateways:
        nat_id = gateway["NatGatewayId"]
        if gateway["State"] not in {"deleting", "deleted"}:
            LOG.info("Deleting NAT gateway %s.", nat_id)
            ec2.delete_nat_gateway(NatGatewayId=nat_id)
        if gateway["State"] != "deleted":
            ec2.get_waiter("nat_gateway_deleted").wait(NatGatewayIds=[nat_id])

    eips = ec2.describe_addresses(
        Filters=[
            {
                "Name": "tag:Name",
                "Values": [
                    f"{prefix}-nat-{region}a",
                    f"{prefix}-nat-{region}b",
                ],
            }
        ]
    )["Addresses"]
    for address in eips:
        if "AllocationId" in address:
            ec2.release_address(AllocationId=address["AllocationId"])

    expected_route_tables = {
        f"{prefix}-public-route-table-public-rtb",
        f"{prefix}-private-route-table-{region}a",
        f"{prefix}-private-route-table-{region}b",
    }
    route_tables = ec2.describe_route_tables(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["RouteTables"]
    for route_table in route_tables:
        name = {tag["Key"]: tag["Value"] for tag in route_table.get("Tags", [])}.get(
            "Name"
        )
        if name not in expected_route_tables:
            continue
        for association in route_table.get("Associations", []):
            if not association.get("Main") and association.get(
                "RouteTableAssociationId"
            ):
                ec2.disassociate_route_table(
                    AssociationId=association["RouteTableAssociationId"]
                )
        ec2.delete_route_table(RouteTableId=route_table["RouteTableId"])

    expected_subnets = {
        f"{prefix}-public-{region}a",
        f"{prefix}-public-{region}b",
        f"{prefix}-private-{region}a",
        f"{prefix}-private-{region}b",
    }
    subnets = ec2.describe_subnets(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["Subnets"]
    for subnet in subnets:
        name = {tag["Key"]: tag["Value"] for tag in subnet.get("Tags", [])}.get(
            "Name"
        )
        if name in expected_subnets:
            ec2.delete_subnet(SubnetId=subnet["SubnetId"])

    security_groups = ec2.describe_security_groups(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
    )["SecurityGroups"]
    for group in security_groups:
        name = {tag["Key"]: tag["Value"] for tag in group.get("Tags", [])}.get(
            "Name"
        )
        if name == f"{prefix}-RDSSecurityGroup":
            ec2.delete_security_group(GroupId=group["GroupId"])
    for group in security_groups:
        name = {tag["Key"]: tag["Value"] for tag in group.get("Tags", [])}.get(
            "Name"
        )
        if name == f"{prefix}-EC2SecurityGroup":
            ec2.delete_security_group(GroupId=group["GroupId"])

    gateways = ec2.describe_internet_gateways(
        Filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}]
    )["InternetGateways"]
    for gateway in gateways:
        name = {tag["Key"]: tag["Value"] for tag in gateway.get("Tags", [])}.get(
            "Name"
        )
        if name != f"{prefix}-igw":
            continue
        gateway_id = gateway["InternetGatewayId"]
        ec2.detach_internet_gateway(InternetGatewayId=gateway_id, VpcId=vpc_id)
        ec2.delete_internet_gateway(InternetGatewayId=gateway_id)

    LOG.info("Deleting VPC %s.", vpc_id)
    ec2.delete_vpc(VpcId=vpc_id)


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
        session = boto3.Session(region_name=args.region)
        account_id = session.client("sts").get_caller_identity()["Account"]
        prefix = f"{args.environment}-{args.project}"
        if not args.yes:
            if not sys.stdin.isatty():
                LOG.error(
                    "A confirmation prompt needs a terminal. "
                    "Rerun interactively or pass --yes."
                )
                return 2
            print(
                f"This permanently deletes the {args.project}-{args.environment} "
                f"deployment in {args.region} (AWS account {account_id}), "
                "including database data and bucket contents."
            )
            if input(f"Type {prefix} to continue: ") != prefix:
                LOG.error("Confirmation did not match; nothing was deleted.")
                return 2
        LOG.info(
            "Tearing down %s in account %s, region %s.",
            prefix,
            account_id,
            args.region,
        )
        ec2 = session.client("ec2")
        rds = session.client("rds")
        secrets = session.client("secretsmanager")
        ssm = session.client("ssm")
        s3 = session.client("s3")
        iam = session.client("iam")
        route53 = session.client("route53")

        vpc_id = list_named_vpc(ec2, prefix)
        delete_compute(ec2, prefix)
        delete_database(rds, prefix)
        delete_database_credentials(
            secrets, ssm, args.project, args.environment, prefix
        )
        delete_iam(iam, prefix)
        delete_transfer_bucket(
            s3, f"{args.project}-{args.environment}-ssm-transfer-{account_id}"
        )
        if vpc_id:
            delete_networking(
                ec2,
                route53,
                prefix,
                args.project,
                args.environment,
                args.region,
                vpc_id,
            )
        else:
            LOG.info("No matching VPC found; skipping networking cleanup.")
        LOG.info("Teardown completed.")
        banner("Teardown Complete")
        return 0
    except (ValueError, BotoCoreError, ClientError, RuntimeError) as exc:
        LOG.error("Teardown failed: %s", exc)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())