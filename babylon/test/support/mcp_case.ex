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

  @doc """
  Call `tool` with `args` from tmux pane `pane` (nil sends no pane): `{:ok, decoded}` from the
  tool's JSON, or `{:error, message}` for a refusal.
  """
  @spec call(String.t(), map(), String.t() | nil) :: {:ok, term()} | {:error, String.t()}
  def call(tool, args, pane \\ nil) do
    headers = [{"mcp-name", tool}] ++ if(pane, do: [{"x-babylon-pane", pane}], else: [])

    case rpc("tools/call", %{name: tool, arguments: args}, headers) do
      %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} -> {:error, message}
      %{"result" => %{"content" => [%{"text" => text}]}} -> {:ok, JSON.decode!(text)}
      other -> flunk("not a tool result: #{inspect(other)}")
    end
  end

  @doc "Send one stateless JSON-RPC request for `method` and return the decoded reply."
  @spec rpc(String.t(), map(), [{String.t(), String.t()}]) :: map()
  def rpc(method, params, headers \\ []) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    body = %{jsonrpc: "2.0", id: 1, method: method, params: Map.put(params, :_meta, meta)}

    conn =
      Enum.reduce(
        [{"mcp-protocol-version", @version}, {"mcp-method", method} | headers],
        :post
        |> conn("/", JSON.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream"),
        fn {key, value}, conn -> put_req_header(conn, key, value) end
      )
      |> Transport.call(Transport.init(server: Babylon.MCP.Server))

    JSON.decode!(conn.resp_body)
  end
end
