# B3-1 트러블슈팅 기록 서식

실제 AWS 배포나 장애 재현은 아직 수행하지 않았다. 아래 3건은 흔한 장애에 대한 진단 절차이며 발생 사실이나 해결 실적이 아니다. 모든 “결과”는 기대 기준과 배포 후 기록란을 구분했다. 리전은 `ap-northeast-2`, 대상은 `Project=B3-1`; 리소스 이름·값의 기준은 `infra/config.env`이다.

## 공통 준비

```bash
export AWS_PROFILE=b3-1-operator
# 아래 placeholder를 실제 배포값으로 교체한 뒤 실행
VPC_ID='<VPC_ID>'
SUBNET_ID='<SUBNET_ID>'
SG_ID='<SG_ID>'
RT_ID='<ROUTE_TABLE_ID>'
IGW_ID='<IGW_ID>'
INSTANCE_ID='<INSTANCE_ID>'
PUBLIC_IP='<PUBLIC_IP>'
# 조회값은 state 파일과 태그를 함께 대조한다.
aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,IP:PublicIpAddress,Subnet:SubnetId,SG:SecurityGroups}'
```

모든 명령은 권한·현재 리소스 상태를 확인하고 수행한다. 출력이 빈 배열인지, 권한 오류인지, 네트워크 오류인지 구별한다. 예시 CIDR 대신 현재 공인 IPv4를 사용한다.

## 사례 1 — 외부 HTTP 접속 타임아웃

### 증상

외부 PC의 `http://<PUBLIC_IP>/health`가 제한 시간 내 응답하지 않는다. 원문: `<HTTP_TIMEOUT_LOG — 배포 후 재현 시 붙여넣기>`.

### 가설

SG에 TCP 80 `0.0.0.0/0` 허용이 빠졌거나, 실제 서브넷에 연결된 Route Table의 `0.0.0.0/0 → IGW` 경로가 없다. 부가적으로 현재 퍼블릭 IP, IGW 연결, Nginx 부팅 실패를 구분한다.

### 검증

```bash
# 외부 PC에서 실행
curl -v --connect-timeout 5 --max-time 15 "http://${PUBLIC_IP}/health"
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=group-id,Values="$SG_ID" \
  --query 'SecurityGroups[].{Id:GroupId,Vpc:VpcId,Ingress:IpPermissions}'
aws ec2 describe-route-tables --region ap-northeast-2 \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[].{Id:RouteTableId,Tags:Tags,Associations:Associations,Routes:Routes}'
aws ec2 describe-internet-gateways --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=attachment.vpc-id,Values="$VPC_ID"
aws ec2 describe-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{State:State.Name,PublicIP:PublicIpAddress,SG:SecurityGroups,Subnet:SubnetId}'
```

확인 기준: 실제 EC2의 SG에 TCP 80 허용이 있는지, 실제 서브넷이 `b3-1-public-rt`와 연결되어 있는지, 기본 경로의 GatewayId가 해당 IGW이며 State가 active인지 확인한다. 서브넷 명시 연결이 없으면 VPC main Route Table이 적용되므로 main 테이블도 점검한다. 태그 있는 테이블만 조회하면 main 테이블을 놓칠 수 있어 VPC ID로 모두 조회한다.

SSH가 가능하면 EC2 내부에서 서버 문제를 분리한다.

```bash
ssh -i ~/.ssh/b3-1-key.pem "ec2-user@${PUBLIC_IP}"
# 다음은 EC2 내부 명령
curl -i http://127.0.0.1/health
sudo nginx -t
sudo systemctl status nginx --no-pager
sudo journalctl -u nginx -b --no-pager -n 100
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/log/nginx/access.log
sudo tail -n 100 /var/log/cloud-init-output.log
```

원문 기록: `<SG_DESCRIBE_LOG>`, `<ROUTE_TABLE_LOG>`, `<IGW_LOG>`, `<LOCALHOST_LOG>`, `<NGINX_LOG>` — 모두 배포 후 채움. 네트워크에서 차단된 요청은 Nginx access 로그에 남지 않을 수 있다.

### 조치

실제로 누락된 항목만 보완한다. SG를 전체 포트 허용으로 바꾸지 않는다.

```bash
# TCP 80 규칙이 누락된 경우에만
aws ec2 authorize-security-group-ingress --region ap-northeast-2 \
  --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0
# 기본 경로가 없는 경우에만(기존 잘못된 경로는 확인 후 별도 변경)
aws ec2 create-route --region ap-northeast-2 --route-table-id "$RT_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID"
# 서브넷에 명시 연결이 없는 경우에만; 기존 연결 교체는 대상 확인 후 수행
aws ec2 associate-route-table --region ap-northeast-2 \
  --subnet-id "$SUBNET_ID" --route-table-id "$RT_ID"
```

IGW가 VPC에 연결되어 있지 않다면 올바른 IGW/VPC를 확인해 연결한다. localhost도 실패하면 Nginx 구성 검사 및 cloud-init 로그를 근거로 서버 설정을 수정한 후 재시작한다. 위 조치 명령 전체를 무조건 실행하지 않는다.

### 결과

기대 기준: 외부 `/health`가 HTTP 200, 본문 OK를 반환한다. 실제 재검증 시각 `<CHECKED_AT>`, 조치한 항목 `<FIX_APPLIED>`, 재요청 원문 `<HTTP_AFTER_LOG>`, 증빙 `screenshots/health-check.png` — 배포 후 채움; 현재 미검증.

### 재발방지

생성 직후 SG 규칙·서브넷 RT 연결·active 기본 경로·현재 퍼블릭 IP를 확인하고 `scripts/verify.sh`의 외부 헬스체크를 실행한다. 변경 전후 SG/RT 조회 결과를 보관하며, EC2 running과 서비스 준비 완료를 구분한다.

## 사례 2 — SSH 접속 타임아웃: 내 IP 변경

### 증상

기존에 사용하던 SSH 명령이 timeout으로 끝난다. HTTP는 별도로 성공할 수 있다. 원문: `<SSH_TIMEOUT_LOG — 배포 후 재현 시 붙여넣기>`.

### 가설

VPN, 회사/집 네트워크 또는 이동통신 전환으로 현재 공인 IPv4가 바뀌어 SG TCP 22의 허용 소스 `<OLD_MY_IP>/32`와 불일치한다. 키 인증 실패(`Permission denied (publickey)`)는 TCP 연결 후 문제이므로 이 타임아웃 가설과 구분한다.

### 검증

```bash
curl -4 -fsS https://checkip.amazonaws.com
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=group-id,Values="$SG_ID" \
  --query 'SecurityGroups[].IpPermissions'
ssh -vvv -o ConnectTimeout=10 -i ~/.ssh/b3-1-key.pem "ec2-user@${PUBLIC_IP}"
aws ec2 describe-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{State:State.Name,IP:PublicIpAddress,SG:SecurityGroups}'
```

현재 IPv4 원문 `<CURRENT_IP_OUTPUT>`, SG 소스 조회 `<SSH_SG_BEFORE_LOG>`, SSH 디버그 원문 `<SSH_DEBUG_LOG>` — 배포 후 채움. 키 파일 내용은 기록하지 않는다. IP가 일치하면 사례 1의 IGW·RT, 현재 퍼블릭 IP, 로컬 방화벽과 EC2 상태를 이어서 점검한다.

### 조치

```bash
# 먼저 직접 조회한 실제 주소로 두 값을 교체; /32 유지
OLD_CIDR='<OLD_MY_IP>/32'
NEW_CIDR='<CURRENT_MY_IP>/32'
# 이전 규칙이 실제 존재하고 더 이상 사용하지 않을 때 제거
aws ec2 revoke-security-group-ingress --region ap-northeast-2 \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$OLD_CIDR"
aws ec2 authorize-security-group-ingress --region ap-northeast-2 \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$NEW_CIDR"
ssh -v -o ConnectTimeout=10 -i ~/.ssh/b3-1-key.pem "ec2-user@${PUBLIC_IP}"
```

동일 규칙이 이미 존재하면 중복 추가하지 않는다. `0.0.0.0/0` 또는 넓은 CIDR로 SSH를 열어 해결하지 않는다.

### 결과

기대 기준: 새 공인 IP `/32`에서 TCP 22 연결 후 키 인증으로 `ec2-user` 로그인 성공. 실제 시각 `<CHECKED_AT>`, 변경 후 규칙 `<SSH_SG_AFTER_LOG>`, 로그인 결과 `<SSH_AFTER_LOG>` — 배포 후 채움; 현재 미검증.

### 재발방지

SSH 전에 현재 공인 IPv4와 SG의 허용 `/32`를 대조한다. 네트워크나 VPN 변경 시 이전 주소 규칙을 정리하고 새 주소 하나만 반영한다. 로그인 성공 증빙은 민감한 키·토큰을 제외하고 기록한다.

## 사례 3 — IAM UnauthorizedOperation

### 증상

프로비저닝 또는 삭제 중 AWS CLI가 `UnauthorizedOperation`과 encoded authorization failure message를 반환한다. 모든 권한 오류가 encoded 메시지를 제공하는 것은 아니다. 원문 `<UNAUTHORIZED_OPERATION_LOG>`와 실패 명령 `<FAILED_COMMAND>` — 배포 후 재현 시 채움.

### 가설

미션에 필요한 API 액션이 커스텀 정책에서 빠졌거나, 다른 IAM 사용자로 호출했거나, 요청 리전이 잘못됐다. 정책의 Allow가 있더라도 explicit deny, permissions boundary, 조직 SCP 등 다른 제한이 적용될 수 있다.

### 검증

```bash
aws sts get-caller-identity --region ap-northeast-2
aws configure list
# encoded 메시지가 실제로 반환된 경우에만 원문을 정확히 전달
aws sts decode-authorization-message --region ap-northeast-2 \
  --encoded-message '<ENCODED_AUTHORIZATION_MESSAGE>' \
  --query DecodedMessage --output text
```

디코딩 결과에서 principal, action, resource, explicitDeny와 적용 조건을 확인한다. `sts:DecodeAuthorizationMessage`는 현재 커스텀 정책에 포함되어 있다. 디코딩 자체가 거부되면 권한 있는 비루트 IAM 관리 주체에게 원문을 전달해 확인한다. encoded 메시지나 디코딩 결과는 공개 제출 전에 계정·리소스 정보를 점검한다.

다음 조회는 IAM 관리 권한이 있는 비루트 관리 주체가 실행한다. `<IAM_ADMIN_PROFILE>`은 해당 비루트 관리자 프로필로 교체한다. 운영 정책에 없는 IAM 조회 권한을 임의로 추가하지 않는다.

```bash
aws --profile '<IAM_ADMIN_PROFILE>' iam list-attached-user-policies --user-name b3-1-operator --region ap-northeast-2
aws --profile '<IAM_ADMIN_PROFILE>' iam list-user-policies --user-name b3-1-operator --region ap-northeast-2
aws --profile '<IAM_ADMIN_PROFILE>' iam list-groups-for-user --user-name b3-1-operator --region ap-northeast-2
aws --profile '<IAM_ADMIN_PROFILE>' iam get-policy --region ap-northeast-2 \
  --policy-arn 'arn:aws:iam::<ACCOUNT_ID>:policy/B3-1-LeastPrivilege'
# get-policy의 DefaultVersionId를 확인한 뒤
aws --profile '<IAM_ADMIN_PROFILE>' iam get-policy-version --region ap-northeast-2 \
  --policy-arn 'arn:aws:iam::<ACCOUNT_ID>:policy/B3-1-LeastPrivilege' \
  --version-id '<DEFAULT_VERSION_ID>'
```

호출 주체 `<CALLER_IDENTITY_LOG>`, decoded 메시지 `<DECODED_AUTH_LOG>`, 실제 부착 정책 `<ATTACHED_POLICY_LOG>` — 배포 후 채움.

### 조치

호출 사용자·리전 오류이면 `b3-1-operator` 프로필과 `ap-northeast-2`로 바로잡는다. 정책 누락이면 실패한 액션이 이 미션에 필요한지 검토하고 IAM 관리 주체가 필요한 액션·리소스·조건만 보완하여 고객 관리형 정책의 새 기본 버전을 적용한다. 저장소 정책과 실제 부착 정책도 일치시킨다. explicit deny·SCP·boundary라면 해당 관리 주체가 원인을 검토한다. `AdministratorAccess` 부착이나 S3/RDS 등 무관 서비스 권한 추가로 우회하지 않는다.

### 결과

기대 기준: 필요한 미션 액션만 허용되고 원래 실패 명령이 성공한다. 실제 변경 내용 `<POLICY_DIFF>`, 재실행 원문 `<IAM_AFTER_LOG>`, 시각 `<CHECKED_AT>` — 배포 후 채움; 현재 미검증.

### 재발방지

스크립트가 호출하는 API와 커스텀 정책의 액션·리전 조건을 변경 때마다 대조한다. 실패 원문과 디코딩 근거를 남기고 필요 권한만 변경한다. 잘못된 리전 요청이나 인스턴스 타입 요청은 제한을 유지한다.

참고: [AWS CLI decode-authorization-message](https://docs.aws.amazon.com/cli/latest/reference/sts/decode-authorization-message.html), [describe-security-groups](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-security-groups.html), [describe-route-tables](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html).

## 자체 점검

실제 발생했다고 표현한 장애, 만들어 넣은 로그·IP·리소스 ID·성공 시각은 없다. 모든 사례는 재현 전 절차이며 검증 결과·스크린샷·조치 이력은 “배포 후 채움” 상태다.
