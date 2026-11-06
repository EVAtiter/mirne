#!/bin/bash
# 公開してはいけない情報がリポジトリに入っていないかを調べる。
#
#   scripts/check-leaks.sh            作業ツリー（追跡中＋未追跡で .gitignore 対象外のファイル）
#   scripts/check-leaks.sh --staged   コミットしようとしている内容（pre-commit フックが使う）
#   scripts/check-leaks.sh --history  全履歴の差分と、全コミットの作者・コミッターのメール
#
# 探すもの:
#   - 一般的なもの（下の GENERIC_PATTERNS）: ホームの絶対パス・私設 IP アドレス・秘密鍵など
#   - 個人のもの: .leakcheck.local に 1 行 1 つの正規表現で書く（氏名・メール・Team ID など）。
#     このファイル自体が個人情報なので .gitignore 対象。雛形は .leakcheck.example
#   - gitleaks が入っていれば、それも実行する
#
# 見つかったら終了コード 1。
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:---worktree}"

# 一般的なパターン（拡張正規表現）。例示用の書き方（/Users/<名前>）には当たらないようにしてある
GENERIC_PATTERNS=(
    '/Users/[A-Za-z0-9._-]+'                                   # macOS のホームの絶対パス
    '/home/[A-Za-z0-9._-]+'                                    # Linux のホームの絶対パス
    '(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}'              # 私設 IP アドレス
    '(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)'
    '(^|[^0-9.])172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'                       # 秘密鍵
    '(^|[^a-z])[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}([^a-z]|$)'  # App 用パスワードの形
)

# 公開しないはずのファイル（.gitignore をすり抜けて追加されたもの）
FORBIDDEN_FILES='(^|/)(Local\.xcconfig|\.leakcheck\.local|CLAUDE\.md)$|(^|/)\.claude/|(^|/)docs/private/|(^|/)fixtures/private/|\.(ts|m2ts|tlv)$'

PATTERN_FILE=.leakcheck.local
PATTERNS=("${GENERIC_PATTERNS[@]}")
if [ -f "$PATTERN_FILE" ]; then
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        PATTERNS+=("$line")
    done < "$PATTERN_FILE"
else
    echo "⚠️ $PATTERN_FILE が無いので、個人の情報（氏名・メールなど）は調べていない（雛形は .leakcheck.example）" >&2
fi

# 検査対象の文字列を「ファイル名<TAB>内容」の行で標準出力へ流す
emit_worktree() {
    git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' file; do
        [ -f "$file" ] || continue
        # 自分自身と雛形はパターンの説明を含むので除く
        case "$file" in scripts/check-leaks.sh|.leakcheck.example) continue ;; esac
        grep -I -n '' "$file" 2>/dev/null | sed "s|^|$file:|" || true
    done
}

emit_staged() {
    git diff --cached --name-only -z --diff-filter=ACMR | while IFS= read -r -d '' file; do
        case "$file" in scripts/check-leaks.sh|.leakcheck.example) continue ;; esac
        git show ":$file" 2>/dev/null | grep -I -n '' | sed "s|^|$file:|" || true
    done
}

emit_history() {
    # 追加された行だけを見る（削除した行は、その時点のコミットの追加行として既に見ている）
    git log --all -p --no-color --format='commit %H' \
        | grep -E '^(commit |\+[^+])' || true
}

list_files() {
    case "$MODE" in
        --staged) git diff --cached --name-only --diff-filter=ACMR ;;
        --history) git log --all --name-only --format= | sort -u ;;
        *) git ls-files --cached --others --exclude-standard ;;
    esac
}

case "$MODE" in
    --worktree) CONTENT=$(emit_worktree) ;;
    --staged)   CONTENT=$(emit_staged) ;;
    --history)  CONTENT=$(emit_history) ;;
    *) echo "使い方: $0 [--staged|--history]" >&2; exit 64 ;;
esac

found=0

# 1. 公開しないはずのファイル
bad_files=$(list_files | grep -E "$FORBIDDEN_FILES" || true)
if [ -n "$bad_files" ]; then
    echo "✗ 公開しないはずのファイルが含まれている:" >&2
    echo "$bad_files" | sed 's/^/    /' >&2
    found=1
fi

# 2. 内容のパターン
for pattern in "${PATTERNS[@]}"; do
    hits=$(printf '%s\n' "$CONTENT" | grep -E -i -- "$pattern" || true)
    if [ -n "$hits" ]; then
        # 個人のパターンは、パターン自体を表示しない（端末のログに残さない）
        echo "✗ 公開してはいけない文字列が見つかった（$(printf '%s\n' "$hits" | wc -l | tr -d ' ') 行）:" >&2
        printf '%s\n' "$hits" | cut -d: -f1-2 | sort -u | sed 's/^/    /' | head -20 >&2
        found=1
    fi
done

# 3. 履歴の作者・コミッターのメール（noreply 以外が混ざっていないか）
if [ "$MODE" = "--history" ]; then
    emails=$(git log --all --format='%ae%n%ce' | sort -u | grep -v '@users\.noreply\.github\.com$' | grep -v '^noreply@anthropic\.com$' || true)
    if [ -n "$emails" ]; then
        echo "✗ noreply 以外のメールアドレスで作られたコミットがある（$(echo "$emails" | wc -l | tr -d ' ') 種類）" >&2
        found=1
    fi
    # Co-Authored-By などの本文中のメールも調べる
    trailer_emails=$(git log --all --format='%b' | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | sort -u \
        | grep -v '@users\.noreply\.github\.com$' | grep -v '^noreply@anthropic\.com$' || true)
    if [ -n "$trailer_emails" ]; then
        echo "✗ コミットメッセージに noreply 以外のメールアドレスがある" >&2
        found=1
    fi
fi

# 4. gitleaks（入っていれば）
if command -v gitleaks >/dev/null 2>&1; then
    case "$MODE" in
        --staged)  gitleaks git --staged --no-banner --redact >/dev/null 2>&1 || { echo "✗ gitleaks が秘密情報を検出した（gitleaks git --staged で確認）" >&2; found=1; } ;;
        --history) gitleaks git --no-banner --redact >/dev/null 2>&1 || { echo "✗ gitleaks が秘密情報を検出した（gitleaks git で確認）" >&2; found=1; } ;;
        *)         gitleaks dir . --no-banner --redact >/dev/null 2>&1 || { echo "✗ gitleaks が秘密情報を検出した（gitleaks dir . で確認）" >&2; found=1; } ;;
    esac
fi

if [ "$found" -ne 0 ]; then
    exit 1
fi
echo "✓ 漏れは見つからなかった（$MODE）"
