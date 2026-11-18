# Codyssey B3-1 — AWS VPC + EC2 + Nginx

서울 리전(ap-northeast-2)에 VPC와 퍼블릭 서브넷을 구성하고 EC2의 Nginx 웹 서비스를 배포했다. 외부 HTTP, SSH, Nginx 상태, localhost 응답과 아웃바운드 검증을 완료했으며 원문은 [logs/verify-aws.log](logs/verify-aws.log)와 [logs/verify-local.log](logs/verify-local.log)에 있다. 설정의 기준은 [infra/config.env](infra/config.env)이다.

현재 상태: 배포·서비스 검증과 B3-1 인프라 정리 완료. 2026-11-18 00:53:11 UTC에 EC2 terminated, VPC NotFound와 해당 EBS 0을 재확인했다. IAM 액세스키도 삭제했다. [삭제 체크리스트](docs/cleanup-checklist.md)에 근거를 기록했으며 Billing Dashboard 확인은 미완료다. 아래 IP와 리소스 ID는 2026-11-18 검증 당시의 기록이며, 리소스 종료·삭제 후에는 접속 대상으로 사용하지 않는다.

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
│   └── ts-ssh-{break,symptom,fix,result}.log
├── screenshots/
│   ├── verify-aws-cloudshell.jpg
│   ├── cleanup-cloudshell.jpg
│   ├── browser-root.jpg
│   └── browser-health.jpg
└── .b3-1-state                 # CloudShell에서 provision이 기록한 상태 파일; Git 제외
```

일부 CloudShell 로그는 터미널 출력의 원문 전사본이며 파일 머리말에 구분되어 있다. 스크린샷은 실제 캡처다. 개인키·액세스키·토큰은 제출 파일에 포함하지 않는다.

## 구성과 트래픽 흐름

![B3-1 아키텍처](docs/architecture.png)

그림은 배포 구성의 설명도이며 AWS 콘솔 캡처가 아니다. 미션 스크립트는 리소스에 `Project=B3-1` 태그를 지정한다.

| 구성 요소 | 설정 / 배포된 ID |
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

## Security Group과 IAM, 최소권한

| 구분 | 제어 대상 | 적용 내역 |
| --- | --- | --- |
| Security Group | EC2 네트워크 트래픽 | TCP 80은 전체 IPv4, TCP 22는 관리자 IPv4 `/32`만 허용 |
| IAM | AWS API 호출 주체와 허용 작업 | `b3-1-operator`에 커스텀 `B3-1-LeastPrivilege`만 부착; AdministratorAccess 없음 |
| SSH 키페어 | EC2 운영체제 로그인 인증 | 로컬 Mac에서 만든 ed25519 키의 공개키만 등록; 개인키는 로컬 보관 |

실행 주체는 `arn:aws:iam::508473919970:user/b3-1-operator`다. 초기 IAM 사용자·정책 생성과 정리 후 감사·액세스키 삭제에 루트 계정을 사용했고, 인프라 생성·정리와 운영 단계 AWS 리소스 검증은 CloudShell의 운영 사용자 프로필로 수행했다. 따라서 이 실습을 “모든 단계에서 루트 미사용”으로 표현하지 않는다. 로컬 Mac에서는 AWS 자격 증명 없이 외부 HTTP와 SSH 검증을 수행했다.

IAM 허용은 SG 포트를 열지 않으며 SG 허용은 API 권한을 부여하지 않는다. [정책 원문](infra/iam-policy.json)은 서울 리전의 EC2 조회·생명주기 작업, AMI용 제한된 SSM 파라미터 읽기, STS 호출 주체 확인·권한 오류 디코딩을 허용한다. 실행 타입 제한에는 `t2.micro`와 `t3.micro`가 포함되지만 실제 배포는 `t3.micro`다. 일부 EC2 액션의 Resource가 `*`, 조회가 `ec2:Describe*`이므로 미션 액션·리전 중심 제한이며 특정 VPC나 Project 태그만 강제하는 리소스별 제한은 아니다.

[최소권한 검증 로그](logs/iam-least-privilege.log)에서는 `s3:ListAllMyBuckets`, `rds:DescribeDBInstances`, `iam:ListUsers`가 모두 AccessDenied로 거부됐다. 이는 해당 무관 서비스 작업의 거부를 확인한 근거이며 전체 IAM 권한 평가를 대체하지 않는다. 운영 사용자에게 S3/RDS/IAM 관리·Billing 권한을 추가하지 않았다. 실제 루트 사용 범위는 초기 IAM 사용자·정책 생성과 정리 후 ELB/RDS/NAT 감사·운영 사용자 액세스키 삭제였다. 인프라 생성·정리는 `b3-1-operator`로 수행했다. [삭제 후 재확인 로그](logs/cleanup-verify.log)에 루트 사용 구간과 액세스키 잔여 0을 구분해 기록했다. 사용자와 커스텀 정책은 과금 없는 증빙용으로 유지했고 Billing 감사 결과는 아직 없다.

## 사전 준비와 실행 방법

다음 명령은 같은 구성을 다시 수행하기 위한 안내다. 이번 배포에서 사용한 옵션은 `SSH_IP=121.135.181.35 PUBLIC_KEY_FILE=/tmp/b3-1-key.pub`이며 [생성 로그](logs/provision.log)에 기록되어 있다. 기존 리소스·상태 파일·키페어와 충돌할 수 있으므로 완료된 생성을 그대로 반복하지 않는다.

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

개인키 `~/.ssh/b3-1-key.pem`은 Mac에 둔다. 공개키 `~/.ssh/b3-1-key.pem.pub`만 CloudShell에 올리고 `/tmp/b3-1-key.pub`로 준비한다. 이번 배포는 `import-key-pair`로 공개키만 AWS에 등록했으며 개인키를 AWS로 보내지 않았다. CloudShell의 IP 대신 실제 SSH를 수행할 Mac의 현재 공인 IPv4를 `SSH_IP`에 지정한다.

### 2. CloudShell에서 리소스 생성과 AWS 검증

```bash
# 저장소 루트, 서울 CloudShell, 운영 사용자 프로필
export AWS_PROFILE=b3-1-operator
aws sts get-caller-identity --region ap-northeast-2
SSH_IP=121.135.181.35 PUBLIC_KEY_FILE=/tmp/b3-1-key.pub bash scripts/provision.sh
bash scripts/verify.sh
```

`PUBLIC_KEY_FILE`을 주면 공개키 등록 경로를 사용한다. 이 옵션이 없으면 스크립트가 새 AWS 키페어를 생성해 KEY_PATH에 개인키를 저장하는 기본 경로를 사용한다. 이번 배포는 공개키 등록 경로를 선택했다. 공통 설정은 `REGION`, `AZ`, `KEY_PATH` 환경변수 재정의를 지원하며, 미션 리전은 `ap-northeast-2`로 유지한다.

CloudShell 검증은 RT·SG·외부 HTTP가 PASS이고 개인키가 없으므로 SSH·인스턴스 내부 검증은 건너뛰었다. `.b3-1-state`는 CloudShell의 저장소 루트에 기록되며 삭제 스크립트가 사용한다. EC2 running 상태와 Nginx 준비 완료는 구분한다.

### 3. 로컬 Mac에서 외부·SSH 검증

```bash
# 로컬 저장소 루트; 이번 검증 당시 주소와 로컬 개인키
PUBLIC_IP=3.35.173.185 KEY_PATH="$HOME/.ssh/b3-1-key.pem" bash scripts/verify.sh
curl -i --connect-timeout 5 --max-time 15 http://3.35.173.185/health
ssh -i ~/.ssh/b3-1-key.pem ec2-user@3.35.173.185
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

정리는 완료했다. [logs/cleanup.log](logs/cleanup.log)의 자동 삭제와 [logs/cleanup-verify.log](logs/cleanup-verify.log)의 후속 조회를 함께 근거로 사용했다. EC2는 terminated, 해당 EBS는 0, VPC는 NotFound이며 SG·RT·서브넷·IGW·키페어가 삭제되었다. 실습 액세스키도 삭제하여 남은 수 0을 확인했다. 계정 전체의 RDS `fireview-db`와 EIP `54.116.76.70`은 기존 FireView 리소스로 남겨두었다. Billing 확인은 후속 항목이며 인프라 삭제 완료와 구분한다.

## 외부 접속 검증과 증빙

선택 방식: (B) GET http://3.35.173.185/health

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

주 증빙은 [CloudShell 검증 스크린샷](screenshots/verify-aws-cloudshell.jpg)과 [검증 원문](logs/verify-aws.log), [Mac 검증 원문](logs/verify-local.log)이다. 브라우저 이미지 두 장에는 주소창이 없으므로 페이지 본문 확인용 보조 증빙으로 사용한다. 대상 퍼블릭 IP는 생성 로그 및 로컬 접속 로그와 함께 대조한다. EC2 내부 localhost 성공만으로 외부 접속 성공을 대체하지 않았다.

| 실제 증빙 파일 | 확인 내용 / 범위 |
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

## 요구사항 체크리스트

| 요구사항 | 어떻게 충족했는가 | 근거 / 상태 |
| --- | --- | --- |
| 서울 리전·AZ, VPC·서브넷 | 서울/2a, `10.0.0.0/16`, `10.0.1.0/24`로 생성 | `infra/config.env`, `scripts/provision.sh`, `logs/provision.log` — 배포 완료 |
| IGW·RT·퍼블릭 IP | 기본 경로가 해당 IGW로 active, 자동 퍼블릭 IP로 외부 응답 | `logs/provision.log`, `logs/verify-aws.log` — 확인 완료 |
| SG 제한 | TCP 80 전체 IPv4, TCP 22 `121.135.181.35/32`, 전체 포트 인바운드 없음 | `logs/verify-aws.log`, `screenshots/verify-aws-cloudshell.jpg` — 확인 완료 |
| EC2·EBS·키 | AL2023, t3.micro, gp3 8 GiB, 로컬 ed25519 공개키 등록 | 설정·생성 스크립트, `logs/provision.log`; SSH는 `logs/verify-local.log` — 배포·접속 완료 |
| Nginx 서비스 | 루트 문구, 외부 `/health` 200 OK, nginx active, localhost 200 | 브라우저 이미지·검증 로그 — 확인 완료 |
| 외부 검증 B + 보조 A | CloudShell·Mac의 HTTP + 브라우저 본문 확인 | 실제 증빙 표 참조 — 확인 완료; 브라우저 주소창 없음 명시 |
| 운영 사용자·최소권한 | 운영은 `b3-1-operator`, 커스텀 정책, S3/RDS/IAM 특정 호출 거부 | `infra/iam-policy.json`, `logs/provision.log`, `logs/iam-least-privilege.log` — 확인; 초기 IAM 생성과 정리 후 감사·키 삭제에 루트 사용 |
| Project 태그 | 생성 스크립트의 각 대상에 `Project=B3-1` 지정 | `scripts/provision.sh` — 설정 근거; 전체 리소스별 태그 조회 원문은 별도 미수집 |
| 트러블슈팅 | SSH 소스 불일치를 의도적으로 재현하고 복구 | `docs/troubleshooting.md`, `logs/ts-ssh-*.log` — 실제 재현 완료 |
| 삭제·비용 정리 | 자동 cleanup + EC2/VPC/EBS 재조회·액세스키 삭제 | `logs/cleanup*.log`, `docs/cleanup-checklist.md` — B3-1 인프라 정리 완료; Billing 미완료 |

## 대표 과금 요인과 보너스

EC2 실행 시간, EBS gp3 용량·추가 성능, 퍼블릭 IPv4 사용 시간, 인터넷 데이터 전송 등이 대표 과금 요인이다. 자동 퍼블릭 IPv4도 과금 대상이 될 수 있고 EC2 중지 후에도 남은 EBS는 별도 비용이 발생할 수 있다. 실제 단가와 무료 제공 조건은 [EC2 On-Demand](https://aws.amazon.com/ec2/pricing/on-demand/), [EBS](https://aws.amazon.com/ebs/pricing/), [VPC 퍼블릭 IPv4](https://aws.amazon.com/vpc/pricing/)에서 확인한다. 실제 청구 금액은 아직 기록하지 않았다.

Elastic IP, NAT Gateway, ELB, RDS는 이 배포 스크립트에서 생성하지 않는다. 정리 후 B3-1 대상 잔여가 없음을 로그로 확인했으며 기존 FireView의 RDS 1건과 EIP 1건은 유지했다. 계정 전체 리소스 0이나 Billing 확인 완료를 주장하지 않는다. 보너스인 HTTPS/도메인, 로드 밸런서, Auto Scaling, 다중 AZ 구성은 미수행이다.

## 문서 자체 점검

실측 IP·리소스 ID·HTTP 응답·SSH 복구와 IAM 거부는 제공된 원문 로그에 근거한다. 미수집된 생성 완료 시각·전체 태그 조회·Billing 결과는 성공으로 채우지 않았다. 삭제 결과는 추가로 받은 두 cleanup 로그에 근거하며, 루트의 후속 감사·키 삭제도 기록했다. 브라우저 이미지에 없는 주소창을 있다고 설명하지 않았고, 파이프라인 `tail`의 종료 코드를 SSH 성공 근거로 사용하지 않았다. 다이어그램은 1800×1180 PNG이며 HTTP·SSH 흐름을 설명한다.
