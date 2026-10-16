import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On, ProcessRunResult, RenderElement } from 'claude-code'

const HOME = '/home/u'
const REPO = `${HOME}/.config/mise`
const WIN = '/mnt/c/Users/u'
const sha = (s: string) => s.padEnd(40, '0')
const MAIN = sha('cafe863')
const OLD = sha('5dc752c')

type Rollup = { name: string; status?: string; conclusion?: string; state?: string }
type World = {
  env?: Record<string, string>
  toplevel?: string
  branch?: string
  head?: string
  origin?: string | null
  drift?: number | null
  windowsHead?: string | null
  pr?: { number: number; mergeStateStatus: string; statusCheckRollup: Rollup[] } | null
}

const BAND = {
  plugin: 'workstation-sync',
  surface: 'terminal' as const,
  component: 'AbovePrompt' as const,
  props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 160, scroll: { offset: 0, bodyRows: 6 }, view: {} },
}

// This host on main at origin's cafe863, every dotfile applied, the Windows checkout at
// cafe863 too, and no PR; each case changes what it needs (w is read at every probe).
function world(on: On, w: World = {}) {
  mock.env(on, w.env ?? { HOME, WSL_DISTRO_NAME: 'AlmaLinux-9' })
  const clock = mock.clock(on, { now: Date.parse('2026-10-16T14:00:00Z') })
  const calls: string[] = []
  // The engine's own answer to a session's start: it echoes the cwd.
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  // ...and its own band, which draws nothing a plugin hasn't drawn.
  on('ui.render', { component: 'AbovePrompt' }, ($, e) => {
    const { Box } = $.ui.resolve(e)
    return h(Box, { key: 'engine' }) as RenderElement
  })
  const out = (stdout: unknown, exitCode = 0, stderr = exitCode ? 'failed' : ''): { value: ProcessRunResult } => ({
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
    if (line === 'git rev-parse --show-toplevel') return out(`${w.toplevel ?? REPO}\n`)
    if (line === 'git rev-parse --abbrev-ref HEAD') return out(`${w.branch ?? 'main'}\n`)
    if (line === 'git rev-parse HEAD') return out(`${w.head ?? MAIN}\n`)
    if (line === 'git ls-remote origin refs/heads/main') {
      return w.origin === null ? out('', 128) : out(`${w.origin ?? MAIN}\trefs/heads/main\n`)
    }
    if (line.startsWith('mise -C ') && line.endsWith(' dot status --json')) {
      if (w.drift === null) return out('', 1)
      const drift = w.drift ?? 0
      return out({ files: [...Array(5).keys()].map(i => ({ state: i < drift ? 'modified' : 'applied' })) })
    }
    if (line === `${HOME}/.local/bin/winterop env USERPROFILE`) return out('C:\\Users\\u\r\n')
    if (line === `${HOME}/.local/bin/winterop path -u C:\\Users\\u`) return out(`${WIN}\n`)
    if (line === 'gh pr view --json number,mergeStateStatus,statusCheckRollup') {
      if (w.pr === null) return out('', 1, 'error connecting to api.github.com')
      return w.pr ? out(w.pr) : out('', 1, `no pull requests found for branch "${w.branch}"`)
    }
    return out('', 1)
  })
  on('fs.read', ($, e) => {
    if (w.windowsHead === null) return { deny: `ENOENT: ${e.path}` }
    if (e.path === `${WIN}/.config/mise/.git/HEAD`) return { value: 'ref: refs/heads/main\n' }
    if (e.path === `${WIN}/.config/mise/.git/refs/heads/main`) return { value: `${w.windowsHead ?? MAIN}\n` }
    return { deny: `ENOENT: ${e.path}` }
  })
  return { clock, calls }
}

// The band's text once the session has started and its first look has settled.
async function band($: Engine, clock: { advance: (ms: number) => Promise<void> }, cwd = REPO) {
  await $.session.start({ cwd, surface: 'terminal', isInteractive: true })
  await clock.advance(1)
  const ui = await $.ui.mount(BAND)
  return { ui, text: async () => (await ui.find({ key: 'sync' }))?.text }
}

describe('the sync band', () => {
  test('all in step: this host, its dotfiles and Windows each get a tick', async ($, on) => {
    const { clock } = world(on)
    const { text } = await band($, clock)
    const shown = await text()
    expect(shown).toContain('✓ main cafe863')
    expect(shown).toContain('✓ dotfiles')
    expect(shown).toContain('✓ Windows')
  })

  test('outside the workstation checkout it draws nothing and looks at nothing', async ($, on) => {
    const { clock, calls } = world(on, { toplevel: '/home/u/src/other' })
    const { text } = await band($, clock, '/home/u/src/other')
    expect(await text()).toBeUndefined()
    expect(calls).toEqual(['git rev-parse --show-toplevel'])
  })

  test('this host behind origin: run wsu', async ($, on) => {
    const { clock } = world(on, { head: OLD })
    const { text } = await band($, clock)
    expect(await text()).toContain('! main 5dc752c, origin cafe863: run wsu')
  })

  test('Windows behind origin: run wsu there', async ($, on) => {
    const { clock } = world(on, { windowsHead: OLD })
    const { text } = await band($, clock)
    expect(await text()).toContain('! Windows 5dc752c: run wsu there')
  })

  test('dotfiles drifted: says how many', async ($, on) => {
    const { clock } = world(on, { drift: 2 })
    const { text } = await band($, clock)
    expect(await text()).toContain('! 2 dotfiles drifted (mise dot status)')
  })

  test('off WSL there is no Windows part', async ($, on) => {
    const { clock, calls } = world(on, { env: { HOME } })
    const { text } = await band($, clock)
    expect(await text()).toContain('✓ main cafe863')
    expect(await text()).not.toContain('Windows')
    expect(calls.some(c => c.includes('winterop'))).toBe(false)
  })

  test('on Windows itself the checkout is found under USERPROFILE', async ($, on) => {
    const { clock } = world(on, { env: { USERPROFILE: 'C:\\Users\\u' }, toplevel: 'C:/Users/u/.config/mise' })
    const { text } = await band($, clock, 'C:\\Users\\u\\.config\\mise')
    expect(await text()).toContain('✓ main cafe863')
  })

  test('a probe that fails leaves a ? and the rest drawn', async ($, on) => {
    const { clock } = world(on, { origin: null, drift: null })
    const { text } = await band($, clock)
    const shown = await text()
    expect(shown).toContain('main cafe863 (origin ?)')
    expect(shown).toContain('? dotfiles')
    // With origin unknown there is nothing to tick Windows against: its commit, untinted.
    expect(shown).toContain('Windows cafe863')
    expect(shown).not.toContain('✓ Windows')
  })

  describe("a branch's PR", () => {
    const pr = (statusCheckRollup: Rollup[], mergeStateStatus = 'CLEAN') => ({
      branch: 'ccstatusline-catppuccin',
      head: sha('281480c'),
      pr: { number: 92, mergeStateStatus, statusCheckRollup },
    })
    const done = (name: string, conclusion = 'SUCCESS') => ({ name, status: 'COMPLETED', conclusion })

    test('green and mergeable: ready for /ship', async ($, on) => {
      const { clock } = world(on, pr([done('invariants'), done('templates')]))
      const { text } = await band($, clock)
      const shown = await text()
      expect(shown).toContain('ccstatusline-catppuccin 281480c')
      expect(shown).toContain('✓ PR #92: 2 checks passed, /ship')
    })

    test('checks running: how many of how many', async ($, on) => {
      const { clock } = world(on, pr([done('invariants'), { name: 'linux', status: 'IN_PROGRESS' }, { name: 'ci/x', state: 'PENDING' }]))
      const { text } = await band($, clock)
      expect(await text()).toContain('… PR #92: 2 of 3 checks running')
    })

    test('a failed check is named', async ($, on) => {
      const { clock } = world(on, pr([done('invariants'), done('windows', 'FAILURE')]))
      const { text } = await band($, clock)
      expect(await text()).toContain('✗ PR #92: windows failed')
    })

    test('green but GitHub won\'t merge it: says why', async ($, on) => {
      const { clock } = world(on, pr([done('invariants')], 'BEHIND'))
      const { text } = await band($, clock)
      expect(await text()).toContain('! PR #92: 1 check passed, BEHIND')
    })

    test('no PR for the branch yet', async ($, on) => {
      const { clock } = world(on, { branch: 'new-work' })
      const { text } = await band($, clock)
      expect(await text()).toContain('no PR yet')
    })

    test("gh can't reach GitHub: a ?, not 'no PR yet'", async ($, on) => {
      const { clock } = world(on, { branch: 'new-work', pr: null })
      const { text } = await band($, clock)
      expect(await text()).toContain('? PR')
    })
  })

  test('it looks again as soon as a slash command finishes', async ($, on) => {
    const w: World = { windowsHead: OLD }
    const { clock } = world(on, w)
    // Whatever answers the command (say /ship) is beneath the band's hook.
    on('command.run', () => ({ text: 'merged' }))
    const { text } = await band($, clock)
    expect(await text()).toContain('! Windows 5dc752c')
    w.windowsHead = MAIN
    const ran = await $.command.run({ command: 'ship', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } })
    expect(ran.text).toBe('merged')
    await clock.advance(1)
    expect(await text()).toContain('✓ Windows')
  })

  test('it looks again every minute', async ($, on) => {
    const w: World = { windowsHead: OLD }
    const { clock } = world(on, w)
    const { text } = await band($, clock)
    expect(await text()).toContain('! Windows 5dc752c')
    w.windowsHead = MAIN
    await clock.advance(60_000)
    expect(await text()).toContain('✓ Windows')
  })
})
