# rocky_major_upgrade

Rocky 8 → 9 **신규 VM 이관** 리허설용 AWX 프로젝트입니다. (Notion: "Rocky 8→9 신규 VM 이관 테스트 작업 계획서 (WEB/WAS, 테스트 서버 1대)" 기준)

제자리(in-place) 업그레이드가 아니라 신규 Rocky 9 VM을 만들어 이관하고, 구 VM은 롤백 기준점으로 그대로 보존합니다.

## 구조

```
ansible.cfg
collections/requirements.yml      # ansible.posix, community.general
playbooks/
  bootstrap.yml                   # Python 검사/설치 (없을 때만 변경)
  collect.yml                     # 구 VM 읽기 전용 수집 (변경점 8개 항목)
  deploy.yml                      # 신규 VM 배포 (check / apply 공용)
  validate.yml                    # 전환 전 검증 (읽기 전용)
  switch_ip.yml                   # IP 교체 전환 (선택)
  rollback_ip.yml                 # IP 원복 롤백 (선택)
  group_vars/                     # 비밀값 없는 변수만
roles/
  common_rocky9/                  # Rocky 9 기본 설정, gratuitous ARP sysctl
  was_tomcat/                     # JDK + Tomcat 신규 설치, systemd, webapps
  web_apache/                     # httpd + reverse proxy
  batch_control/                  # 배치 타이머/crond 활성·비활성
examples/                         # AWX에 넣을 Extra Variables 예시
```

`group_vars`는 플레이북 옆(`playbooks/group_vars/`)에 둬야 Ansible이 읽습니다. 저장소 루트에 두면 `playbooks/` 아래 플레이북에는 적용되지 않습니다.

## AWX 잡 템플릿

공통: Inventory `inv-r8to9-test`, Project `proj-r8to9`(태그 고정), Machine Credential, **Privilege Escalation 체크**, EE 버전 고정(`AWX EE (24.6.1)`).

| 템플릿 | Job Type | Playbook | Limit | 비고 |
|---|---|---|---|---|
| r8to9-00-bootstrap | Run | playbooks/bootstrap.yml | rocky8_old | Python이 있으면 변경 없음 |
| r8to9-01-collect | Run | playbooks/collect.yml | rocky8_old | Extra Vars: `examples/collect_extra_vars.yml` |
| r8to9-02-deploy-check | **Check** | playbooks/deploy.yml | rocky9_new | Show Changes 켬 |
| r8to9-03-deploy-apply | Run | playbooks/deploy.yml | rocky9_new | check 결과 승인 후 |
| r8to9-04-validate | Run | playbooks/validate.yml | rocky9_new | 읽기 전용 |
| r8to9-05-switch-ip | Run | playbooks/switch_ip.yml | rocky8_old:rocky9_new | 승인 필요, `confirm_switch=true` |
| r8to9-06-rollback-ip | Run | playbooks/rollback_ip.yml | rocky8_old:rocky9_new | 승인 필요, `confirm_rollback=true` |

권장 Workflow: `deploy-check → 승인 노드 → deploy-apply → validate`

## 사용 순서

1. 구 VM과 신규 VM에 자동화 계정, 공개키, sudoers를 준비하고 인벤토리에 등록합니다 (`examples/awx_inventory_vars.yml`).
2. `bootstrap` → `collect` 실행 후 결과를 사람이 판정합니다.
3. `playbooks/group_vars/rocky9_new.yml`의 빈 값을 채웁니다 (`tomcat_version`, `tomcat_tarball_url`, `tomcat_webapps` 등).
4. `deploy-check` 결과를 확인·승인한 뒤 `deploy-apply`, `validate`를 실행합니다.
5. 전환과 롤백은 `switch_ip` / `rollback_ip` 또는 콘솔로 수행합니다. 롤백은 성공해도 1회 의도적으로 수행해 시간을 실측하세요.

다운타임 실측은 작업 PC에서 1초 간격 curl 루프가 가장 정확합니다 (계획서 Q4 참고).

## 주의 사항

- **스크립트가 채워 넣은 값이 아니라 뼈대입니다.** 인증서(SHA-256 이상), firewalld 규칙, NetworkManager 설정, cgroup v2 대응 스크립트처럼 서버마다 다른 부분은 수집 결과를 보고 role에 반영하세요. `web_apache`는 TLS를 설정하지 않으며 Nginx role은 포함되어 있지 않습니다.
- **IP 교체 잡**은 구 VM의 SSH가 끊기도록 설계되어 있어 해당 태스크를 `async`로 분리했습니다. 신규 VM은 서비스 IP를 primary로, 임시 IP를 secondary로 유지해 잡 연결이 유지됩니다. 플랫폼에 IP·MAC 바인딩이 켜져 있으면 OS에서 IP를 바꾸는 방식 자체가 막힐 수 있습니다. 전환 후에는 AWX 인벤토리의 `ansible_host`를 서로 바꿔 주세요.
- 동일 IP에 다른 호스트 키가 생기므로 전환 후 SSH 호스트 키 불일치가 날 수 있습니다. 리허설에서만 `ansible_ssh_common_args: -o StrictHostKeyChecking=no`로 우회하고, 운영에서는 known_hosts를 관리하세요.
- 배치는 **timer 유닛만** `batch_units`에 넣으세요. oneshot service를 넣으면 시작과 동시에 배치가 실행됩니다.
- Rocky 8 기본 Python은 3.6입니다. EE의 ansible-core가 이를 지원하지 않으면 `playbooks/group_vars/rocky8_old.yml`의 주석 두 줄을 풀어 Python 3.9를 쓰세요.
- 개인키, 토큰, 비밀번호는 이 저장소에 넣지 않습니다. AWX Credential 또는 Vault만 사용하세요.

## 로컬 점검

```bash
ansible-playbook -i localhost, --syntax-check playbooks/deploy.yml
ansible-lint
```

## Git에 올리기

```bash
git init
git remote add origin https://github.com/SummerToday/rocky_major_upgrade.git
git add . && git commit -m "Initial AWX project for Rocky 8 to 9 migration"
git push -u origin main
git tag v0.1.0 && git push origin v0.1.0   # the AWX project pins this tag
```
