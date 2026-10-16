// One run of scripts/check-invariants.sh, from its banner to its verdict, folded to a
// line when the verdict is a pass. A run that failed, or was cut off before its verdict,
// comes back undefined: the caller keeps the text whole. The script's own lines are
// matched with their colour codes taken off: hdr() `==> name`, ok() `   ✓ text`,
// bad() `   ✗ text`, note() `   · text` (a check that was skipped, kept in the fold).
const COLOUR = /\x1b\[[0-9;]*m/g
const BANNER = '== workstation invariant check =='
const PASSED = '✓ all invariant checks passed'

export function fold(text: string): string | undefined {
  const lines = text.split('\n')
  const plain = lines.map(line => line.replace(COLOUR, ''))
  const start = plain.findIndex(line => line.trim() === BANNER)
  if (start < 0) return undefined
  const end = plain.findIndex((line, i) => i > start && line.trim() === PASSED)
  if (end < 0) return undefined
  const run = plain.slice(start + 1, end)
  if (run.some(line => line.trimStart().startsWith('✗'))) return undefined

  const checks = run.filter(line => line.trimStart().startsWith('✓ ')).length
  const sections = run.filter(line => line.startsWith('==> ')).length
  const notes = run.filter(line => line.trimStart().startsWith('· ')).map(line => `   ${line.trim()}`)
  const summary = `${PASSED}: ${checks} checks in ${sections} sections (folded by workstation-lint-fold; run it again to see them)`

  return [...lines.slice(0, start), summary, ...notes, ...lines.slice(end + 1)].join('\n')
}
