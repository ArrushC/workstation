# Memory index

- [Always push after commit](feedback_always_push_after_commit.md) — standing instruction: every commit gets pushed without asking, overriding the default guardrail.
- [Commit .claude/ changes routinely](feedback_commit_claude_dir_routinely.md) — .claude/{settings.json, settings.local.json, memory/*} are regular tracked content. Stop treating their modifications as session-drift to defer.
- [Skip redundant final review in subagent-driven-development](feedback_skip_redundant_final_review.md) — after per-task two-stage reviews pass, go straight to finishing-a-development-branch; do not dispatch a final cross-cutting reviewer.
- [Check Windows chezmoi before apply](feedback_windows_chezmoi_check_before_apply.md) — when a sync must reach Windows, verify chezmoi.exe exists first; if present apply via interop, else deploy manually (never substitute the WSL Linux chezmoi — it renders templates as os=linux and re-breaks the ssh fix).
