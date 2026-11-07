# rocky_major_upgrade

Rocky 8 → 9 **신규 VM 이관** 리허설용 AWX 프로젝트입니다. (Notion: "Rocky 8→9 신규 VM 이관 테스트 작업 계획서 (WEB/WAS, 테스트 서버 1대)" 기준)

제자리(in-place) 업그레이드가 아니라 신규 Rocky 9 VM을 만들어 이관하고, 구 VM은 롤백 기준점으로 그대로 보존합니다.

## 구조

```
ansible.cfg
collections/requirements.yml      # ansible.posix, community.general
playbooks/
  bootstrap.yml                   # Python 검사/설치 (없을 때만 변경)
  collect.yml                     # 구 VM 읽기 전용 수집 (변경점 8개 항목, 대상 자동 탐색)
  collect_services.yml            # 구 VM WEB/WAS 상세 수집 (경로 자동 탐색, 읽기 전용)
  deploy.yml                      # 신규 VM 배포 (check / apply 공용)
  validate.yml                    # 전환 전 검증 (읽기 전용)
  switch_ip.yml                   # IP 교체 전환 (선택)
  rollback_ip.yml                 # IP 원복 롤백 (선택)
  group_vars/                     # 비밀값 없는 변수만 (all.yml에 수집용 셸 함수 shell_helpers 포함)
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
| r8to9-01-collect | Run | playbooks/collect.yml | rocky8_old | Extra Vars 불필요 (선택: `examples/collect_extra_vars.yml`) |
| r8to9-01b-collect-services | Run | playbooks/collect_services.yml | rocky8_old | 변수는 모두 선택, `examples/collect_services_extra_vars.yml` |
| r8to9-02-deploy-check | **Check** | playbooks/deploy.yml | rocky9_new | Show Changes 켬 |
| r8to9-03-deploy-apply | Run | playbooks/deploy.yml | rocky9_new | check 결과 승인 후 |
| r8to9-04-validate | Run | playbooks/validate.yml | rocky9_new | 읽기 전용 |
| r8to9-05-switch-ip | Run | playbooks/switch_ip.yml | rocky8_old:rocky9_new | 승인 필요, `confirm_switch=true` |
| r8to9-06-rollback-ip | Run | playbooks/rollback_ip.yml | rocky8_old:rocky9_new | 승인 필요, `confirm_rollback=true` |

권장 Workflow: `deploy-check → 승인 노드 → deploy-apply → validate`

## 사용 순서

1. 구 VM과 신규 VM에 자동화 계정, 공개키, sudoers를 준비하고 인벤토리에 등록합니다 (`examples/awx_inventory_vars.yml`).
2. `bootstrap` → `collect` → `collect_services` 실행 후 결과를 사람이 판정합니다.
3. `playbooks/group_vars/rocky9_new.yml`의 빈 값을 채웁니다 (`tomcat_version`, `tomcat_tarball_url`, `tomcat_webapps` 등).
4. `deploy-check` 결과를 확인·승인한 뒤 `deploy-apply`, `validate`를 실행합니다.
5. 전환과 롤백은 `switch_ip` / `rollback_ip` 또는 콘솔로 수행합니다. 롤백은 성공해도 1회 의도적으로 수행해 시간을 실측하세요.

다운타임 실측은 작업 PC에서 1초 간격 curl 루프가 가장 정확합니다 (계획서 Q4 참고).

## collect_services 수집 범위

실행 중인 프로세스(`ss -lntp`)에서 Apache/Nginx와 Tomcat 경로를 **자동으로 찾아** 수집합니다. 서버는 변경하지 않습니다.

| 구분 | 수집 내용 |
|---|---|
| Apache / Nginx | 빌드 옵션(`-V`), 로드 모듈(`-M`), 설정 파일(주석 제거), 바이너리·모듈의 OpenSSL 링크, 인증서 서명 알고리즘과 만료일 |
| Tomcat | CATALINA_BASE/HOME, JVM 옵션, systemd unit, 버전, webapps, server.xml/context.xml, JDBC·LDAP·Redis·HTTP 연동 대상, TLS 파일, DB 드라이버 jar, 네이티브 라이브러리의 OpenSSL 링크 |
| 배치 | crontab, cron.d, systemd timer, enabled 서비스 |
| 연동 | web/WAS 프로세스의 established 연결(연동 대상 IP:포트) |
| 기준값 | 리슨 중인 모든 포트(22 제외)를 http→https로 찔러 응답하는 URL과 Tomcat webapp 경로를 자동 측정 (3회, 응답 코드·시간). `health_urls`는 추가용 |
| OS | SELinux, firewalld, 타임존 |

- 비밀번호·secret·token·credential·passphrase 값은 `****`로 가립니다. 최선의 처리이므로 **출력을 공유하기 전에 직접 확인**하세요.
- 개인키 파일과 키스토어(jks, p12) 내용은 읽지 않습니다. 경로만 표시합니다.
- 자동 탐색에 실패하면 `apache_bin_override`, `tomcat_home_override`로 직접 지정하세요.
- systemd unit 탐색(`systemctl status <pid>`)은 실제 Rocky 8 서버에서 첫 실행 때 확인이 필요합니다.

## collect 자동 탐색 방식

사용자가 경로를 입력하지 않아도 서버에서 직접 알아냅니다. 입력 변수(`binary_paths`, `cert_paths`, `script_dirs`, `xfs_mount_points`)는 **추가용 선택값**입니다.

| 대상 | 탐색 방법 |
|---|---|
| 직접 설치한 바이너리·라이브러리 | 실행 중인 모든 프로세스의 실행 파일과 매핑된 `.so` 중 `rpm -qf`가 실패하는 것 → `ldd`로 OpenSSL 1.x 의존(`REVIEW`), 누락(`MISSING`) 판정 |
| 인증서 | Apache/Nginx/Tomcat 설정에서 추출 + `/etc/pki/tls/certs`, `/etc/httpd`, `/etc/nginx`, 설치 디렉터리 스캔 → SHA-1/MD5, 2048bit 미만 판정과 만료일 |
| cgroup v1 경로 | systemd unit, cron, `/usr/local/bin`, 직접 설치 프로그램과 Tomcat bin 디렉터리 스캔 (CPUShares, MemoryLimit 포함) |
| Java cgroup v2 | 리슨 중인 java와 설치된 JDK 버전 판정 (8u372+, 11.0.16+, 15+) |
| OS 패키지 변경 | `rpm -Va`(기본 켜짐, `nice`로 실행). 설정 파일(`c`) 변경 목록과 내용을 보여주고, 바뀐 파일 종류에 따라 후속 명령을 자동 실행 |
| SELinux | 모드, `semanage` 로컬 규칙(fcontext/boolean/port)과 **규칙 경로의 현존 여부(EXISTS/MISSING, 오래된 규칙 식별)**, 웹/WAS 프로세스의 SELinux 도메인, 앱 경로 라벨·심볼릭 링크, `restorecon -Rnv` 드라이런(변경 없음), 부팅 이후 AVC 거부 |
| 부팅·암호·방화벽 | 커널 cmdline, cgroup 모드(v1/v2), crypto policy, firewalld 규칙과 **리슨 포트별 허용 여부(`NOT-ALLOWED` 표시)** |
| OS 패키지 밖 항목 | 벤더가 Rocky가 아닌 RPM, 저장소 설정, `/usr/local` 파일, 소스 빌드 옵션(`config.nice`), 직접 만든 systemd unit의 **전체 정의·활성 상태·ExecStart 실제 경로(심볼릭 링크 해석)** |
| 서버 사양·네트워크 | CPU/메모리/스왑/가상화, IP·MAC·MTU·라우트·DNS, NetworkManager 연결과 ifcfg 내용 |
| RPM 비소유 `/etc` 파일 | `rpm -Va`가 못 보는, 사람이 새로 만든 설정 파일(`sysctl.d`, `limits.d`, `logrotate.d` 등) 목록과 내용 |
| 데이터 크기 | 앱 경로(심볼릭 링크 해석)와 상위 디렉터리 하위 항목, Tomcat webapps, `/var/log` 등 용량 |
| 로컬 계정 | uid 1000 이상·로그인 가능 계정, 그룹 멤버, sudoers, authorized_keys 개수(키 내용은 읽지 않음), 잠금 상태 |
| 마운트·계정 | fstab, 마운트된 파일시스템, 리슨 프로그램의 **모든 실행 계정(워커 포함) uid/gid·passwd 항목**과 limit |
| XFS | `findmnt -t xfs`로 마운트 탐색 후 `xfs_info` |

`rpm -Va` 후속 점검 분기: `file_contexts.local`이 바뀌면 `semanage fcontext -l -C`, `/etc/ssh/*`이면 `sshd -T` 유효값, `/etc/systemd/*`이면 `systemd-delta`, `/etc/chrony*`이면 `chronyc sources`, `/etc/crypto-policies/*`이면 정책 표시, sudoers면 `visudo -c`, fstab이면 마운트 목록을 이어서 실행합니다. 시간이 오래 걸리면 `collect_rpm_va: false`로 끄거나 `rpm_va_timeout`(기본 900초)을 조정하세요.

탐색 결과의 한계: 실행 중이 아닌 프로그램, 64KB 초과 인증서 파일, 깊이 6 초과 경로는 놓칩니다. 이때만 추가 변수를 사용하세요.

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
