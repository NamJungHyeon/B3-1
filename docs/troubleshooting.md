# B3-1 트러블슈팅

서울 리전 `ap-northeast-2`의 배포·검증 로그를 근거로 작성했다. 사례 2는 최초 v1 배포에서 SG를 의도적으로 변경해 복구한 기록이고, 사례 3은 태그 정책 v2 재배포에서 실제 겪은 공개키 파일 소실 및 부재 키페어의 권한 거부 기록이다. 사례 1만 재현하지 않은 예상 시나리오다. 리소스는 이후 정리되었으므로 아래 명령을 과거 ID로 다시 실행하지 않는다.

사례 1·2의 최초 v1 검증 대상: EC2 `i-0d3a2ed22d4d891b1`, 당시 퍼블릭 IP `3.35.173.185`, SG `sg-0b9bcafca08337847`, VPC `vpc-017b387de9ebebe39`. 생성·SG 변경은 CloudShell의 `b3-1-operator`, 접속 시험은 공인 IP `121.135.181.35`인 로컬 Mac에서 수행했다. 일부 CloudShell 파일은 머리말에 표시된 터미널 원문 전사본이다.

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

## 사례 3 — 실제 기록: 공개키 소실 후 부재 키페어 DeleteKeyPair의 UnauthorizedOperation

### 증상

태그 조건 정책 v2 적용 후 재배포 1차 시도에서 `[6] Key Pair` 단계가 ParamValidation으로 중단됐다. CloudShell 세션 재시작으로 `/tmp/b3-1-key.pub`가 사라져 공개키를 읽지 못했으며, 이때 키페어 import는 실행되지 않았다. [logs/tagpolicy-run.log](../logs/tagpolicy-run.log) 2절 원문:

```text
aws: [ERROR]: An error occurred (ParamValidation): Error parsing parameter '--public-key-material': Unable to load paramfile fileb:///tmp/b3-1-key.pub: [Errno 2] No such file or directory: '/tmp/b3-1-key.pub'
```

남은 VPC·서브넷·IGW·RT·SG는 cleanup으로 정리됐지만, 생성되지 않은 키페어를 DeleteKeyPair로 삭제하려 할 때 NotFound 대신 UnauthorizedOperation이 나왔다. 같은 로그 3절 원문:

```text
aws: [ERROR]: An error occurred (UnauthorizedOperation) when calling the DeleteKeyPair operation: You are not authorized to perform this operation. User: arn:aws:iam::508473919970:user/b3-1-operator is not authorized to perform: ec2:DeleteKeyPair on resource: arn:aws:ec2:ap-northeast-2:508473919970:*/* because no identity-based policy allows the ec2:DeleteKeyPair action. Encoded authorization failure message: …
```

로그의 `…`는 제공된 전사본의 생략 표시다. encoded 메시지 전체를 보관하거나 디코딩한 결과는 없으며 이를 만들어 넣지 않았다.

### 가설

처음에는 DeleteKeyPair 액션이 정책에서 빠졌는지, 또는 대상 키페어가 없어 ResourceTag 조건을 평가할 수 없는지 구분했다. 현재 [정책 원문](../infra/iam-policy.json)의 `UseAndDeleteOnlyProjectTaggedResources`에는 DeleteKeyPair가 있고, `ec2:ResourceTag/Project=B3-1` 조건이 붙어 있다. 오류에 평가 대상이 구체적인 key-pair ARN 대신 `arn:aws:ec2:ap-northeast-2:508473919970:*/*`로 나타난 점과 실제 생성 단계를 함께 확인했다.

기록의 해석은 “대상 키페어가 부재해 Project 태그 조건을 충족하지 못했다”다. 디코딩으로 내부 정책 평가를 직접 관찰한 결과라고 주장하지 않고, 리소스 부재와 동일 정책하의 정상 삭제 비교를 근거로 판단했다.

### 검증

[재배포 로그](../logs/tagpolicy-run.log) 2~6절을 순서대로 대조했다.

| 비교 항목 | 실제 근거 |
| --- | --- |
| 1차 생성 중단 지점 | 공개키 파일 로드 단계에서 ParamValidation; 키 import와 EC2 생성 이전에 중단 |
| 1차 cleanup 후 상태 | EC2/EBS/EIP/IGW/VPC/NAT/KeyPair의 Project=B3-1 잔여 목록 모두 빈 값 |
| 정책의 액션 | DeleteKeyPair가 ResourceTag 조건 Statement에 실제 포함됨 |
| 같은 정책으로 재배포 | 공개키를 홈으로 옮긴 뒤 전 단계 성공, 키페어 `b3-1-key` 생성 |
| 존재하는 키페어의 삭제 비교 | 2차 cleanup에서 태그 있는 키페어 DeleteKeyPair가 Return true, KeyPairId 반환 |

2차 cleanup의 원문:

```text
+ aws ec2 delete-key-pair --key-name b3-1-key                          -> "Return": true, "KeyPairId": "key-0331c34eb129cab79"
```

진단에 쓰는 조회 명령은 다음과 같다. 아래는 방법 설명이며 별도 출력 원문이 있는 것처럼 기록하지 않는다.

```bash
# 재실행 전 실제 공개키 파일 유무부터 확인
ls -l "$HOME/b3-1-key.pub"
test -s "$HOME/b3-1-key.pub"
aws ec2 describe-key-pairs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=key-name,Values=b3-1-key
aws ec2 describe-vpcs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
```

### 조치

정책 변경은 필요하지 않았다. 권한을 넓히는 대신 임시 `/tmp` 경로의 공개키 소실을 원인으로 처리했다. 로컬 Mac의 공개키만 CloudShell 홈 `~/b3-1-key.pub`에 다시 보관하고 `PUBLIC_KEY_FILE` 경로를 바꾸어 재배포했다. 개인키는 계속 Mac에 두었다. 아래는 성공 경로를 설명하는 동등한 명령 예시이며 원문 명령 전체의 전사라고 주장하지 않는다.

```bash
# 공개키가 홈에 복구된 것을 확인한 새 배포에서만 실행
# 앞선 부분 생성 리소스와 상태 파일을 먼저 정리한다.
test -s "$HOME/b3-1-key.pub"
SSH_IP=121.135.181.35 PUBLIC_KEY_FILE="$HOME/b3-1-key.pub" bash scripts/provision.sh
bash scripts/verify.sh
```

없는 키의 UnauthorizedOperation을 이유로 조건 없는 DeleteKeyPair나 AdministratorAccess를 추가하지 않았다. cleanup 성공 여부는 마지막 문구가 아니라 실제 잔여 조회와 존재하는 대상의 삭제 결과로 판단했다.

### 결과

2차 시도는 EC2 `i-04dd8916b77900977`, 퍼블릭 IP `43.201.55.219`로 배포·검증에 성공했다. CloudShell RT·SG·외부 HTTP는 PASS이고 [Mac 원문](../logs/tagpolicy-verify-local.log)도 `/health` 200 OK, SSH, nginx active, localhost 200, 아웃바운드가 모두 PASS다. 동일한 v2 정책으로 생성된 키페어 `key-0331c34eb129cab79`를 포함해 인프라를 정리했다.

2026-11-18 03:34:48 UTC의 재확인에서는 EC2 terminated, VPC NotFound, KeyPair NotFound, FireView running이었다. 루트가 운영 사용자 액세스키를 삭제하고 남은 키 0을 확인했다. 키페어가 실제 존재했던 2차에서는 DeleteKeyPair가 성공하므로, 1차 오류를 일괄적인 액션 누락으로 판단하지 않았다. [정리 스크린샷](../screenshots/tagpolicy-cleanup.jpg)과 [삭제 체크리스트](cleanup-checklist.md)에도 회차를 구분했다.

### 재발방지

CloudShell 공개키는 홈 영구 저장소에 보관하고 세션 재시작 후 `test -s`로 파일을 확인한다. 실패하면 마지막으로 완료한 생성 단계와 상태 파일을 확인하고 부분 생성분을 정리한다. 태그 정책에서 삭제 권한 오류가 나면 대상의 존재·태그·정책 액션·오류의 리소스 ARN을 함께 확인한다. 원문이 없는 decode 결과를 추정해 기록하거나 권한을 즉시 확장하지 않는다.

최초 v1의 S3/RDS/IAM AccessDenied 시험은 [logs/iam-least-privilege.log](../logs/iam-least-privilege.log)에 별도 보관했다. 이는 무관 서비스 작업의 정상 거부 시험이며 이번 키페어 오류의 decode 결과가 아니다.

참고: [AWS CLI decode-authorization-message](https://docs.aws.amazon.com/cli/latest/reference/sts/decode-authorization-message.html), [describe-security-groups](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-security-groups.html), [describe-route-tables](https://docs.aws.amazon.com/cli/latest/reference/ec2/describe-route-tables.html).

## 자체 점검

사례 2의 SSH 실패·복구는 v1 원문, 사례 3의 실제 공개키 소실·키페어 오류·성공 비교는 v2 원문에 근거한다. 사례 1의 예상 HTTP 장애를 실제 발생으로 적지 않았다. DryRunOperation을 실제 중지·재부팅·종료로 해석하지 않았고, SSH 파이프라인의 tail 종료 코드와 미실행 authorization decode도 성공 근거로 사용하지 않았다.
