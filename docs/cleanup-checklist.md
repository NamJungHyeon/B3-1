# B3-1 삭제 체크리스트와 실제 결과

B3-1 인프라는 최초 v1 배포와 태그 정책 v2 재배포 모두 정리 완료했다. 아래 1~11절은 v1 기록이고, v2 재배포분은 12절에 별도 기록했다. 최초 배포는 2026-11-18 00:53:11 UTC(09:53:11 KST)에 EC2 terminated, VPC NotFound, 해당 EBS 잔여 0을 재확인했다. 근거는 [자동 정리 로그](../logs/cleanup.log), [삭제 후 재확인 로그](../logs/cleanup-verify.log), [CloudShell 캡처](../screenshots/cleanup-cloudshell.jpg)다. Billing 청구서에서 11월 예상 총합계 USD 0.00을 확인했다(11절, 무료 플랜 크레딧 충당).

체크된 항목은 아래 원문 또는 전달된 실제 수행 사실에 근거한다. 삭제 시도만으로 완료 처리하지 않았으며, 원문에 없는 사전 볼륨 ID·종료 코드·개별 단계의 정확한 시각·Billing 금액은 만들지 않았다. 리전은 `ap-northeast-2`, 식별 태그는 `Project=B3-1`, 이름·값은 `infra/config.env` 기준이다.

## 삭제 순서와 실행 경로

EC2 종료 → EBS 확인 → EIP 미할당 확인(할당했다면 분리·해제) → SG 삭제 → RT 서브넷 연결 해제·RT/서브넷 삭제 → IGW detach + delete → VPC 삭제 → 키페어 삭제 → IAM 액세스키 비활성화 또는 삭제 → Billing 확인 순서다.

EC2/ENI가 SG·서브넷을 참조하므로 먼저 종료를 기다린다. EBS는 DeleteOnTermination으로 자동 삭제될 수 있지만 잔여를 별도 확인한다. 사용자 정의 RT는 연결을 해제해야 삭제할 수 있고, IGW는 VPC에서 분리 후 삭제한다. main RT와 default SG는 VPC 삭제 시 함께 정리된다. IAM 키는 삭제·재조회 후 마지막에 닫는다.

- [x] 자동 경로: 상태 파일이 있는 CloudShell에서 `bash scripts/cleanup.sh`를 실행했다.
- [x] 출력 원문 `logs/cleanup.log`와 캡처 `screenshots/cleanup-cloudshell.jpg`를 보관했다.
- [x] 종료 문구 외에 `logs/cleanup-verify.log`로 EC2·VPC·볼륨·주소·미사용 서비스와 IAM 키를 재확인했다.

실제 인프라 생성·정리 API 실행 주체는 `b3-1-operator`다. `cleanup-verify.log`의 앞 4개 결과는 해당 운영 사용자, `(root)` 이후 ELB/RDS/NAT 감사와 IAM 액세스키 삭제는 루트 자격 증명으로 수행했다고 원문에 명시되어 있다. 따라서 전체 작업에서 루트를 전혀 쓰지 않았다고 표현하지 않는다. 초기 IAM 사용자·정책 생성에도 루트를 사용했다. 운영 사용자에 무관 서비스 권한을 추가하지 않았다.

자동 스크립트는 일부 실패 후에도 진행할 수 있으므로 종료 문구만 완료 근거가 되지 않는다. 아래 명령은 수행 방법과 재배포 시 확인용이며, 이미 삭제된 리소스에 반복 실행하지 않는다. 콘솔 수동 경로는 대체 절차로 안내하며 이번에 콘솔에서 각 리소스를 수동 삭제했다고 주장하지 않는다.

```bash
# 새 배포에서만 최신 실제 ID로 설정한다. 아래는 이번에 삭제한 대상의 기록이다.
VPC_ID='vpc-017b387de9ebebe39'
INSTANCE_ID='i-0d3a2ed22d4d891b1'
SG_ID='sg-0b9bcafca08337847'
SUBNET_ID='subnet-053424ed40ee5e872'
RT_ID='rtb-062bb6ef39f712a4b'
RT_ASSOC_ID='rtbassoc-0a575477549135e20'
IGW_ID='igw-0f2ea6a5447a030d1'
# 삭제 전에는 state 파일·태그와 ID를 대조한다.
aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
```

## 1. EC2 종료

- [x] EC2 `i-0d3a2ed22d4d891b1`를 종료하고 terminated까지 기다렸다.
- [x] 00:53:11 UTC ID 기준 재조회에서 `terminated`를 확인했다.

```bash
aws ec2 terminate-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --region ap-northeast-2 --instance-ids "$INSTANCE_ID"
aws ec2 describe-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].State.Name'
aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down
```

콘솔 대체 경로: EC2 → 인스턴스 → 대상 ID/태그 확인 → 인스턴스 종료. 중지로 끝내지 않는다.
완료 근거: `cleanup.log`의 종료 요청·대기, `cleanup-verify.log`의 `terminated`. 종료 완료 순간의 정확한 시각은 기록하지 않았으며 00:53:11 UTC는 재확인 시각이다.

## 2. EBS 확인

- [x] DeleteOnTermination에 의해 루트 EBS가 정리되었고 B3-1 잔여 EBS가 없음을 확인했다.
- [x] 해당 인스턴스에 붙었던 EBS 조회 결과 0을 확인했다.
- [ ] 선택적 추가 감사: 수동 스냅샷 조회 원문은 미수집이다(본 미션은 스냅샷 미생성).

```bash
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters Name=attachment.instance-id,Values="$INSTANCE_ID"
# 새 배포에서 잔여 available 볼륨이 있을 때만 소유·Attachment 확인 후 삭제
aws ec2 delete-volume --region ap-northeast-2 --volume-id '<VOLUME_ID>'
aws ec2 describe-snapshots --region ap-northeast-2 --owner-ids self \
  --filters Name=tag:Project,Values=B3-1
```

콘솔 대체 경로: EC2 → 볼륨 → Project 태그·연결 ID 대조 → 실제 잔여 볼륨만 삭제. EC2 종료 후 남은 EBS·스냅샷은 별도 과금될 수 있다.
완료 근거: `scripts/provision.sh`의 DeleteOnTermination=true 설정, `cleanup.log`의 EBS 빈 목록, `cleanup-verify.log`의 해당 볼륨 수 0. 수동 delete-volume 수행이나 실제 볼륨 ID는 원문에 없어 기록하지 않았다.

## 3. EIP 미할당 확인

- [x] B3-1용 EIP는 미할당(해당 없음)이며 Project 태그 조회의 잔여가 없음을 확인했다.
- [x] 계정 전체 EIP 1건을 B3-1과 구분하고 삭제하지 않았다.

```bash
aws ec2 describe-addresses --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
# 전체 주소와 소유·연결을 대조; 전체 0을 기대하지 않는다.
aws ec2 describe-addresses --region ap-northeast-2
# 새 배포에서 B3-1 EIP를 수동 할당한 예외가 있을 때만 분리·해제
aws ec2 disassociate-address --region ap-northeast-2 --association-id '<EIP_ASSOCIATION_ID>'
aws ec2 release-address --region ap-northeast-2 --allocation-id '<EIP_ALLOCATION_ID>'
```

콘솔 대체 경로: EC2 → 탄력적 IP → 대상 확인 → 필요한 경우만 분리·릴리스. 자동 퍼블릭 IP `3.35.173.185`는 EC2 종료로 해제되며 EIP release 대상이 아니다.
완료 근거: `cleanup.log`의 B3-1 EIP 빈 목록. 전체 조회의 `54.116.76.70`은 기존 FireView 리소스로, `cleanup-verify.log`에 연결 인스턴스 `i-0f29938e558d1e55c` 등 식별 근거가 있다. B3-1 주소로 오인해 해제하지 않았다.

## 4. Security Group 삭제

- [x] `sg-0b9bcafca08337847`를 삭제했다.

```bash
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=vpc-id,Values="$VPC_ID"
# 의존성 오류 때만: 자동 생성 ENI에는 Project 태그가 없을 수 있다.
aws ec2 describe-network-interfaces --region ap-northeast-2 \
  --filters Name=group-id,Values="$SG_ID"
aws ec2 delete-security-group --region ap-northeast-2 --group-id "$SG_ID"
```

콘솔 대체 경로: VPC/EC2 → 보안 그룹 → 대상 SG 삭제. ENI가 참조하면 종료·분리 상태를 먼저 확인한다.
완료 근거: `cleanup.log`의 delete-security-group 결과 `"Return": true`와 대상 GroupId. ENI 장애가 실제 발생했다고 기록하지 않는다.

## 5. Subnet / Route Table 삭제

- [x] 연결 `rtbassoc-0a575477549135e20`를 해제했다.
- [x] RT `rtb-062bb6ef39f712a4b`와 서브넷 `subnet-053424ed40ee5e872`를 삭제했다.

```bash
aws ec2 describe-route-tables --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
aws ec2 disassociate-route-table --region ap-northeast-2 --association-id "$RT_ASSOC_ID"
aws ec2 delete-route-table --region ap-northeast-2 --route-table-id "$RT_ID"
aws ec2 delete-subnet --region ap-northeast-2 --subnet-id "$SUBNET_ID"
```

콘솔 대체 경로: VPC → 라우팅 테이블 → 서브넷 연결 해제 → 사용자 정의 RT 삭제 및 서브넷 삭제. main RT와 구분한다.
완료 근거: `cleanup.log`의 세 삭제 단계, 후속 VPC 삭제와 NotFound 재확인. 개별 RT/Subnet 삭제 후 조회 원문을 별도 수집했다고 주장하지 않는다.

## 6. IGW detach + delete

- [x] `igw-0f2ea6a5447a030d1`을 VPC에서 분리 후 삭제했다.

```bash
aws ec2 describe-internet-gateways --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
aws ec2 detach-internet-gateway --region ap-northeast-2 \
  --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --region ap-northeast-2 --internet-gateway-id "$IGW_ID"
```

콘솔 대체 경로: VPC → 인터넷 게이트웨이 → VPC에서 분리 → 삭제. 연결된 IGW는 먼저 분리해야 한다.
완료 근거: `cleanup.log`의 detach·delete 명령과 IGW 빈 잔여 목록.

## 7. VPC 삭제

- [x] `vpc-017b387de9ebebe39`를 삭제하고 ID 조회의 NotFound를 확인했다.

```bash
aws ec2 delete-vpc --region ap-northeast-2 --vpc-id "$VPC_ID"
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
aws ec2 describe-vpcs --region ap-northeast-2 --vpc-ids "$VPC_ID"
```

콘솔 대체 경로: VPC → 대상 VPC 삭제. 서브넷·사용자 정의 SG·RT·IGW 의존성을 먼저 제거한다.
완료 근거: `cleanup.log`의 VPC 빈 잔여 목록과 `cleanup-verify.log` 원문:

```text
aws: [ERROR]: An error occurred (InvalidVpcID.NotFound) when calling the DescribeVpcs operation: The vpc ID 'vpc-017b387de9ebebe39' does not exist
```

이 ID의 NotFound는 삭제 후 기대 결과다. AccessDenied·통신 오류와 혼동하지 않는다.

## 8. 키페어 삭제와 로컬 개인키

- [x] AWS 키페어 `b3-1-key`를 삭제하고 잔여 목록이 비어 있음을 확인했다.
- [ ] 로컬 개인키의 보관·삭제 결과는 아직 기록이 없다. AWS 키 삭제와 별도다.

```bash
aws ec2 delete-key-pair --region ap-northeast-2 --key-name b3-1-key
aws ec2 describe-key-pairs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
ls -l ~/.ssh/b3-1-key.pem
```

콘솔 대체 경로: EC2 → 키 페어 → b3-1-key 삭제. 개인키 내용은 출력하지 않는다.
완료 근거: `cleanup.log`의 `"Return": true`, KeyPairId `key-0b66fe67472ceb2da`, KeyPair 빈 잔여 목록. 개인키는 처음부터 Mac에서 생성·보관했고 공개키만 AWS에 등록했다. 로컬 파일을 삭제했다고 주장하지 않는다.

## 9. NAT GW / ELB / RDS 구분

- [x] NAT Gateway: 미생성(해당 없음) — B3-1 잔여 없음, 전체 pending/available 수 0.
- [x] ELBv2(ALB/NLB): 미생성(해당 없음) — 전체 수 0.
- [x] RDS: B3-1 미생성(해당 없음) — 전체 1건은 기존 FireView DB로 구분하여 유지했다.
- [ ] 추가 감사: Classic ELB, RDS cluster·스냅샷·보존 백업 조회 결과는 이번 원문에 없다.

```bash
aws ec2 describe-nat-gateways --region ap-northeast-2 \
  --filter Name=tag:Project,Values=B3-1 Name=state,Values=pending,available
# ELB/RDS는 operator에 권한이 없다. 아래 AUDIT_PROFILE은 권한 있는 관리 프로필 예시.
aws --profile '<AUDIT_PROFILE>' elbv2 describe-load-balancers --region ap-northeast-2
aws --profile '<AUDIT_PROFILE>' rds describe-db-instances --region ap-northeast-2
# 목록이 있을 때 Project 태그와 소유·기존 생성일을 함께 대조
aws --profile '<AUDIT_PROFILE>' elbv2 describe-tags --region ap-northeast-2 --resource-arns '<LB_ARN>'
aws --profile '<AUDIT_PROFILE>' rds list-tags-for-resource --region ap-northeast-2 --resource-name '<DB_ARN>'
# 추가 감사용 예시(실제 실행 근거 아님)
aws --profile '<AUDIT_PROFILE>' elb describe-load-balancers --region ap-northeast-2
aws --profile '<AUDIT_PROFILE>' rds describe-db-clusters --region ap-northeast-2
aws --profile '<AUDIT_PROFILE>' rds describe-db-snapshots --region ap-northeast-2 --snapshot-type manual
aws --profile '<AUDIT_PROFILE>' rds describe-db-instance-automated-backups --region ap-northeast-2
```

콘솔 대체 경로: EC2 → 로드 밸런서 및 VPC → NAT 게이트웨이 및 RDS → 데이터베이스/백업에서 대상과 소유를 대조한다. 태그 필터를 직접 지원하지 않는 API는 목록 후 describe-tags/list-tags-for-resource로 `Project=B3-1`을 확인한다. AccessDenied를 미생성 증거로 삼지 않는다.
완료 근거: `cleanup-verify.log`에 루트로 수행한 ELBv2 0, RDS 1, NAT 0이 기록되어 있다. RDS `fireview-db`는 postgres/db.t4g.micro, 2026-08-23 생성된 기존 타 프로젝트 DB이며 B3-1 삭제 대상이 아니다. 계정 전체 EIP·RDS 수를 0으로 만들지 않았다.

## 10. IAM 액세스키 삭제

- [x] 리소스 정리·재조회 후 `b3-1-operator`의 실습 액세스키를 삭제했다.
- [x] 남은 액세스키 수 0을 확인했다.
- [x] IAM 사용자 `b3-1-operator`와 정책 `B3-1-LeastPrivilege`는 과금 없는 증빙용으로 유지했다.

이번에는 Inactive 전환 후 보관 대신 키를 삭제했다. 중간 Inactive 상태를 측정했다고 주장하지 않는다. 실제 키 삭제·재조회는 루트가 수행했으며 원문에는 키 ID가 `AKIAXMY3...`로 마스킹되어 있다.

```bash
# 권한 있는 관리 주체의 예시. 실제 삭제한 키를 재삭제하지 않는다.
aws --profile '<IAM_ADMIN_PROFILE>' iam list-access-keys --region ap-northeast-2 --user-name b3-1-operator
# 보관이 필요한 경우 먼저 비활성화; 이번 실제 결과는 삭제 및 남은 수 0
aws --profile '<IAM_ADMIN_PROFILE>' iam update-access-key --region ap-northeast-2 \
  --user-name b3-1-operator --access-key-id '<ACCESS_KEY_ID>' --status Inactive
aws --profile '<IAM_ADMIN_PROFILE>' iam delete-access-key --region ap-northeast-2 \
  --user-name b3-1-operator --access-key-id '<ACCESS_KEY_ID>'
aws --profile '<IAM_ADMIN_PROFILE>' iam list-access-keys --region ap-northeast-2 --user-name b3-1-operator
```

콘솔 대체 경로: IAM → 사용자 → 보안 자격 증명 → 대상 액세스키 비활성화/삭제. IAM은 글로벌이며 `--region`이 사용자를 서울로 한정하지 않는다. 액세스키는 Project 태그 필터가 없어 사용자 이름과 키 ID로 식별한다.
완료 근거: `cleanup-verify.log`의 `deleted AKIAXMY3...`와 남은 수 0. 로컬 AWS 자격 증명 파일의 정리 여부는 별도 미기록이다.

## 11. Billing Dashboard 확인 — 최초 v1 배포 후 기록

- [x] 정리 직후 루트로 Billing → 청구서(2026년 11월)를 확인했다. 페이지 새로 고침 시각: 2026-11-18 10:15:26 KST.
- [x] 예상 총합계 **USD 0.00**, 활성 서비스 7개(Data Transfer, Elastic Compute Cloud, Glue, Key Management Service, Relational Database Service, Simple Storage Service, Virtual Private Cloud) 모두 USD 0.00.
- [x] 계정은 무료 플랜이라 사용 요금이 크레딧으로 충당되고 청구되지 않는다는 안내가 표시된다. "가장 높은 AWS 리전 지출" 항목은 Asia Pacific (Seoul) USD 25.25로 표시된다(크레딧 차감 전 사용액으로 보이며, 기존 FireView RDS/EIP 사용분이 포함된다).
- [ ] B3-1 사용분(EC2 약 10분, gp3 8GiB, 퍼블릭 IPv4)만 따로 분리한 금액은 이 화면에서 구분되지 않는다. 사용량은 수 시간~하루 늦게 반영될 수 있으므로 다음 날 같은 화면을 다시 확인한다.

증빙: [screenshots/billing-summary.jpg](../screenshots/billing-summary.jpg)(요약·예상 총합계), [screenshots/billing-services.jpg](../screenshots/billing-services.jpg)(서비스별 금액). 과금 0 표시는 리소스 삭제의 증거가 아니며, 삭제 근거는 위 로그다.

## 12. 태그 정책 v2 재배포분 정리 결과

[logs/tagpolicy-run.log](../logs/tagpolicy-run.log) 2~3절은 공개키 소실로 중단된 1차 시도의 잔여 정리, 4~6절은 공개키 복구 후 성공한 2차 시도의 검증·정리 기록이다. 기존 v1 배포와도 구분한다. IAM 정책 v2는 루트로 적용했고 인프라 생성·정리는 운영 사용자 `b3-1-operator`가 수행했다.

1차 시도는 `/tmp/b3-1-key.pub` 부재로 키 import 전에 중단되어 VPC `vpc-092d0a98dbb51ae38` 등의 부분 생성분을 정리했다. 없는 키페어를 삭제할 때 태그 조건을 충족하지 못해 UnauthorizedOperation이 나왔으나 Project 잔여 목록은 모두 비어 있었다. 이 사례는 [실제 IAM 트러블슈팅](troubleshooting.md)의 사례 3에 기록했다. 정책을 넓혀 해결한 사례가 아니다.

홈의 `~/b3-1-key.pub`로 성공한 2차 시도의 삭제 대상과 결과:

| 대상 | 실제 ID / 결과 |
| --- | --- |
| EC2 / 당시 퍼블릭 IP | `i-04dd8916b77900977` / `43.201.55.219`; 종료 후 terminated |
| VPC | `vpc-05713bf5c6a23b20e`; 삭제 후 InvalidVpcID.NotFound |
| Public Subnet | `subnet-0d646fc669d77d6ec`; 삭제 |
| IGW | `igw-064e41dcc91822d1d`; detach + delete |
| Route Table / 연결 | `rtb-054ffc06245f65109` / `rtbassoc-030e8465681e82542`; 연결 해제 후 삭제 |
| Security Group | `sg-04d2a1f2c07a35329`; delete 결과 Return true |
| KeyPair | `b3-1-key`, `key-0331c34eb129cab79`; delete 결과 Return true, 재조회 NotFound |

- [x] 생성·검증 후 동일 v2 정책으로 EC2 종료와 SG·RT·서브넷·IGW·VPC·키페어 삭제를 마쳤다.
- [x] 1차 시도와 달리 실제 존재하는 태그 키페어는 DeleteKeyPair가 성공했다.
- [x] Project=B3-1 잔여 조회에서 EC2(terminated 제외)·EBS·EIP·IGW·VPC·NAT·KeyPair가 모두 빈 값임을 확인했다.
- [x] 2026-11-18 03:34:48 UTC(12:34:48 KST)에 EC2 terminated, VPC NotFound, KeyPair NotFound를 재확인했다.
- [x] 기존 타 프로젝트 FireView 인스턴스 `i-0f29938e558d1e55c`는 running을 유지했다.
- [x] 루트가 마지막 실습 액세스키를 삭제하고 남은 키 0을 확인했다.
- [ ] v2 재배포 이후 사용분까지 반영한 Billing 후속 확인 결과는 아직 없다. 11절 캡처는 그 이전의 v1 정리 후 기록이다.

재확인 원문 발췌:

```text
== 재확인 (2026-11-18 03:34:48 UTC)
terminated
aws: [ERROR]: An error occurred (InvalidVpcID.NotFound) when calling the DescribeVpcs operation: The vpc ID 'vpc-05713bf5c6a23b20e' does not exist
aws: [ERROR]: An error occurred (InvalidKeyPair.NotFound) when calling the DescribeKeyPairs operation: The key pair 'b3-1-key' does not exist
FireView: running
(root) deleted AKIAXMY3...
(root) remaining keys: 0
```

동일 결과의 실제 캡처는 [screenshots/tagpolicy-cleanup.jpg](../screenshots/tagpolicy-cleanup.jpg)다. 03:34:48 UTC는 조회 시각이며 각 리소스가 정확히 그 시각에 삭제되었다고 뜻하지 않는다. `tagpolicy-run.log`는 생략 부호·설명 주석이 포함된 원문 전사본이고, 액세스키 전체 ID나 미실행 decode 결과는 기록하지 않았다. v2의 부재 키페어 오류를 무시해 성공 처리한 것이 아니라, 재배포 후 실제 태그 키페어의 정상 삭제·최종 NotFound를 별도로 확인했다.

## 최종 결과와 자체 점검

| 항목 | 실제 결과 |
| --- | --- |
| 실행 경로 | CloudShell 자동 cleanup + 삭제 후 별도 재조회 |
| 재확인 시각 | v1: 2026-11-18 00:53:11 UTC / 09:53:11 KST; v2: 03:34:48 UTC / 12:34:48 KST |
| B3-1 인프라 | v1·v2 모두 EC2 terminated, Project 잔여 없음, SG/RT/Subnet/IGW/VPC/키페어 삭제 |
| 계정의 타 프로젝트 | FireView RDS 1건과 EIP 1건 유지; B3-1 삭제 대상 아님 |
| IAM | 실습 액세스키 삭제·남은 수 0, 사용자와 정책 유지 |
| 미확인 사항 | v2 이후 Billing 재확인(B3-1 사용분 분리 불가), 다른 리전 감사, 선택적 추가 감사·로컬 키/프로필 정리 여부 |
| 증빙 | v1: `logs/cleanup.log`, `logs/cleanup-verify.log`, `screenshots/cleanup-cloudshell.jpg`; v2: `logs/tagpolicy-run.log`, `screenshots/tagpolicy-cleanup.jpg` |

실측 삭제·부재는 제공된 로그 범위로 한정했다. 계정 전체 EIP/RDS가 없다고 적지 않았고, 루트 사용·Billing 표시의 한계(크레딧 충당·반영 지연)·로컬 파일 상태를 숨기지 않았다. 비어 있는 잔여 목록과 ID 기준 NotFound를 함께 근거로 사용했다.
