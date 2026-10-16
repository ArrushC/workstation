import { atom, read, update } from 'claude-code'
import type { Color, EngineInterface, Register } from 'claude-code'

import type { Sync, SyncChecks, SyncPr } from '../types'

// A band above the prompt in the workstation checkout (~/.config/mise, or
// %USERPROFILE%\.config\mise), and nowhere else: is this host's checkout at origin/main
// (else `wsu`), are its dotfiles applied, is the Windows checkout at origin/main (from
// WSL, read from /mnt/c), and how do the branch's PR checks stand. It looks when the
// session starts, every minute after, and when a turn or a slash command ends. A probe that fails shows a ?
// and the rest still draws.

const sync = atom({ plugin: 'workstation-sync', key: 'sync' } as const, null)
const EVERY_MS = 60_000
const PASSED = new Set(['SUCCESS', 'NEUTRAL', 'SKIPPED'])
const MERGEABLE = new Set(['CLEAN', 'HAS_HOOKS'])

type $ = EngineInterface
type Rollup = { name?: string; context?: string; status?: string; conclusion?: string | null; state?: string }
type Part = { text: string; color: Color }

const short = (sha: string) => sha.trim().slice(0, 7)
// One spelling for a path: forward slashes, no trailing one, a drive path in lower case.
const norm = (path: string) => {
  const p = path.trim().replace(/\\/g, '/').replace(/\/+$/, '')
  return /^[a-z]:\//i.test(p) ? p.toLowerCase() : p
}
const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`

async function run($: $, argv: string[]) {
  const ran = await $.process.run(argv, { timeoutMs: 20_000 })
  if (ran.exitCode !== 0) throw new Error(ran.stderr.trim() || `${argv[0]} exited ${ran.exitCode}`)
  return ran.stdout
}

// A probe's answer, or null when it failed.
async function probe<T>(look: () => Promise<T>): Promise<T | null> {
  try {
    return await look()
  } catch {
    return null
  }
}

// The commit a checkout's HEAD names, read from its .git (a loose ref or packed-refs).
async function headOf($: $, repo: string) {
  const head = (await $.fs.read(`${repo}/.git/HEAD`)).trim()
  if (!head.startsWith('ref: ')) return short(head)
  const ref = head.slice(5)
  try {
    return short(await $.fs.read(`${repo}/.git/${ref}`))
  } catch {
    const packed = (await $.fs.read(`${repo}/.git/packed-refs`)).split('\n').find(line => line.endsWith(` ${ref}`))
    if (!packed) throw new Error(`no ${ref}`)
    return short(packed)
  }
}

function checksOf(rollup: Rollup[]): SyncChecks {
  const checks: SyncChecks = { passed: 0, running: 0, failed: [] }
  for (const c of rollup) {
    const name = c.name ?? c.context ?? '?'
    if (c.state !== undefined) {
      if (c.state === 'SUCCESS') checks.passed++
      else if (c.state === 'PENDING' || c.state === 'EXPECTED') checks.running++
      else checks.failed.push(name)
    } else if (c.status !== 'COMPLETED') checks.running++
    else if (PASSED.has(c.conclusion ?? '')) checks.passed++
    else checks.failed.push(name)
  }
  return checks
}

async function prOf($: $): Promise<SyncPr | 'none' | null> {
  const ran = await $.process.run(['gh', 'pr', 'view', '--json', 'number,mergeStateStatus,statusCheckRollup'], { timeoutMs: 20_000 })
  if (ran.exitCode !== 0) return ran.stderr.includes('no pull requests found') ? 'none' : null
  const pr = JSON.parse(ran.stdout) as { number: number; mergeStateStatus: string; statusCheckRollup: Rollup[] | null }
  return { number: pr.number, mergeState: pr.mergeStateStatus, checks: checksOf(pr.statusCheckRollup ?? []) }
}

function prPart(pr: SyncPr | 'none' | null): Part {
  if (pr === 'none') return { text: 'no PR yet', color: 'inactive' }
  if (pr === null) return { text: '? PR', color: 'inactive' }
  const { number: n, checks, mergeState } = pr
  const total = checks.passed + checks.running + checks.failed.length
  if (checks.failed.length > 0) return { text: `✗ PR #${n}: ${checks.failed.join(', ')} failed`, color: 'error' }
  if (checks.running > 0) return { text: `… PR #${n}: ${checks.running} of ${total} checks running`, color: 'warning' }
  if (total === 0) return { text: `… PR #${n}: no checks yet`, color: 'warning' }
  const passed = `${plural(checks.passed, 'check')} passed`
  if (MERGEABLE.has(mergeState)) return { text: `✓ PR #${n}: ${passed}, /ship`, color: 'success' }
  return { text: `! PR #${n}: ${passed}, ${mergeState}`, color: 'warning' }
}

function partsOf(s: Sync): Part[] {
  const parts: Part[] = []
  if (s.branch === null || s.head === null) parts.push({ text: '? checkout', color: 'inactive' })
  else if (s.branch !== 'main') parts.push({ text: `${s.branch} ${s.head}`, color: 'claude' }, prPart(s.pr))
  else if (s.origin === null) parts.push({ text: `main ${s.head} (origin ?)`, color: 'inactive' })
  else if (s.head === s.origin) parts.push({ text: `✓ main ${s.head}`, color: 'success' })
  else parts.push({ text: `! main ${s.head}, origin ${s.origin}: run wsu`, color: 'warning' })

  if (s.drift === null) parts.push({ text: '? dotfiles', color: 'inactive' })
  else if (s.drift === 0) parts.push({ text: '✓ dotfiles', color: 'success' })
  else parts.push({ text: `! ${plural(s.drift, 'dotfile')} drifted (mise dot status)`, color: 'warning' })

  if (s.windows === undefined) return parts
  if (s.windows === null) parts.push({ text: '? Windows', color: 'inactive' })
  else if (s.origin === null) parts.push({ text: `Windows ${s.windows}`, color: 'inactive' })
  else if (s.windows === s.origin) parts.push({ text: '✓ Windows', color: 'success' })
  else parts.push({ text: `! Windows ${s.windows}: run wsu there`, color: 'warning' })
  return parts
}

// Module state, which a reload starts over (session.start then fires again): the home
// directory once the session turns out to run in the workstation checkout, and the
// Windows checkout as WSL sees it (undefined off WSL, null when it can't be found).
let home: string | undefined
let windowsRepo: string | null | undefined
let isLooking = false

async function look($: $) {
  if (home === undefined || isLooking) return
  isLooking = true
  try {
    const at = home
    const repo = windowsRepo
    const [branch, head, origin, drift, windows] = await Promise.all([
      probe(async () => (await run($, ['git', 'rev-parse', '--abbrev-ref', 'HEAD'])).trim()),
      probe(async () => short(await run($, ['git', 'rev-parse', 'HEAD']))),
      probe(async () => short(await run($, ['git', 'ls-remote', 'origin', 'refs/heads/main'])) || null),
      probe(async () => {
        const status = JSON.parse(await run($, ['mise', '-C', at, 'dot', 'status', '--json'])) as { files: { state: string }[] }
        return status.files.filter(f => f.state !== 'applied').length
      }),
      repo === undefined ? undefined : repo === null ? null : probe(() => headOf($, repo)),
    ])
    const pr = branch !== null && branch !== 'main' ? await probe(() => prOf($)) : null
    const snapshot: Sync = { branch, head, origin, drift, pr }
    if (windows !== undefined) snapshot.windows = windows
    await update($, sync, () => snapshot)
  } catch {
    // A call refused because a pull just reloaded this mod: the reloaded copy looks again.
  } finally {
    isLooking = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    home = undefined
    windowsRepo = undefined
    const userHome = (await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))
    if (userHome === undefined) return started
    const top = await probe(() => run($, ['git', 'rev-parse', '--show-toplevel']))
    if (top === null || norm(top) !== norm(`${userHome}/.config/mise`)) return started

    home = userHome
    if (await $.env.get('WSL_DISTRO_NAME')) {
      const winterop = `${userHome}/.local/bin/winterop`
      windowsRepo = await probe(async () => {
        const profile = (await run($, [winterop, 'env', 'USERPROFILE'])).trim()
        return `${(await run($, [winterop, 'path', '-u', profile])).trim()}/.config/mise`
      })
    }
    void look($)
    $.clock.every(EVERY_MS, () => void look($))
    return started
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    void look($)
    return done
  })

  // Any slash command (a /ship that merged and pulled, say): look once it has finished,
  // passing its answer on as it came. This sits in every command's chain, so a failure here
  // hands the command's own answer on (a called next replays, never runs it twice).
  on('command.run', async ($, e, next) => {
    const ran = await next(e)
    void look($)
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (home === undefined || e.props.hasSurvey) return next(e)
    const snapshot = await read($, sync)
    if (snapshot === null) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box key="sync" flexDirection="row" flexWrap="wrap">
        <Text color="inactive">workstation </Text>
        {partsOf(snapshot).map((part, i) => (
          <Text key={`part-${i}`} color={part.color}>
            {(i === 0 ? ' ' : '  ·  ') + part.text}
          </Text>
        ))}
      </Box>
    )
  })
}
