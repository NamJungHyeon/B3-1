# Codyssey B3-1 — AWS VPC + EC2 + Nginx

서울 리전(`ap-northeast-2`)에 VPC·퍼블릭 서브넷·EC2를 만들고 Nginx로 웹 서비스를 띄운 뒤, 외부 접속 검증과 리소스 정리까지 마친 기록이다.

> **현재 상태: 모든 리소스 정리 완료.** 아래의 퍼블릭 IP는 검증 당시 기록이며 지금은 접속할 수 없다.

## 목차

1. [한눈에 보기](#1-한눈에-보기)
2. [디렉터리 구조](#2-디렉터리-구조)
3. [아키텍처와 트래픽 흐름](#3-아키텍처와-트래픽-흐름)
4. [Security Group과 IAM 최소권한](#4-security-group과-iam-최소권한)
5. [실행 방법](#5-실행-방법)
6. [검증 결과와 증빙](#6-검증-결과와-증빙)
7. [정리와 비용](#7-정리와-비용)
8. [요구사항 체크리스트](#8-요구사항-체크리스트)
9. [한계와 미수행 항목](#9-한계와-미수행-항목)

---

## 1. 한눈에 보기

배포는 두 번 했다. 처음에는 IAM 정책 v1으로 배포했고, 정책을 태그 조건으로 강화한 v2로 한 번 더 배포해 검증했다. 두 회차 모두 검증과 정리를 마쳤다.

| 회차 | IAM 정책 | EC2 / 당시 퍼블릭 IP | 외부 HTTP 확인 (UTC) | 정리 재확인 (UTC) | 근거 |
| --- | --- | --- | --- | --- | --- |
| 최초 배포 | v1 | `i-0d3a2ed22d4d891b1` / `3.35.173.185` | 00:48:31 | 00:53:11 | `logs/provision.log`, `logs/verify-*.log`, `logs/cleanup*.log` |
| 태그 정책 재검증 | v2 | `i-04dd8916b77900977` / `43.201.55.219` | 03:33:16 | 03:34:48 | `logs/tagpolicy-run.log`, `logs/tagpolicy-verify-local.log` |

날짜는 모두 2026-11-18이다. KST는 UTC+9.

**검증 결과 요약** (두 회차 공통)

- ✅ 외부 `GET /health` → `HTTP/1.1 200 OK`, 본문 `OK`
- ✅ 외부 `GET /` → `Hello Cloud - B3-1`
- ✅ SSH 접속 (내 IP `/32`만 허용)
- ✅ EC2 내부: nginx active, `localhost` 200, 아웃바운드 `https://example.com` 성공
- ✅ IAM 최소권한: 관련 없는 S3·RDS·IAM 호출 거부, 다른 프로젝트 리소스 변경 거부
- ✅ 정리: EC2 terminated, VPC·키페어 NotFound, 실습 액세스키 삭제

설정값의 기준은 [infra/config.env](infra/config.env)다.

---

## 2. 디렉터리 구조

```text
.
├── README.md
├── .gitignore                    # 상태 파일(.b3-1-state*)과 개인키(*.pem) 제외
├── infra/
│   ├── config.env                # 리전·CIDR·인스턴스 타입 등 공통 설정
│   ├── iam-policy.json           # 운영 사용자 최소권한 정책 (v2)
│   └── user-data.sh              # EC2 첫 부팅 시 Nginx 설치
├── scripts/
│   ├── provision.sh              # 리소스 생성
│   ├── verify.sh                 # 요구사항 검증
│   └── cleanup.sh                # 리소스 삭제와 잔여 확인
├── docs/
│   ├── architecture.png          # 구성도
│   ├── diagram/draw_architecture.py  # 구성도 재생성 소스 (Pillow)
│   ├── troubleshooting.md        # 장애 사례 3건
│   ├── cleanup-checklist.md      # 회차별 삭제 체크리스트
│   └── project-walkthrough.md    # 동료평가 발표 대본
├── logs/                         # 실행 출력 원문 (아래 6장 참고)
└── screenshots/                  # 실제 콘솔·브라우저 캡처 (아래 6장 참고)
```

- `.b3-1-state`는 CloudShell에서 `provision.sh`가 만드는 상태 파일이다. Git에는 넣지 않는다.
- 일부 CloudShell 로그는 터미널 출력을 그대로 옮겨 적은 것이며, 파일 첫 줄에 그렇게 표시했다.
- 개인키·액세스키·토큰은 저장소에 없다.

---

## 3. 아키텍처와 트래픽 흐름

![B3-1 아키텍처](docs/architecture.png)

> 그림은 v1 배포의 주소를 넣어 그린 구성도이며 AWS 콘솔 캡처가 아니다. v2도 같은 구조지만 리소스 ID와 IP는 다르다.

### 구성 요소

| 구성 요소 | 설정 | v1 리소스 ID |
| --- | --- | --- |
| 리전 / AZ | `ap-northeast-2` / `ap-northeast-2a` | — |
| VPC | `b3-1-vpc`, `10.0.0.0/16` | `vpc-017b387de9ebebe39` |
| 퍼블릭 서브넷 | `b3-1-public-subnet`, `10.0.1.0/24` | `subnet-053424ed40ee5e872` |
| Internet Gateway | `b3-1-igw` | `igw-0f2ea6a5447a030d1` |
| Route Table | `b3-1-public-rt`, `0.0.0.0/0 → IGW` | `rtb-062bb6ef39f712a4b` (연결 `rtbassoc-0a575477549135e20`) |
| Security Group | `b3-1-web-sg`: TCP 80 `0.0.0.0/0`, TCP 22 `121.135.181.35/32` | `sg-0b9bcafca08337847` |
| EC2 / EBS | Amazon Linux 2023, `t3.micro`, `gp3` 8 GiB | `i-0d3a2ed22d4d891b1` |
| 키페어 / 퍼블릭 IP | `b3-1-key` / 자동 할당 IPv4 (Elastic IP 미사용) | `3.35.173.185` |
| 웹 서버 | Nginx: `/` → `Hello Cloud - B3-1`, `/health` → 200 `OK` | — |

모든 리소스에 `Project=B3-1` 태그를 붙인다. 리소스 ID는 [생성 로그](logs/provision.log), 라우트 active 상태와 SG 규칙은 [AWS 검증 로그](logs/verify-aws.log)에서 확인할 수 있다.

### 요청이 서버까지 가는 길

```text
HTTP:  인터넷 → Internet Gateway → EC2 퍼블릭 IPv4 → SG (TCP 80 허용) → Nginx
SSH:   내 Mac (121.135.181.35) → Internet Gateway → EC2 → SG (TCP 22, /32만 허용) → sshd
응답:  EC2 → 서브넷 Route Table의 0.0.0.0/0 → IGW → 인터넷
```

인터넷 접속이 되려면 아래 네 가지가 모두 맞아야 한다. 하나라도 빠지면 접속이 안 된다.

1. **IGW**가 VPC에 연결되어 있다.
2. 서브넷 **Route Table**에 `0.0.0.0/0 → IGW` 경로가 있다.
3. EC2에 **퍼블릭 IPv4**가 있다. 자동 할당 IP는 중지 후 다시 시작하면 바뀔 수 있다.
4. **SG**가 해당 포트와 소스를 허용한다.

참고: [AWS Internet Gateway 문서](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html)

---

## 4. Security Group과 IAM 최소권한

세 가지는 막는 대상이 다르다.

| 장치 | 무엇을 제어하나 | 이 미션의 설정 |
| --- | --- | --- |
| Security Group | EC2로 들어오는 네트워크 트래픽 | TCP 80 전체, TCP 22 내 IP `/32`만. 전체 포트 허용 규칙 없음 |
| IAM | AWS API를 호출할 권한 | 운영 사용자 `b3-1-operator`에 커스텀 정책 `B3-1-LeastPrivilege` 하나만 연결. AdministratorAccess 없음 |
| SSH 키 | 운영체제 로그인 | `b3-1-key` 개인키로 `ec2-user` 로그인 |

### IAM 정책 v2

[정책 원문](infra/iam-policy.json)은 v2이고, v1과의 차이는 커밋 `a19ea88`의 diff로 볼 수 있다.

- **v1의 문제:** 리전만 맞으면 Project 태그가 없는 다른 EC2도 변경하거나 삭제할 수 있었다.
- **v2의 해결:** 리소스를 만들 때는 `Project=B3-1` 태그를 반드시 붙여야 하고, 기존 리소스는 이 태그가 있을 때만 변경·삭제할 수 있다.

일부 Statement의 Resource가 `*`이어도 무엇이든 허용하는 것은 아니다. 아래 표의 Condition이 함께 걸린다.

| 작업 | 허용 조건 | Statement (Sid) |
| --- | --- | --- |
| EC2 조회 | `ec2:Describe*`, `GetConsoleOutput`을 서울 리전에서만. 조회 대상의 태그는 제한하지 않음 | `ReadOnlyDescribeInSeoul` |
| 리소스 생성 | VPC·Subnet·IGW·RT·SG·KeyPair 생성, ImportKeyPair, RunInstances는 요청에 `Project=B3-1` 태그가 있어야 함. 서울 리전 ARN만 | `CreateOnlyWithProjectTag` |
| 태그 붙이기 | `CreateTags`는 위 생성 작업과 동시에 할 때만. 기존 리소스에 따로 태그를 붙이는 것은 거부 | `TagOnlyAtCreation` |
| 기존 리소스 변경·삭제 | 서울 리전에서 `Project=B3-1` 태그가 있는 리소스만. Start/Stop/Reboot/Terminate 포함 | `UseAndDeleteOnlyProjectTaggedResources` |
| 태그 없는 보조 리소스 | RunInstances와 SG 규칙 작업에 필요한 image, network-interface, security-group-rule ARN은 태그 조건 없이 허용. 액션과 서울 ARN으로만 제한 | `UntaggableSubResources` |
| 인스턴스 크기 | `t2.micro`, `t3.micro` 외에는 명시적으로 거부 | `OnlyMicroInstances` |
| AMI 조회·진단 | 서울 AL2023 공개 SSM 파라미터 조회, `sts:GetCallerIdentity`, `DecodeAuthorizationMessage` | `ReadAmiParameter`, `DecodeAuthErrorsForTroubleshooting` |
| 그 밖의 서비스 | S3·RDS·IAM 관리·Billing 권한은 없음 | — |

### v2 권한 검증 (dry-run)

[logs/tagpolicy-run.log](logs/tagpolicy-run.log) 1·5절에서 발췌했다. 비교 대상은 다음 두 인스턴스다.

- B3-1: `i-04dd8916b77900977` (`Project=B3-1`)
- FireView: `i-0f29938e558d1e55c` (같은 계정의 다른 프로젝트, 태그 없음)

```text
terminate FireView                     => UnauthorizedOperation   (거부)
stop FireView                          => UnauthorizedOperation   (거부)
create-tags Project=B3-1 on FireView   => UnauthorizedOperation   (거부)
create-vpc (태그 없음)                  => UnauthorizedOperation   (거부)
create-vpc (Project=B3-1)              => DryRunOperation         (허용)
terminate B3-1                         => DryRunOperation         (허용)
reboot B3-1                            => DryRunOperation         (허용)
reboot FireView                        => UnauthorizedOperation   (거부)
```

- `DryRunOperation`은 권한상 허용된다는 응답일 뿐이고, 실제로 실행한 것은 아니다.
- FireView는 실제로 중지·종료하거나 태그를 바꾸지 않았고, 정리 후에도 running 상태임을 확인했다.
- 캡처: [배포 전 dry-run](screenshots/tagpolicy-dryrun.jpg), [서비스 검증·리소스 비교](screenshots/tagpolicy-verify-compare.jpg)

v1 배포 때 관련 없는 서비스의 호출이 거부된 기록은 [logs/iam-least-privilege.log](logs/iam-least-privilege.log)에 있다. 거부된 호출은 S3 ListBuckets, RDS DescribeDBInstances, IAM ListUsers다.

### 루트 계정 사용 범위

| 수행 주체 | 한 일 |
| --- | --- |
| 운영 사용자 `b3-1-operator` | 인프라 생성·검증·정리 |
| 루트 | IAM 사용자·정책 생성, v2 정책 적용, 액세스키 삭제, 계정 단위 사후 점검, Billing 조회 |

모든 단계에서 루트를 쓰지 않았다고 말할 수는 없다. IAM 사용자와 정책은 증빙용으로 남겨 두었고, 실습에 쓴 액세스키는 삭제했다.

---

## 5. 실행 방법

> 같은 구성을 다시 만들 때의 안내다. 이미 만든 리소스, 상태 파일, 키페어와 충돌할 수 있으므로 끝난 배포 위에서 그대로 다시 실행하지 않는다.

**준비물:** AWS CLI v2, Bash, curl, SSH 클라이언트. 운영 사용자에게는 커스텀 정책만 연결한다. 처음 IAM 사용자를 만들 때는 IAM 관리 권한이 있는 주체가 필요하다.

### 0. AWS 프로필 설정

```bash
aws configure --profile b3-1-operator     # region: ap-northeast-2, output: json
export AWS_PROFILE=b3-1-operator
aws sts get-caller-identity --region ap-northeast-2
# 이번 배포의 Arn: arn:aws:iam::508473919970:user/b3-1-operator
```

### 1. 로컬 Mac에서 SSH 키 준비

```bash
mkdir -p ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/b3-1-key.pem -C b3-1-key   # 기존 키를 덮어쓰지 않게 주의
chmod 400 ~/.ssh/b3-1-key.pem
curl -4 -fsS https://checkip.amazonaws.com                 # 내 공인 IP 확인 → SSH_IP에 사용
```

- 개인키 `~/.ssh/b3-1-key.pem`은 Mac에만 둔다.
- 공개키 `~/.ssh/b3-1-key.pem.pub`만 CloudShell의 `~/b3-1-key.pub`로 올린다.
- ⚠️ 공개키를 `/tmp`에 두면 안 된다. CloudShell 세션이 다시 시작되면 사라진다. v2 1차 배포가 이 때문에 중단됐다. 자세한 내용은 [트러블슈팅 사례 3](docs/troubleshooting.md)에 있다.

### 2. CloudShell에서 생성과 AWS 검증

```bash
export AWS_PROFILE=b3-1-operator
test -s "$HOME/b3-1-key.pub"
SSH_IP=121.135.181.35 PUBLIC_KEY_FILE="$HOME/b3-1-key.pub" bash scripts/provision.sh
bash scripts/verify.sh
```

| 옵션 | 동작 |
| --- | --- |
| `PUBLIC_KEY_FILE` 지정 | 공개키만 AWS에 등록한다 (`import-key-pair`). **이번 배포에서 사용한 방식이다.** |
| `PUBLIC_KEY_FILE` 미지정 | AWS가 새 키페어를 만들고, 개인키를 `KEY_PATH`에 저장한다. |
| `SSH_IP` | SSH를 허용할 IP. CloudShell의 IP가 아니라 실제로 SSH를 할 Mac의 IP를 넣는다. |
| `REGION`, `AZ`, `KEY_PATH` | 환경변수로 바꿀 수 있다. 미션 리전은 `ap-northeast-2`로 유지한다. |

CloudShell에는 개인키가 없어서 SSH와 인스턴스 내부 검사는 건너뛴다. 생성된 리소스 ID는 `.b3-1-state`에 기록되고 `cleanup.sh`가 이 파일을 읽는다.

### 3. 로컬 Mac에서 외부·SSH 검증

```bash
PUBLIC_IP=43.201.55.219 KEY_PATH="$HOME/.ssh/b3-1-key.pem" bash scripts/verify.sh
curl -i --connect-timeout 5 --max-time 15 http://43.201.55.219/health
ssh -i ~/.ssh/b3-1-key.pem ec2-user@43.201.55.219

# EC2 안에서 추가로 점검할 때
curl -i http://127.0.0.1/health
sudo systemctl status nginx --no-pager
sudo journalctl -u nginx -b --no-pager -n 100
```

로컬에는 AWS 자격 증명이 없어서 RT·SG 검사는 건너뛴다. 그래서 CloudShell 로그와 로컬 로그를 함께 증빙으로 쓴다.

### 4. 증빙 저장 후 정리

```bash
export AWS_PROFILE=b3-1-operator
bash scripts/cleanup.sh      # 상태 파일이 있는 CloudShell 저장소 루트에서 실행
```

삭제 순서는 의존 관계의 역순이다: EC2(+EBS) → EIP → SG → RT → Subnet → IGW → VPC → 키페어. 마지막에 `Project=B3-1` 태그가 붙은 리소스가 남아 있는지 조회한다.

---

## 6. 검증 결과와 증빙

외부 접속 검증은 **(B) `GET /health`** 방식을 주로 쓰고, **(A) 브라우저 확인**을 보조로 썼다.

### v1 상세 기록

| 항목 | 기록 |
| --- | --- |
| 계정 / 실행 주체 | `508473919970` / `arn:aws:iam::508473919970:user/b3-1-operator` |
| EC2 / 퍼블릭 IP | `i-0d3a2ed22d4d891b1` / `3.35.173.185` |
| SSH 허용 소스 | Mac 공인 IP `121.135.181.35/32` |
| `/health` 응답 | `HTTP/1.1 200 OK`, 본문 `OK` |
| 응답 시각 | Mac 00:48:31 UTC, CloudShell 00:48:47 UTC |
| 브라우저 | `http://3.35.173.185/`에서 `Hello Cloud - B3-1` 확인 |
| 내부 검사 | SSH, nginx active, localhost 200, example.com 모두 PASS |

v2 결과(03:33:16 UTC, 모두 PASS)는 [logs/tagpolicy-verify-local.log](logs/tagpolicy-verify-local.log)에 있다. 생성 완료 시각은 provision 로그에 남지 않아 적지 않았다.

### 증빙 파일 목록

별도 표시가 없으면 v1 기록이다.

**생성과 검증**

| 파일 | 내용 |
| --- | --- |
| [logs/provision.log](logs/provision.log) | 생성 단계, 호출 ARN, 리소스 ID, SSH 소스, 퍼블릭 IP |
| [logs/verify-aws.log](logs/verify-aws.log) | CloudShell: RT active, SG 80/22 규칙, 외부 HTTP 200 (SSH는 건너뜀) |
| [screenshots/verify-aws-cloudshell.jpg](screenshots/verify-aws-cloudshell.jpg) | 위 검증의 CloudShell 화면 (**외부 접속 주 증빙**) |
| [logs/verify-local.log](logs/verify-local.log) | Mac: 외부 HTTP, SSH, nginx, localhost, 아웃바운드 PASS (AWS 검사는 건너뜀) |
| [screenshots/browser-root.jpg](screenshots/browser-root.jpg) | 루트 페이지 문구 (주소창 없음, 보조 증빙) |
| [screenshots/browser-health.jpg](screenshots/browser-health.jpg) | `/health`의 `OK` (주소창 없음, 보조 증빙) |

**권한과 트러블슈팅**

| 파일 | 내용 |
| --- | --- |
| [logs/iam-least-privilege.log](logs/iam-least-privilege.log) | S3·RDS·IAM 호출 AccessDenied |
| [logs/ts-ssh-break.log](logs/ts-ssh-break.log) → [symptom](logs/ts-ssh-symptom.log) → [fix](logs/ts-ssh-fix.log) → [result](logs/ts-ssh-result.log) | SSH 소스 IP를 일부러 틀리게 바꿔 장애를 재현하고 복구한 과정 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 사례 3건: HTTP 타임아웃(예상 시나리오), SSH 타임아웃(실제 재현), 공개키 소실(v2 실제 사례) |

**v2 태그 정책 재검증**

| 파일 | 내용 |
| --- | --- |
| [logs/tagpolicy-run.log](logs/tagpolicy-run.log) | v2 적용, dry-run, 공개키 소실과 1차 잔여 정리, 재배포·검증·최종 정리, 루트 재확인 |
| [logs/tagpolicy-verify-local.log](logs/tagpolicy-verify-local.log) | Mac 외부 HTTP 200, SSH·nginx·localhost·아웃바운드 PASS |
| [screenshots/tagpolicy-dryrun.jpg](screenshots/tagpolicy-dryrun.jpg) | FireView 변경·태그 추가 거부, 생성 시 태그 조건 비교 |
| [screenshots/tagpolicy-verify-compare.jpg](screenshots/tagpolicy-verify-compare.jpg) | 서비스 검증, B3-1 허용 / FireView 거부 비교 |
| [screenshots/tagpolicy-cleanup.jpg](screenshots/tagpolicy-cleanup.jpg) | 삭제 후 EC2 terminated, VPC·키페어 NotFound, FireView running |

**정리와 비용**

| 파일 | 내용 |
| --- | --- |
| [logs/cleanup.log](logs/cleanup.log), [logs/cleanup-verify.log](logs/cleanup-verify.log) | 자동 삭제와 삭제 후 재조회 |
| [screenshots/cleanup-cloudshell.jpg](screenshots/cleanup-cloudshell.jpg) | CloudShell 정리 출력 |
| [docs/cleanup-checklist.md](docs/cleanup-checklist.md) | 회차별 삭제 체크리스트 |
| [screenshots/billing-summary.jpg](screenshots/billing-summary.jpg), [screenshots/billing-services.jpg](screenshots/billing-services.jpg) | 청구서 요약과 서비스별 화면 |

---

## 7. 정리와 비용

### 정리 결과

| 회차 | 결과 | 근거 |
| --- | --- | --- |
| v1 | EC2 terminated, EBS 0, VPC NotFound. SG·RT·서브넷·IGW·키페어 삭제. 액세스키 0 | `logs/cleanup.log`, `logs/cleanup-verify.log` |
| v2 | 03:34:48 UTC 재조회: EC2 terminated, VPC·키페어 NotFound. 루트로 액세스키 삭제 후 0 | `logs/tagpolicy-run.log` 6절, `screenshots/tagpolicy-cleanup.jpg` |

같은 계정에 있는 FireView 프로젝트의 RDS `fireview-db`와 EIP `54.116.76.70`은 B3-1과 관계없는 기존 리소스라 그대로 두었다. 계정 전체 리소스가 0개라는 뜻은 아니다.

### 과금 요인

이 미션에서 과금되는 대표 항목은 EC2 실행 시간, EBS gp3 용량, 퍼블릭 IPv4 사용 시간(자동 할당 IP 포함), 인터넷 데이터 전송이다. EC2를 중지해도 EBS 비용은 계속 나간다. Elastic IP, NAT Gateway, ELB, RDS는 만들지 않았다.

정확한 단가: [EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/), [EBS](https://aws.amazon.com/ebs/pricing/), [VPC 퍼블릭 IPv4](https://aws.amazon.com/vpc/pricing/)

### Billing 확인

- 2026-11-18 10:15 KST 청구서의 예상 총합계는 **USD 0.00**이다.
- 이 금액은 무료 플랜 크레딧으로 충당된 결과이므로, B3-1 사용분만 따로 계산한 금액이 아니다.
- 이 캡처는 v1 정리 후에 찍었기 때문에 v2 사용분은 반영되지 않았다. 사용량은 늦게 반영될 수 있어 다음 날 다시 확인해야 한다.

---

## 8. 요구사항 체크리스트

| 요구사항 | 충족 방법 | 근거 |
| --- | --- | --- |
| ✅ 서울 리전·AZ, VPC·서브넷 | 서울 `2a`, `10.0.0.0/16`, `10.0.1.0/24` | `infra/config.env`, `scripts/provision.sh`, `logs/provision.log` |
| ✅ IGW·RT·퍼블릭 IP | IGW로 가는 기본 경로 active, 자동 퍼블릭 IP로 외부 응답 | `logs/provision.log`, `logs/verify-aws.log` |
| ✅ SG 제한 | TCP 80 전체, TCP 22 `/32`, 전체 포트 허용 규칙 없음 | `logs/verify-aws.log`, `screenshots/verify-aws-cloudshell.jpg` |
| ✅ EC2·EBS·키 | AL2023, t3.micro, gp3 8 GiB, ed25519 공개키 등록 | `logs/provision.log`, `logs/verify-local.log` |
| ✅ Nginx 서비스 | 루트 문구, `/health` 200, nginx active, localhost 200 | 브라우저 캡처, 검증 로그 |
| ✅ 외부 검증 (B) + 보조 (A) | CloudShell·Mac의 HTTP 확인 + 브라우저 본문 확인 | 6장 증빙 목록 (브라우저 캡처에는 주소창 없음) |
| ✅ 운영 사용자·최소권한 | 생성 시 태그 필수, 기존 리소스는 태그 조건, 따로 태그 붙이기 거부 | `infra/iam-policy.json`, `logs/tagpolicy-run.log` |
| ✅ Project 태그 | 태그 없는 VPC 생성 거부, 태그 있는 생성 허용 | `logs/tagpolicy-run.log` 1·5절 |
| ✅ 트러블슈팅 | SSH 소스 불일치 복구(v1), 공개키 소실 진단(v2) | `docs/troubleshooting.md`, `logs/ts-ssh-*.log` |
| ✅ 삭제·비용 정리 | 두 회차 모두 자동 정리, 재조회, 액세스키 삭제 | `logs/cleanup*.log`, `logs/tagpolicy-run.log`, `docs/cleanup-checklist.md` |

---

## 9. 한계와 미수행 항목

**IAM 정책의 남은 한계**

- `Describe*`로 서울 리전의 계정 전체 EC2 리소스를 조회할 수 있다.
- 사용자가 직접 `Project=B3-1` 태그를 붙이면 허용된 액션·리전·인스턴스 타입 안에서는 새 리소스를 만들 수 있다.
- 같은 태그가 붙은 리소스끼리 소유자를 구분하거나 비용 한도를 강제하지는 않는다.

**기록하지 못한 것**

- 생성 완료 시각과 리소스별 전체 태그 조회 결과는 수집하지 않았다. 없는 결과를 성공으로 채우지 않았다.
- 트러블슈팅 사례 3의 권한 오류 메시지는 decode하지 않았다.
- 브라우저 캡처에는 주소창이 없어서 보조 증빙으로만 썼다.
- v2 이후 Billing은 다시 캡처하지 않았다.

**보너스 미수행:** HTTPS·도메인, 로드 밸런서, Auto Scaling, 다중 AZ
