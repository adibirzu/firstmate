#!/usr/bin/env bash
# Behavior tests for the no-mistakes commit-identity pre-push gate.
#
# The pass case proves that the pull-request range excludes the base commit and
# accepts a branch commit whose author and committer match the configured global
# Git identity.
# The refusal case independently proves that a wrong author and a wrong
# committer are both named with their offending commit and identity.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-commit-identity-check.sh"
TMP=$(fm_test_tmproot fm-commit-identity-check)
REPO="$TMP/repo"
REMOTE="$TMP/origin.git"
GLOBAL_CONFIG="$TMP/global.gitconfig"

cat > "$GLOBAL_CONFIG" <<'EOF'
[user]
	name = Adrian Birzu
	email = adibirzu@gmail.com
EOF

export GIT_CONFIG_GLOBAL="$GLOBAL_CONFIG"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm 'base commit'
git clone -q --bare "$REPO" "$REMOTE"
git -C "$REPO" remote add origin "file://$REMOTE"
git -C "$REPO" fetch -q origin main:refs/remotes/origin/main
git -C "$REPO" checkout -qb feature

printf 'good\n' >> "$REPO/file.txt"
git -C "$REPO" commit -qam 'correct identity'

out=$(cd "$REPO" && "$CHECK" 2>&1) \
  || fail "identity check refused a correctly authored branch commit"$'\n'"$out"
assert_contains "$out" "verified 1 commit(s) as Adrian Birzu <adibirzu@gmail.com>" \
  "pass case did not report the configured identity"
pass "commit identity gate accepts the pull-request range with the configured identity"

GIT_AUTHOR_NAME='Crewmate' GIT_AUTHOR_EMAIL='crewmate@pai-private' \
  GIT_COMMITTER_NAME='Adrian Birzu' GIT_COMMITTER_EMAIL='adibirzu@gmail.com' \
  git -C "$REPO" commit -q --allow-empty -m 'wrong author'
wrong_author_sha=$(git -C "$REPO" rev-parse HEAD)

GIT_AUTHOR_NAME='Adrian Birzu' GIT_AUTHOR_EMAIL='adibirzu@gmail.com' \
  GIT_COMMITTER_NAME='Crewmate' GIT_COMMITTER_EMAIL='crewmate@pai-private' \
  git -C "$REPO" commit -q --allow-empty -m 'wrong committer'
wrong_committer_sha=$(git -C "$REPO" rev-parse HEAD)

rc=0
out=$(cd "$REPO" && "$CHECK" 2>&1) || rc=$?
expect_code 1 "$rc" "identity check with offending commits"
assert_contains "$out" "commit $wrong_author_sha author is Crewmate <crewmate@pai-private>" \
  "refusal did not name the wrong author commit and identity"
assert_contains "$out" "commit $wrong_committer_sha committer is Crewmate <crewmate@pai-private>" \
  "refusal did not name the wrong committer commit and identity"
assert_contains "$out" "2 offending commit(s)" \
  "refusal did not summarize every offending commit"
assert_contains "$out" "refusing push" \
  "refusal did not state that the push is blocked"
pass "commit identity gate refuses wrong author and committer identities with commit diagnostics"

lint_command=$(ruby -e '
  require "yaml"
  value = YAML.safe_load(File.read(ARGV.fetch(0))).dig("commands", "lint")
  abort "missing commands.lint" unless value.is_a?(String)
  print value
' "$ROOT/.no-mistakes.yaml") \
  || fail "could not read the no-mistakes lint command"
assert_equals 'bin/fm-commit-identity-check.sh && bin/fm-lint.sh' "$lint_command" \
  "no-mistakes does not run the identity check before its canonical lint"
pass "no-mistakes runs the commit identity check in its deterministic pre-push path"
