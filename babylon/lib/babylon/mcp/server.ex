defmodule Babylon.MCP.Server do
  @moduledoc """
  babylon's MCP server, served on loopback with no authorization: on a one-person machine a local
  process can already reach the database, so a token would guard nothing.
  """
  use Anubis.Server,
    name: "babylon",
    version: "0.1.0",
    capabilities: [:tools],
    protocol_versions: ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

  component(Babylon.MCP.Tools.FileTicket, name: "file_ticket")
  component(Babylon.MCP.Tools.ListTickets, name: "list_tickets")
  component(Babylon.MCP.Tools.GetTicket, name: "get_ticket")
  component(Babylon.MCP.Tools.UpdateTicket, name: "update_ticket")
  component(Babylon.MCP.Tools.LinkTickets, name: "link_tickets")
  component(Babylon.MCP.Tools.UnlinkTickets, name: "unlink_tickets")
end
