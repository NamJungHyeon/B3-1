# B3-1 트러블슈팅

서울 리전 `ap-northeast-2`의 배포·검증 로그를 근거로 작성했다. 사례 2는 SG를 의도적으로 변경해 재현하고 복구한 실제 기록이다. 사례 1·3은 재현하지 않은 예상 장애 시나리오이며 실제 장애로 주장하지 않는다. 사례 3에는 별도의 정상적인 최소권한 거부 시험을 구분해 수록했다. 리소스는 이후 정리되었으므로 아래 명령을 과거 ID로 다시 실행하지 않는다.

검증 대상: EC2 `i-0d3a2ed22d4d891b1`, 당시 퍼블릭 IP `3.35.173.185`, SG `sg-0b9bcafca08337847`, VPC `vpc-017b387de9ebebe39`. 생성·SG 변경은 CloudShell의 `b3-1-operator`, 접속 시험은 공인 IP `121.135.181.35`인 로컬 Mac에서 수행했다. 일부 CloudShell 파일은 머리말에 표시된 터미널 원문 전사본이다.

## 사례 1 — 외부 HTTP 타임아웃: 재현하지 않은 예상 시나리오

### 증상

외부 `GET /health` 요청이 timeout으로 끝나는 상황을 가정한다. 이번 배포에서 이 장애를 의도적으로 재현하지 않았다.

### 가설

SG TCP 80 허용 누락 또는 실제 서브넷 Route Table의 `0.0.0.0/0 → IGW` 경로 누락을 먼저 확인한다. 현재 퍼블릭 IP, EC2 상태와 Nginx 부팅 문제도 구분한다.

### 검증

다음은 재배포 시 실제 대상 ID를 지정해 쓰는 진단 명령이다.

```bash
curl -v --connect-timeout 5 --max-time 15 "http://${PUBLIC_IP}/health"
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=group-id,Values="$SG_ID"
aws ec2 describe-route-tables --region ap-northeast-2 \
  --filters Name=vpc-id,Values="$VPC_ID"
aws ec2 describe-internet-gateways --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=attachment.vpc-id,Values="$VPC_ID"
# SSH 접속 후 EC2 내부에서 서버 문제 분리
curl -i http://127.0.0.1/health
sudo nginx -t
sudo journalctl -u nginx -b --no-pager -n 100
sudo tail -n 100 /var/log/nginx/error.log
sudo tail -n 100 /var/log/nginx/access.log
```

서브넷의 실제 RT 연결과 active 기본 경로를 확인한다. 명시 연결이 없으면 VPC main 테이블이 적용되므로 VPC ID로 모든 테이블을 조회한다. 네트워크에서 차단된 요청은 Nginx access 로그에 남지 않을 수 있다.

### 조치

조회 결과 실제로 빠진 TCP 80 규칙, RT 기본 경로 또는 서브넷 연결만 복구한다. Nginx 내부 문제이면 구성 검사와 cloud-init/Nginx 로그를 근거로 수정한다. 전체 포트 인바운드 허용으로 우회하지 않는다.

### 결과

이 장애의 조치 전후 로그는 없다. 정상 상태의 별도 근거로 [logs/verify-aws.log](../logs/verify-aws.log)의 RT active·SG 규칙·외부 HTTP 200 OK와 [logs/verify-local.log](../logs/verify-local.log)의 localhost 200을 확인했다. 이를 장애 복구 실적으로 해석하지 않는다.

### 재발방지

생성 직후 SG·서브넷 RT 연결·active 기본 경로·현재 퍼블릭 IP를 대조하고 외부 `/health` 검사를 수행한다. EC2 running과 Nginx 준비 완료를 구분한다.

## 사례 2 — SSH 타임아웃: 의도적으로 재현한 실제 기록

### 증상

2026-11-18, SG의 SSH 소스를 `203.0.113.10/32`로 바꾸어 “내 IP가 바뀌었는데 SG가 예전 주소를 허용하는 상황”을 의도적으로 재현했다. 실제 Mac의 공인 IP는 계속 `121.135.181.35`였으며 실제 네트워크 변경이 일어났다고 주장하지 않는다. TCP 80은 그대로 유지했다.

[logs/ts-ssh-break.log](../logs/ts-ssh-break.log)의 변경 후 규칙 원문:

```text
## [재현] SSH 소스를 다른 IP(203.0.113.10/32)로 바꿔 'IP 변경' 상황 재현
true
true
| 80| 0.0.0.0/0       |
| 22| 203.0.113.10/32 |
```

09:49:51 KST의 [증상 로그](../logs/ts-ssh-symptom.log)에서 발췌한 SSH 원문:

```text
### 증상: SSH 시도 (2026-11-18 09:49:51 KST)
debug1: Connecting to 3.35.173.185 [3.35.173.185] port 22.
debug1: connect to address 3.35.173.185 port 22: Operation timed out
ssh: connect to host 3.35.173.185 port 22: Operation timed out
```

### 가설

SSH 허용 소스 `203.0.113.10/32`와 실제 클라이언트 `121.135.181.35/32`가 불일치하여 SG가 TCP 22를 허용하지 않는다고 판단했다. 같은 시각 HTTP 200과 80번 연결은 성공했으므로 서비스 전체 중단과 SSH 포트만의 차단을 구분할 수 있었다. 키 인증 실패는 TCP 연결 이후의 문제이므로 이 타임아웃과 구분했다.

### 검증

[logs/ts-ssh-symptom.log](../logs/ts-ssh-symptom.log)에서 현재 IP, HTTP 상태와 포트 결과를 대조했다. 원문 발췌:

```text
121.135.181.35
```

```text
HTTP 200 in 0.016120s
nc: connectx to 3.35.173.185 port 22 (tcp) failed: Operation timed out
Connection to 3.35.173.185 port 80 [tcp/http] succeeded!
```

재현 때 사용하는 명령의 동등한 예시는 다음과 같다. 아래 명령 블록은 원문 전사가 아니라 진단 방법 설명이다.

```bash
curl -4 -fsS https://checkip.amazonaws.com
curl -i --connect-timeout 5 --max-time 15 http://3.35.173.185/health
ssh -vvv -o ConnectTimeout=10 -i ~/.ssh/b3-1-key.pem ec2-user@3.35.173.185
nc -vz -G 5 3.35.173.185 22
nc -vz -G 5 3.35.173.185 80
# AWS 자격 증명이 있는 CloudShell에서 SG 실제 소스 대조
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=group-id,Values=sg-0b9bcafca08337847
```

증상 로그의 `exit=0`은 파이프라인 마지막 `tail`의 종료 코드이며 SSH의 종료 코드가 아니다. SSH 성공 근거로 사용하지 않았다. 성공·실패는 연결 문구와 포트 검사 및 조치 후 실제 원격 명령 결과로 판단했다.

### 조치

CloudShell에서 잘못된 `203.0.113.10/32` 규칙을 revoke하고 실제 Mac IP `121.135.181.35/32`를 authorize했다. TCP 80 규칙을 유지하고 SSH를 전체 IPv4에 열지 않았다. 아래는 조치 방법을 나타낸 동등한 명령이다.

```bash
aws ec2 revoke-security-group-ingress --region ap-northeast-2 \
  --group-id sg-0b9bcafca08337847 --protocol tcp --port 22 --cidr 203.0.113.10/32
aws ec2 authorize-security-group-ingress --region ap-northeast-2 \
  --group-id sg-0b9bcafca08337847 --protocol tcp --port 22 --cidr 121.135.181.35/32
```

[logs/ts-ssh-fix.log](../logs/ts-ssh-fix.log)의 변경 후 규칙 원문:

```text
## [조치] 이전 IP 규칙 제거 + 현재 IP(121.135.181.35/32) 허용
true
true
| 80| 0.0.0.0/0         |
| 22| 121.135.181.35/32 |
```

### 결과

09:50:28 KST SSH 접속이 성공했고 원격 hostname, Nginx active, localhost 200, `/health`의 200 OK 및 아웃바운드 200을 확인했다. [logs/ts-ssh-result.log](../logs/ts-ssh-result.log)의 원문 발췌:

```text
### 결과: 조치 후 SSH (2026-11-18 09:50:28 KST)
ip-10-0-1-105.ap-northeast-2.compute.internal
active
--- curl -i http://localhost
HTTP/1.1 200 OK
Server: nginx/1.30.6
Date: Wed, 18 Nov 2026 00:50:29 GMT
--- curl -i http://localhost/health
HTTP/1.1 200 OK
OK
--- outbound
https://example.com -> 200
```

같은 결과 파일의 access 로그에는 실제 Mac IP의 외부 `/health` 200 기록도 있다. 이 행의 시각은 UTC 00:50:01이며 SSH 복구 확인 시각 09:50:28 KST와 구분한다.

```text
121.135.181.35 - - [18/Nov/2026:00:50:01 +0000] "GET /health HTTP/1.1" 200 3 "-" "curl/8.7.1" "-"
```

### 재발방지

SSH 전에 현재 공인 IPv4와 SG의 `/32`를 대조한다. VPN·네트워크 변경 시 예전 소스 규칙을 제거하고 새 주소 하나만 허용한다. CloudShell에서 생성할 때는 실행 환경의 IP 대신 접속할 Mac의 IP를 `SSH_IP`로 전달한다. 파이프를 사용한 진단에서는 `pipefail` 또는 원래 명령의 종료 코드를 별도로 보관해 `tail`의 성공을 SSH 성공으로 오인하지 않는다.

## 사례 3 — IAM UnauthorizedOperation: 재현하지 않은 예상 시나리오

### 증상

미션에 필요한 API가 UnauthorizedOperation으로 실패하는 상황을 가정한다. 이번 기록에는 필수 미션 API의 누락 권한 장애나 encoded 오류의 디코딩 결과가 없다.

### 가설

실제 호출 주체·리전 오류, 누락된 액션, explicit deny, permissions boundary나 조직 SCP를 구분한다.

### 검증

```bash
aws sts get-caller-identity --region ap-northeast-2
aws configure list
# encoded 메시지가 실제 반환된 경우에만 실행하는 진단 예시
aws sts decode-authorization-message --region ap-northeast-2 \
  --encoded-message '<ENCODED_AUTHORIZATION_MESSAGE>' \
  --query DecodedMessage --output text
```

실제 수행한 것은 미션과 무관한 S3/RDS/IAM 호출의 거부 시험이다. [logs/iam-least-privilege.log](../logs/iam-least-privilege.log)에는 다음 원문이 있다.

```text
aws: [ERROR]: An error occurred (AccessDenied) when calling the ListBuckets operation: User: arn:aws:iam::508473919970:user/b3-1-operator is not authorized to perform: s3:ListAllMyBuckets because no identity-based policy allows the s3:ListAllMyBuckets action
aws: [ERROR]: An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:iam::508473919970:user/b3-1-operator is not authorized to perform: rds:DescribeDBInstances on resource: arn:aws:rds:ap-northeast-2:508473919970:db:* because no identity-based policy allows the rds:DescribeDBInstances action
aws: [ERROR]: An error occurred (AccessDenied) when calling the ListUsers operation: User: arn:aws:iam::508473919970:user/b3-1-operator is not authorized to perform: iam:ListUsers on resource: arn:aws:iam::508473919970:user/ because no identity-based policy allows the iam:ListUsers action. (이하 authorization-details 링크 생략)
```

### 조치

위 3건은 최소권한이 정상적으로 거부한 결과이므로 권한을 추가하지 않았다. 향후 필수 액션이 실패하면 호출 주체·리전·디코딩 근거를 확인하고 관리 주체가 필요한 액션과 조건만 검토한다. AdministratorAccess나 무관 서비스 권한으로 우회하지 않는다.

### 결과

S3 ListBuckets, RDS DescribeDBInstances, IAM ListUsers의 거부를 확인했다. 이 시험은 해당 작업의 거부 근거이며 미션 장애 복구 또는 전체 정책의 완전한 최소권한 검증을 뜻하지 않는다.

### 재발방지

스크립트 API와 정책 액션·리전 조건을 함께 검토한다. 정상적인 권한 거부와 필수 권한 누락을 구분하고, IAM 관리 작업은 운영 사용자에게 부여하지 않는다.

참고: [AWS CLI decode-authorization-message](https://docs.aws.amazon.com/cli/latest/reference/sts/decode-authorization-message.html), [describe-security-groups](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-security-groups.html), [describe-route-tables](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html).

## 자체 점검

사례 2의 시각·IP·규칙·접속 결과와 사례 3의 정상 거부 시험은 링크된 원문에 근거한다. 사례 1·3의 예상 장애를 실제 발생으로 적지 않았고, 제공되지 않은 HTTP 장애 로그나 encoded 디코딩 결과를 만들지 않았다. SSH 시험은 의도적인 소스 불일치였으며 `tail`의 종료 코드는 성공 근거에서 제외했다.
