#!/usr/bin/env bash
# VPC → Subnet → IGW → Route Table → Security Group → Key Pair → EC2 순서로 생성한다.
# 생성된 리소스 ID는 $STATE_FILE 에 기록되어 cleanup.sh 가 사용한다.
set -euo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export AWS_DEFAULT_REGION="$REGION"

if [[ -f "$STATE_FILE" ]]; then
  echo "이미 $STATE_FILE 이 있다. 먼저 scripts/cleanup.sh 를 실행하라." >&2
  exit 1
fi

tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT_TAG}]"; }
save() { echo "$1=$2" >> "$STATE_FILE"; echo "  $1=$2"; }

echo "[0] 호출자 확인 (루트가 아니어야 함)"
CALLER=$(aws sts get-caller-identity --query Arn --output text)
echo "  $CALLER"
[[ "$CALLER" == *":root" ]] && { echo "루트 계정으로 실행하지 마라." >&2; exit 1; }

MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
echo "  SSH 허용 IP: $MY_IP/32"

echo "[1] VPC"
VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "$(tags vpc $NAME_PREFIX-vpc)" --query Vpc.VpcId --output text)
save VPC_ID "$VPC_ID"
aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

echo "[2] Public Subnet"
SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "$(tags subnet $NAME_PREFIX-public-subnet)" --query Subnet.SubnetId --output text)
save SUBNET_ID "$SUBNET_ID"
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch

echo "[3] Internet Gateway"
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "$(tags internet-gateway $NAME_PREFIX-igw)" \
  --query InternetGateway.InternetGatewayId --output text)
save IGW_ID "$IGW_ID"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "[4] Route Table (0.0.0.0/0 -> IGW)"
RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table $NAME_PREFIX-public-rt)" \
  --query RouteTable.RouteTableId --output text)
save RT_ID "$RT_ID"
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null
RT_ASSOC_ID=$(aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" \
  --query AssociationId --output text)
save RT_ASSOC_ID "$RT_ASSOC_ID"

echo "[5] Security Group (80: 0.0.0.0/0, 22: $MY_IP/32)"
SG_ID=$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name "$NAME_PREFIX-web-sg" \
  --description "B3-1 web: HTTP from anywhere, SSH from my IP only" \
  --tag-specifications "$(tags security-group $NAME_PREFIX-web-sg)" --query GroupId --output text)
save SG_ID "$SG_ID"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP-public}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description=SSH-my-ip}]" >/dev/null

echo "[6] Key Pair"
if [[ -f "$KEY_PATH" ]]; then
  echo "  $KEY_PATH 이 이미 있다. 덮어쓰지 않으려면 지우거나 KEY_PATH를 바꿔라." >&2; exit 1
fi
mkdir -p "$(dirname "$KEY_PATH")"
aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
  --tag-specifications "$(tags key-pair $KEY_NAME)" \
  --query KeyMaterial --output text > "$KEY_PATH"
chmod 400 "$KEY_PATH"
save KEY_NAME "$KEY_NAME"

echo "[7] EC2 ($INSTANCE_TYPE, Amazon Linux 2023, gp3 ${VOLUME_SIZE_GB}GiB)"
AMI_ID=$(aws ssm get-parameters --names "$AMI_SSM_PARAM" --query 'Parameters[0].Value' --output text)
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=$VOLUME_SIZE_GB,VolumeType=gp3,DeleteOnTermination=true}" \
  --user-data file://infra/user-data.sh \
  --tag-specifications "$(tags instance $NAME_PREFIX-web)" "$(tags volume $NAME_PREFIX-web-root)" \
  --query 'Instances[0].InstanceId' --output text)
save INSTANCE_ID "$INSTANCE_ID"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
save PUBLIC_IP "$PUBLIC_IP"

cat <<MSG

완료. user-data(Nginx 설치)가 끝나기까지 1~2분 걸린다.
  웹:      http://$PUBLIC_IP
  헬스:    curl -i http://$PUBLIC_IP/health
  SSH:     ssh -i $KEY_PATH ec2-user@$PUBLIC_IP
  검증:    scripts/verify.sh
MSG
