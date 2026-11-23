export type Tone = 'move' | 'failed' | 'running' | 'queued' | 'plain'

export type Row = {
  label: string
  pre?: string
  repo: string
  mid: string
  text: string
  why?: string
  todo?: string
  at?: number
  tone: Tone
}

export type Feed = {
  move: Row[]
  landing: Row[]
  building: Row[]
  landing_more: number
  building_more: number
  status: string
  go?: number
}

declare module 'claude-code' {
  interface PluginState {
    arena: { feed: Shaped<Feed>; now: number }
  }
}
