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
    - Finished: update_ticket to done. Stopping short: write where it stands into its body, then release_ticket so another session can pick it up.
    - Work that has to wait on other work: file it with blocked_by, or link_tickets with blocks. A blocked ticket cannot be claimed.
    - list_tickets with mine shows what this session holds; with repo, one repo's tickets.
    """,
    protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  component(Babylon.MCP.Tools.FileTicket, name: "file_ticket")
  component(Babylon.MCP.Tools.ListTickets, name: "list_tickets")
  component(Babylon.MCP.Tools.GetTicket, name: "get_ticket")
  component(Babylon.MCP.Tools.UpdateTicket, name: "update_ticket")
  component(Babylon.MCP.Tools.LinkTickets, name: "link_tickets")
  component(Babylon.MCP.Tools.UnlinkTickets, name: "unlink_tickets")
  component(Babylon.MCP.Tools.ClaimTicket, name: "claim_ticket")
  component(Babylon.MCP.Tools.ReleaseTicket, name: "release_ticket")
end
