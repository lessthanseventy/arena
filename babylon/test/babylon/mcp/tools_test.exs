defmodule Babylon.MCP.ToolsTest do
  use Babylon.MCPCase

  test "a session learns when to file and claim from the server's instructions" do
    assert %{"result" => %{"instructions" => instructions}} = rpc("server/discover", %{})
    assert instructions =~ "claim_ticket"
  end

  test "file, list, get, update and link, through the HTTP plug" do
    assert {:ok, %{"id" => blocker, "status" => "backlog", "repo" => "arena"}} =
             call("file_ticket", %{title: "blocker", repo: "arena"})

    assert {:ok, %{"id" => blocked}} =
             call("file_ticket", %{title: "blocked", repo: "arena", blocked_by: [blocker], priority: "high"})

    assert {:ok, %{"id" => _}} = call("file_ticket", %{title: "elsewhere", repo: "tlon"})

    assert {:ok, [%{"title" => "blocker"}, %{"title" => "blocked"}]} = call("list_tickets", %{repo: "arena"})

    assert {:ok, %{"blocked_by" => [^blocker], "links" => [%{"kind" => "blocks", "direction" => "in"}]}} =
             call("get_ticket", %{id: blocked})

    assert {:ok, %{"status" => "done"}} = call("update_ticket", %{id: blocker, status: "done"})
    assert {:ok, %{"blocked_by" => []}} = call("get_ticket", %{id: blocked})

    assert {:ok, []} = call("unlink_tickets", %{from: blocker, to: blocked, kind: "blocks"})
    assert {:ok, [%{"kind" => "relates"}]} = call("link_tickets", %{from: blocker, to: blocked, kind: "relates"})
  end

  test "a claim is held by the calling pane, and refused without one" do
    {:ok, %{"id" => id}} = call("file_ticket", %{title: "Claim me"})

    assert {:error, "this session sent no pane" <> _} = call("claim_ticket", %{id: id})

    assert {:ok, %{"status" => "doing", "claimed_by" => "%9", "start" => start}} =
             call("claim_ticket", %{id: id}, "%9")

    assert start == "wt switch --create t#{id}-claim-me"
    assert {:ok, [%{"id" => ^id}]} = call("list_tickets", %{mine: true}, "%9")
    assert {:ok, []} = call("list_tickets", %{mine: true}, "%8")

    assert {:ok, %{"status" => "todo", "claimed_by" => nil}} = call("release_ticket", %{id: id}, "%9")
  end

  test "refusals come back as one sentence" do
    assert {:error, "no ticket #0"} = call("get_ticket", %{id: 0})
    assert {:ok, %{"id" => id}} = call("file_ticket", %{title: "t"})
    assert {:error, "to_id a ticket cannot link to itself"} = call("link_tickets", %{from: id, to: id, kind: "relates"})
  end
end
