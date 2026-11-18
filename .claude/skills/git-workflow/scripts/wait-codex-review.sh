#!/usr/bin/env bash
# Codex 자동 리뷰가 올라올 때까지 기다렸다가 결과를 출력한다.
#
# 사용법: wait-codex-review.sh <PR번호> <since-ISO8601> [timeout초=900] [간격초=30]
#   since 이후에 Codex 봇이 남긴 리뷰/코멘트만 대상으로 한다.
#   (PR 생성 시각 또는 사용자 추가 작업 push 시각을 넘긴다)
#
# 종료 코드: 0 = 리뷰 찾음(내용 출력), 2 = 타임아웃, 1 = 사용법/gh 오류
set -euo pipefail

PR="${1:?PR 번호가 필요합니다}"
SINCE="${2:?since(ISO8601, UTC) 시각이 필요합니다}"
TIMEOUT="${3:-900}"
INTERVAL="${4:-30}"
# Codex GitHub 앱 봇 로그인. 다르면 CODEX_BOT_PATTERN 환경변수로 덮어쓴다.
BOT="${CODEX_BOT_PATTERN:-codex}"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
deadline=$(( $(date +%s) + TIMEOUT ))

bot_filter='select(.user.login | test($bot; "i")) | select(.user.type == "Bot")'

while :; do
  # 1) PR 리뷰 (요약 + 인라인 코멘트 묶음)
  reviews="$(gh api --paginate "repos/$REPO/pulls/$PR/reviews" \
    | jq -s --arg bot "$BOT" --arg since "$SINCE" \
      "[.[][] | $bot_filter | select(.submitted_at > \$since)]")"
  # 2) 이슈 코멘트 (문제 없음 같은 일반 코멘트)
  issue_comments="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
    | jq -s --arg bot "$BOT" --arg since "$SINCE" \
      "[.[][] | $bot_filter | select(.created_at > \$since)]")"

  if [ "$(jq 'length' <<<"$reviews")" -gt 0 ] || [ "$(jq 'length' <<<"$issue_comments")" -gt 0 ]; then
    # 인라인 코멘트가 다 붙을 시간을 조금 준다
    sleep 10
    review_ids="$(jq -c '[.[].id]' <<<"$reviews")"
    echo "=== Codex reviews (since $SINCE) ==="
    jq -r '.[] | "--- review \(.id) [\(.state)] commit \(.commit_id[0:7]) at \(.submitted_at)\n\(.body)\n"' <<<"$reviews"
    echo "=== Codex inline comments ==="
    gh api --paginate "repos/$REPO/pulls/$PR/comments" \
      | jq -s -r --argjson ids "$review_ids" \
        '.[][] | select(.pull_request_review_id as $r | $ids | index($r))
         | "--- \(.path):\(.line // .original_line) (comment \(.id))\n\(.body)\n"'
    echo "=== Codex issue comments ==="
    jq -r '.[] | "--- comment \(.id) at \(.created_at)\n\(.body)\n"' <<<"$issue_comments"
    exit 0
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "TIMEOUT: ${TIMEOUT}s 동안 Codex 리뷰가 올라오지 않았습니다 (PR #$PR, since $SINCE)."
    exit 2
  fi
  sleep "$INTERVAL"
done
