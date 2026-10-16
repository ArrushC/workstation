// What the band draws from: one snapshot of this host's checkout, its dotfiles, the
// Windows checkout (from WSL) and the branch's PR, each null when its probe failed.
export type SyncChecks = { passed: number; running: number; failed: string[] }
export type SyncPr = { number: number; mergeState: string; checks: SyncChecks }
export type Sync = {
  branch: string | null
  head: string | null
  origin: string | null
  drift: number | null
  // undefined off WSL, where there is no Windows checkout to look at
  windows?: string | null
  // 'none': the branch has no PR yet; null: gh couldn't say
  pr: SyncPr | 'none' | null
}

declare module 'claude-code' {
  interface PluginState {
    'workstation-sync': { sync: Sync | null }
  }
}
