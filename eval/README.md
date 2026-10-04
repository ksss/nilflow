# Evaluation: do type-resolved call relations and value provenance reduce an AI agent's rework?

## Hypothesis

When investigating bugs in a Rails application, an agent that receives call targets resolved by receiver type
and the provenance of values will, compared with an agent that only has grep and Read,
reach the faulty code sooner, make fewer wrong edits, and produce correct fixes more often.

## Tasks

Five past bug-fix commits from mastodon (`tasks/*.yaml`).

| task | fix commit | description |
|---|---|---|
| t1_idempotency_500 | 4e15f3db | Posting twice with the same Idempotency-Key returns HTTP 500 |
| t2_create_author_change | 9d51f51c | A `Create` for a known status by a different author raises RecordInvalid |
| t3_reach_filter_threshold | 5d7465a9 | A condition that is never true makes the saturation threshold wrong |
| t4_reported_statuses_purge | cd4e10bb | Reported statuses get no `deleted_at` when the account is deleted |
| t5_quote_edit_text | 18865140 | The text of a quote post cannot be edited |

Selection criteria: the commit changes `app/` or `lib/`, also changes `spec/`, adds fewer than 80 lines, and was made after June 2025.
The agent works on the parent of the fix commit and only receives a description of the symptom, with file and method names withheld.
The ground truth is the set of methods changed by the fix commit. Fix correctness is judged by the spec included in the fix commit.
To ignore examples that fail for environmental reasons, the baseline is the set of failures observed when the real fix is applied (`oracle.sh`).

## Conditions

| condition | what the agent gets | mechanism |
|---|---|---|
| A | grep / Read / Edit / Bash only | |
| B | A, plus documentation of the nilflow CLI | appended to the system prompt |
| C | A, plus a nilflow summary automatically attached for each file the agent touches | PostToolUse hook (`hooks/inject.sh`) |
| D | B, plus edits are refused for files on which nilflow has not been run | PreToolUse hook (`hooks/require_nilflow.sh`) |
| E | A, plus hand-written "ideal" analysis results attached once | PostToolUse hook (`hooks/inject_oracle.sh`, `oracle_notes/`) |

The notes for E only state facts such as types, provenance, and evaluation order; they never say how to fix the bug.
Condition E measures the upper bound of information value: would it help if nilflow could produce ideal information?

Model: claude-sonnet-5-5, with at most 60 tool calls.
Running tests or rails commands is forbidden, and the prompt asks for a minimal fix.

## Results

`results/pilot-2026-10.txt` lists every run. Each task and condition was run only once or twice, so treat these numbers as trends only.

| condition | runs | root cause identified | spec passed | avg. tool calls | avg. nilflow calls |
|---|---|---|---|---|---|
| A | 10 | 9/10 | 8/10 | 4.5 | 0 |
| B | 5 | 4/5 | 4/5 | 4.0 | 0 |
| C | 5 | 5/5 | 4/5 | 4.2 | 0 (2.2 injections on average) |
| D | 5 | 5/5 | 3/5 | 6.2 | 1.4 |
| E | 10 | 9/10 | 8/10 | 3.9 | 0 (0.9 injections on average) |

Almost all spec failures are on t1, which failed under every condition.

## Findings

1. **Localization showed no difference.** Under every condition, the agent reached the faulty file on the first or second step. Class names and distinctive wording remained in the symptom descriptions, so grep was enough.
2. **Documentation alone does not get a tool used.** Under B, nilflow was never called. Getting an agent to use an unfamiliar tool requires a hook that injects its output or enforces its use.
3. **With nilflow's current information, the fixes did not change.** Under C and D the information reached the agent, but for the key expressions nilflow answered `untyped [unknown]`. In t3, `bloom_filters.size` goes through an ActiveRecord attribute; in t1, `@status` is an instance variable.
4. **Ideal information changed what the agent recognized.** t1 has two defects. The reported symptom is that when a duplicate is detected, the return value is discarded and post-processing runs with `@status` still nil. The second is that the duplicate check runs before `preprocess_attributes!`, so `@scheduled_at` is not set yet; the regression spec requires fixing this too. In both E runs, the agent correctly described the second defect, then decided not to fix it because it was "separate from the reported problem" and the fix should stay minimal. No run under A mentioned this defect.

## Problems with this design

- The symptom descriptions and the ground-truth specs disagree on scope. As a result, "understood but did not fix" scores the same as "did not understand". Recognizing the root cause needs to be measured separately from the fix.
- The symptom descriptions reveal the location, so localization cannot show a difference.
- There are too few runs.

## Pitfalls in the harness

- rbenv's `exec` leaves `RBENV_VERSION` and `versions/<v>/bin` in the environment of child processes. To make each worktree's `.ruby-version` take effect, the harness cleans `PATH` and puts the shims first.
- When the wrapper changes directory, relative paths passed by the agent are resolved against the wrong base. nilflow resolves them against `NILFLOW_ROOT`.
- The `additionalContext` returned by a hook does not appear in the stream-json output. Injections are counted from the hook's own log.
- Agents often edit with `sed -i` or Python through Bash rather than the Edit tool. Edit counting must account for this.
- `claude -p` inherits the user's `~/.claude/CLAUDE.md` and output style. The harness disables them with `--setting-sources project`.

## Reproducing

You need a mastodon checkout, PostgreSQL, Redis, libvips, and the Ruby version each base commit requires.

```sh
# Prepare rbs collection in mastodon first (rbs_collection.yaml / .lock.yaml / .gem_rbs_collection)
MASTODON_DIR=/path/to/mastodon PG_BIN=/path/to/postgresql/bin eval/prepare.sh
eval/oracle.sh t1_idempotency_500 t2_create_author_change t3_reach_filter_threshold t4_reported_statuses_purge t5_quote_edit_text
PG_BIN=/path/to/postgresql/bin ruby eval/run.rb t1_idempotency_500 A 1
ruby eval/report.rb
python3 eval/show_run.py eval/runs/t1_idempotency_500_E_1.jsonl
```

`prepare.sh` creates a git worktree for each task under `eval/wt/<task>`, builds `eval/db/<task>.db`, and sets up a test database.
`run.rb` runs the `claude` CLI headless, which incurs API costs.
