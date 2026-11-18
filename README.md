<p align="center">
  <img src="docs/images/ansible-logo.png" alt="Ansible" width="160">
</p>

# DangUBI Host Network

OpenStack(kolla-ansible) 멀티노드 배포 전에 필요한 **호스트 네트워크 상태를 Ansible로 점검**하는 저장소입니다.
노트북 3대(컨트롤러)와 PC 1대(컴퓨트)로 구성된 클러스터를 대상으로 합니다.

## 1. 멀티노드 네트워크 구조

### 노드 구성

| 호스트 | 그룹 | 장비 | 관리망 IP (`mgmt_ip`) | 외부망 IP (`ext_ip`) | 망이 붙는 인터페이스 (`mgmt_if`) |
|---|---|---|---|---|---|
| os-ctl1 | controllers | 노트북 | 10.10.0.11 | 10.20.0.2 | `br-mgmt` (브리지) |
| os-ctl2 | controllers | 노트북 | 10.10.0.12 | 10.20.0.3 | `br-mgmt` (브리지) |
| os-ctl3 | controllers | 노트북 | 10.10.0.13 | 10.20.0.4 | `br-mgmt` (브리지) |
| os-cmp1 | computes | PC | 10.10.0.14 | 10.20.0.5 | `enp3s0` (물리 NIC) |

SSH 접속 주소(`ansible_host`)와 계정은 [`ansible/inventory/hosts.yml`](ansible/inventory/hosts.yml)에 있습니다.

### 네트워크

| 네트워크 | 대역 | 용도 |
|---|---|---|
| 업링크 | `wlo1` (Wi-Fi) | 인터넷으로 나가는 기본 경로 |
| 관리망 | `10.10.0.0/24` | kolla 관리망. 노드 간 API·DB·메시지 큐 통신 |
| 외부망 | `10.20.0.0/24` | Neutron 외부망. VM의 floating IP 대역 |
| NAT VIP | `10.20.0.1` | 외부망의 게이트웨이. 컨트롤러 중 한 대가 보유 |
| Ansible 제어 | Tailscale (`100.x.x.x`) | 작업자 PC에서 각 노드로 SSH 접속 |

```mermaid
flowchart TB
    internet((Internet))

    subgraph CTL["os-ctl1 ~ 3 (controllers)"]
        direction TB
        wlo1_c["wlo1 (Wi-Fi)<br/>기본 경로"]
        br["br-mgmt<br/>10.10.0.1x/24 + 10.20.0.x/24"]
        vh["veth-host"]
        vn["veth-neutron<br/>→ Neutron 외부 인터페이스"]
        br --- vh
        vh ===|veth pair| vn
        br -. "MASQUERADE<br/>10.20.0.0/24 → wlo1" .-> wlo1_c
    end

    subgraph CMP["os-cmp1 (computes)"]
        direction TB
        wlo1_p["wlo1 (Wi-Fi)<br/>기본 경로"]
        enp["enp3s0<br/>10.10.0.14/24 + 10.20.0.5/24"]
    end

    L2["유선 L2 세그먼트<br/>관리망 10.10.0.0/24 · 외부망 10.20.0.0/24"]

    br --- L2
    enp --- L2
    wlo1_c --> internet
    wlo1_p --> internet
```

### 핵심 포인트

- **관리망과 외부망은 같은 인터페이스를 씁니다.** 컨트롤러는 `br-mgmt`, 컴퓨트는 `enp3s0` 하나에 두 대역의 IP가 함께 붙습니다.
- **컨트롤러의 veth pair.** `veth-host`는 `br-mgmt`에 포트로 꽂히고, 반대쪽 `veth-neutron`은 Neutron이 외부 인터페이스로 가져갑니다. 이 pair는 `veth-neutron.service`(systemd)가 부팅할 때 만들고, NetworkManager는 두 인터페이스를 관리하지 않도록(`unmanaged`) 설정합니다.
- **외부망은 NAT으로 인터넷에 나갑니다.** 컨트롤러는 IP 포워딩을 켜고, `10.20.0.0/24`에서 나가는 트래픽을 `wlo1`로 MASQUERADE합니다. 규칙은 `/etc/iptables/rules.v4`에 저장해서 재부팅 뒤에도 유지됩니다.
- **NAT VIP `10.20.0.1`**은 외부망의 기본 게이트웨이이며, 컨트롤러 중 한 대가 보유합니다.

## 2. 폴더 구조

```
.
├── README.md
├── docs/images/                    # README 이미지
└── ansible/
    ├── ansible.cfg                 # 인벤토리·roles 경로, sudo, SSH 설정
    ├── inventory/
    │   ├── hosts.yml               # 호스트 목록과 호스트별 IP (controllers / computes 그룹)
    │   └── group_vars/
    │       ├── all.yml             # 공통: uplink_if, ext_cidr, nat_vip, net_prefix
    │       ├── controllers.yml     # mgmt_if: br-mgmt
    │       └── computes.yml        # mgmt_if: enp3s0
    ├── playbooks/
    │   └── verify.yml              # 네트워크 상태 점검 (읽기 전용)
    └── roles/
        └── verify_network/tasks/
            ├── main.yml            # 점검 순서. 컨트롤러 전용 항목은 group_names로 선택
            ├── route.yml           # 전체: 기본 경로가 uplink_if인지
            ├── mgmt_addr.yml       # 전체: mgmt_if에 관리망·외부망 IP가 있는지
            ├── veth.yml            # 컨트롤러: veth pair, systemd 서비스, NetworkManager
            └── nat.yml             # 컨트롤러: NAT VIP, IP 포워딩, MASQUERADE
```

점검 태스크는 `조회(get) → 판정(assert)` 쌍으로 되어 있고, 이름도 `<대상> | get …`, `<대상> | assert …` 형식으로 맞췄습니다.

## 3. Ansible 명령어

모든 명령은 **`ansible/` 디렉터리에서** 실행합니다. `ansible.cfg`가 이 디렉터리에 있어서, 다른 곳에서 실행하면 인벤토리와 role을 찾지 못합니다.

```bash
cd ansible
```

### 실행 전 준비

1. 작업자 PC와 모든 노드가 Tailscale에 연결되어 있어야 합니다.
2. 각 노드 계정에 SSH 키로 로그인할 수 있어야 합니다. (`ssh-copy-id <user>@<ansible_host>`)
3. `host_key_checking = True`이므로 각 노드에 한 번 `ssh`로 접속해 known_hosts에 등록합니다.
4. 실행하면 처음에 `BECOME password:`(sudo 비밀번호)를 한 번 묻습니다. 이 값을 모든 노드에 똑같이 사용합니다.

### 인벤토리 확인

```bash
ansible-inventory --graph                 # 그룹과 호스트 트리
ansible-inventory --graph --vars          # 호스트별 변수까지
ansible-inventory --host os-ctl1          # 특정 호스트에 적용되는 변수
ansible all -m ping                       # 모든 노드 SSH·Python 연결 확인
```

### 네트워크 점검 (verify)

```bash
ansible-playbook playbooks/verify.yml                         # 전체 노드 점검
ansible-playbook playbooks/verify.yml --limit controllers     # 컨트롤러만
ansible-playbook playbooks/verify.yml --limit os-cmp1         # 특정 호스트만
ansible-playbook playbooks/verify.yml -v                      # 명령 출력까지 자세히
```

### 실행 전 검사

```bash
ansible-playbook playbooks/verify.yml --syntax-check          # 문법 검사
ansible-playbook playbooks/verify.yml --list-tasks            # 실행할 태스크 목록
ansible-playbook playbooks/verify.yml --list-hosts            # 대상 호스트 목록
```

### 결과 읽기

- `ok`는 통과, `failed`는 실패, `skipping`은 대상이 아니라서 건너뛴 태스크입니다.
- 실패하면 assert의 `fail_msg`에 실제 값이 출력됩니다. (예: `net.ipv4.ip_forward = 0`)
- 마지막 `PLAY RECAP`에서 호스트별로 `failed=0`인지 확인합니다.
- 하나라도 실패하면 종료 코드가 0이 아니므로 스크립트에서 `&&`로 이어 쓸 수 있습니다.
- 실패한 호스트는 그 지점에서 점검이 멈춥니다. 원인을 고친 뒤 다시 실행합니다.

`verify.yml`은 조회만 하고 시스템을 바꾸지 않으므로 언제 실행해도 안전합니다. 네트워크 설정을 바꾼 직후, 노드를 재부팅한 뒤, kolla-ansible 배포 전에 실행하는 것을 권장합니다.
