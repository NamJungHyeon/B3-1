# B3-1 삭제 체크리스트

현재 상태: 실제 AWS 배포·삭제·잔여 리소스 검증을 아직 실행하지 않았다. 체크박스는 모두 미완료다. `<...>`와 근거 기입란은 배포 후 실제 조회 원문·시각·확인자로 채운다. 성공 예시를 실측 로그로 제출하지 않는다.

## 대상 식별과 삭제 순서

리전 `ap-northeast-2`, 태그 `Project=B3-1`, 이름·값은 `infra/config.env`가 기준이다. 실행 전 `.b3-1-state`와 AWS 조회 결과를 대조한다. 태그만 믿고 다른 실습 리소스를 삭제하지 않는다. 태그가 없는 자동 생성 리소스도 있으므로 VPC ID와 연결 관계를 함께 확인한다.

삭제 순서: EC2 종료 → EBS 잔여 확인·삭제 → EIP 미생성 확인(있다면 분리·해제) → SG → Subnet/Route Table 연결 해제·삭제 → IGW detach + delete → VPC → 키페어 → IAM 액세스키 비활성화 → Billing Dashboard 확인.

EC2와 ENI가 SG·서브넷을 참조하므로 먼저 인스턴스 종료를 기다린다. EBS는 자동 삭제 설정을 점검하고 남은 볼륨을 별도로 삭제한다. IGW를 분리하기 전에 공인 주소를 사용하는 리소스를 제거한다. 사용자 정의 Route Table은 서브넷 연결을 해제한 뒤 삭제하고, VPC의 main Route Table과 default SG는 VPC 삭제 시 정리된다. 키페어와 IAM 액세스키는 검증 및 정리가 끝난 뒤 정리한다.

```bash
export AWS_PROFILE=b3-1-operator
# 아래는 실제 배포값으로 교체한다. 문서의 placeholder를 그대로 실행하지 않는다.
VPC_ID='<VPC_ID>'
INSTANCE_ID='<INSTANCE_ID>'
SG_ID='<SG_ID>'
SUBNET_ID='<SUBNET_ID>'
RT_ID='<ROUTE_TABLE_ID>'
RT_ASSOC_ID='<ROUTE_TABLE_ASSOCIATION_ID>'
IGW_ID='<IGW_ID>'
# 삭제 전 인벤토리; 현재 태그와 실제 ID가 일치하는지 확인
aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Vpc:VpcId,Subnet:SubnetId,Volumes:BlockDeviceMappings}'
aws ec2 describe-vpcs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
```

아래 삭제 명령은 실제 B3-1 소유임을 확인한 ID에만 적용한다. “조회 성공 + 잔여 없음”이 완료 기준이며, 권한 오류·통신 오류·종속성 오류는 완료 근거가 아니다. terminated EC2나 deleted NAT GW 기록이 잠시 남는 것과 과금 중인 리소스가 남는 것을 구분한다.

## 자동 경로: scripts/cleanup.sh

- [ ] 외부 접속·구성 증빙을 먼저 저장하고 상태 파일의 리소스 ID와 태그를 확인했다.
- [ ] 저장소 루트에서 아래 명령을 실행했다.

```bash
export AWS_PROFILE=b3-1-operator
bash scripts/cleanup.sh
```

- [ ] 스크립트 로그 원문을 보관했다: `<CLEANUP_SCRIPT_LOG — 배포 후 채움>`.
- [ ] 스크립트의 종료 문구만으로 완료 처리하지 않고, 아래 항목을 독립적으로 조회했다.

현재 스크립트는 EC2 종료를 기다린 뒤 EIP 점검과 남은 available EBS 삭제, SG, RT 연결/테이블, 서브넷, IGW, VPC, 키페어 순으로 시도한다. EIP는 설계상 없으므로, 사람의 수동 확인 절차에서는 먼저 EBS 잔여를 확인한 뒤 EIP 미생성을 확인한다. 스크립트는 일부 명령 실패 후에도 계속 진행할 수 있고 상태 파일을 `.b3-1-state.deleted-<시각>`으로 옮길 수 있다. “정리 완료” 출력이나 상태 파일의 이름 변경은 모든 리소스 삭제의 증거가 아니다. 실패한 리소스는 아래 수동 경로로 ID·의존관계를 확인하고 정리한다.

스크립트가 수행하지 않는 IAM 액세스키 비활성화, ELB/RDS 감사, Billing 확인은 별도로 수행한다. 상태 파일이 없거나 오래된 경우에는 태그 조회로 대상 ID를 재확인한다.

완료 근거: `<실행 시각 / 종료 코드 / 로그 위치 / 잔여 항목 — 배포 후 채움>`.

## 수동 경로: 콘솔 + CLI 확인

콘솔은 비루트 사용자로 로그인하고 오른쪽 위 리전을 서울로 맞춘다. 리소스 목록에서 `Project=B3-1` 태그로 필터링하고 상태 파일 ID도 대조한다. 아래 콘솔 동작과 CLI 명령은 같은 항목을 정리·확인하는 두 경로다. 이미 삭제했다면 다시 삭제하지 말고 조회 결과를 남긴다.

### 1. EC2 종료 및 EBS 자동 삭제 설정 확인

- [ ] EC2 → 인스턴스에서 B3-1 인스턴스의 루트 볼륨 ID와 DeleteOnTermination 설정을 기록했다.
- [ ] 인스턴스를 “중지”가 아닌 “종료”하고 terminated 상태까지 기다렸다.

```bash
# 종료 전: 연결된 EBS의 ID와 자동 삭제 여부 기록
aws ec2 describe-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].BlockDeviceMappings'
# 위 ID가 Project=B3-1 인스턴스인지 확인한 뒤 실행
aws ec2 terminate-instances --region ap-northeast-2 --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-terminated --region ap-northeast-2 --instance-ids "$INSTANCE_ID"
# 완료 조회: 비종료 상태 인스턴스가 없어야 함(shutting-down도 포함)
aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'
```

이유: 중지만 하면 저장소 등 비용이 남고, 종료 중에는 ENI가 SG와 서브넷을 참조할 수 있다. 스크립트의 루트 EBS는 DeleteOnTermination=true로 요청하지만 실제 설정과 잔여 볼륨을 조회한다.

완료 근거: `<종료 시각 / 실제 인스턴스 ID / 볼륨 ID·자동 삭제 여부 / 잔여 조회 원문 — 배포 후 채움>`.

### 2. EBS 잔여 확인 및 삭제

- [ ] EC2 → 볼륨에서 `Project=B3-1` 잔여가 없는지 확인했다.
- [ ] 남은 볼륨은 Attachment와 소유 관계를 확인하고 available일 때만 삭제했다.
- [ ] 수동 스냅샷을 만들었다면 별도로 확인했다(본 설계는 스냅샷 미생성).

```bash
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  --query 'Volumes[].{Id:VolumeId,State:State,Attachments:Attachments,Type:VolumeType,GiB:Size}'
# 실제 잔여 볼륨이 있을 때만, 조회한 ID로 실행
aws ec2 delete-volume --region ap-northeast-2 --volume-id '<VOLUME_ID>'
# 삭제 후 같은 describe-volumes 명령 재실행 → 잔여 없음 확인
aws ec2 describe-snapshots --region ap-northeast-2 --owner-ids self \
  --filters Name=tag:Project,Values=B3-1 \
  --query 'Snapshots[].{Id:SnapshotId,Volume:VolumeId,State:State}'
```

이유: EC2 종료 후 남은 볼륨과 스냅샷은 별도로 과금될 수 있다. 스냅샷이 발견되면 본 미션에서 만들었는지 소유·용도를 확인한다. 현 운영 정책은 DeleteSnapshot을 허용하지 않으므로 필요하면 비루트 관리 주체가 정리한다.

완료 근거: `<볼륨 삭제/자동 삭제 확인 / 스냅샷 해당 여부 / 조회 원문 — 배포 후 채움>`.

### 3. EIP 미생성 확인 및 예외 해제

- [ ] 미생성(해당 없음) — 이 미션은 자동 할당 퍼블릭 IP만 사용한다. 아래 명령으로 실제 잔여를 확인했다.

```bash
aws ec2 describe-addresses --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 \
  --query 'Addresses[].{Allocation:AllocationId,Association:AssociationId,IP:PublicIp}'
# 수동으로 추가한 B3-1 EIP가 발견되었을 때만: 콘솔 EC2 → 탄력적 IP
aws ec2 disassociate-address --region ap-northeast-2 --association-id '<EIP_ASSOCIATION_ID>'
aws ec2 release-address --region ap-northeast-2 --allocation-id '<EIP_ALLOCATION_ID>'
# 연관이 이미 없으면 disassociate를 생략. describe-addresses 재실행으로 잔여 확인.
```

이유: EC2의 자동 퍼블릭 IP는 인스턴스 종료로 해제되며 EIP release 명령의 대상이 아니다. 추가로 할당한 EIP는 인스턴스 종료만으로 해제되지 않으므로 분리 후 반환한다. 예상치 못한 다른 실습 주소는 삭제하지 않는다.

완료 근거: `<EIP 미생성 확인 또는 발견한 예외의 분리·해제 내역 / 조회 원문 — 배포 후 채움>`.

### 4. Security Group 삭제

- [ ] VPC/EC2 → 보안 그룹에서 `b3-1-web-sg`를 삭제했다.
- [ ] 의존성 오류가 나면 아래 ENI 조회로 참조가 남았는지 확인했다.

```bash
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=vpc-id,Values="$VPC_ID"
# 자동 생성 ENI는 Project 태그가 없을 수 있어 SG/VPC 관계로 확인
aws ec2 describe-network-interfaces --region ap-northeast-2 \
  --filters Name=group-id,Values="$SG_ID" Name=vpc-id,Values="$VPC_ID"
aws ec2 delete-security-group --region ap-northeast-2 --group-id "$SG_ID"
# describe-security-groups의 Project 태그 조회 재실행 → 미션 SG 잔여 없음
```

이유: EC2 ENI가 사용 중인 SG는 삭제할 수 없다. 종료 완료를 기다리고 다른 리소스가 참조하는지 확인한다. default SG는 개별 삭제하지 않고 VPC 삭제 때 함께 정리한다.

완료 근거: `<SG ID / ENI 참조 없음 / 삭제 후 조회 원문 — 배포 후 채움>`.

### 5. Subnet / Route Table 정리

- [ ] VPC → 라우팅 테이블에서 `b3-1-public-rt`의 서브넷 연결을 해제했다.
- [ ] 사용자 정의 RT와 `b3-1-public-subnet`을 삭제했다. 연결 해제 뒤 RT와 서브넷의 삭제 순서는 바뀌어도 된다.

```bash
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=vpc-id,Values="$VPC_ID"
aws ec2 describe-route-tables --region ap-northeast-2 \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[].{Id:RouteTableId,Tags:Tags,Associations:Associations,Routes:Routes}'
# Main=false인 사용자 정의 RT의 실제 서브넷 연결 ID에만 적용
aws ec2 disassociate-route-table --region ap-northeast-2 --association-id "$RT_ASSOC_ID"
aws ec2 delete-route-table --region ap-northeast-2 --route-table-id "$RT_ID"
aws ec2 delete-subnet --region ap-northeast-2 --subnet-id "$SUBNET_ID"
# 삭제 후 Project 태그로 재조회
aws ec2 describe-route-tables --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
aws ec2 describe-subnets --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
```

이유: 서브넷과 연결된 사용자 정의 RT는 연결을 먼저 해제해야 삭제된다. 서브넷에는 EC2·NAT 등의 ENI가 남아 있으면 안 된다. VPC의 main RT는 사용자 정의 RT와 구분하며 VPC 삭제에 맡긴다.

완료 근거: `<서브넷/RT/연결 ID / 삭제 후 조회 원문 — 배포 후 채움>`.

### 6. IGW detach + delete

- [ ] VPC → 인터넷 게이트웨이에서 `b3-1-igw`를 VPC에서 분리한 후 삭제했다.

```bash
aws ec2 describe-internet-gateways --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
aws ec2 detach-internet-gateway --region ap-northeast-2 \
  --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
aws ec2 delete-internet-gateway --region ap-northeast-2 --internet-gateway-id "$IGW_ID"
aws ec2 describe-internet-gateways --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1
```

이유: 연결 상태인 IGW는 삭제할 수 없다. detach가 실패하면 VPC 내 퍼블릭 주소·ENI 등 남은 참조를 조사한다.

완료 근거: `<분리·삭제 시각 / IGW ID / 잔여 조회 원문 — 배포 후 채움>`.

### 7. VPC 삭제

- [ ] VPC → VPC에서 `b3-1-vpc`를 삭제하고 남은 B3-1 VPC가 없는지 확인했다.

```bash
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
aws ec2 delete-vpc --region ap-northeast-2 --vpc-id "$VPC_ID"
aws ec2 describe-vpcs --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
```

이유: 서브넷·사용자 정의 SG·RT·게이트웨이 등의 의존관계를 먼저 제거해야 한다. DependencyViolation이 나오면 오류를 기록하고 VPC 안의 ENI 및 미삭제 구성부터 확인한다. 다른 VPC를 대신 삭제하지 않는다.

완료 근거: `<VPC ID / 삭제 시각 / 잔여 조회 원문 — 배포 후 채움>`.

### 8. 키페어 및 로컬 개인키 정리

- [ ] EC2 → 키 페어에서 `b3-1-key`를 삭제했다.
- [ ] 더 이상 필요 없는 로컬 개인키는 보관 정책에 맞춰 정리했다(개인키 내용은 증빙하지 않음).

```bash
aws ec2 describe-key-pairs --region ap-northeast-2 \
  --filters Name=tag:Project,Values=B3-1 Name=key-name,Values=b3-1-key
aws ec2 delete-key-pair --region ap-northeast-2 --key-name b3-1-key
aws ec2 describe-key-pairs --region ap-northeast-2 --filters Name=tag:Project,Values=B3-1
# 로컬 파일 유무 확인만 수행. 자동 cleanup은 로컬 개인키를 지우지 않는다.
ls -l ~/.ssh/b3-1-key.pem
```

이유: AWS 키페어 삭제는 로컬 개인키 삭제와 별개다. 재배포 스크립트는 기존 KEY_PATH 파일이 있으면 중단하므로, 재사용·보관 계획을 확인하고 로컬 키를 정리한다. 키페어 자체는 주요 과금 항목은 아니지만 접근 수단을 정리한다.

완료 근거: `<AWS 키페어 잔여 조회 / 로컬 개인키 보관·정리 여부 — 배포 후 채움>`.

### 9. 미사용 서비스 확인: NAT GW / ELB / RDS

- [ ] NAT Gateway: 미생성(해당 없음) — 확인 명령을 실행하고 원문을 남겼다.

```bash
aws ec2 describe-nat-gateways --region ap-northeast-2 \
  --filter Name=tag:Project,Values=B3-1 \
  Name=state,Values=pending,available,deleting,failed \
  --query 'NatGateways[].{Id:NatGatewayId,State:State,Vpc:VpcId}'
```

`<AUDIT_PROFILE>`은 서비스 조회 권한이 있는 비루트 감사 프로필로, `<IAM_ADMIN_PROFILE>`은 IAM 관리 프로필로 교체한다. ELB/RDS는 운영 정책에 조회 권한도 없다. 아래 감사 명령과 콘솔 확인은 해당 조회 권한이 있는 별도 비루트 관리 주체가 실행한다. 운영 사용자에 무관 서비스 권한을 붙이지 않는다. `AccessDenied`를 “미생성”의 증거로 사용하지 않는다.

- [ ] ELB(ALB/NLB 및 Classic): 미생성(해당 없음) — 콘솔 EC2 → 로드 밸런서와 아래 조회로 확인했다.

```bash
# 전체 목록 확인: ELB describe에는 EC2 방식 tag 필터가 없음
aws --profile '<AUDIT_PROFILE>' elbv2 describe-load-balancers --region ap-northeast-2 \
  --query 'LoadBalancers[].{Arn:LoadBalancerArn,Name:LoadBalancerName,Vpc:VpcId}'
# 목록이 있을 때 각 ARN의 Project=B3-1 태그 대조
aws --profile '<AUDIT_PROFILE>' elbv2 describe-tags --region ap-northeast-2 --resource-arns '<LOAD_BALANCER_ARN>'
aws --profile '<AUDIT_PROFILE>' elb describe-load-balancers --region ap-northeast-2 \
  --query 'LoadBalancerDescriptions[].{Name:LoadBalancerName,Vpc:VPCId}'
aws --profile '<AUDIT_PROFILE>' elb describe-tags --region ap-northeast-2 --load-balancer-names '<CLASSIC_LB_NAME>'
```

- [ ] RDS: 미생성(해당 없음) — 콘솔 RDS → 데이터베이스, 스냅샷/백업과 아래 조회로 확인했다.

```bash
aws --profile '<AUDIT_PROFILE>' rds describe-db-instances --region ap-northeast-2 \
  --query 'DBInstances[].{Id:DBInstanceIdentifier,Arn:DBInstanceArn,Vpc:DBSubnetGroup.VpcId}'
aws --profile '<AUDIT_PROFILE>' rds describe-db-clusters --region ap-northeast-2 \
  --query 'DBClusters[].{Id:DBClusterIdentifier,Arn:DBClusterArn}'
# 목록이 있을 때 각 DB/cluster ARN의 Project=B3-1 태그 대조
aws --profile '<AUDIT_PROFILE>' rds list-tags-for-resource --region ap-northeast-2 --resource-name '<DB_OR_CLUSTER_ARN>'
aws --profile '<AUDIT_PROFILE>' rds describe-db-snapshots --region ap-northeast-2 --snapshot-type manual
aws --profile '<AUDIT_PROFILE>' rds describe-db-cluster-snapshots --region ap-northeast-2 --snapshot-type manual
aws --profile '<AUDIT_PROFILE>' rds describe-db-instance-automated-backups --region ap-northeast-2
```

ELB/RDS는 태그 필터를 직접 지원하지 않는 위 조회 API 때문에 목록 → 각 리소스 태그의 `Project=B3-1` 대조 방식으로 확인한다. 태그 누락을 놓치지 않도록 실제 VPC ID와 전체 인벤토리도 대조한다. 이 미션은 해당 서비스를 생성하지 않으므로 발견되면 소유·용도를 조사하고 임의 삭제하지 않는다. RDS 수동 스냅샷·보존 백업은 DB 인스턴스 부재와 별개로 확인한다.

완료 근거: `<NAT/ELB/RDS별 조회 성공 여부 / Project 태그 대조 / 해당 없음 확인 원문 / 감사자 — 배포 후 채움>`.

### 10. IAM 액세스키 비활성화

- [ ] 모든 리소스 삭제·잔여 조회가 끝난 뒤 실습용 액세스키를 비활성화했다.
- [ ] 비활성화 후 키의 Status=Inactive를 별도 관리 주체가 확인했다.

IAM은 글로벌 서비스다. 아래 `--region ap-northeast-2`는 CLI의 명시적 리전 설정이며 IAM 사용자를 서울 리전에 한정한다는 의미가 아니다. 액세스키에는 EC2처럼 `Project` 태그 필터가 없으므로 태그가 지정된 IAM 사용자 이름과 키 ID로 대상을 식별한다.

```bash
# 운영 정책에 IAM 관리 권한이 없으므로 비루트 IAM 관리 주체로 실행
aws --profile '<IAM_ADMIN_PROFILE>' iam list-user-tags --region ap-northeast-2 --user-name b3-1-operator
aws --profile '<IAM_ADMIN_PROFILE>' iam list-access-keys --region ap-northeast-2 --user-name b3-1-operator
aws --profile '<IAM_ADMIN_PROFILE>' iam update-access-key --region ap-northeast-2 --user-name b3-1-operator \
  --access-key-id '<B3_1_ACCESS_KEY_ID>' --status Inactive
aws --profile '<IAM_ADMIN_PROFILE>' iam list-access-keys --region ap-northeast-2 --user-name b3-1-operator \
  --query 'AccessKeyMetadata[].{Id:AccessKeyId,Status:Status}'
```

콘솔: IAM → 사용자 → `b3-1-operator` → 보안 자격 증명 → 해당 실습 키 → 비활성화. 비밀키는 문서·로그에 남기지 않는다. 더 이상 사용할 계획이 없다면 보관 정책에 맞춰 액세스키 삭제와 로컬 AWS 프로필의 자격 증명 정리도 수행한다. 다른 작업에서 사용하는 키인지 확인한다.

이유: 키를 먼저 끄면 남은 리소스 조회·삭제가 중단될 수 있으므로 마지막에 접근 수단을 닫는다. 사용자·커스텀 정책 자체의 삭제는 이 체크리스트의 필수 범위가 아니며 계정 관리 방침에 따른다.

완료 근거: `<키 식별 정보(마스킹) / Inactive 확인 원문 / 확인자·시각 — 배포 후 채움>`.

### 11. Billing Dashboard 최종 확인

- [ ] Billing 권한이 있는 비루트 관리 주체로 Billing and Cost Management → Dashboard 및 Bills/Cost Explorer를 확인했다.
- [ ] EC2, EBS, Public IPv4, 데이터 전송 등 사용 내역과 삭제 시점을 대조했다.
- [ ] NAT GW, ELB, RDS에 예상치 못한 사용 내역이 없는지 확인했다.
- [ ] 다른 리전의 잔여 리소스·사용 내역도 계정 차원에서 확인했다.
- [ ] 요금 반영 지연을 고려해 이후 다시 확인할 시점을 기록했다.

IAM 사용자 `b3-1-operator`의 정책에는 Billing 권한을 부여하지 않는다. `Project=B3-1` 태그 기반 비용 필터는 비용 할당 태그가 활성화되고 데이터가 반영된 경우에만 보조로 사용한다. 태그 필터가 보이지 않거나 비용이 0이라고 리소스 삭제가 증명되는 것은 아니다. 리소스 잔여 조회 원문과 함께 확인한다.

완료 근거: `<Billing 확인 시각 / 조회 기간 / 서비스·리전별 내역 / 재확인 예정 시각 / 확인자 — 배포 후 채움>`.
스크린샷: `screenshots/cleanup.png`, `screenshots/billing.png` — 아직 없음, 배포 후 채움.

## 최종 기록과 자체 점검

| 항목 | 실제 기록 |
| --- | --- |
| 자동/수동 경로 | `<수행한 경로 — 배포 후 채움>` |
| 삭제 완료 및 재조회 시각 | `<CHECKED_AT — 배포 후 채움>` |
| 미삭제 리소스·오류 | `<없음 여부를 실제 조회 후 기록 — 배포 후 채움>` |
| IAM 키 비활성화 | `<키 상태 확인 — 배포 후 채움>` |
| Billing 확인 | `<실제 내역과 후속 확인일 — 배포 후 채움>` |
| 로그·스크린샷 위치 | `<실제 생성된 경로 — 배포 후 채움>` |

문서 자체 점검: 삭제 성공, 빈 잔여 목록, EIP/NAT/ELB/RDS의 실측 부재, 청구 금액을 지어내지 않았다. “미생성(해당 없음)”은 설계 범위의 표시이며 실제 계정 확인 완료를 뜻하지 않는다. 모든 체크박스와 완료 근거는 실제 수행 후 작성한다.
