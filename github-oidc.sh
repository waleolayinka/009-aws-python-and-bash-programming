#!/usr/bin/env bash
# Sets up GitHub Actions -> AWS OIDC authentication for this repo:
#   1. Creates the GitHub OIDC identity provider in IAM (if missing)
#   2. Creates/updates an IAM role that only workflows on ONE branch of this
#      repo can assume (default: main)
#   3. Gives the role a least-privilege inline policy covering only what the
#      bash/python deploy + destroy scripts call, scoped to resources whose
#      names contain the project name (default: programming)
#   4. Stores the role ARN in the repo secret AWS_ROLE_TO_ASSUME
#
# Safe to re-run: existing resources are reused/updated, not duplicated. Re-running
# also detaches AdministratorAccess if an earlier version of this script attached it.
#
# Usage: ./github-oidc.sh [github-owner/repo] [role-name] [branch] [project]

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ROLE_NAME="${2:-github-actions-009-deploy}"
BRANCH="${3:-main}"
PROJECT="${4:-programming}"
INLINE_POLICY_NAME="deploy-aws-resources"
SECRET_NAME="AWS_ROLE_TO_ASSUME"
OIDC_HOST="token.actions.githubusercontent.com"

for cmd in aws gh; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is not installed." >&2; exit 1; }
done

# Git Bash: keep aws.exe from seeing CRLF output or mangled /-prefixed args.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  aws() { MSYS_NO_PATHCONV=1 command aws "$@" | tr -d '\r'; }
fi

# The token's "sub" claim prefix differs per repo: newer repos use the immutable
# form (repo:owner@<id>/name@<id>), older ones repo:owner/name. Ask GitHub which.
SUB_PREFIX="$(gh api "repos/${REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null || true)"
SUB_PREFIX="${SUB_PREFIX:-repo:${REPO}}"
SUBJECT="${SUB_PREFIX}:ref:refs/heads/${BRANCH}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
IAM="arn:aws:iam::${ACCOUNT_ID}"

echo "Account : $ACCOUNT_ID"
echo "Repo    : $REPO"
echo "Subject : $SUBJECT"
echo "Role    : $ROLE_NAME"
echo "Scope   : resources named *${PROJECT}*"
echo

# 1. OIDC provider
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" >/dev/null 2>&1; then
  echo "OIDC provider already exists: $PROVIDER_ARN"
else
  echo "Creating OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list sts.amazonaws.com >/dev/null
  echo "Created: $PROVIDER_ARN"
fi

# 2. Role whose trust policy only accepts tokens from workflows on $BRANCH.
# Passed inline (not via a temp file): Windows aws.exe can't resolve Git Bash /tmp paths.
TRUST_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "${SUBJECT}"
      }
    }
  }]
}
EOF
)"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role exists; updating trust policy..."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
else
  echo "Creating role..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --description "GitHub Actions OIDC role for ${REPO} (${BRANCH})" \
    --assume-role-policy-document "$TRUST_POLICY" >/dev/null
fi

# 3. Least-privilege permissions for the deploy/destroy scripts.
# IAM is the privilege-escalation path, so it is scoped tightly: the role can only
# manage roles/policies/profiles named *-<project>-*, can only attach the specific
# AWS managed policies the scripts use (or its own *-<project>-* policies), and can
# only pass those roles to EC2 and RDS monitoring.
PERMISSIONS_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Networking",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:CreateTags",
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway", "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AllocateAddress", "ec2:ReleaseAddress",
        "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress",
        "ec2:RunInstances", "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Database",
      "Effect": "Allow",
      "Action": "rds:*",
      "Resource": "*"
    },
    {
      "Sid": "PrivateDns",
      "Effect": "Allow",
      "Action": [
        "route53:CreateHostedZone", "route53:DeleteHostedZone",
        "route53:GetHostedZone", "route53:ListHostedZones", "route53:ListHostedZonesByName",
        "route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:GetChange",
        "route53:ChangeTagsForResource", "route53:ListTagsForResource",
        "route53:AssociateVPCWithHostedZone", "route53:DisassociateVPCFromHostedZone"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TransferBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketTagging",
        "s3:PutBucketPublicAccessBlock", "s3:PutEncryptionConfiguration",
        "s3:GetEncryptionConfiguration", "s3:GetBucketLocation",
        "s3:ListBucket", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads",
        "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"
      ],
      "Resource": [
        "arn:aws:s3:::${PROJECT}-*-ssm-transfer-${ACCOUNT_ID}",
        "arn:aws:s3:::${PROJECT}-*-ssm-transfer-${ACCOUNT_ID}/*"
      ]
    },
    {
      "Sid": "ListBuckets",
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    },
    {
      "Sid": "DbPasswordParameter",
      "Effect": "Allow",
      "Action": ["ssm:PutParameter", "ssm:GetParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT_ID}:parameter/*/${PROJECT}/*"
    },
    {
      "Sid": "DbCredentialsSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret",
        "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret",
        "secretsmanager:TagResource"
      ],
      "Resource": "arn:aws:secretsmanager:*:${ACCOUNT_ID}:secret:*-${PROJECT}-*"
    },
    {
      "Sid": "ListAndGenerate",
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeParameters",
        "secretsmanager:ListSecrets", "secretsmanager:GetRandomPassword",
        "iam:ListRoles", "iam:ListPolicies", "iam:ListInstanceProfiles"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageOwnIamResources",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
        "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies", "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
        "iam:TagInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:TagPolicy",
        "iam:ListPolicyVersions", "iam:DeletePolicyVersion"
      ],
      "Resource": [
        "${IAM}:role/*-${PROJECT}-*",
        "${IAM}:instance-profile/*-${PROJECT}-*",
        "${IAM}:policy/*-${PROJECT}-*"
      ]
    },
    {
      "Sid": "AttachOnlyKnownPolicies",
      "Effect": "Allow",
      "Action": "iam:AttachRolePolicy",
      "Resource": "${IAM}:role/*-${PROJECT}-*",
      "Condition": {
        "ArnLike": {
          "iam:PolicyARN": [
            "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
            "arn:aws:iam::aws:policy/AmazonSSMFullAccess",
            "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM",
            "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy",
            "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole",
            "${IAM}:policy/*-${PROJECT}-*"
          ]
        }
      }
    },
    {
      "Sid": "PassOwnRolesToServices",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "${IAM}:role/*-${PROJECT}-*",
      "Condition": {
        "StringEquals": { "iam:PassedToService": ["ec2.amazonaws.com", "monitoring.rds.amazonaws.com"] }
      }
    },
    {
      "Sid": "RdsServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "*",
      "Condition": { "StringEquals": { "iam:AWSServiceName": "rds.amazonaws.com" } }
    }
  ]
}
EOF
)"

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$INLINE_POLICY_NAME" \
  --policy-document "$PERMISSIONS_POLICY"
echo "Applied inline policy: $INLINE_POLICY_NAME"

# Remove the broad policy an earlier version of this script attached.
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query "AttachedPolicies[?PolicyName=='AdministratorAccess'].PolicyArn" --output text | grep -q .; then
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  echo "Detached AdministratorAccess"
fi

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"

# 4. Repo secret used by the workflows
gh secret set "$SECRET_NAME" --repo "$REPO" --body "$ROLE_ARN"
echo "Set secret $SECRET_NAME on $REPO"

echo
echo "Done. Role ARN: $ROLE_ARN"
echo "Only workflows run from '${BRANCH}' can assume it, e.g.:"
echo "  gh workflow run deploy-bash-pipeline.yml --repo $REPO --ref $BRANCH"
