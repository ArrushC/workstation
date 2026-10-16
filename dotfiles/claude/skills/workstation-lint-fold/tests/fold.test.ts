import { describe, expect, test } from 'claude-code/testing'

import { fold } from '../hooks/fold'

const ESC = '\x1b'
const g = (s: string) => `   ${ESC}[0;32m✓${ESC}[0m ${s}`
const hdr = (s: string) => `${ESC}[0;34m==>${ESC}[0m ${ESC}[1m${s}${ESC}[0m`
const HEAD = `${ESC}[1m${ESC}[0;34m== workstation invariant check ==${ESC}[0m`
const PASSED = `${ESC}[0;32m✓ all invariant checks passed${ESC}[0m`
const FAILED = `${ESC}[0;31m✗ 1 invariant check(s) failed${ESC}[0m`

const passing = [
  '[lint] $ scripts/check-invariants.sh',
  HEAD,
  hdr('pins recorded in more than one place'),
  g('VCPKG_ROOT @ $HOME/.local/share/vcpkg'),
  g('typescript: 5.9.3 (major <= 5)'),
  hdr('self-tests'),
  `   ${ESC}[1;33m·${ESC}[0m jq missing — test-hooks.sh skipped`,
  g('all 22 check_pins cases passed'),
  '',
  PASSED,
  '[ws-mods 1a2b3c4] Add the mods',
  ' 3 files changed, 40 insertions(+)',
].join('\n')

const bashRow = (content: unknown) => ({
  message: {
    type: 'user' as const,
    role: 'user' as const,
    content: [{ type: 'tool_result', tool_use_id: 'toolu_1', content }],
  },
  door: 'tool-result' as const,
  origin: { kind: 'tool' as const, tool: 'Bash' },
  uuid: 'row-1',
})

// The stored row's tool_result content: a string, or text blocks.
const resultOf = (row: { message?: { content: readonly unknown[] } }) =>
  (row.message?.content[0] as { content?: unknown } | undefined)?.content

describe('fold', () => {
  test('a passing run becomes one line, keeping its notes and what came around it', () => {
    const out = fold(passing)
    expect(out).toBeDefined()
    const lines = (out ?? '').split('\n')
    expect(lines[0]).toBe('[lint] $ scripts/check-invariants.sh')
    expect(lines[1]).toBe(
      '✓ all invariant checks passed: 3 checks in 2 sections (folded by workstation-lint-fold; run it again to see them)',
    )
    expect(lines[2]).toBe('   · jq missing — test-hooks.sh skipped')
    expect(lines.slice(3)).toEqual(['[ws-mods 1a2b3c4] Add the mods', ' 3 files changed, 40 insertions(+)'])
  })

  test('a failing run is left whole', () => {
    const failing = passing.replace(PASSED, FAILED).replace(g('typescript: 5.9.3 (major <= 5)'), `   ${ESC}[0;31m✗${ESC}[0m typescript: 7.0`)
    expect(fold(failing)).toBeUndefined()
  })

  test('a run cut off before its verdict is left whole', () => {
    expect(fold(passing.split(PASSED)[0] ?? '')).toBeUndefined()
  })

  test('output with no lint run is left whole', () => {
    expect(fold('On branch main\nnothing to commit, working tree clean')).toBeUndefined()
  })

  test('the same run without colour codes folds the same way', () => {
    const plain = passing.replace(/\x1b\[[0-9;]*m/g, '')
    expect(fold(plain)?.split('\n')[1]).toMatch(/^✓ all invariant checks passed: 3 checks in 2 sections/)
  })
})

describe('the session.append hook', () => {
  test('a Bash result holding a passing run reaches the model folded', async $ => {
    const row = await $.session.append(bashRow(passing))
    const content = resultOf(row) as string
    expect(content).toMatch(/^\[lint\] \$ scripts\/check-invariants\.sh\n✓ all invariant checks passed: 3 checks/)
    expect(content).not.toContain('VCPKG_ROOT')
  })

  test('a result given as text blocks folds each block', async $ => {
    const row = await $.session.append(bashRow([{ type: 'text', text: passing }]))
    const parts = resultOf(row) as { text: string }[]
    expect(parts[0]?.text).toContain('✓ all invariant checks passed: 3 checks')
  })

  test('a failing run reaches the model whole', async $ => {
    const failing = passing.replace(PASSED, FAILED)
    const row = await $.session.append(bashRow(failing))
    expect(resultOf(row)).toBe(failing)
  })

  test('another tool\'s result is left alone', async $ => {
    const row = await $.session.append({ ...bashRow(passing), origin: { kind: 'tool', tool: 'Read' } })
    expect(resultOf(row)).toBe(passing)
  })
})
