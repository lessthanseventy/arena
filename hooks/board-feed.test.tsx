import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'arena',
  component: 'Pane',
  requestId: 'board-feed',
  surface: 'terminal',
  props: {
    title: 'Board',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const NOW = Date.parse('2026-11-21T12:00:00Z')

const card = (id: number, title: string, status: string, rest: object = {}) => ({
  id,
  title,
  status,
  repo: 'arena',
  claimed_by: null,
  stage: null,
  ask: null,
  ...rest,
})

const BOARD = {
  tickets: [
    card(7, 'A todo card', 'todo'),
    card(12, 'The rail draws twice', 'doing', {
      claimed_by: '%4',
      stage: 'failed',
      stage_note: 'the gate is red: e2e timed out\nmore of the log',
    }),
    card(14, 'A pane for the board', 'doing', { claimed_by: '%5', claimed_at: '2026-11-21T10:00:00Z' }),
    card(15, 'Keys under a box', 'review', {
      claimed_by: '%6',
      claimed_at: '2026-11-21T11:00:00Z',
      stage: 'verifying',
    }),
    card(16, 'Which colour is the rail', 'doing', {
      claimed_by: '%9',
      claimed_at: '2026-11-21T09:00:00Z',
      ask: { id: 3, question: 'Blue or green?', options: ['Blue', 'Green'], asked_at: '2026-11-21T11:48:00Z' },
    }),
    card(9, 'The strip keeps its width', 'done', { stage: 'landed', closed_at: '2026-11-21T09:00:00Z' }),
    card(8, 'An older landing', 'done', { stage: 'landed', closed_at: '2026-11-21T08:00:00Z' }),
  ],
}

// a board of `null` is a read that fails
type Start = { session: string; boards: Array<object | null> }

// The world an orchestrator's Claude starts in: tmux, the board file, and a watcher that
// reports one change of the file each time `change` is called.
const world = (on: Parameters<Parameters<typeof test>[1]>[1], { session, boards }: Start) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { TMUX_PANE: '%1', XDG_RUNTIME_DIR: '/run/user/1000' })

  const opened: string[] = []
  const read: string[] = []
  const changes: Array<() => void> = []
  let board = 0

  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.open', (_, e) => {
    opened.push(e.id)

    return { value: { isPlaced: true } }
  })
  on('fs.read', (_, e) => {
    read.push(e.path)

    const now = boards[Math.min(board, boards.length - 1)]
    if (now === null) throw new Error('ENOENT')

    return { value: JSON.stringify(now) }
  })
  on('process.run', (_, e) => ({
    value: {
      exitCode: 0,
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
      stdout: e.argv.includes('display-message')
        ? `${session}\n`
        : '%4 claudes:rail\n%5 claudes:t14-a-pane\n%6 claudes:keys\n',
    },
  }))
  on('process.spawn', async function* () {
    yield { stream: 'stderr' as const, text: 'Setting up watches.\nWatches established.\n' }
    for (;;) {
      await new Promise<void>(done => changes.push(done))
      board += 1
      yield { stream: 'stdout' as const, text: 'board.json.new\nboard.json\n' }
    }
  })

  return { clock, opened, read, change: () => changes.shift()?.() }
}

test('in the orchestrator, the pane shows asks, send-backs, work and landings', async ($, on) => {
  const { opened, read } = world(on, { session: 'orchestrator', boards: [BOARD] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(opened).toEqual(['board-feed'])
  expect(read[0]).toBe('/run/user/1000/babylon/board.json')

  const ui = await $.ui.mount(PANE)
  const row = async (text: RegExp) => (await ui.find({ type: 'Text', text }))?.text

  expect(await row(/#16 asks/)).toBe('#16 asks 12m Blue or green?')
  expect(await row(/#12/)).toBe('#12 sent back the gate is red: e2e timed out')
  expect(await row(/#14/)).toBe('#14 doing claudes:t14-a-pane A pane for the board')
  expect(await row(/#15/)).toBe('#15 review verifying claudes:keys Keys under a box')
  expect(await row(/#16 doing/)).toBe('#16 doing %9 Which colour is the rail')
  expect(await row(/#9/)).toBe('#9 landed 3h The strip keeps its width')
  expect(await row(/#7/)).toBe(undefined)

  const all = await ui.findAll({ type: 'Text', text: /^#/ })
  expect(all.map(one => one.text?.split(' ')[0])).toEqual(['#16', '#12', '#15', '#14', '#16', '#9', '#8'])
  await ui.unmount()
})

test('the pane is drawn again when the board file changes, and a wait grows by the minute', async ($, on) => {
  const landed = { tickets: [card(14, 'A pane for the board', 'done', { stage: 'landed', closed_at: '2026-11-21T12:00:00Z' })] }
  const { clock, read, change } = world(on, { session: 'orchestrator', boards: [BOARD, landed] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  await clock.advance(60_000)
  expect((await ui.find({ type: 'Text', text: /#16 asks/ }))?.text).toBe('#16 asks 13m Blue or green?')
  expect(read.length).toBe(2)

  change()
  await clock.settle()
  expect(read.length).toBe(3)
  expect((await ui.find({ type: 'Text', text: /#14/ }))?.text).toBe('#14 landed 1m A pane for the board')
  expect(await ui.find({ type: 'Text', text: /#16/ })).toBe(undefined)
  await ui.unmount()
})

test('a read of the board that fails leaves the pane as it was, and the next change is read', async ($, on) => {
  const landed = { tickets: [card(14, 'A pane for the board', 'done', { stage: 'landed' })] }
  const { clock, change } = world(on, { session: 'orchestrator', boards: [BOARD, null, landed] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  change()
  await clock.settle()
  expect((await ui.find({ type: 'Text', text: /#14/ }))?.text).toBe('#14 doing claudes:t14-a-pane A pane for the board')

  change()
  await clock.settle()
  expect((await ui.find({ type: 'Text', text: /#14/ }))?.text).toBe('#14 landed A pane for the board')
  await ui.unmount()
})

test('any other Claude gets no pane and reads no board', async ($, on) => {
  const { opened, read } = world(on, { session: 'claudes', boards: [BOARD] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  expect(opened).toEqual([])
  expect(read).toEqual([])
})
