import type { Register } from 'claude-code'

import { fold } from './fold'

type Block = { type: string; text?: string; content?: unknown }

// A text block, or a tool_result's content (a string, or text blocks), with each
// passing lint run folded; the same object when nothing folded.
function foldBlock(block: Block): Block {
  if (block.type === 'text' && typeof block.text === 'string') {
    const text = fold(block.text)
    return text === undefined ? block : { ...block, text }
  }
  if (block.type !== 'tool_result') return block
  if (typeof block.content === 'string') {
    const content = fold(block.content)
    return content === undefined ? block : { ...block, content }
  }
  if (!Array.isArray(block.content)) return block
  const parts = (block.content as Block[]).map(foldBlock)
  return parts.every((part, i) => part === (block.content as Block[])[i]) ? block : { ...block, content: parts }
}

// What the model reads of a Bash result: session.append stores the row the next request
// sends, while the tool's own record (what the transcript draws, ctrl+o) keeps the run whole.
export const register: Register = on => {
  on('session.append', { door: 'tool-result' }, ($, e, next) => {
    if (e.origin.kind !== 'tool' || e.origin.tool !== 'Bash') return next(e)
    const content = (e.message.content as Block[]).map(foldBlock)
    if (content.every((block, i) => block === e.message.content[i])) return next(e)
    return next({ ...e, message: { ...e.message, content: content as typeof e.message.content } })
  })
}
