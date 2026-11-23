import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Feed, Row } from '../types'

const PANE = 'board-feed'
const ORCHESTRATOR = 'orchestrator'
const CAP = 5
const NONE: Feed = { move: [], landing: [], building: [], landing_more: 0, building_more: 0, status: '' }

const feed = atom({ plugin: 'arena', key: 'feed' } as const, NONE, { shape: 'feed-2' })
const now = atom({ plugin: 'arena', key: 'now' } as const, 0)

const REPO_COLORS: Record<string, string> = {
  arena: '#5fafd7',
  babylon: '#d7af5f',
  tlon: '#87d787',
  ficciones: '#d787d7',
}
const repoColor = (repo: string) => REPO_COLORS[repo] ?? '#a8a8a8'

type Ask = { question: string; asked_at?: string }
type Card = {
  id: number
  title: string
  status: string
  kind?: string
  repo?: string | null
  stage?: string | null
  stage_note?: string
  claimed_at?: string | null
  submitted_at?: string | null
  closed_at?: string | null
  ask?: Ask | null
}
type Proposal = { id: number; action: string; ticket_id?: number | null; what: string; why?: string }
type Board = {
  tickets: Card[]
  proposals?: Proposal[]
  hold?: boolean
  auto?: { on: boolean; working: number; cap: number }
}

const time = (iso?: string | null) => (iso ? Date.parse(iso) : undefined)
const line = (text: string) => text.split('\n')[0] ?? ''
const byTime = (at: (card: Card) => number | undefined) => (a: Card, b: Card) =>
  (at(a) ?? 0) - (at(b) ?? 0) || a.id - b.id
const ordinal = (n: number) => `${n}${['th', 'st', 'nd', 'rd'][n % 100 > 10 && n % 100 < 14 ? 0 : n % 10] ?? 'th'}`
const RUNNING = ['verifying', 'reviewing']

const capped = (list: Row[]) => ({ shown: list.slice(0, CAP), more: Math.max(0, list.length - CAP) })

/** The feed's rows from the board file's text, as of `at_now`. */
export const rows = (text: string, at_now: number): Feed => {
  const board = JSON.parse(text) as Board
  const cards = board.tickets.filter(card => card.kind !== 'epic')
  const repoOf = (card: Card) => card.repo ?? ''
  const byId = new Map(cards.map(card => [card.id, card]))

  const proposals: Row[] = (board.proposals ?? []).map(proposal => {
    const card = proposal.ticket_id ? byId.get(proposal.ticket_id) : undefined

    return {
      label: `P${proposal.id}`,
      pre: card ? `${proposal.action} #${card.id}` : proposal.action,
      repo: card ? repoOf(card) : '',
      mid: '',
      text: card?.title ?? line(proposal.what),
      why: proposal.why ? line(proposal.why) : undefined,
      tone: 'move',
    }
  })
  const asks: Row[] = cards
    .filter(card => card.ask)
    .sort(byTime(card => time(card.ask?.asked_at)))
    .map(card => ({
      label: `#${card.id}`,
      repo: repoOf(card),
      mid: 'ask',
      text: line(card.ask?.question ?? ''),
      at: time(card.ask?.asked_at),
      tone: 'move',
    }))
  const sentBack: Row[] = cards
    .filter(card => card.stage === 'failed' && card.status !== 'done')
    .map(card => ({
      label: `#${card.id}`,
      repo: repoOf(card),
      mid: 'sent back',
      text: line(card.stage_note ?? '') || card.title,
      tone: 'failed',
    }))

  // board.json carries no queue order: the pipeline takes a repo's tickets in submitted order, so
  // submitted_at stands for it, and claimed_at for a ticket not yet stamped.
  const queue = cards
    .filter(card => card.status === 'review' && card.stage !== 'failed')
    .sort(
      (a, b) =>
        Number(RUNNING.includes(b.stage ?? '')) - Number(RUNNING.includes(a.stage ?? '')) ||
        byTime(card => time(card.submitted_at) ?? time(card.claimed_at))(a, b),
    )
  const landing: Row[] = queue.map((card, index) => ({
    label: `#${card.id}`,
    repo: repoOf(card),
    mid: RUNNING.includes(card.stage ?? '') ? (card.stage ?? '') : `queued ${ordinal(index + 1)}`,
    text: card.title,
    tone: RUNNING.includes(card.stage ?? '') ? 'running' : 'queued',
  }))
  const building: Row[] = cards
    .filter(card => card.status === 'doing' && card.stage !== 'failed' && !card.ask)
    .sort(byTime(card => time(card.claimed_at)))
    .map(card => ({
      label: `#${card.id}`,
      repo: repoOf(card),
      mid: '',
      text: card.title,
      at: time(card.claimed_at),
      tone: 'plain',
    }))

  const midnight = new Date(at_now).setHours(0, 0, 0, 0)
  const landed = cards.filter(card => card.stage === 'landed' && (time(card.closed_at) ?? 0) >= midnight).length
  const auto = board.auto
  const status = [
    auto?.on ? `auto ${auto.working}/${auto.cap}` : 'auto off',
    `hold ${board.hold ? 'on' : 'off'}`,
    `landed today ${landed}`,
  ].join(' · ')

  const move = [...proposals, ...asks, ...sentBack]
  const lands = capped(landing)
  const builds = capped(building)

  return {
    move,
    landing: lands.shown,
    building: builds.shown,
    landing_more: lands.more,
    building_more: builds.more,
    status,
    go: board.proposals?.[0]?.id,
  }
}

const ago = (at: number | undefined, at_now: number) => {
  if (at === undefined || at_now === 0) return ''
  const minutes = Math.max(0, Math.floor((at_now - at) / 60_000))
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h`
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
      const read_at = await $.clock.now()
      await update($, feed, () => rows(text, read_at))
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
    const { move, landing, building, landing_more, building_more, status, go } = await read($, feed)
    const at_now = await read($, now)

    const item = (row: Row) => {
      const mid = [row.mid, ago(row.at, at_now)].filter(Boolean).join(' ')
      const color = row.tone === 'move' ? 'warning' : row.tone === 'failed' ? 'error' : undefined

      return (
        <Text wrap="truncate-end" color={color} dimColor={row.tone === 'queued'} bold={row.tone === 'running'}>
          <Text bold>{row.label}</Text>
          {row.pre ? ` ${row.pre}` : ''}
          {row.repo ? <Text color={repoColor(row.repo)}> {row.repo}</Text> : ''}
          {mid ? ` · ${mid}` : ''} · {row.text}
          {row.why ? ` — ${row.why}` : ''}
        </Text>
      )
    }
    const more = (n: number) => n > 0 && <Text dimColor>+{n} more</Text>
    const section = (title: string, list: Row[], extra: number, color?: 'warning') =>
      list.length > 0 && (
        <Box flexDirection="column">
          <Text bold color={color}>
            {title}
          </Text>
          {list.map(item)}
          {more(extra)}
        </Box>
      )

    return (
      <Box flexDirection="column" gap={1}>
        <Text dimColor>{status}</Text>
        <Box flexDirection="column">
          <Text bold color="warning">
            Your move
          </Text>
          {move.length === 0 && <Text dimColor>nothing needs you</Text>}
          {move.map(item)}
          {go !== undefined && <Text dimColor>say go: babylon go {go} · go all, in a plain terminal</Text>}
        </Box>
        {section('Landing', landing, landing_more)}
        {section('Building', building, building_more)}
      </Box>
    )
  })
}
