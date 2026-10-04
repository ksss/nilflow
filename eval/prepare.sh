#!/bin/bash
# Create a worktree at each task's base commit, and set up gems, the nilflow DB and the test DB
#   MASTODON_DIR=/path/to/mastodon [PG_BIN=/path/to/postgres/bin] eval/prepare.sh
# MASTODON_DIR must contain rbs_collection.yaml / .lock.yaml / .gem_rbs_collection and .env.test
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
  # rbs collection files are untracked in mastodon, so copy them
  cp "$MAST/rbs_collection.yaml" "$MAST/rbs_collection.lock.yaml" "$wt/"
  ln -sfn "$MAST/.gem_rbs_collection" "$wt/.gem_rbs_collection"
  # Old Gemfile.lock files may lack platforms. Normalize them, and hide the change from the agent's git status
  (cd "$wt" && (bundle check >/dev/null 2>&1 || { bundle lock --normalize-platforms >/dev/null 2>&1; bundle install --quiet 2>&1 | tail -2; }) && git update-index --skip-worktree Gemfile.lock)
  # Hide the added files from the agent via .git/info/exclude
  (cd "$wt" && { echo .gem_rbs_collection; echo rbs_collection.yaml; echo rbs_collection.lock.yaml; } >> "$(git rev-parse --git-path info/exclude)")
  if [ ! -f "$EVAL/db/$id.db" ]; then
    (cd "$NF" && bundle exec exe/nilflow build "$wt/app" "$wt/lib" --collection "$wt/rbs_collection.yaml" -o "$EVAL/db/$id.db" 2>&1 | grep -E "analyze|wrote")
  fi
  (cd "$wt" && DB_NAME="mastodon_$id" RAILS_ENV=test bin/rails db:prepare 2>&1 | tail -1)
  echo "spec run check: $(cd "$wt" && DB_NAME="mastodon_$id" RAILS_ENV=test bundle exec rspec spec/models/account_alias_spec.rb 2>&1 | grep -E 'examples,')"
done
echo DONE
