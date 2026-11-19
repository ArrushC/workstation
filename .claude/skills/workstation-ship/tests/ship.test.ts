import { describe, expect, test } from 'claude-code/testing'
import type { On, ProcessRunResult, PromptOrigin } from 'claude-code'

const HEAD = '281480c12cc4254fc38e90717497d8a7d707ab40'
const MAIN = '5dc752cbb4fa6ad1c2e8f7a9b0c3d4e5f6a7b8c9'
// The PR's head once /ship has merged main into its branch
const HEAD2 = '9a4be7705d1f4c2b8e6a3f0d1c2b3a4958677685'

type Check = { name: string; status: string; conclusion: string | null; started_at: string }
type World = {
  dirty?: string
  pr?: Record<string, unknown>
  checks?: Check[]
  statuses?: { state: string; total_count: number }
  behindBy?: number
  mainDate?: string
  mergeExit?: number
  // The checkout's branch before the merge (the PR's own, unless set) and after it
  branchBefore?: string
  branchAfter?: string
  files?: string[]
  noPr?: boolean
  // What each look at the head's check runs finds, in turn; the last one repeats
  checksSeq?: Check[][]
  // The head's workflow runs, likewise
  workflowsSeq?: { name: string; status: string; conclusion: string | null }[][]
  // What main has that the PR's head lacks
  baseFiles?: string[]
  // gh pr update-branch: its exit code, how many looks GitHub still shows the old head for,
  // and the checks on the new head (green, started after main moved, unless set)
  updateExit?: number
  updateLag?: number
  checksAfterUpdate?: Check[][]
  // What GitHub calls the merge state, look by look; the last one repeats
  mergeStates?: string[]
}

const pass = (name: string, started_at = '2026-10-16T13:16:42Z'): Check => ({
  name,
  status: 'completed',
  conclusion: 'success',
  started_at,
})

// A repo whose PR #92 is open, its four checks green on its head, started after main's
// last commit (13:10), GitHub calling it mergeable, and the checkout on the PR's branch
// until gh pr merge switches it to main; each case changes one thing.
function world(on: On, w: World = {}) {
  const calls: string[] = []
  let isMerged = false
  let isUpdated = false
  let lag = w.updateLag ?? 0
  let head = HEAD
  const seen: Record<string, number> = {}
  // The nth answer of a series, its last one from then on
  const turn = <T>(key: string, series: T[]): T => {
    const n = seen[key] ?? 0
    seen[key] = n + 1
    return series[Math.min(n, series.length - 1)] as T
  }
  // A hook on a call of $ answers { value }: what the call resolves to.
  const ok = (stdout: unknown, exitCode = 0, stderr = ''): { value: ProcessRunResult } => ({
    value: {
      exitCode,
      stdout: typeof stdout === 'string' ? stdout : JSON.stringify(stdout),
      stderr,
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  })
  // The line under the prompt while /ship waits
  on('ui.status', () => ({ value: undefined }))
  on('process.run', ($, e) => {
    const line = e.argv.join(' ')
    calls.push(line)
    const pr = {
      number: 92,
      title: 'Claude Code: the status line in Catppuccin Mocha',
      state: 'OPEN',
      isDraft: false,
      headRefName: 'ccstatusline-catppuccin',
      headRefOid: head,
      baseRefName: 'main',
      mergeStateStatus: 'CLEAN',
      url: 'https://github.com/o/r/pull/92',
      files: (w.files ?? ['README.md']).map(path => ({ path })),
      ...w.pr,
    }
    if (line === 'git status --porcelain --untracked-files=no') return ok(w.dirty ?? '')
    if (line.startsWith('gh pr view')) {
      if (w.noPr) return ok('', 1, 'no pull requests found for branch "main"')
      if (isUpdated && head === HEAD && lag-- <= 0) head = HEAD2
      const state = w.mergeStates ? { mergeStateStatus: turn('merge', w.mergeStates) } : {}
      return ok({ ...pr, headRefOid: head, ...state })
    }
    if (line === `gh api repos/{owner}/{repo}/actions/runs?head_sha=${head}&per_page=100`) {
      return ok({ workflow_runs: turn(`workflows ${head}`, w.workflowsSeq ?? [[{ name: 'lint', status: 'completed', conclusion: 'success' }]]) })
    }
    if (line === `gh api repos/{owner}/{repo}/commits/${head}/check-runs?per_page=100`) {
      const green = ['invariants', 'templates', 'powershell', 'windows-http']
      const series =
        head === HEAD
          ? (w.checksSeq ?? [w.checks ?? green.map(n => pass(n))])
          : (w.checksAfterUpdate ?? [green.map(n => pass(n, '2026-10-16T13:40:00Z'))])
      const runs = turn(`checks ${head}`, series)
      return ok({ total_count: runs.length, check_runs: runs })
    }
    if (line === `gh api repos/{owner}/{repo}/commits/${head}/status`) return ok(w.statuses ?? { state: 'pending', total_count: 0 })
    if (line === `gh api repos/{owner}/{repo}/compare/main...${head}`) return ok({ behind_by: head === HEAD ? (w.behindBy ?? 0) : 0 })
    if (line === `gh api repos/{owner}/{repo}/compare/${head}...main`) {
      return ok({ files: (w.baseFiles ?? ['README.md']).map(filename => ({ filename })) })
    }
    if (line === 'gh api repos/{owner}/{repo}/commits/main')
      return ok({ sha: MAIN, commit: { committer: { date: w.mainDate ?? '2026-10-16T13:10:00Z' } } })
    if (line === 'gh pr update-branch 92') {
      isUpdated = !w.updateExit
      return ok('', w.updateExit ?? 0, w.updateExit ? 'merge conflict between base and head' : '')
    }
    if (line === 'sleep 15') return ok('')
    if (line.startsWith('gh pr merge')) {
      isMerged = !w.mergeExit
      return ok('', w.mergeExit ?? 0, w.mergeExit ? 'GraphQL: Head branch was modified' : '')
    }
    if (line === 'git rev-parse --abbrev-ref HEAD') {
      return ok(`${isMerged ? (w.branchAfter ?? 'main') : (w.branchBefore ?? 'ccstatusline-catppuccin')}\n`)
    }
    if (line === 'git pull --ff-only --prune') return ok('')
    if (line === 'git fetch --prune') return ok('')
    if (line === 'git rev-parse --short HEAD') return ok('cafe863\n')
    return ok('', 1, `unexpected: ${line}`)
  })
  return calls
}

const ship = ($: { command: { run: (e: never) => Promise<{ text?: string }> } }, args = '', origin: PromptOrigin = { kind: 'composer' }) =>
  $.command.run({ command: 'ship', args, origin, presentation: { isFullscreen: false, columns: 120 } } as never)

const merged = (calls: string[]) => calls.filter(c => c.startsWith('gh pr merge'))
const naps = (calls: string[]) => calls.filter(c => c === 'sleep 15').length
const running = (name: string): Check => ({ ...pass(name), status: 'in_progress', conclusion: null })

describe('/ship', () => {
  test('merges a PR whose checks passed on its head after main last moved, then pulls main', async ($, on) => {
    const calls = world(on)
    const { text } = await ship($)
    expect(merged(calls)).toEqual([`gh pr merge 92 --squash --delete-branch --match-head-commit ${HEAD}`])
    expect(calls).toContain('git pull --ff-only --prune')
    expect(text).toContain('#92 Claude Code: the status line in Catppuccin Mocha')
    expect(text).toContain('✓ 4 checks passed on 281480c')
    expect(text).toContain('✓ squash-merged; branch deleted')
    expect(text).toContain('✓ main pulled: cafe863')
  })

  test('/ship 91 ships that PR', async ($, on) => {
    const calls = world(on, { pr: { number: 91 } })
    await ship($, '91')
    expect(calls.find(c => c.startsWith('gh pr view'))).toMatch(/^gh pr view 91 /)
    expect(merged(calls)[0]).toMatch(/^gh pr merge 91 /)
  })

  test('only a /ship the person typed merges', async ($, on) => {
    const calls = world(on)
    const { text } = await ship($, '', { kind: 'plugin', name: 'other' } as PromptOrigin)
    expect(merged(calls)).toEqual([])
    expect(calls).toEqual([])
    expect(text).toContain('only when you type it')
  })

  test('no PR for the branch: says how to name one', async ($, on) => {
    const calls = world(on, { noPr: true })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toBe("/ship\n✗ not merged: no open PR for main; switch to a PR's branch or use /ship <number>")
  })

  test('a tree with uncommitted changes: nothing merged', async ($, on) => {
    const calls = world(on, { dirty: ' M README.md\n' })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('uncommitted changes')
  })

  test('a draft or closed PR: nothing merged', async ($, on) => {
    const calls = world(on, { pr: { isDraft: true } })
    expect((await ship($)).text).toContain('draft')
    expect(merged(calls)).toEqual([])
  })

  test('checks still running: waits for them, then merges', async ($, on) => {
    const calls = world(on, { checksSeq: [[pass('invariants'), running('linux')], [pass('invariants'), running('linux')], [pass('invariants'), pass('linux')]] })
    const { text } = await ship($)
    expect(naps(calls)).toBe(2)
    expect(merged(calls)).toHaveLength(1)
    expect(text).toContain('✓ waited 30 s for the checks')
    expect(text).toContain('✓ 2 checks passed on 281480c')
  })

  test('checks that never finish: gives up after 20 minutes, nothing merged, and they are named', async ($, on) => {
    const calls = world(on, { checks: [pass('invariants'), running('linux')] })
    const { text } = await ship($)
    expect(naps(calls)).toBe(80)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('✗ not merged: still running: linux, after 20 min; /ship again when they finish')
  })

  test('a check that fails while /ship waits: nothing merged', async ($, on) => {
    const calls = world(on, { checksSeq: [[running('linux')], [{ ...pass('linux'), conclusion: 'failure' }]] })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('failed: linux')
  })

  // disk-budget.yml's `commit` job has no check until the two jobs it needs have finished.
  test('every check green but a workflow still going: waits for its later jobs', async ($, on) => {
    const going = [{ name: 'disk-budget', status: 'in_progress', conclusion: null }]
    const calls = world(on, {
      workflowsSeq: [going, [{ name: 'disk-budget', status: 'completed', conclusion: 'success' }]],
      checksSeq: [[pass('linux')], [pass('linux'), pass('commit')]],
    })
    const { text } = await ship($)
    expect(naps(calls)).toBe(1)
    expect(text).toContain('✓ 2 checks passed')
    expect(merged(calls)).toHaveLength(1)
  })

  test("a bot PR's workflows held for approval: says so at once", async ($, on) => {
    const calls = world(on, { checks: [], workflowsSeq: [[{ name: 'lint', status: 'completed', conclusion: 'action_required' }]] })
    const { text } = await ship($)
    expect(naps(calls)).toBe(0)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('holding lint for approval')
  })

  // lint.yml's scope job skips the jobs a change doesn't reach.
  test('skipped checks are counted apart from the ones that ran', async ($, on) => {
    const calls = world(on, { checks: [pass('scope'), pass('invariants'), { ...pass('windows-http'), conclusion: 'skipped' }] })
    const { text } = await ship($)
    expect(merged(calls)).toHaveLength(1)
    expect(text).toContain('✓ 2 checks passed (1 skipped) on 281480c')
  })

  test('a failing check: nothing merged, and it is named', async ($, on) => {
    const calls = world(on, { checks: [pass('invariants'), { ...pass('windows'), conclusion: 'failure' }] })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('failed: windows')
  })

  test('a re-run check counts by its latest run', async ($, on) => {
    const calls = world(on, {
      checks: [{ ...pass('linux', '2026-10-16T13:11:00Z'), conclusion: 'failure' }, pass('linux', '2026-10-16T13:20:00Z')],
    })
    await ship($)
    expect(merged(calls)).toHaveLength(1)
  })

  test('no checks at all: nothing merged', async ($, on) => {
    const calls = world(on, { checks: [] })
    expect((await ship($)).text).toContain('no checks')
    expect(merged(calls)).toEqual([])
  })

  test('a failing commit status: nothing merged', async ($, on) => {
    const calls = world(on, { statuses: { state: 'failure', total_count: 1 } })
    expect((await ship($)).text).toContain('commit status is failure')
    expect(merged(calls)).toEqual([])
  })

  test('main moved after CI started: merges main into the branch, waits for the new checks, then merges that head', async ($, on) => {
    const calls = world(on, {
      behindBy: 1,
      mainDate: '2026-10-16T13:30:00Z',
      updateLag: 1,
      checksAfterUpdate: [[], [running('invariants')], [pass('invariants', '2026-10-16T13:40:00Z')]],
    })
    const { text } = await ship($)
    expect(calls.filter(c => c === 'gh pr update-branch 92')).toHaveLength(1)
    expect(merged(calls)).toEqual([`gh pr merge 92 --squash --delete-branch --match-head-commit ${HEAD2}`])
    expect(text).toContain('✓ main moved (5dc752c at 13:30) after CI started (13:16), so the checks predate it: merged main into the branch, CI restarted')
    expect(text).toContain('✓ waited 1 min for the checks')
    expect(text).toContain('✓ 1 checks passed on 9a4be77, which holds main')
  })

  test('main moved and merging it conflicts: nothing merged, and why', async ($, on) => {
    const calls = world(on, { behindBy: 1, mainDate: '2026-10-16T13:30:00Z', updateExit: 1 })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(naps(calls)).toBe(0)
    expect(text).toContain('main moved')
    expect(text).toContain('merging main into the branch failed: merge conflict')
  })

  test('main moved on another day: the times carry their dates', async ($, on) => {
    const calls = world(on, { behindBy: 1, mainDate: '2026-10-17T11:17:00Z', updateExit: 1 })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('main moved (5dc752c at 10-17 11:17) after CI started (10-16 13:16)')
  })

  // disk-budget.yml commits disk-budget.toml to main a few minutes after a merge.
  test('main is ahead only by a generated file: the checks still count', async ($, on) => {
    const calls = world(on, { behindBy: 1, mainDate: '2026-10-16T13:30:00Z', baseFiles: ['disk-budget.toml'] })
    const { text } = await ship($)
    expect(calls).not.toContain('gh pr update-branch 92')
    expect(merged(calls)).toHaveLength(1)
    expect(text).toContain('✓ 4 checks passed on 281480c, behind main only by disk-budget.toml')
  })

  test('GitHub still working out the merge state: waits for it', async ($, on) => {
    const calls = world(on, { mergeStates: ['UNKNOWN', 'UNKNOWN', 'CLEAN'] })
    await ship($)
    expect(naps(calls)).toBe(2)
    expect(merged(calls)).toHaveLength(1)
  })

  test('behind main, but CI started after main moved: merged', async ($, on) => {
    const calls = world(on, { behindBy: 1, mainDate: '2026-10-16T13:00:00Z' })
    await ship($)
    expect(merged(calls)).toHaveLength(1)
  })

  test('GitHub says it can\'t merge: nothing merged, and why', async ($, on) => {
    const calls = world(on, { pr: { mergeStateStatus: 'DIRTY' } })
    expect((await ship($)).text).toContain('DIRTY')
    expect(merged(calls)).toEqual([])
  })

  test('a merge GitHub refuses is reported, and main is not pulled', async ($, on) => {
    const calls = world(on, { mergeExit: 1 })
    const { text } = await ship($)
    expect(text).toContain('Head branch was modified')
    expect(calls).not.toContain('git pull --ff-only --prune')
  })

  // Run from this checkout, /ship loads from .claude/skills/workstation-ship: once main has
  // a PR that changes it, Claude Code reloads it, and a call after that is refused.
  test('a PR that changes /ship, shipped from its branch: nothing runs after gh switches and pulls', async ($, on) => {
    const calls = world(on, { files: ['README.md', '.claude/skills/workstation-ship/hooks/register.ts'] })
    const { text } = await ship($)
    expect(calls[calls.length - 1]).toMatch(/^gh pr merge 92 /)
    expect(text).toContain('✓ squash-merged; branch deleted')
    expect(text).toContain('✓ gh switched to main and pulled it; the PR changes /ship, so Claude Code reloads it')
    expect(text).not.toContain('merged, but')
  })

  test('a PR that changes /ship, shipped from main: main is left for you to pull', async ($, on) => {
    const calls = world(on, { files: ['.claude/skills/workstation-ship/tests/ship.test.ts'], branchBefore: 'main' })
    const { text } = await ship($)
    expect(calls[calls.length - 1]).toMatch(/^gh pr merge 92 /)
    expect(text).toContain("! the PR changes /ship, so main wasn't pulled (that reloads /ship mid-command): git pull --ff-only --prune")
  })

  test('a PR that changes another mod is shipped as usual', async ($, on) => {
    const calls = world(on, { files: ['.claude/skills/workstation-sync/hooks/register.tsx'] })
    await ship($)
    expect(calls).toContain('git pull --ff-only --prune')
  })

  test('on another branch afterwards: fetch, not pull', async ($, on) => {
    const calls = world(on, { branchAfter: 'other-work' })
    await ship($)
    expect(calls).toContain('git fetch --prune')
    expect(calls).not.toContain('git pull --ff-only --prune')
  })
})
