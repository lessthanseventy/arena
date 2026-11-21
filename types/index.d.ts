export type Row = { id: number; lead: string; text: string; at?: number }

export type Feed = { asks: Row[]; sentBack: Row[]; running: Row[]; landed: Row[] }

declare module 'claude-code' {
  interface PluginState {
    arena: { feed: Shaped<Feed>; now: number }
  }
}
