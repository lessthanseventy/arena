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
  auto: { on: true, working: 3, cap: 4 },
  hold: false,
  proposals: [{ id: 4, action: 'start', ticket_id: 7, what: 'Start #7: A todo card', why: 'Next in line\nmore' }],
  tickets: [
    card(7, 'A todo card', 'todo'),
    card(12, 'The rail draws twice', 'doing', {
      stage: 'failed',
      stage_note: 'the gate is red: e2e timed out\nmore of the log',
    }),
    card(360, 'Released after a send-back', 'todo', { repo: 'ficciones', stage: 'failed', stage_note: 'needs the human' }),
    card(14, 'A pane for the board', 'doing', { claimed_at: '2026-11-21T10:00:00Z' }),
    card(495, 'Held after a send-back', 'doing', {
      claimed_by: '%610',
      claimed_at: '2026-11-21T11:00:00Z',
      stage: 'failed',
      stage_note: 'red',
    }),
    card(361, 'The blocker', 'doing', { claimed_at: '2026-11-21T11:10:00Z' }),
    card(362, 'Blocked after a send-back', 'todo', { stage: 'failed', stage_note: 'red', blocked_by: [361, 6] }),
    card(15, 'Keys under a box', 'review', { claimed_at: '2026-11-21T09:00:00Z', stage: 'verifying' }),
    card(17, 'Queued later', 'review', { submitted_at: '2026-11-21T11:30:00Z' }),
    card(18, 'Queued first', 'review', { repo: 'tlon', submitted_at: '2026-11-21T11:10:00Z' }),
    card(16, 'Which colour is the rail', 'doing', {
      claimed_at: '2026-11-21T09:00:00Z',
      ask: { id: 3, question: 'Blue or green?\nmore', options: ['Blue', 'Green'], asked_at: '2026-11-21T11:48:00Z' },
    }),
    card(20, 'An epic', 'doing', { kind: 'epic' }),
    card(9, 'Landed today', 'done', { stage: 'landed', closed_at: '2026-11-21T11:30:00Z' }),
    card(8, 'Landed long ago', 'done', { stage: 'landed', closed_at: '2026-11-19T08:00:00Z' }),
    card(6, 'Failed and done', 'done', { stage: 'failed' }),
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

test('in the orchestrator, the pane shows what needs the human, then landing and building', async ($, on) => {
  const { opened, read } = world(on, { session: 'orchestrator', boards: [BOARD] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(opened).toEqual(['board-feed'])
  expect(read[0]).toBe('/run/user/1000/babylon/board.json')

  const ui = await $.ui.mount(PANE)
  const row = async (text: RegExp) => (await ui.find({ type: 'Text', text }))?.text

  expect(await row(/auto/)).toBe('auto 3/4 · hold off · landed today 1')
  expect(await row(/^P4/)).toBe('P4 start #7 arena · A todo card — Next in line → go/no on its card')
  expect(await row(/^#16 arena · ask/)).toBe(
    '#16 arena · ask 12m · Blue or green? → answer: tell the orchestrator, or 1–N on the board',
  )
  expect(await row(/^#12/)).toBe('#12 arena · sent back · the gate is red: e2e timed out → the orchestrator will propose')
  expect(await row(/^#360/)).toBe('#360 ficciones · sent back · needs the human → the orchestrator will propose')
  expect(await row(/^#495/)).toBe('#495 arena · ✗ fixing after send-back · Held after a send-back')
  expect(await row(/^#362/)).toBe('#362 arena · ✗ waits on #361 · Blocked after a send-back')
  expect(await row(/^#15/)).toBe('#15 arena · verifying · Keys under a box')
  expect(await row(/^#18/)).toBe('#18 tlon · queued 2nd · Queued first')
  expect(await row(/^#17/)).toBe('#17 arena · queued 3rd · Queued later')
  expect(await row(/^#14/)).toBe('#14 arena · 2h · A pane for the board')
  expect(await row(/say go/)).toBe('say go: babylon go 4 · go all, in a plain terminal')
  expect(await row(/^#20/)).toBe(undefined)
  expect(await row(/^#6 /)).toBe(undefined)

  const all = await ui.findAll({ type: 'Text', text: /^[#P]\d+ / })
  expect(all.map(one => one.text?.split(' ')[0])).toEqual([
    'P4',
    '#16',
    '#12',
    '#360',
    '#15',
    '#18',
    '#17',
    '#362',
    '#14',
    '#495',
    '#361',
  ])
  await ui.unmount()
})

test('an empty board says nothing needs the human', async ($, on) => {
  world(on, { session: 'orchestrator', boards: [{ tickets: [card(7, 'A todo card', 'todo')] }] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  expect(await ui.find({ type: 'Text', text: 'nothing needs you' })).toBeTruthy()
  expect(await ui.find({ type: 'Text', text: /say go/ })).toBe(undefined)
  await ui.unmount()
})

test('landing and building show five rows each, then how many more', async ($, on) => {
  const many = Array.from({ length: 7 }, (_, i) => i)
  const board = {
    tickets: [
      ...many.map(i => card(100 + i, `Building ${i}`, 'doing', { claimed_at: `2026-11-21T10:0${i}:00Z` })),
      ...many.map(i => card(200 + i, `Landing ${i}`, 'review', { submitted_at: `2026-11-21T11:0${i}:00Z` })),
    ],
  }
  world(on, { session: 'orchestrator', boards: [board] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  expect((await ui.findAll({ type: 'Text', text: /^#1\d\d / })).length).toBe(5)
  expect((await ui.findAll({ type: 'Text', text: /^#2\d\d / })).length).toBe(5)
  expect((await ui.findAll({ type: 'Text', text: '+2 more' })).length).toBe(2)
  await ui.unmount()
})

test('the pane is drawn again when the board file changes, and a wait grows by the minute', async ($, on) => {
  const landed = { tickets: [card(14, 'A pane for the board', 'done', { stage: 'landed', closed_at: '2026-11-21T12:00:00Z' })] }
  const { clock, read, change } = world(on, { session: 'orchestrator', boards: [BOARD, landed] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  await clock.advance(60_000)
  expect((await ui.find({ type: 'Text', text: /^#16/ }))?.text).toBe(
    '#16 arena · ask 13m · Blue or green? → answer: tell the orchestrator, or 1–N on the board',
  )
  expect(read.length).toBe(2)

  change()
  await clock.settle()
  expect(read.length).toBe(3)
  expect(await ui.find({ type: 'Text', text: /^#16/ })).toBe(undefined)
  expect((await ui.find({ type: 'Text', text: /landed today/ }))?.text).toBe('auto off · hold off · landed today 1')
  await ui.unmount()
})

test('a read of the board that fails leaves the pane as it was, and the next change is read', async ($, on) => {
  const landed = { tickets: [card(14, 'A pane for the board', 'done', { stage: 'landed' })] }
  const { clock, change } = world(on, { session: 'orchestrator', boards: [BOARD, null, landed] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const ui = await $.ui.mount(PANE)

  change()
  await clock.settle()
  expect((await ui.find({ type: 'Text', text: /^#14/ }))?.text).toBe('#14 arena · 2h · A pane for the board')

  change()
  await clock.settle()
  expect(await ui.find({ type: 'Text', text: /^#14/ })).toBe(undefined)
  await ui.unmount()
})

test('any other Claude gets no pane and reads no board', async ($, on) => {
  const { opened, read } = world(on, { session: 'claudes', boards: [BOARD] })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  expect(opened).toEqual([])
  expect(read).toEqual([])
})
