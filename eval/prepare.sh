#!/bin/bash
# 各課題の base コミットで worktree を作り、gem・nilflow DB・テスト DB を用意する
#   MASTODON_DIR=/path/to/mastodon [PG_BIN=/path/to/postgres/bin] eval/prepare.sh
# MASTODON_DIR には rbs_collection.yaml / .lock.yaml / .gem_rbs_collection と .env.test を用意しておくこと
set -u
: "${MASTODON_DIR:?set MASTODON_DIR to a mastodon checkout}"
[ -n "${PG_BIN:-}" ] && export PATH="$PG_BIN:$PATH"
EVAL=$(cd "$(dirname "$0")" && pwd); NF=$(dirname "$EVAL"); MAST=$MASTODON_DIR
mkdir -p "$EVAL/wt" "$EVAL/db"
for yaml in "$EVAL"/tasks/*.yaml; do
  id=$(grep '^id:' "$yaml" | awk '{print $2}'); base=$(grep '^base_commit:' "$yaml" | awk '{print $2}')
  wt="$EVAL/wt/$id"
  echo "=== $id ($base)"
  if [ ! -d "$wt" ]; then (cd "$MAST" && git worktree add --detach "$wt" "$base" >/dev/null 2>&1) || { echo "worktree failed"; continue; }; fi
  cp "$MAST/.env.test" "$wt/.env.test" 2>/dev/null
  # rbs collection は mastodon 側で未追跡なのでコピーする
  cp "$MAST/rbs_collection.yaml" "$MAST/rbs_collection.lock.yaml" "$wt/"
  ln -sfn "$MAST/.gem_rbs_collection" "$wt/.gem_rbs_collection"
  # 古い Gemfile.lock は platform を含まないことがある。正規化して入れ、エージェントの git status には出さない
  (cd "$wt" && (bundle check >/dev/null 2>&1 || { bundle lock --normalize-platforms >/dev/null 2>&1; bundle install --quiet 2>&1 | tail -2; }) && git update-index --skip-worktree Gemfile.lock)
  # エージェントから見えないよう、追加したファイルは .git/info/exclude に入れる
  (cd "$wt" && { echo .gem_rbs_collection; echo rbs_collection.yaml; echo rbs_collection.lock.yaml; } >> "$(git rev-parse --git-path info/exclude)")
  if [ ! -f "$EVAL/db/$id.db" ]; then
    (cd "$NF" && bundle exec exe/nilflow build "$wt/app" "$wt/lib" --collection "$wt/rbs_collection.yaml" -o "$EVAL/db/$id.db" 2>&1 | grep -E "analyze|wrote")
  fi
  (cd "$wt" && DB_NAME="mastodon_$id" RAILS_ENV=test bin/rails db:prepare 2>&1 | tail -1)
  echo "spec run check: $(cd "$wt" && DB_NAME="mastodon_$id" RAILS_ENV=test bundle exec rspec spec/models/account_alias_spec.rb 2>&1 | grep -E 'examples,')"
done
echo DONE
