---
name: readme-sync
description: 이 저장소에서 git push(푸시)하기 직전에, 푸시될 변경 내용을 README.md에 반영한다. 사용자가 "푸시해줘", "커밋하고 푸시", "push" 등을 요청하면 push 명령을 실행하기 전에 반드시 이 스킬을 먼저 따른다.
---

# README 동기화 (푸시 전)

푸시 전에 이번에 올라갈 변경 사항이 README.md 내용과 어긋나지 않는지 확인하고, 어긋나면 README.md를 고쳐서 함께 푸시한다.

## 1. 푸시될 변경 범위 파악

```bash
git fetch -q origin
BASE=origin/develop                           # 작업 브랜치의 PR 대상 브랜치
git log --oneline $BASE..HEAD                 # 푸시될 커밋
git diff --stat $BASE...HEAD                  # 푸시될 파일 변경
git diff --name-status $BASE...HEAD           # 추가(A)·삭제(D)·이름변경(R)
git status --short                            # 아직 커밋 안 된 변경 (이번에 함께 커밋할 것)
```

기준은 PR 대상 브랜치다. 작업 브랜치는 `origin/develop`, develop → main 반영이면 `origin/main`을 쓴다.

## 2. 변경 → README 섹션 매핑

| 변경된 파일 | 확인할 README 섹션 |
|---|---|
| `ansible/inventory/hosts.example.yml`, `group_vars/*.yml` | 1. 멀티노드 네트워크 구조 (노드 표, 네트워크 표, 핵심 포인트) |
| `docs/images/*` | 1. 구성도 이미지 경로 |
| 파일·디렉터리 추가/삭제/이름 변경 (어느 위치든) | 2. 폴더 구조 트리와 한 줄 설명 |
| `ansible/playbooks/*`, `ansible/roles/**` | 2. 폴더 구조 + 3. Ansible 명령어 (새 플레이북 실행법, 점검 항목) |
| `ansible/ansible.cfg` | 3. 실행 전 준비 (sudo, host_key_checking, 경로 등) |
| `.gitignore`, `.claude/**` | 2. 폴더 구조 |

매핑되는 섹션만 읽고, 실제 파일 내용과 README 설명이 다른 곳만 고친다.

## 3. 작성 규칙

- **필요한 곳만 고친다.** 영향 없는 섹션의 문장·형식은 건드리지 않는다.
- **README와 같은 톤의 한국어**로 쓴다. 표·트리 정렬 형식을 유지한다.
- **민감 정보 금지.** 저장소는 공개 상태다. `ansible/inventory/hosts.yml`(gitignore 대상)의 Tailscale IP·SSH 계정, 비밀번호·키·vault 값은 README에 절대 옮기지 않는다.
- **추측 금지.** 코드나 구성도에서 확인되지 않는 구성(물리 연결, VIP 관리 방식 등)은 쓰지 않는다. 불확실하면 사용자에게 묻는다.
- Ansible 태스크 이름을 인용할 때는 파일에 있는 영어 이름을 그대로 쓴다.
- README에 적힌 상대 경로 링크·이미지가 실제로 존재하는지 확인한다.

## 4. 커밋과 푸시

1. README에 고칠 것이 없으면 "README 반영 사항 없음"이라고 사용자에게 한 줄로 알리고 그대로 푸시한다.
2. 고쳤다면 README.md만 별도 커밋으로 만든다. 메시지는 저장소 관례(`type : 설명`)를 따른다.
   ```
   docs : sync README with <바뀐 내용 요약>
   ```
3. `git push` 후, 사용자에게 README에서 어떤 섹션을 왜 고쳤는지 짧게 보고한다.
