defmodule Babylon.MCP.Server do
  @moduledoc """
  babylon's MCP server, served on loopback with no authorization: on a one-person machine a local
  process can already reach the database, so a token would guard nothing.
  """
  use Anubis.Server,
    name: "babylon",
    version: "0.1.0",
    capabilities: [:tools],
    instructions: """
    babylon holds the tickets every Claude session on this machine shares, across repos.

    - Work you notice but will not do now (a follow-up, a bug outside the task, a plan's next step): file_ticket it with its repo, rather than leaving it in chat.
    - Before working a ticket, claim_ticket it. The claim belongs to this session's tmux pane for as long as the session runs; run the `start` command its answer gives, which puts you on the ticket's own branch with wt.
    - While working, run only the tests of what you change; do not run the repo's whole gate (`mise run check`) yourself: submit_ticket is the gate, run once by babylon, so you do not wait on it.
    - Finished: commit the work on the ticket's branch, then submit_ticket. babylon rebases it onto main, runs the repo's gate, has it reviewed and lands it on main, and tells this session how it went (see inbox): landed (the ticket is done) or sent back with why. Work with nothing to land: update_ticket to done. Stopping short: write where it stands into its body, then release_ticket so another session can pick it up.
    - A decision about a ticket you need from your human: ask_human with the options; it shows on their board, and the answer comes to this session's inbox.
    - A decision your human makes about a ticket (an approval, a choice, a rescope), in chat or as an ask's answer: write it into the ticket's body then. babylon's review reads the ticket, never your chat.
    - A line typed into this session starting `babylon:` is babylon's word to it (a landing, a send-back, an answer): act on what it says. inbox reads any still held.
    - Work that has to wait on other work: file it with blocked_by, or link_tickets with blocks. A blocked ticket cannot be claimed.
    - list_tickets with mine shows what this session holds; with repo, one repo's tickets.
    - Work that touches another session or repo, a question of what should go next, or being stuck on another session: message the orchestrator (SendMessage to `orchestrator`, the standing Claude over every session and the board); it files and links the tickets. Your own follow-ups you still file yourself.
    """,
    protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  component(Babylon.MCP.Tools.FileTicket, name: "file_ticket")
  component(Babylon.MCP.Tools.ListTickets, name: "list_tickets")
  component(Babylon.MCP.Tools.GetTicket, name: "get_ticket")
  component(Babylon.MCP.Tools.UpdateTicket, name: "update_ticket")
  component(Babylon.MCP.Tools.MoveTicket, name: "move_ticket")
  component(Babylon.MCP.Tools.LinkTickets, name: "link_tickets")
  component(Babylon.MCP.Tools.UnlinkTickets, name: "unlink_tickets")
  component(Babylon.MCP.Tools.ClaimTicket, name: "claim_ticket")
  component(Babylon.MCP.Tools.ReleaseTicket, name: "release_ticket")
  component(Babylon.MCP.Tools.SubmitTicket, name: "submit_ticket")
  component(Babylon.MCP.Tools.BumpTicket, name: "bump_ticket")
  component(Babylon.MCP.Tools.AskHuman, name: "ask_human")
  component(Babylon.MCP.Tools.AnswerAsk, name: "answer_ask")
  component(Babylon.MCP.Tools.Inbox, name: "inbox")
end
