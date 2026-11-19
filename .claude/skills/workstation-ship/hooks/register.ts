import type { Register } from 'claude-code'

// /ship [pr]: squash-merge a PR only once the checks GitHub shows for it really cover it.
// GitHub doesn't re-run a PR's checks when its base moves, so a green PR can predate a
// change on main (a reused bot branch did, .claude/memory/project-version-bumps-pr-stale-
// checks.md). The checks must have passed on the PR's head, and have started after the
// base's last commit unless the head already holds it; `--match-head-commit` then refuses
// the merge if the head moved meanwhile. Only a /ship the person typed merges: a command
// the model or another plugin runs is refused.
// What used to be a refusal to come back to is now done here (2026-11-18: four of seven
// /ship runs in one day were refused, each for one of these):
// - main moved under the PR (shipping one PR does that to every other open one): /ship
//   merges main into the branch once (gh pr update-branch), which restarts CI;
// - checks still running, or not there yet: it waits, looking every POLL_S seconds for
//   up to MAX_POLLS looks, then says what it was waiting for.
// A base that is ahead only by GENERATED files (disk-budget.yml commits disk-budget.toml
// to main minutes after a merge that changes the toolbelt) does not make checks stale.
// It also reads the head's workflow runs: one still going means jobs whose checks don't
// exist yet (a job behind `needs:`), and one GitHub holds for approval (a bot's PR) is
// named, since no check will ever appear for it.
// /ship loads from this checkout's .claude/skills/workstation-ship, so a PR that changes
// that folder changes /ship itself: once the checkout has the merge (gh pr merge switches
// to the base and pulls it when run on the PR's branch), Claude Code reloads /ship and any
// call it makes after that is refused. For such a PR it runs nothing after the merge.

type Pr = {
  number: number
  title: string
  state: string
  isDraft: boolean
  headRefName: string
  headRefOid: string
  baseRefName: string
  mergeStateStatus: string
  files?: { path: string }[]
}
type CheckRun = { name: string; status: string; conclusion: string | null; started_at: string }
type WorkflowRun = { name: string; status: string; conclusion: string | null }
// What one look at the PR found: mergeable now, worth waiting for, or checks that predate the base.
type Look = { kind: 'ready'; line: string } | { kind: 'wait'; why: string } | { kind: 'stale'; why: string }

const PR_FIELDS = 'number,title,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,files'
const PASSED = new Set(['success', 'neutral', 'skipped'])
const MERGEABLE = new Set(['CLEAN', 'HAS_HOOKS'])
const WHY_NOT: Record<string, string> = {
  BEHIND: 'the branch must be brought up to date',
  BLOCKED: 'a required review or check is missing',
  DIRTY: 'it conflicts with its base',
  DRAFT: 'it is a draft',
  UNKNOWN: 'GitHub is still working it out; try again in a moment',
  UNSTABLE: 'a check is failing',
}
// Files a workflow commits to the base by itself; no check reads a PR differently for them.
const GENERATED = new Set(['disk-budget.toml'])
const POLL_S = 15
const MAX_POLLS = 80 // 20 minutes
const short = (sha: string) => sha.slice(0, 7)
const clock = (iso: string) => iso.slice(11, 16)
// Two times side by side: the day too when they aren't the same day ("11:17 after 20:44" was the day after).
const clocks = (a: string, b: string): [string, string] =>
  a.slice(0, 10) === b.slice(0, 10) ? [clock(a), clock(b)] : [`${a.slice(5, 10)} ${clock(a)}`, `${b.slice(5, 10)} ${clock(b)}`]
const waited = (polls: number) => {
  const s = polls * POLL_S
  return s < 60 ? `${s} s` : `${Math.round(s / 60)} min`
}

// A refusal: its message is what the person reads.
class Stop extends Error {}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'ship',
      description: "Squash-merge this branch's PR (or PR n) once its checks passed on its head after main last moved (updating the branch and waiting for CI if need be), then pull main",
      argumentHint: '[pr number]',
    })
    return next(e)
  })

  on('command.run', { command: 'ship' }, async ($, e) => {
    if (e.origin.kind !== 'composer' && e.origin.kind !== 'bridge') {
      return { text: `/ship merges only when you type it at the prompt; this run came from ${e.origin.kind}, so nothing was merged.` }
    }

    const done: string[] = []
    let header = '/ship'
    let isMerged = false
    const must = async (argv: string[], timeoutMs = 60_000) => {
      const ran = await $.process.run(argv, { timeoutMs })
      if (ran.exitCode !== 0) throw new Stop(`${argv.slice(0, 3).join(' ')} failed: ${(ran.stderr || ran.stdout).trim()}`)
      return ran.stdout
    }
    const json = async <T>(argv: string[]) => JSON.parse(await must(argv)) as T
    const api = <T>(path: string) => json<T>(['gh', 'api', `repos/{owner}/{repo}/${path}`])

    try {
      if ((await must(['git', 'status', '--porcelain', '--untracked-files=no'])).trim()) {
        throw new Stop('the working tree has uncommitted changes; commit or stash them first')
      }
      const which = e.args.trim().replace(/^#/, '')
      if (which && !/^\d+$/.test(which)) throw new Stop(`"${e.args.trim()}" is not a PR number`)
      const view = await $.process.run(['gh', 'pr', 'view', ...(which ? [which] : []), '--json', PR_FIELDS], { timeoutMs: 60_000 })
      if (view.exitCode !== 0) {
        const none = /no pull requests found for branch "([^"]+)"/.exec(view.stderr)
        if (none) throw new Stop(`no open PR for ${none[1]}; switch to a PR's branch or use /ship <number>`)
        throw new Stop(`gh pr view failed: ${(view.stderr || view.stdout).trim()}`)
      }
      let pr = JSON.parse(view.stdout) as Pr
      const { number, baseRefName: base } = pr
      header = `/ship #${number} ${pr.title}`
      if (pr.state !== 'OPEN') throw new Stop(`#${number} is ${pr.state.toLowerCase()}`)
      if (pr.isDraft) throw new Stop(`#${number} is a draft`)
      done.push('✓ open, not a draft; working tree clean')

      // The head /ship updated, while GitHub may still show it as the PR's head.
      let updatedFrom = ''
      const look = async (): Promise<Look> => {
        const head = pr.headRefOid
        if (head === updatedFrom) return { kind: 'wait', why: 'GitHub is still updating the branch' }
        const { workflow_runs: workflows } = await api<{ workflow_runs: WorkflowRun[] }>(`actions/runs?head_sha=${head}&per_page=100`)
        const held = workflows.filter(w => w.conclusion === 'action_required').map(w => w.name)
        if (held.length > 0) {
          throw new Stop(`GitHub is holding ${held.join(', ')} for approval ("Approve workflows to run" on the PR's page)`)
        }
        const unfinished = workflows.filter(w => w.status !== 'completed').map(w => w.name)

        const { check_runs: runs } = await api<{ check_runs: CheckRun[] }>(`commits/${head}/check-runs?per_page=100`)
        const latest = new Map<string, CheckRun>()
        for (const run of runs) {
          const seen = latest.get(run.name)
          if (!seen || run.started_at > seen.started_at) latest.set(run.name, run)
        }
        const checks = [...latest.values()]
        if (checks.length === 0) {
          if (updatedFrom || unfinished.length > 0) return { kind: 'wait', why: `no checks yet on ${short(head)}` }
          throw new Stop(`no checks ran on ${short(head)}`)
        }
        const running = checks.filter(c => c.status !== 'completed').map(c => c.name)
        if (running.length > 0) return { kind: 'wait', why: `still running: ${running.join(', ')}` }
        const failed = checks.filter(c => !PASSED.has(c.conclusion ?? '')).map(c => c.name)
        if (failed.length > 0) throw new Stop(`failed: ${failed.join(', ')}`)
        if (unfinished.length > 0) return { kind: 'wait', why: `${unfinished.join(', ')} has jobs still to start` }
        const status = await api<{ state: string; total_count: number }>(`commits/${head}/status`)
        if (status.total_count > 0 && status.state === 'pending') return { kind: 'wait', why: 'a commit status is pending' }
        if (status.total_count > 0 && status.state !== 'success') throw new Stop(`the commit status is ${status.state}`)

        const firstStart = checks.map(c => c.started_at).sort()[0] ?? ''
        const { behind_by: behind } = await api<{ behind_by: number }>(`compare/${base}...${head}`)
        let fresh = `which holds ${base}`
        if (behind > 0) {
          const tip = await api<{ sha: string; commit: { committer: { date: string } } }>(`commits/${base}`)
          const moved = tip.commit.committer.date
          if (firstStart < moved) {
            const ahead = await api<{ files?: { filename: string }[] }>(`compare/${head}...${base}`)
            const files = (ahead.files ?? []).map(f => f.filename)
            const isGenerated = files.length > 0 && files.length < 300 && files.every(f => GENERATED.has(f))
            if (!isGenerated) {
              const [at, started] = clocks(moved, firstStart)
              return { kind: 'stale', why: `${base} moved (${short(tip.sha)} at ${at}) after CI started (${started}), so the checks predate it` }
            }
            fresh = `behind ${base} only by ${files.join(', ')}`
          } else {
            fresh = `started after ${base}'s ${short(tip.sha)}`
          }
        }
        if (pr.mergeStateStatus === 'UNKNOWN') return { kind: 'wait', why: 'GitHub is still working out whether it can merge' }
        // A job a change doesn't reach is skipped (lint.yml's scope job): say so, don't call it passed.
        const skipped = checks.filter(c => c.conclusion === 'skipped').length
        const ran = `${checks.length - skipped} checks passed${skipped > 0 ? ` (${skipped} skipped)` : ''}`
        return { kind: 'ready', line: `✓ ${ran} on ${short(head)}, ${fresh}` }
      }

      let polls = 0
      try {
        for (;;) {
          const found = await look()
          if (found.kind === 'ready') {
            if (polls > 0) done.push(`✓ waited ${waited(polls)} for the checks`)
            done.push(found.line)
            break
          }
          if (found.kind === 'stale') {
            if (updatedFrom) throw new Stop(`${found.why}, again, after /ship had updated the branch; /ship once more`)
            const update = await $.process.run(['gh', 'pr', 'update-branch', String(number)], { timeoutMs: 120_000 })
            if (update.exitCode !== 0) {
              throw new Stop(`${found.why}, and merging ${base} into the branch failed: ${(update.stderr || update.stdout).trim()}`)
            }
            updatedFrom = pr.headRefOid
            done.push(`✓ ${found.why}: merged ${base} into the branch, CI restarted`)
          } else if (polls >= MAX_POLLS) {
            throw new Stop(`${found.why}, after ${waited(polls)}; /ship again when they finish`)
          }
          await $.ui.status(`/ship #${number}: ${found.kind === 'stale' ? 'CI restarted' : found.why} (${waited(polls)})`)
          // sleep(1) where there is one (Linux, Git Bash), else PowerShell's.
          const nap = await $.process.run(['sleep', String(POLL_S)], { timeoutMs: (POLL_S + 15) * 1000 })
          if (nap.exitCode !== 0) {
            await $.process.run(['powershell', '-NoProfile', '-Command', `Start-Sleep ${POLL_S}`], { timeoutMs: (POLL_S + 30) * 1000 })
          }
          polls += 1
          pr = await json<Pr>(['gh', 'pr', 'view', String(number), '--json', PR_FIELDS])
          if (pr.state !== 'OPEN') throw new Stop(`#${number} is ${pr.state.toLowerCase()} now`)
        }
      } finally {
        if (polls > 0 || updatedFrom) await $.ui.status(undefined)
      }
      const head = pr.headRefOid

      if (!MERGEABLE.has(pr.mergeStateStatus)) {
        const why = WHY_NOT[pr.mergeStateStatus]
        throw new Stop(`GitHub won't merge it yet (${pr.mergeStateStatus}${why ? `: ${why}` : ''})`)
      }
      done.push(`✓ GitHub says it can merge (${pr.mergeStateStatus})`)

      const ownFolder = `.claude/skills/${$.plugin.name}/`
      const changesShip = (pr.files ?? []).some(f => f.path.startsWith(ownFolder))
      const branchBefore = (await must(['git', 'rev-parse', '--abbrev-ref', 'HEAD'])).trim()

      const merge = await $.process.run(
        ['gh', 'pr', 'merge', String(number), '--squash', '--delete-branch', '--match-head-commit', head],
        { timeoutMs: 120_000 },
      )
      if (merge.exitCode !== 0) {
        // The merge can land and the branch clean-up fail: ask GitHub which it was.
        const after = await json<{ state: string }>(['gh', 'pr', 'view', String(number), '--json', 'state'])
        if (after.state !== 'MERGED') throw new Stop(`gh pr merge failed: ${(merge.stderr || merge.stdout).trim()}`)
        isMerged = true
        done.push(`✓ squash-merged; ! ${(merge.stderr || merge.stdout).trim()}`)
      } else {
        isMerged = true
        done.push('✓ squash-merged; branch deleted')
      }

      if (changesShip) {
        done.push(
          branchBefore === pr.headRefName
            ? `✓ gh switched to ${base} and pulled it; the PR changes /ship, so Claude Code reloads it`
            : `! the PR changes /ship, so ${base} wasn't pulled (that reloads /ship mid-command): git pull --ff-only --prune`,
        )
        return { text: [header, ...done].join('\n') }
      }

      const branch = (await must(['git', 'rev-parse', '--abbrev-ref', 'HEAD'])).trim()
      if (branch === base) {
        await must(['git', 'pull', '--ff-only', '--prune'], 120_000)
        done.push(`✓ ${base} pulled: ${(await must(['git', 'rev-parse', '--short', 'HEAD'])).trim()}`)
      } else {
        await must(['git', 'fetch', '--prune'], 120_000)
        done.push(`✓ fetched; you're on ${branch}, so ${base} wasn't pulled`)
      }
      return { text: [header, ...done].join('\n') }
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err)
      const verdict = isMerged ? `! merged, but ${reason}` : `✗ not merged: ${reason}`
      return { text: [header, ...done, verdict].join('\n') }
    }
  })
}
