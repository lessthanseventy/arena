import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Feed, Row } from '../types'

const PANE = 'board-feed'
const ORCHESTRATOR = 'orchestrator'
const LANDED = 10
const NONE: Feed = { asks: [], sentBack: [], running: [], landed: [] }

const feed = atom({ plugin: 'arena', key: 'feed' } as const, NONE, { shape: 'feed-1' })
const now = atom({ plugin: 'arena', key: 'now' } as const, 0)

type Ask = { question: string; asked_at?: string }
type Card = {
  id: number
  title: string
  status: string
  repo?: string | null
  claimed_by?: string | null
  stage?: string | null
  stage_note?: string
  closed_at?: string | null
  ask?: Ask | null
}

const time = (iso?: string | null) => (iso ? Date.parse(iso) : undefined)
const newest = (a: Row, b: Row) => (b.at ?? 0) - (a.at ?? 0) || b.id - a.id
const line = (text: string) => text.split('\n')[0] ?? ''

/** The feed's rows from the board file's text; `windows` names each holding pane's window. */
export const rows = (text: string, windows: Record<string, string>): Feed => {
  const cards = (JSON.parse(text) as { tickets: Card[] }).tickets
  const working = cards.filter(card => card.status === 'doing' || card.status === 'review')
  const isSentBack = (card: Card) => card.status === 'doing' && card.stage === 'failed'
  const holder = (card: Card) =>
    card.claimed_by ? (windows[card.claimed_by] ?? card.claimed_by) : 'nobody'

  return {
    asks: cards
      .flatMap(card =>
        card.ask
          ? [{ id: card.id, lead: 'asks', text: line(card.ask.question), at: time(card.ask.asked_at) }]
          : [],
      )
      .sort(newest),
    sentBack: working
      .filter(isSentBack)
      .map(card => ({ id: card.id, lead: 'sent back', text: line(card.stage_note ?? '') || card.title })),
    running: working
      .filter(card => !isSentBack(card))
      .map(card => ({
        id: card.id,
        lead: [card.status, card.stage, holder(card)].filter(Boolean).join(' '),
        text: card.title,
      })),
    landed: cards
      .filter(card => card.stage === 'landed')
      .map(card => ({ id: card.id, lead: 'landed', text: card.title, at: time(card.closed_at) }))
      .sort(newest)
      .slice(0, LANDED),
  }
}

const ago = (at: number | undefined, at_now: number) => {
  if (at === undefined || at_now === 0) return ''
  const minutes = Math.max(0, Math.floor((at_now - at) / 60_000))
  return minutes < 60 ? ` ${minutes}m` : ` ${Math.floor(minutes / 60)}h`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const pane = await $.env.get('TMUX_PANE')
    if (!e.isInteractive || pane === undefined) return started

    const tmux = (...args: string[]) => $.process.run(['tmux', ...args]).then(ran => ran.stdout)
    const session = await tmux('display-message', '-p', '-t', pane, '#{session_name}')
    if (session.trim() !== ORCHESTRATOR) return started

    const state =
      (await $.env.get('XDG_RUNTIME_DIR')) ??
      (await $.env.get('XDG_STATE_HOME')) ??
      `${await $.env.get('HOME')}/.local/state`
    const dir = `${state}/babylon`

    const load = async () => {
      const text = await $.fs.read(`${dir}/board.json`)
      const panes = await tmux('list-panes', '-a', '-F', '#{pane_id} #{session_name}:#{window_name}')
      const windows = Object.fromEntries(
        panes.split('\n').map(one => [one.split(' ')[0], one.slice(one.indexOf(' ') + 1)]),
      )
      const read_at = await $.clock.now()
      await update($, feed, () => rows(text, windows))
      await update($, now, () => read_at)
    }

    const say = (error: unknown) => $.ui.log(`board feed: ${error}`, { to: 'debug' })
    const reload = () => load().catch(say)

    await reload()
    void $.ui.open({ id: PANE, title: 'Board' })
    $.clock.every(60_000, () => void $.clock.now().then(at => update($, now, () => at)))

    void (async () => {
      // babylon writes the board beside itself and renames it into place
      const watch = $.process.spawn({
        argv: ['inotifywait', '-m', '-e', 'moved_to', '-e', 'close_write', '--format', '%f', dir],
      })
      for await (const { stream, text } of watch) {
        // a board written before the watch was set up is read once it is
        const isWatching = stream === 'stderr' && text.includes('Watches established')
        const isChanged = stream === 'stdout' && text.split('\n').includes('board.json')
        if (isWatching || isChanged) await reload()
      }
    })().catch(say)

    return started
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const { asks, sentBack, running, landed } = await read($, feed)
    const at_now = await read($, now)
    const section = (title: string, list: Row[]) =>
      list.length > 0 && (
        <Box flexDirection="column">
          <Text dimColor>{title}</Text>
          {list.map(row => (
            <Text wrap="truncate-end">
              #{row.id} {row.lead}
              {ago(row.at, at_now)} {row.text}
            </Text>
          ))}
        </Box>
      )

    return (
      <Box flexDirection="column" gap={1}>
        {asks.length + sentBack.length + running.length + landed.length === 0 && (
          <Text dimColor>Nothing on the board.</Text>
        )}
        {section('Waiting on you', asks)}
        {section('Sent back', sentBack)}
        {section('Doing and in review', running)}
        {section('Landed', landed)}
      </Box>
    )
  })
}
