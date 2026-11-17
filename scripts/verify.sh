#!/usr/bin/env bash
# 요구사항 검증: 라우팅 / SG 규칙 / 외부 HTTP / SSH / 인스턴스 내부 curl / 아웃바운드
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/config.env
source "$STATE_FILE"
export AWS_DEFAULT_REGION="$REGION"
SSH="ssh -i $KEY_PATH -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ec2-user@$PUBLIC_IP"
fail=0
check() { local name=$1; shift; if "$@"; then echo "PASS  $name"; else echo "FAIL  $name"; fail=1; fi; }

echo "== Route Table =="
aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,State]' --output table
check "0.0.0.0/0 -> $IGW_ID" test "$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text)" = "$IGW_ID"

echo "== Security Group =="
aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp]' --output table
OPEN_ALL=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query \
  "SecurityGroups[0].IpPermissions[?(IpProtocol=='-1' || (FromPort==\`0\` && ToPort==\`65535\`)) && contains(IpRanges[].CidrIp, '0.0.0.0/0')]" --output text)
check "전체 포트 0.0.0.0/0 규칙 없음" test -z "$OPEN_ALL"
SSH_SRC=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[].CidrIp" --output text)
check "SSH 소스가 /32 단일 IP ($SSH_SRC)" bash -c "[[ '$SSH_SRC' == */32 && '$SSH_SRC' != 0.0.0.0* ]]"

echo "== 외부 접속 (B: /health, A: /) =="
curl -sS -i --max-time 10 "http://$PUBLIC_IP/health"
check "외부 GET /health = 200 OK" bash -c "[[ \$(curl -s --max-time 10 http://$PUBLIC_IP/health) == OK ]]"
check "외부 GET / = 200" test "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$PUBLIC_IP/")" = 200

echo "== 인스턴스 내부 (SSH) =="
check "SSH 접속" $SSH true
check "nginx active" $SSH systemctl is-active --quiet nginx
check "curl http://localhost = 200" test "$($SSH "curl -s -o /dev/null -w '%{http_code}' http://localhost")" = 200
check "아웃바운드 curl https://example.com" $SSH "curl -fsS -o /dev/null --max-time 10 https://example.com"

echo
[[ $fail == 0 ]] && echo "모든 검증 통과" || { echo "실패 항목이 있다 (docs/troubleshooting.md 참고)"; exit 1; }
