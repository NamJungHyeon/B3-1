#!/usr/bin/env bash
# 의존관계 역순으로 삭제: EC2(+EBS) → EIP → SG → RT → Subnet → IGW → VPC → Key Pair
# 끝에 Project=B3-1 태그로 남은 과금 리소스를 조회해 근거로 출력한다.
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
export AWS_DEFAULT_REGION="$REGION"
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
run() { echo "+ $*"; "$@" || echo "  (실패 또는 이미 삭제됨)"; }

if [[ -n "${INSTANCE_ID:-}" ]]; then
  run aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --output text
  echo "  terminated 대기..."; aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
fi
# 혹시 수동으로 할당한 Elastic IP가 있으면 해제
for alloc in $(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'Addresses[].AllocationId' --output text); do
  run aws ec2 release-address --allocation-id "$alloc"
done
# DeleteOnTermination=true 지만, 남은(available) 볼륨이 있으면 삭제
for vol in $(aws ec2 describe-volumes --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text); do
  run aws ec2 delete-volume --volume-id "$vol"
done
[[ -n "${SG_ID:-}" ]]       && run aws ec2 delete-security-group --group-id "$SG_ID"
[[ -n "${RT_ASSOC_ID:-}" ]] && run aws ec2 disassociate-route-table --association-id "$RT_ASSOC_ID"
[[ -n "${RT_ID:-}" ]]       && run aws ec2 delete-route-table --route-table-id "$RT_ID"
[[ -n "${SUBNET_ID:-}" ]]   && run aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
if [[ -n "${IGW_ID:-}" ]]; then
  run aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  run aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
[[ -n "${VPC_ID:-}" ]]      && run aws ec2 delete-vpc --vpc-id "$VPC_ID"
run aws ec2 delete-key-pair --key-name "$KEY_NAME"

echo; echo "== 잔여 리소스 확인 (Project=$PROJECT_TAG, 모두 비어 있어야 함) =="
F="Name=tag:Project,Values=$PROJECT_TAG"
echo "EC2 (terminated 제외):"; aws ec2 describe-instances --filters "$F" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text
echo "EBS:";      aws ec2 describe-volumes --filters "$F" --query 'Volumes[].VolumeId' --output text
echo "EIP:";      aws ec2 describe-addresses --filters "$F" --query 'Addresses[].PublicIp' --output text
echo "IGW:";      aws ec2 describe-internet-gateways --filters "$F" --query 'InternetGateways[].InternetGatewayId' --output text
echo "VPC:";      aws ec2 describe-vpcs --filters "$F" --query 'Vpcs[].VpcId' --output text
echo "NAT GW:";   aws ec2 describe-nat-gateways --filter "$F" "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text
echo "KeyPair:";  aws ec2 describe-key-pairs --filters "$F" --query 'KeyPairs[].KeyName' --output text

[[ -f "$STATE_FILE" ]] && mv "$STATE_FILE" "$STATE_FILE.deleted-$(date +%Y%m%d%H%M%S)"
echo "정리 완료. Billing Dashboard도 확인하라."
