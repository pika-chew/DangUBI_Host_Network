---
name: git-workflow
description: 이 저장소에서 파일을 바꾸는 작업(기능 추가, 수정, 리팩터링, 문서, 스킬 등)을 시작할 때 반드시 따른다. develop에서 작업 브랜치를 따고, 작은 단위로 자동 커밋하고, 작업이 끝나면 PR 여부를 묻고, PR 생성/사용자 추가 push 후 Codex 자동 리뷰를 기다려 검토 의견을 사용자에게 올린다. "PR 만들어줘", "Codex 리뷰 확인", "작업 브랜치" 같은 요청에도 사용한다.
---

# Git 작업 흐름 (develop → 작업 브랜치 → PR → Codex 리뷰)

## 1. 작업 시작: 브랜치

사용자가 브랜치를 지정하지 않았으면 최신 `develop`에서 새 브랜치를 딴다.

```bash
git fetch -q origin
git status --short                      # 커밋 안 된 변경이 있으면 먼저 사용자에게 묻는다
git switch -c <type>/<짧은-설명> origin/develop
git branch --unset-upstream             # origin/develop 으로 push 되지 않게 추적 해제
```

- 브랜치 이름: `feat/…`, `fix/…`, `refactor/…`, `docs/…`, `chore/…` + 영어 kebab-case (예: `feat/keepalived-role`).
- 이미 작업 브랜치(develop/main 아님) 위에서 같은 작업을 이어가는 중이면 새로 따지 않는다.
- `main`, `develop`에 직접 커밋하지 않는다.

## 2. 작업 중: 작은 단위 자동 커밋

사용자에게 묻지 않고, 의미 있는 작은 단위가 끝날 때마다 커밋한다.

- 단위 예: 역할 하나 추가, 변수 정리, 버그 하나 수정, 문서 한 섹션. 서로 무관한 변경을 한 커밋에 섞지 않는다.
- 메시지는 저장소 관례 `type : 설명` (영어, 소문자 시작). 예: `feat : add keepalived role`, `fix : correct vip netmask`.
- `git add <파일>`로 해당 단위 파일만 올린다(`git add -A` 금지). `ansible/inventory/hosts.yml`, 비밀값, vault 파일은 절대 커밋하지 않는다.
- 커밋 메시지 끝에 시스템이 지정한 Co-Authored-By 줄을 붙인다.
- 커밋만 하고 push는 하지 않는다 (push는 PR 단계에서).

## 3. 작업 완료: PR 여부 확인

작업이 끝나면 커밋 목록을 짧게 보여주고 **"PR 만들까요?"** 라고 묻는다. 사용자가 원할 때만 진행한다.

PR을 만들 때:

1. push 전에 `readme-sync` 스킬을 따른다 (비교 기준은 `origin/develop`).
2. push 후 develop 대상으로 PR 생성:
   ```bash
   git push -u origin HEAD
   gh pr create --base develop --title "<type> : <요약>" --body "<변경 요약 / 확인 방법>"
   ```
   PR 본문 끝에 시스템이 지정한 Generated with 줄을 붙인다.
3. 바로 4단계(Codex 리뷰 처리)로 넘어간다.

## 4. Codex 리뷰 처리 (트리거당 한 번만)

Codex는 push마다 리뷰를 반복할 수 있다. 무한 반복을 막기 위해 **아래 트리거에서만, 그 트리거 이후 처음 올라온 Codex 리뷰 한 건만** 처리한다.

| 트리거 | 처리 여부 |
|---|---|
| PR 최초 생성 | O |
| 사용자가 요청한 추가 작업을 이 PR에 push | O |
| Codex 리뷰 의견을 반영하려고 push | **X** (이후 올라오는 Codex 재리뷰는 무시) |
| 같은 트리거에 대해 두 번째 이후 Codex 리뷰 | **X** |

무시하는 경우에도 사용자가 직접 "Codex 리뷰 다시 봐줘"라고 하면 그때는 처리한다.

### 4-1. 리뷰 대기

트리거 직후 UTC 시각을 기록하고, 대기 스크립트를 **백그라운드**로 실행한다 (끝나면 알림이 온다).

```bash
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)     # PR 생성/push 직전에 기록
.claude/skills/git-workflow/scripts/wait-codex-review.sh <PR번호> "$SINCE" 900
```

- 종료 코드 0: 리뷰 요약, 인라인 코멘트(파일:줄), 일반 코멘트가 출력된다.
- 종료 코드 2(15분 타임아웃): 사용자에게 Codex 리뷰가 아직 없다고 알리고, 더 기다릴지 묻는다.
- 봇 계정 이름이 달라 못 찾으면 `CODEX_BOT_PATTERN` 환경변수로 바꿔 다시 실행한다.

### 4-2. 판단 후 사용자에게 검토 요청

각 지적 사항을 실제 코드와 대조해 판단하고, **코드를 고치기 전에** 사용자에게 아래 형식으로 올린다.

```
Codex 리뷰 (PR #N) — 지적 K건

1. [반영 권장] path/to/file.yml:42 — <Codex 지적 요약>
   판단: <왜 맞는지, 어떻게 고칠지>
2. [반영 불필요] path:line — <요약>
   판단: <왜 틀렸거나 이 저장소에서 해당 없는지>
3. [선택] path:line — <요약>
   판단: <트레이드오프>

어떤 항목을 반영할까요?
```

- 판단 기준: 실제 버그·보안 문제·Ansible 멱등성/실행 실패 → 반영 권장. 스타일 취향, 이 환경(Tailscale, 멀티노드 구성)에 맞지 않는 일반론 → 반영 불필요 또는 선택.
- 지적이 없으면 "Codex 리뷰: 지적 사항 없음"이라고 한 줄로 알린다.

### 4-3. 반영

사용자가 고른 항목만 고치고, 항목별로 작게 커밋해 push한다 (`fix : address review - <요약>`). 이 push는 트리거가 아니므로 이후 Codex 재리뷰는 기다리거나 처리하지 않는다.
