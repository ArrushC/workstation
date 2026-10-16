import { describe, expect, test } from 'claude-code/testing'
import type { On, ProcessRunResult, PromptOrigin } from 'claude-code'

const HEAD = '281480c12cc4254fc38e90717497d8a7d707ab40'
const MAIN = '5dc752cbb4fa6ad1c2e8f7a9b0c3d4e5f6a7b8c9'

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
  on('process.run', ($, e) => {
    const line = e.argv.join(' ')
    calls.push(line)
    const pr = {
      number: 92,
      title: 'Claude Code: the status line in Catppuccin Mocha',
      state: 'OPEN',
      isDraft: false,
      headRefName: 'ccstatusline-catppuccin',
      headRefOid: HEAD,
      baseRefName: 'main',
      mergeStateStatus: 'CLEAN',
      url: 'https://github.com/o/r/pull/92',
      files: (w.files ?? ['README.md']).map(path => ({ path })),
      ...w.pr,
    }
    if (line === 'git status --porcelain --untracked-files=no') return ok(w.dirty ?? '')
    if (line.startsWith('gh pr view')) return ok(pr)
    if (line === `gh api repos/{owner}/{repo}/commits/${HEAD}/check-runs?per_page=100`) {
      const runs = w.checks ?? ['invariants', 'templates', 'powershell', 'windows-http'].map(n => pass(n))
      return ok({ total_count: runs.length, check_runs: runs })
    }
    if (line === `gh api repos/{owner}/{repo}/commits/${HEAD}/status`) return ok(w.statuses ?? { state: 'pending', total_count: 0 })
    if (line === `gh api repos/{owner}/{repo}/compare/main...${HEAD}`) return ok({ behind_by: w.behindBy ?? 0 })
    if (line === 'gh api repos/{owner}/{repo}/commits/main')
      return ok({ sha: MAIN, commit: { committer: { date: w.mainDate ?? '2026-10-16T13:10:00Z' } } })
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

  test('checks still running: nothing merged, and they are named', async ($, on) => {
    const calls = world(on, { checks: [pass('invariants'), { ...pass('linux'), status: 'in_progress', conclusion: null }] })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('still running: linux')
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

  test('main moved after CI started: stale checks, nothing merged', async ($, on) => {
    const calls = world(on, { behindBy: 1, mainDate: '2026-10-16T13:30:00Z' })
    const { text } = await ship($)
    expect(merged(calls)).toEqual([])
    expect(text).toContain('main moved')
    expect(text).toContain('5dc752c')
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
