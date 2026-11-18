# Codyssey B3-1 — AWS VPC + EC2 + Nginx

서울 리전(ap-northeast-2)에 VPC·퍼블릭 서브넷·EC2 Nginx 서비스를 배포했다. 최초 배포는 IAM 정책 v1, 태그 조건으로 강화한 뒤의 재배포는 v2로 수행했으며 두 배포 모두 외부 HTTP·SSH·Nginx·localhost·아웃바운드 검증과 인프라 정리를 마쳤다. 최신 근거는 [태그 정책 재검증 로그](logs/tagpolicy-run.log)와 [Mac 검증 로그](logs/tagpolicy-verify-local.log), 설정 기준은 [infra/config.env](infra/config.env)이다.

현재 상태: v1 최초 배포와 v2 재배포 모두 정리 완료. v2는 2026-11-18 03:34:48 UTC(12:34:48 KST)에 EC2 terminated, VPC·키페어 NotFound, FireView running을 재확인했고 운영 사용자 액세스키도 삭제해 잔여 0을 확인했다. [삭제 체크리스트](docs/cleanup-checklist.md)에 회차별 근거를 기록했다. 기존 Billing 캡처는 v1 정리 후 10:15 KST의 예상 USD 0.00 화면이며, 이후 v2 사용분까지 반영한 재조회 결과는 아니다. 두 퍼블릭 IP는 검증 당시 기록으로, 종료·삭제 후 접속 대상으로 사용하지 않는다.

| 배포 이력 | 정책 / 당시 퍼블릭 IP | 검증·정리 근거 |
| --- | --- | --- |
| 최초 배포 | v1 / `3.35.173.185`, EC2 `i-0d3a2ed22d4d891b1` | `logs/provision.log`, `logs/verify-*.log`, `logs/cleanup*.log`; 정리 재확인 00:53:11 UTC |
| 태그 정책 재검증 | v2 / `43.201.55.219`, EC2 `i-04dd8916b77900977` | `logs/tagpolicy-run.log`, `logs/tagpolicy-verify-local.log`; 로컬 HTTP 03:33:16 UTC, 정리 재확인 03:34:48 UTC |


## 디렉터리 구조

```text
.
├── README.md
├── infra/
│   ├── config.env
│   ├── iam-policy.json
│   └── user-data.sh
├── scripts/
│   ├── provision.sh
│   ├── verify.sh
│   └── cleanup.sh
├── docs/
│   ├── architecture.png
│   ├── diagram/draw_architecture.py  # PNG 재생성 소스(Pillow)
│   ├── troubleshooting.md
│   └── cleanup-checklist.md
├── logs/
│   ├── provision.log
│   ├── verify-aws.log
│   ├── verify-local.log
│   ├── iam-least-privilege.log
│   ├── cleanup.log
│   ├── cleanup-verify.log
│   ├── tagpolicy-run.log
│   ├── tagpolicy-verify-local.log
│   └── ts-ssh-{break,symptom,fix,result}.log
├── screenshots/
│   ├── verify-aws-cloudshell.jpg
│   ├── billing-summary.jpg
│   ├── billing-services.jpg
│   ├── cleanup-cloudshell.jpg
│   ├── tagpolicy-dryrun.jpg
│   ├── tagpolicy-verify-compare.jpg
│   ├── tagpolicy-cleanup.jpg
│   ├── browser-root.jpg
│   └── browser-health.jpg
└── .b3-1-state                 # CloudShell에서 provision이 기록한 상태 파일; Git 제외
```

일부 CloudShell 로그는 터미널 출력의 원문 전사본이며 파일 머리말에 구분되어 있다. 스크린샷은 실제 캡처다. 개인키·액세스키·토큰은 제출 파일에 포함하지 않는다.

## 구성과 트래픽 흐름

![B3-1 아키텍처](docs/architecture.png)

그림은 v1 최초 배포의 주소가 적힌 구성 설명도이며 AWS 콘솔 캡처가 아니다. v2 재배포도 같은 네트워크 구조를 사용했지만 실제 ID·퍼블릭 IP는 아래 회차별 기록과 구분한다. 미션 스크립트는 리소스에 `Project=B3-1` 태그를 지정한다.

| 구성 요소 | 공통 설정 / v1 최초 배포 ID |
| --- | --- |
| 리전 / AZ | `ap-northeast-2` / `ap-northeast-2a` |
| VPC | `b3-1-vpc`, `10.0.0.0/16`, `vpc-017b387de9ebebe39` |
| Public Subnet | `b3-1-public-subnet`, `10.0.1.0/24`, `subnet-053424ed40ee5e872` |
| Internet Gateway | `b3-1-igw`, `igw-0f2ea6a5447a030d1` |
| Route Table | `b3-1-public-rt`, `rtb-062bb6ef39f712a4b`, `0.0.0.0/0 → IGW` |
| RT 연결 ID | `rtbassoc-0a575477549135e20` |
| Security Group | `b3-1-web-sg`, `sg-0b9bcafca08337847`; TCP 80 `0.0.0.0/0`, TCP 22 `121.135.181.35/32` |
| EC2 / EBS | `i-0d3a2ed22d4d891b1`, Amazon Linux 2023, `t3.micro`, `gp3` 8 GiB |
| 키페어 / 퍼블릭 IP | `b3-1-key` / 자동 할당 IPv4 `3.35.173.185`; Elastic IP 미사용 |
| 웹 서버 | Nginx; `/`에 `Hello Cloud - B3-1`, `/health`에 HTTP 200과 `OK` |

리소스 ID의 근거는 [생성 로그](logs/provision.log), 라우트 active와 실제 SG 인바운드 규칙의 근거는 [AWS 검증 로그](logs/verify-aws.log)다. CIDR·AZ·볼륨 사양·태그 지정은 설정 및 생성 스크립트와 함께 대조한다.

HTTP 요청은 인터넷 → Internet Gateway → 퍼블릭 IPv4가 연결된 EC2 네트워크 인터페이스 → SG의 TCP 80 허용 → Nginx 순서로 도달한다. 응답은 서브넷 Route Table의 `0.0.0.0/0 → IGW` 경로를 이용한다. Route Table은 경로를 결정하는 설정이다.

IGW는 VPC와 인터넷을 연결하고, 서브넷의 IGW 기본 경로는 인터넷 방향 경로를 제공한다. EC2의 퍼블릭 IPv4는 외부에서 접근할 주소이며, SG는 허용할 포트와 소스를 제한한다. 이 조건을 함께 충족해야 인터넷 접속이 가능하다. 관련 동작은 [AWS Internet Gateway 문서](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)를 참고한다.

SSH도 인터넷·IGW를 거쳐 같은 EC2의 TCP 22로 도달한다. 검증 당시 로컬 Mac의 공인 IPv4 `121.135.181.35/32`만 SG에서 허용하고 `b3-1-key` 개인키로 `ec2-user`에 로그인했다. SSH 전체 IPv4 허용이나 전체 포트 인바운드 허용은 사용하지 않았다. 자동 퍼블릭 IP는 중지 후 시작 시 바뀔 수 있다.

## Security Group과 IAM, 최소권한 — 정책 v2

SG는 EC2 네트워크 트래픽, IAM은 AWS API 작업 권한, SSH 키는 운영체제 로그인 인증을 제어한다. SG는 두 배포 모두 TCP 80 `0.0.0.0/0`, TCP 22 `121.135.181.35/32`이며 전체 포트 인바운드 허용은 없다. IAM 사용자는 `arn:aws:iam::508473919970:user/b3-1-operator`, 연결 정책은 커스텀 `B3-1-LeastPrivilege` 하나이며 AdministratorAccess는 없다.

[현재 정책 원문](infra/iam-policy.json)은 v2다. 변경 전후는 커밋 `a19ea88`의 정책 diff로 확인할 수 있다. 최초 v1의 “리전만 맞으면 Project 태그와 무관한 다른 EC2도 변경·삭제할 수 있는 범위”는 **v2의 리소스 태그 조건으로 해결했다**. 일부 Statement의 Resource가 `*`인 것만으로 무제한 변경 허용을 뜻하지 않으며 아래 Condition을 함께 적용한다.

| 작업 범위 | v2 적용 조건 / 제한 | 확인 근거 |
| --- | --- | --- |
| EC2 조회 | `ec2:Describe*`, GetConsoleOutput은 `aws:RequestedRegion=ap-northeast-2`; 조회 대상의 Project 태그 제한은 없음 | `ReadOnlyDescribeInSeoul` |
| 리소스 생성 | CreateVpc/Subnet/InternetGateway/RouteTable/SecurityGroup/KeyPair, ImportKeyPair, RunInstances의 신규 대상은 `aws:RequestTag/Project=B3-1` 필수; ARN은 서울 리전으로 제한 | `CreateOnlyWithProjectTag`; 태그 없는 VPC 거부 / 태그 있는 VPC dry-run 허용 |
| 생성 시 태그 지정 | CreateTags는 `Project=B3-1` 요청과 허용된 `ec2:CreateAction`이 있는 생성 시점에만 허용; 별도 CreateTags로 기존 FireView에 Project 태그를 붙이는 시도는 거부 | `TagOnlyAtCreation`; FireView create-tags dry-run 거부 |
| 기존 리소스 사용·변경·연결·삭제 | 서울 리전의 `ec2:ResourceTag/Project=B3-1` 대상만 허용; Start/Stop/Reboot/TerminateInstances도 포함 | `UseAndDeleteOnlyProjectTaggedResources`; FireView 거부, B3-1 허용 비교 |
| 보조 리소스 ARN 예외 | RunInstances와 SG 규칙 작업이 참조하는 image / network-interface / security-group-rule ARN에는 Project 태그 조건을 적용하지 않음; 허용 액션·서울 ARN 범위로 제한 | `UntaggableSubResources`; 모든 EC2 리소스나 액션을 무조건 허용하는 예외가 아님 |
| 인스턴스 크기 | t2.micro/t3.micro 이외의 RunInstances는 명시적 Deny; 실제 배포는 t3.micro | `OnlyMicroInstances` |
| AMI·진단 | 서울 AL2023 공개 파라미터 경로의 ssm:GetParameters, sts:GetCallerIdentity·DecodeAuthorizationMessage 유지 | `ReadAmiParameter`, `DecodeAuthErrorsForTroubleshooting`; 이번 오류의 decode는 미실행 |
| 무관 서비스·계정 관리 | S3/RDS/IAM 관리·Billing 권한은 운영 정책에 없음 | v1의 `logs/iam-least-privilege.log`에 특정 S3/RDS/IAM 호출 AccessDenied; IAM/Billing은 실제 루트로 수행 |

[logs/tagpolicy-run.log](logs/tagpolicy-run.log) 1·5절의 dry-run 비교 원문 발췌:

```text
terminate FireView => UnauthorizedOperation
stop FireView => UnauthorizedOperation
create-tags Project=B3-1 on FireView => UnauthorizedOperation
create-vpc (태그 없음) => UnauthorizedOperation
create-vpc (Project=B3-1) => DryRunOperation
terminate B3-1 => DryRunOperation
terminate FireView => UnauthorizedOperation
reboot B3-1 => DryRunOperation
reboot FireView => UnauthorizedOperation
```

FireView 대상은 `i-0f29938e558d1e55c`(Project 태그 없음), B3-1 대상은 `i-04dd8916b77900977`(Project=B3-1)이다. DryRunOperation은 권한 평가상 허용을 의미하는 dry-run 응답이며 실제 생성·중지·재부팅·종료를 수행한 것이 아니다. UnauthorizedOperation은 해당 dry-run의 거부다. FireView를 실제로 중지·종료하거나 Project 태그를 변경하지 않았으며 정리 후 running을 확인했다. 증빙은 [배포 전 dry-run](screenshots/tagpolicy-dryrun.jpg)과 [서비스 검증·리소스 비교](screenshots/tagpolicy-verify-compare.jpg)다.

남은 한계: Describe*는 서울 리전 안에서 계정 전체 EC2 리소스를 조회할 수 있다. 신규 리소스의 Project 값은 사용자가 생성 요청에 붙일 수 있으므로 허용된 액션·리전·타입 범위에서는 `Project=B3-1`을 붙여 새 리소스를 만들 수 있다. 이미 B3-1 태그가 있는 리소스 간 소유자 구분이나 비용 한도까지 강제하는 정책은 아니다. 보조 ARN 예외와 조회 범위도 표와 같이 남아 있다.

인프라 생성·검증·정리는 운영 사용자로, IAM 사용자·정책 생성 및 v2 적용·액세스키 삭제, 계정 차원 후속 감사와 Billing 조회는 루트로 수행했다. 이 실습을 모든 단계에서 루트 미사용이라고 표현하지 않는다. IAM 사용자와 정책은 증빙용으로 유지했고 마지막 실습 액세스키는 삭제했다.

## 사전 준비와 실행 방법

다음 명령은 같은 구성을 다시 수행하기 위한 안내다. 최초 v1 배포는 `PUBLIC_KEY_FILE=/tmp/b3-1-key.pub`를 사용했다. v2 재배포 1차는 CloudShell 세션 재시작으로 그 파일이 사라져 중단되었고, 2차는 공개키를 홈의 `~/b3-1-key.pub`에 두어 성공했다. 근거는 [최초 생성 로그](logs/provision.log)와 [v2 재배포 로그](logs/tagpolicy-run.log) 2~4절이다. 기존 리소스·상태 파일·키페어와 충돌할 수 있으므로 완료된 생성을 그대로 반복하지 않는다.

AWS CLI v2, Bash, curl, SSH 클라이언트를 준비한다. IAM 사용자는 커스텀 정책만 부착하고 `aws sts get-caller-identity`로 호출 주체를 확인한다. 초기 설정에는 권한 있는 IAM 관리 주체가 필요하다. 이번 실습에서 초기 IAM 생성에 루트를 사용한 사실은 위에 별도 기록했다.

```bash
# AWS 프로필이 필요한 환경에서만 설정. 비밀 값은 로컬 자격 증명 저장소에 입력한다.
aws configure --profile b3-1-operator
# Default region: ap-northeast-2 / Default output: json
export AWS_PROFILE=b3-1-operator
aws sts get-caller-identity --region ap-northeast-2
# 이번 배포의 확인된 Arn: arn:aws:iam::508473919970:user/b3-1-operator
```

### 1. 로컬 Mac에서 SSH 키 준비

```bash
# 새 배포용 키를 준비하는 예시. 기존 개인키를 덮어쓰지 않는다.
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/b3-1-key.pem -C b3-1-key
chmod 400 ~/.ssh/b3-1-key.pem
curl -4 -fsS https://checkip.amazonaws.com
```

개인키 `~/.ssh/b3-1-key.pem`은 Mac에 둔다. 공개키 `~/.ssh/b3-1-key.pem.pub`만 CloudShell에 올리고 영구 저장소인 `~/b3-1-key.pub`로 준비한다. `/tmp`는 세션 재시작 후 소실될 수 있으므로 사용하지 않는다. 이번 배포는 `import-key-pair`로 공개키만 AWS에 등록했으며 개인키를 AWS로 보내지 않았다. CloudShell의 IP 대신 실제 SSH를 수행할 Mac의 현재 공인 IPv4를 `SSH_IP`에 지정한다.

### 2. CloudShell에서 리소스 생성과 AWS 검증

```bash
# 저장소 루트, 서울 CloudShell, 운영 사용자 프로필
export AWS_PROFILE=b3-1-operator
aws sts get-caller-identity --region ap-northeast-2
test -s "$HOME/b3-1-key.pub"
SSH_IP=121.135.181.35 PUBLIC_KEY_FILE="$HOME/b3-1-key.pub" bash scripts/provision.sh
bash scripts/verify.sh
```

`PUBLIC_KEY_FILE`을 주면 공개키 등록 경로를 사용한다. 이 옵션이 없으면 스크립트가 새 AWS 키페어를 생성해 KEY_PATH에 개인키를 저장하는 기본 경로를 사용한다. 이번 배포는 공개키 등록 경로를 선택했다. 공통 설정은 `REGION`, `AZ`, `KEY_PATH` 환경변수 재정의를 지원하며, 미션 리전은 `ap-northeast-2`로 유지한다.

CloudShell 검증은 RT·SG·외부 HTTP가 PASS이고 개인키가 없으므로 SSH·인스턴스 내부 검증은 건너뛰었다. `.b3-1-state`는 CloudShell의 저장소 루트에 기록되며 삭제 스크립트가 사용한다. EC2 running 상태와 Nginx 준비 완료는 구분한다.

### 3. 로컬 Mac에서 외부·SSH 검증

```bash
# 로컬 저장소 루트; v2 검증 당시 주소(현재 정리 완료)와 로컬 개인키
PUBLIC_IP=43.201.55.219 KEY_PATH="$HOME/.ssh/b3-1-key.pem" bash scripts/verify.sh
curl -i --connect-timeout 5 --max-time 15 http://43.201.55.219/health
ssh -i ~/.ssh/b3-1-key.pem ec2-user@43.201.55.219
# 다음은 EC2 내부에서 필요 시 수행하는 추가 점검 명령
curl -i http://127.0.0.1/health
sudo systemctl status nginx --no-pager
sudo journalctl -u nginx -b --no-pager -n 100
```

로컬 검증은 AWS 자격 증명이 없어 RT·SG 검사를 건너뛰고 외부 HTTP, SSH, nginx active, localhost HTTP 200, `https://example.com` 아웃바운드가 모두 PASS였다. 따라서 CloudShell과 로컬의 두 로그를 함께 근거로 사용한다. 로컬에도 AWS 자격 증명이 있는 재실행 환경이라면 AWS 검사에 필요한 RT/SG/IGW ID도 상태 파일 또는 환경변수로 준비해야 한다.

### 4. 증빙 저장 후 정리

```bash
# 생성 시 상태 파일이 있는 CloudShell 저장소 루트
export AWS_PROFILE=b3-1-operator
bash scripts/cleanup.sh
```

최초 v1 배포의 정리는 완료했다. [logs/cleanup.log](logs/cleanup.log)의 자동 삭제와 [logs/cleanup-verify.log](logs/cleanup-verify.log)의 후속 조회를 함께 근거로 사용했다. EC2는 terminated, 해당 EBS는 0, VPC는 NotFound이며 SG·RT·서브넷·IGW·키페어가 삭제되었다. 실습 액세스키도 삭제하여 남은 수 0을 확인했다. 계정 전체의 RDS `fireview-db`와 EIP `54.116.76.70`은 기존 FireView 리소스로 남겨두었다. Billing 청구서(2026-11-18 10:15 KST)의 예상 총합계는 USD 0.00이며 [요약](screenshots/billing-summary.jpg)·[서비스별](screenshots/billing-services.jpg) 화면을 남겼다. 사용량 반영 지연이 있을 수 있어 다음 날 재확인한다. v2 재배포분도 [logs/tagpolicy-run.log](logs/tagpolicy-run.log) 6절과 [정리 캡처](screenshots/tagpolicy-cleanup.jpg)로 별도 정리 완료를 확인했으며, 03:34:48 UTC 재조회에서 VPC·KeyPair NotFound, EC2 terminated, FireView running, 루트의 액세스키 삭제 후 잔여 0을 확인했다.

## 외부 접속 검증과 증빙

선택 방식: (B) GET /health — 최초 v1은 http://3.35.173.185/health, 최신 v2 재검증은 http://43.201.55.219/health (현재 모두 정리 완료).

v2 로컬 응답은 2026-11-18 03:33:16 UTC(12:33:16 KST)의 `HTTP/1.1 200 OK`, 본문 `OK`다. SSH·nginx active·localhost 200·아웃바운드도 모두 PASS이며 [logs/tagpolicy-verify-local.log](logs/tagpolicy-verify-local.log)에 있다. 아래 상세 표와 브라우저 캡처는 v1 최초 배포 기록이다.

| 접속 정보 | 실측 기록 |
| --- | --- |
| AWS 계정 / 실행 주체 | `508473919970` / `arn:aws:iam::508473919970:user/b3-1-operator` |
| 배포·검증 일자 | 2026-11-18; 생성 완료의 정확한 시각은 provision 로그에 없음 |
| EC2 Instance ID / 퍼블릭 IP | `i-0d3a2ed22d4d891b1` / `3.35.173.185` |
| Mac 공인 IPv4 / 최종 SSH 허용 소스 | `121.135.181.35` / `121.135.181.35/32` |
| 주 검증 URL / 결과 | `http://3.35.173.185/health` / `HTTP/1.1 200 OK`, 본문 `OK` |
| 로컬 외부 응답 시각 | 2026-11-18 00:48:31 UTC = 09:48:31 KST |
| CloudShell 외부 응답 시각 | 2026-11-18 00:48:47 UTC = 09:48:47 KST |
| 보조 방식 (A) | 브라우저 `http://3.35.173.185/`에서 `Hello Cloud - B3-1` 본문 확인 |
| 내부·아웃바운드 | SSH / nginx active / localhost 200 / example.com 모두 PASS |
| 정리·과금 상태 | B3-1 인프라·액세스키 정리 완료; 00:53:11 UTC 재확인. 실제 과금 내역은 후속 확인 필요 |

최초 v1의 주 증빙은 [CloudShell 검증 스크린샷](screenshots/verify-aws-cloudshell.jpg)과 [검증 원문](logs/verify-aws.log), [Mac 검증 원문](logs/verify-local.log)이다. 브라우저 이미지 두 장에는 주소창이 없으므로 페이지 본문 확인용 보조 증빙으로 사용한다. 대상 퍼블릭 IP는 생성 로그 및 로컬 접속 로그와 함께 대조한다. EC2 내부 localhost 성공만으로 외부 접속 성공을 대체하지 않았다.

| 실제 증빙 파일 | 확인 내용 / 범위(별도 v2 표기 외에는 v1) |
| --- | --- |
| [logs/provision.log](logs/provision.log) | CloudShell 생성 단계, 호출 ARN, 리소스 ID, SSH 소스, 퍼블릭 IP |
| [logs/verify-aws.log](logs/verify-aws.log) | RT active, SG 80/22 규칙, 외부 HTTP 200 OK; SSH 검사는 건너뜀 |
| [screenshots/verify-aws-cloudshell.jpg](screenshots/verify-aws-cloudshell.jpg) | 외부 접속 주 스크린샷: CloudShell RT·SG·HTTP 응답과 PASS 출력 |
| [logs/verify-local.log](logs/verify-local.log) | Mac 외부 HTTP와 SSH·Nginx·localhost·아웃바운드 PASS; AWS 검사는 건너뜀 |
| [screenshots/browser-root.jpg](screenshots/browser-root.jpg) | 루트 페이지 문구; 주소창 미포함 |
| [screenshots/browser-health.jpg](screenshots/browser-health.jpg) | `/health`의 OK 본문; 주소창 미포함 |
| [logs/iam-least-privilege.log](logs/iam-least-privilege.log) | S3/RDS/IAM의 특정 호출 AccessDenied |
| [logs/ts-ssh-break.log](logs/ts-ssh-break.log), [symptom](logs/ts-ssh-symptom.log), [fix](logs/ts-ssh-fix.log), [result](logs/ts-ssh-result.log) | 의도적인 SSH 소스 불일치 재현과 복구 |
| [logs/cleanup.log](logs/cleanup.log), [logs/cleanup-verify.log](logs/cleanup-verify.log), [screenshots/cleanup-cloudshell.jpg](screenshots/cleanup-cloudshell.jpg) | 삭제 절차·재조회와 CloudShell 정리 출력; 계정 내 기존 타 프로젝트 리소스 구분 |
| [logs/tagpolicy-run.log](logs/tagpolicy-run.log) | v2 적용, dry-run, 공개키 소실·1차 잔여 정리, 재배포·검증·최종 정리·루트 재확인 |
| [logs/tagpolicy-verify-local.log](logs/tagpolicy-verify-local.log) | v2 Mac 외부 HTTP 200 OK와 SSH·Nginx·localhost·아웃바운드 PASS |
| [screenshots/tagpolicy-dryrun.jpg](screenshots/tagpolicy-dryrun.jpg) | v2 FireView 변경·태그 추가 거부와 생성 태그 조건 비교 |
| [screenshots/tagpolicy-verify-compare.jpg](screenshots/tagpolicy-verify-compare.jpg) | v2 서비스 검증과 B3-1 허용 / FireView 거부 dry-run 비교 |
| [screenshots/tagpolicy-cleanup.jpg](screenshots/tagpolicy-cleanup.jpg) | v2 삭제 후 EC2 terminated·VPC/KeyPair NotFound·FireView running |

## 요구사항 체크리스트

| 요구사항 | 어떻게 충족했는가 | 근거 / 상태 |
| --- | --- | --- |
| 서울 리전·AZ, VPC·서브넷 | 서울/2a, `10.0.0.0/16`, `10.0.1.0/24`로 생성 | `infra/config.env`, `scripts/provision.sh`, `logs/provision.log` — 배포 완료 |
| IGW·RT·퍼블릭 IP | 기본 경로가 해당 IGW로 active, 자동 퍼블릭 IP로 외부 응답 | `logs/provision.log`, `logs/verify-aws.log` — 확인 완료 |
| SG 제한 | TCP 80 전체 IPv4, TCP 22 `121.135.181.35/32`, 전체 포트 인바운드 없음 | `logs/verify-aws.log`, `screenshots/verify-aws-cloudshell.jpg` — 확인 완료 |
| EC2·EBS·키 | AL2023, t3.micro, gp3 8 GiB, 로컬 ed25519 공개키 등록 | 설정·생성 스크립트, `logs/provision.log`; SSH는 `logs/verify-local.log` — 배포·접속 완료 |
| Nginx 서비스 | 루트 문구, 외부 `/health` 200 OK, nginx active, localhost 200 | 브라우저 이미지·검증 로그 — 확인 완료 |
| 외부 검증 B + 보조 A | CloudShell·Mac의 HTTP + 브라우저 본문 확인 | 실제 증빙 표 참조 — 확인 완료; 브라우저 주소창 없음 명시 |
| 운영 사용자·최소권한 | v2 생성 요청 태그 필수, 기존 리소스는 B3-1 태그 조건, 독립 태그 추가 거부 | `infra/iam-policy.json`, `logs/tagpolicy-run.log` — dry-run 비교·재배포·정리 확인; IAM/Billing은 루트 |
| Project 태그 | v2 정책에서 요청·기존 리소스 태그 조건을 적용하고 태그 없는 VPC 생성 거부 | `logs/tagpolicy-run.log` 1·5절 — 권한 평가 비교 확인; 전체 리소스별 태그 조회 원문은 별도 미수집 |
| 트러블슈팅 | v1 SSH 소스 불일치 복구, v2 공개키 소실과 부재 키페어의 권한 거부 진단 | `docs/troubleshooting.md`, `logs/ts-ssh-*.log`, `logs/tagpolicy-run.log` — 실제 기록 |
| 삭제·비용 정리 | v1·v2 자동 cleanup 및 재조회·키 삭제 | `logs/cleanup*.log`, `logs/tagpolicy-run.log`, `docs/cleanup-checklist.md` — 둘 다 정리 완료; Billing 캡처는 v1 이후 기록 |

## 대표 과금 요인과 보너스

EC2 실행 시간, EBS gp3 용량·추가 성능, 퍼블릭 IPv4 사용 시간, 인터넷 데이터 전송 등이 대표 과금 요인이다. 자동 퍼블릭 IPv4도 과금 대상이 될 수 있고 EC2 중지 후에도 남은 EBS는 별도 비용이 발생할 수 있다. 실제 단가와 무료 제공 조건은 [EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/), [EBS](https://aws.amazon.com/ebs/pricing/), [VPC 퍼블릭 IPv4](https://aws.amazon.com/vpc/pricing/)에서 확인한다. 기존 청구서 캡처는 v1 정리 이후의 예상 금액이며 v2 사용분을 별도로 분리한 금액은 아직 없다.

Elastic IP, NAT Gateway, ELB, RDS는 이 배포 스크립트에서 생성하지 않는다. 정리 후 B3-1 대상 잔여가 없음을 로그로 확인했으며 기존 FireView의 RDS 1건과 EIP 1건은 유지했다. 계정 전체 리소스 0을 주장하지 않으며, Billing USD 0.00은 무료 플랜 크레딧 충당 결과라 B3-1 사용분만의 금액은 아니다. 보너스인 HTTPS/도메인, 로드 밸런서, Auto Scaling, 다중 AZ 구성은 미수행이다.

## 문서 자체 점검

실측 IP·리소스 ID·HTTP 응답·SSH 복구와 IAM 거부는 제공된 원문 로그에 근거한다. 미수집된 생성 완료 시각·전체 태그 조회는 성공으로 채우지 않았다. v1 삭제는 두 cleanup 로그, v2 삭제는 tagpolicy-run 로그에 근거하며 루트의 정책 적용·후속 감사·키 삭제도 기록했다. dry-run의 허용 응답과 실제 실행을 구분했고 디코딩하지 않은 오류의 decode 결과는 만들지 않았다. 브라우저 이미지에 없는 주소창을 있다고 설명하지 않았고, 파이프라인 `tail`의 종료 코드를 SSH 성공 근거로 사용하지 않았다. 다이어그램은 1800×1180 PNG이며 HTTP·SSH 흐름을 설명한다.
