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

## 구성

```
roles/base/
├── defaults/main.yml   # 기본 변수
├── handlers/main.yml   # chrony reload / restart
└── tasks/
    ├── main.yml        # 아래 파일을 순서대로 import_tasks
    ├── hostname.yml
    ├── hosts_file.yml
    ├── power.yml
    ├── firewall.yml
    ├── sysctl.yml
    └── chrony.yml
```

| 파일 | 대상 | 하는 일 |
|---|---|---|
| `hostname.yml` | 전체 | 호스트명이 `inventory_hostname`과 같은지 확인. 다르면 실패 |
| `hosts_file.yml` | 전체 | `/etc/hosts`에서 `127.0.1.1` 줄 제거, 모든 노드의 `mgmt_ip 호스트명` 매핑 보장 |
| `power.yml` | 전체 / controllers | 절전 target 4개 mask, 노트북 덮개 닫힘 무시 |
| `firewall.yml` | 전체 | ufw 비활성 |
| `sysctl.yml` | controllers | `net.ipv4.ip_forward = 1` 영구 적용 |
| `chrony.yml` | 전체 | chrony 설치·실행, NTP 소스 파일 관리 |

## 항목별 설명

### hostname
Kolla 배포 후에는 호스트명이 RabbitMQ 노드 이름 등에 들어가 있어서, 바꾸면 클러스터가 깨집니다.
그래서 기본 동작은 **확인만 하고, 다르면 실패**입니다. 실제 변경은 `-e base_allow_hostname_change=true`일 때만 합니다. 이 옵션은 Kolla 재배포를 전제로 할 때만 씁니다.

### /etc/hosts
- `127.0.1.1 <호스트명>` 줄이 있으면 RabbitMQ·Kolla가 자기 호스트명을 루프백 주소로 해석합니다. 그러면 다른 노드가 접속할 수 없는 주소로 클러스터에 참여하게 되므로 이 줄을 지웁니다.
- 노드끼리 호스트명으로 관리망 IP를 찾을 수 있도록, 모든 노드의 매핑이 있어야 합니다. 대상 목록은 인벤토리의 `groups['all']`에서 만듭니다.
- 파일에는 예전에 손으로 추가한 4줄(마커 없음)과 Kolla `bootstrap-servers`가 만든 `# BEGIN/END ANSIBLE GENERATED HOSTS` 블록이 함께 있을 수 있습니다. 그래서 다음 규칙을 따릅니다.
  - 매핑이 어디에든 이미 있으면 아무것도 하지 않습니다. Kolla 블록 안의 줄이나 별칭이 붙은 줄도 "있음"으로 봅니다.
  - 매핑이 아예 없을 때만 파일 끝에 한 줄 추가합니다. 기존 줄을 바꿔 쓰지는 않습니다.
  - 같은 매핑이 여러 줄이면 보고만 합니다.
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
- 기준 시계 호스트는 `chrony_cluster_server_host`로 정하고, IP는 그 호스트의 `mgmt_ip`를 씁니다.
- 파일을 바꿨을 때 실행되는 handler는 다음과 같습니다.
  - `sources.d` 변경 → `chronyc reload sources`. 서비스 중단이 없습니다.
  - `conf.d` 변경 → chrony 재시작. `allow`·`local` 설정은 재시작해야 반영되며, chrony 재시작은 안전합니다.

## 변수

| 변수 | 기본값 | 덮어쓰는 곳 | 설명 |
|---|---|---|---|
| `base_allow_hostname_change` | `false` | 실행 시 `-e` | 호스트명 실제 변경 허용 |
| `base_sleep_targets` | 4개 target | — | mask할 절전 target |
| `base_lid_switch_ignore` | `false` | `group_vars/controllers.yml`: `true` | 덮개 닫힘 무시 drop-in 관리 |
| `base_logind_dropin_path` | `/etc/systemd/logind.conf.d/lid-switch-ignore.conf` | — | drop-in 경로 |
| `base_ip_forward` | `false` | `group_vars/controllers.yml`: `true` | IP 포워딩 관리 |
| `base_ip_forward_file` | `/etc/sysctl.d/99-forward.conf` | — | 포워딩 영구 설정 파일 |
| `chrony_kr_sources` | `true` | — | kr.sources 관리 |
| `chrony_cluster_server_host` | `os-ctl1` | — | 클러스터 기준 시계 호스트 |
| `chrony_cluster_server` / `_client` | 기준 호스트 여부로 계산 | — | cluster.conf / cluster.sources 관리 |
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
