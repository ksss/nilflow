#!/bin/bash
# Check that a task's spec works as an oracle: it should fail on the base commit and pass with the real fix
set -u
[ -n "${PG_BIN:-}" ] && export PATH="$PG_BIN:$PATH"
mkdir -p "$(cd "$(dirname "$0")" && pwd)/runs"
EVAL=$(cd "$(dirname "$0")" && pwd)
for id in "$@"; do
  y="$EVAL/tasks/$id.yaml"; wt="$EVAL/wt/$id"
  fix=$(grep '^fix_commit:' "$y" | awk '{print $2}'); spec=$(grep '^spec:' "$y" | awk '{print $2}')
  cd "$wt" && git checkout -q -- . && git clean -fdq -e .gem_rbs_collection -e 'rbs_collection*.yaml' -e .env.test
  git show "$fix:$spec" > "$spec"
  echo "=== $id  base+spec:   $(DB_NAME=mastodon_$id RAILS_ENV=test bundle exec rspec "$spec" 2>&1 | grep -E 'examples,')"
  git show "$fix" --format= --name-only -- app lib | while read f; do git show "$fix:$f" > "$f"; done
  echo "    truefix+spec: $(DB_NAME=mastodon_$id RAILS_ENV=test bundle exec rspec "$spec" 2>&1 | tee "$EVAL/runs/$id.oracle.log" | grep -E 'examples,')"
  grep -E "^rspec " "$EVAL/runs/$id.oracle.log" | head -3
  git checkout -q -- . && git clean -fdq -e .gem_rbs_collection -e 'rbs_collection*.yaml' -e .env.test
done
