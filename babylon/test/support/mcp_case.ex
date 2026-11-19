defmodule Babylon.MCPCase do
  @moduledoc "Calls a tool as the CLI does: one stateless tools/call through the HTTP plug."
  use ExUnit.CaseTemplate

  import Plug.Conn
  import Plug.Test

  alias Anubis.Server.Transport.StreamableHTTP.Plug, as: Transport
  alias Ecto.Adapters.SQL.Sandbox

  @version "2026-07-28"

  using do
    quote do
      import Babylon.MCPCase
    end
  end

  setup do
    pid = Sandbox.start_owner!(Babylon.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Call `tool` with `args`: `{:ok, decoded}` from the tool's JSON, or `{:error, message}` for a refusal."
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def call(tool, args) do
    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: %{
        name: tool,
        arguments: args,
        _meta: %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn =
      :post
      |> conn("/", JSON.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", tool)
      |> Transport.call(Transport.init(server: Babylon.MCP.Server))

    case JSON.decode!(conn.resp_body) do
      %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} -> {:error, message}
      %{"result" => %{"content" => [%{"text" => text}]}} -> {:ok, JSON.decode!(text)}
      other -> flunk("not a tool result: #{inspect(other)}")
    end
  end
end
