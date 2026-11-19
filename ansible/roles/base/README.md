# base role

물리 노드 4대(os-ctl1~3, os-cmp1)의 호스트 기본 설정을 코드로 표현한 role입니다.
노드는 이미 손으로 구성돼 있고 Kolla가 배포돼 운영 중이라, 새로 구성하는 것이 아니라 **현재 상태를 그대로 옮기는 것**이 목표입니다.
그래서 `--check --diff` 결과가 **`changed=0`이면 정상**입니다.

```bash
cd ansible
ansible-playbook playbooks/base.yml --check --diff --limit os-ctl2   # VIP 없는 노드부터 미리보기
ansible-playbook playbooks/base.yml --check --diff                   # 전체 미리보기
ansible-playbook playbooks/base.yml                                  # 적용
ansible-playbook playbooks/verify.yml                                # 적용 결과 점검 (verify_base)
```

일부 항목만 실행하려면 태그를 씁니다. 태그는 `hostname`, `hosts`, `power`, `firewall`, `sysctl`, `chrony`입니다.

```bash
ansible-playbook playbooks/base.yml --tags chrony --check --diff     # chrony만 미리보기
ansible-playbook playbooks/base.yml --list-tags                      # 태그 목록
```

## 구성

```
roles/base/
├── defaults/main.yml   # 기본 변수
├── handlers/main.yml   # chrony reload / restart
└── tasks/
    ├── main.yml        # 아래 파일을 순서대로 import_tasks (파일별 태그)
    ├── hostname.yml
    ├── hosts_file.yml
    ├── power.yml
    ├── firewall.yml
    ├── sysctl.yml
    └── chrony.yml
```

| 파일 (태그) | 대상 | 하는 일 |
|---|---|---|
| `hostname.yml` (`hostname`) | 전체 | 호스트명이 `inventory_hostname`과 같은지 확인. 다르면 실패 |
| `hosts_file.yml` (`hosts`) | 전체 | `/etc/hosts`에서 `127.0.1.1` 줄 제거, 모든 노드의 `mgmt_ip 호스트명` 매핑 보장 |
| `power.yml` (`power`) | 전체 / controllers | 절전 target 4개 mask, 노트북 덮개 닫힘 무시 |
| `firewall.yml` (`firewall`) | 전체 | ufw 비활성 |
| `sysctl.yml` (`sysctl`) | controllers | `net.ipv4.ip_forward = 1` 영구 적용 |
| `chrony.yml` (`chrony`) | 전체 | chrony 설치·실행, NTP 소스 파일 관리 (기본은 꺼짐) |

## 항목별 설명

### hostname
Kolla 배포 후에는 호스트명이 RabbitMQ 노드 이름 등에 들어가 있어서, 바꾸면 클러스터가 깨집니다.
그래서 기본 동작은 **확인만 하고, 다르면 실패**입니다. 실제 변경은 `-e base_allow_hostname_change=true`일 때만 합니다. 이 옵션은 Kolla 재배포를 전제로 하거나 새 노드를 추가할 때만 씁니다.

새 노드(예: os-cmp2)를 추가하는 순서는 다음과 같습니다.
1. `inventory/hosts.yml`에 노드를 추가하고, SSH 키 등록과 known_hosts 등록을 합니다.
2. 새 노드에만 호스트명 변경을 허용해 적용합니다.
   ```bash
   ansible-playbook playbooks/base.yml --check --diff --limit os-cmp2 -e base_allow_hostname_change=true
   ansible-playbook playbooks/base.yml --limit os-cmp2 -e base_allow_hostname_change=true
   ```
3. 기존 노드에도 base를 다시 실행해 `/etc/hosts`에 새 노드 매핑을 추가합니다. 이때 노드마다 변경 1건이 나오는 것이 정상입니다.
4. Kolla 쪽(인벤토리, `bootstrap-servers`)은 이 role의 범위 밖이라 따로 진행합니다.

### /etc/hosts
- `127.0.1.1 <호스트명>` 줄이 있으면 RabbitMQ·Kolla가 자기 호스트명을 루프백 주소로 해석합니다. 그러면 다른 노드가 접속할 수 없는 주소로 클러스터에 참여하게 되므로 이 줄을 지웁니다.
- 노드끼리 호스트명으로 관리망 IP를 찾을 수 있도록, 모든 노드의 매핑이 있어야 합니다. 대상 목록은 인벤토리의 `groups['all']`에서 만듭니다.
- 파일에는 예전에 손으로 추가한 4줄(마커 없음)과 Kolla `bootstrap-servers`가 만든 `# BEGIN/END ANSIBLE GENERATED HOSTS` 블록이 함께 있을 수 있습니다. 그래서 다음 규칙을 따릅니다.
  - 매핑이 어디에든 이미 있으면 아무것도 하지 않습니다. Kolla 블록 안의 줄이나 별칭이 붙은 줄도 "있음"으로 봅니다.
  - 매핑이 아예 없을 때만 파일 끝에 한 줄 추가합니다. 기존 줄을 바꿔 쓰지는 않습니다.
  - 같은 매핑이 여러 줄이어도(수동 4줄 + Kolla 블록) IP가 같으면 동작에 문제가 없으므로 그대로 둡니다.
  - 같은 호스트명이 다른 IP로 매핑돼 있으면 실패하고 멈춥니다. 어느 줄을 남길지는 사람이 정합니다.

### 절전
- 노드가 절전에 들어가면 OpenStack 서비스와 VM이 통째로 클러스터에서 빠집니다. 그래서 `sleep` / `suspend` / `hibernate` / `hybrid-sleep` target을 mask합니다.
- controllers는 노트북이라, 덮개를 닫으면 기본 동작인 suspend가 일어납니다. 그래서 `/etc/systemd/logind.conf.d/lid-switch-ignore.conf` drop-in에 다음 값을 둡니다.
  - `HandleLidSwitch=ignore`
  - `HandleLidSwitchExternalPower=ignore`
- `/etc/systemd/logind.conf` 끝에도 같은 값이 손으로 추가돼 있습니다. 값이 같으므로 그 파일은 건드리지 않습니다.
- drop-in이 바뀌어도 logind는 재시작하지 않습니다. "재부팅 필요" 메시지만 출력하고, 실제 반영은 재부팅 때 됩니다.

### 방화벽 (ufw)
ufw는 iptables 규칙을 자체적으로 덮어씁니다. 그래서 켜져 있으면 Kolla(Neutron, Docker)의 규칙이나 NAT와 충돌합니다.
- ufw가 설치된 노드에서만 `state: disabled`로 둡니다. 설치 여부는 `package_facts`로 확인합니다.
- 서비스 disable까지는 하지 않습니다.

### IP 포워딩 (controllers)
컨트롤러는 외부망 트래픽을 `wlo1`로 NAT하는 게이트웨이입니다. 포워딩이 꺼지면 VM의 외부 통신이 끊깁니다.
- 영구 설정은 기존 파일인 `/etc/sysctl.d/99-forward.conf`에 둡니다.
- computes는 포워딩이 필요 없지만, 지금 켜져 있어도 끄지 않습니다. 관리 대상이 아닙니다.

### chrony
노드 간 시간이 어긋나면 RabbitMQ, Galera, Keystone 토큰 검증 등이 실패합니다.

| 변수 | 파일 | 내용 |
|---|---|---|
| `chrony_kr_sources` | `/etc/chrony/sources.d/kr.sources` | 국내 NTP 서버 (time.google.com, time.bora.net, kr.pool.ntp.org) |
| `chrony_cluster_server` | `/etc/chrony/conf.d/cluster.conf` | 클러스터 기준 시계 역할 (os-ctl1). 관리망 질의 허용, 외부 NTP가 끊겨도 stratum 10으로 시간 제공 |
| `chrony_cluster_client` | `/etc/chrony/sources.d/cluster.sources` | 나머지 노드가 기준 시계를 우선 소스로 사용 |

- 플래그가 `false`면 해당 파일은 **관리하지 않습니다.** 만들지도, 지우지도 않습니다.
- **현재 기본값은 모두 `false`입니다.** 상태를 수집해 보니 세 파일 모두 어느 노드에도 없었습니다. 노드들은 Ubuntu 기본 NTP 서버로 각자 동기화하고 있습니다. 내부 시간 서버 구성을 도입하는 것은 동작이 바뀌는 일이라 다음 단계에서 따로 켭니다.
  - 국내 서버: `chrony_kr_sources: true`
  - 클러스터 내부 시간 서버: `chrony_cluster: true` (os-ctl1은 `cluster.conf`, 나머지는 `cluster.sources`를 받습니다)
- os-cmp1은 `systemd-timesyncd`를 쓰고 있었습니다. chrony를 설치하면 timesyncd는 자동으로 제거됩니다.
- 기준 시계 호스트는 `chrony_cluster_server_host`로 정하고, IP는 그 호스트의 `mgmt_ip`를 씁니다.
- 파일을 바꿨을 때 실행되는 handler는 다음과 같습니다.
  - `sources.d` 변경 → `chronyc reload sources`. 서비스 중단이 없습니다.
  - `conf.d` 변경 → chrony 재시작. `allow`·`local` 설정은 재시작해야 반영되며, chrony 재시작은 안전합니다.

## 동작 상세

태스크 파일에서 옮겨 온 설명입니다.

### 공통
- `tasks/main.yml`은 `import_tasks`를 씁니다. 플레이북을 읽을 때 펼쳐지므로 `--list-tasks`에 모든 태스크가 보입니다.
- controllers 전용 항목은 `when: 'controllers' in group_names` 대신 group_vars 플래그(`base_lid_switch_ignore`, `base_ip_forward`)로 거릅니다.

### hostname.yml
- 비교 대상인 `ansible_facts['hostname']`은 `gather_facts`로 수집한 짧은 호스트명입니다. `ansible_hostname` 같은 최상위 fact 변수는 ansible-core 2.24에서 없어지므로 쓰지 않습니다.
- `-e base_allow_hostname_change=true`로 넘기면 문자열 `"true"`가 됩니다. 그래서 `| bool`로 변환해 비교합니다.
- 다른 이름으로 운영 중인 노드를 놓치면 `/etc/hosts`·chrony 설정이 엉뚱한 이름을 기준으로 들어갑니다. 그래서 다르면 바로 실패시킵니다.
- 변경 태스크는 check 모드에서는 바뀔지 여부만 보고하고 실제로 바꾸지 않습니다.

### hosts_file.yml
- `slurp`로 현재 파일 전체를 읽습니다. 충돌·누락을 판단하려면 전체 내용이 필요하기 때문입니다. 읽기만 하므로 check 모드에서도 실행됩니다.
- 판단할 때 주석·빈 줄은 뺍니다. `127.0.1.1` 줄은 어차피 지울 것이라 충돌 판단에서도 뺍니다.
- 충돌: 호스트명이 `mgmt_ip`가 아닌 다른 IP로도 매핑돼 있으면, 어느 쪽이 맞는지 코드가 판단할 수 없어서 실패합니다. 그냥 두면 잘못된 줄이 남아 있어도 정상으로 보이고, `getent` 결과가 노드마다 달라질 수 있습니다.
- 중복: 같은 매핑이 두 줄 이상이어도 보고하지 않습니다. 모든 노드가 수동 4줄과 Kolla 블록을 함께 갖고 있어서, 보고하면 매번 같은 메시지만 반복되기 때문입니다.
- 추가: `lineinfile`에 `regexp` 없이 `line`만 주면, 정확히 같은 줄이 없을 때 파일 끝에 추가만 합니다. 다른 줄은 건드리지 않습니다. 다른 형식(별칭 포함 등)으로 이미 매핑돼 있으면 `when`으로 건너뜁니다.

### power.yml
- target을 mask하면 전원 버튼, 유휴 타이머, GUI 등 어떤 경로로도 해당 target에 들어가지 못합니다.
- Ubuntu 기본 설치에는 `/etc/systemd/logind.conf.d/` 디렉터리가 없을 수 있어서 먼저 만듭니다.
- drop-in이 `logind.conf`보다 우선 적용됩니다. 관리하는 값은 drop-in으로 분리합니다.
- check 모드에서는 디렉터리를 실제로 만들지 않습니다. 그래서 디렉터리가 아직 없으면 drop-in copy가 "디렉터리 없음"으로 실패하므로 그 경우 건너뜁니다. 변경 예정이라는 것은 디렉터리 태스크의 `changed`로 알 수 있습니다.
- 지금은 `logind.conf`에 같은 값이 있으므로 실제 동작은 이미 `ignore`일 가능성이 높습니다. `verify.yml`이 logind의 실행 중 값을 확인합니다.

### firewall.yml
- ufw가 설치되지 않은 노드에서 ufw 모듈을 부르면 "ufw 명령 없음"으로 실패합니다. 그래서 `package_facts`로 설치 여부를 먼저 봅니다. 조회만 하므로 check 모드에서도 실행됩니다.
- 이미 inactive면 변경 없음(ok)입니다. check 모드에서는 상태만 비교합니다.

### sysctl.yml
- 모듈은 `키 = 값`의 공백 차이를 무시하고 값으로 비교합니다. 값이 같으면 파일을 다시 쓰지 않습니다.
- check 모드에서는 실행 중 값과 파일을 비교만 하고 `sysctl -p`는 실행하지 않습니다.

### chrony.yml
- Ubuntu 기본 `/etc/chrony/chrony.conf`가 `sourcedir /etc/chrony/sources.d`와 `confdir /etc/chrony/conf.d`를 읽습니다. 그래서 이 두 디렉터리에 파일을 둡니다.
- `kr.sources`는 기본 Ubuntu pool 대신 국내에서 응답이 빠른 서버를 쓰기 위한 파일입니다.
- check 모드에서 chrony가 새로 설치될 예정이면 서비스가 아직 없어 서비스 태스크가 실패합니다. 그래서 그 경우에는 서비스 태스크를 건너뜁니다.
- handler의 `chronyc reload sources`는 command 모듈이라 check 모드에서는 실행되지 않습니다.

## 변수

| 변수 | 기본값 | 덮어쓰는 곳 | 설명 |
|---|---|---|---|
| `base_allow_hostname_change` | `false` | 실행 시 `-e` | 호스트명 실제 변경 허용 |
| `base_sleep_targets` | 4개 target | — | mask할 절전 target |
| `base_lid_switch_ignore` | `false` | `group_vars/controllers.yml`: `true` | 덮개 닫힘 무시 drop-in 관리 |
| `base_logind_dropin_path` | `/etc/systemd/logind.conf.d/lid-switch-ignore.conf` | — | drop-in 경로 |
| `base_ip_forward` | `false` | `group_vars/controllers.yml`: `true` | IP 포워딩 관리 |
| `base_ip_forward_file` | `/etc/sysctl.d/99-forward.conf` | — | 포워딩 영구 설정 파일 |
| `chrony_kr_sources` | `false` | — | kr.sources 관리 |
| `chrony_cluster` | `false` | — | 클러스터 내부 시간 서버 구성 관리 |
| `chrony_cluster_server_host` | `os-ctl1` | — | 클러스터 기준 시계 호스트 |
| `chrony_cluster_server` / `_client` | `chrony_cluster`와 기준 호스트 여부로 계산 | — | cluster.conf / cluster.sources 관리 |
| `chrony_*_content` | 위 표의 내용 | — | 파일 내용. 현재 노드 파일과 글자 하나까지 같아야 changed=0 |

`mgmt_cidr`(chrony allow 대상)는 `inventory/group_vars/all.yml`에 있습니다.

## 하지 않는 것과 이유

| 하지 않는 것 | 이유 |
|---|---|
| systemd-logind 재시작·reload | 데스크톱 세션이 강제로 종료됩니다 (실제 사고). 적용은 재부팅으로만 합니다 |
| NetworkManager 재시작 | `wlo1`(Tailscale/SSH 경로)과 `br-mgmt`(관리망)이 끊기고 NAT VIP가 넘어갈 수 있습니다 |
| docker·Kolla 컨테이너 재시작 | 해당 노드의 OpenStack 서비스가 한꺼번에 멈춥니다 |
| 재부팅 | 운영 중인 클러스터라 사람이 시점을 정합니다 |
| NetworkManager 프로필, iptables, Tailscale, veth-neutron, Wi-Fi, Kolla 설정 변경 | 이 role의 범위가 아닙니다 |
| 마커 없는 파일에 blockinfile, `shell`로 sed/echo | 기존 내용과 중복되거나 멱등성이 깨집니다 |

handler는 변경이 생긴 **모든 호스트에서 동시에** 실행됩니다. 위 서비스의 재시작 handler가 컨트롤러 3대에서 한꺼번에 돌면 Galera와 RabbitMQ가 정족수를 잃습니다. 그러면 수동으로 복구해야 합니다.
