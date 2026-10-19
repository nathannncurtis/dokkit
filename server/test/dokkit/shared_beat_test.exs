defmodule Dokkit.SharedBeatTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Alerts, SharedBeat}

  setup do
    test = self()

    Req.Test.stub(Alerts, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), body}
      )

      {status, answer} =
        case conn.method do
          "POST" ->
            {201, %{"url" => "https://beat.example.test/beat/t1", "token" => "t1", "key" => "k1"}}

          _ ->
            {204, nil}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, if(answer, do: Jason.encode!(answer), else: ""))
    end)

    :ok
  end

  test "needs an ntfy topic without a token, or a webhook, to send to" do
    assert {:error, "Set an ntfy topic" <> _} = SharedBeat.use()
    refute_received _

    {:ok, _, _} =
      Alerts.update(%{"ntfy_url" => "https://ntfy.example.test/topic", "ntfy_token" => "tk"})

    assert {:error, _} = SharedBeat.use()
  end

  test "gets a heartbeat, follows the ntfy topic, and stops" do
    {:ok, _, _} = Alerts.update(%{"ntfy_url" => "https://ntfy.example.test/topic"})
    assert {:ok, %{"url" => url}} = SharedBeat.use()
    assert_received {"POST", "/v1/beats", [], body}

    assert %{"kind" => "ntfy", "notify" => "https://ntfy.example.test/topic"} =
             Jason.decode!(body)

    assert Alerts.config()["heartbeat_url"] == url
    assert SharedBeat.current()["kind"] == "ntfy"

    {:ok, _, _} =
      Alerts.update(%{"ntfy_url" => "", "webhook_url" => "https://hooks.example.test/x"})

    assert_received {"PUT", "/v1/beats/t1", ["Bearer k1"], body}

    assert %{"kind" => "webhook", "notify" => "https://hooks.example.test/x"} =
             Jason.decode!(body)

    assert SharedBeat.current()["kind"] == "webhook"

    {:ok, _, _} = Alerts.update(%{"heartbeat_url" => "https://elsewhere.example.test/ping"})
    assert_received {"DELETE", "/v1/beats/t1", ["Bearer k1"], _}
    assert SharedBeat.current() == nil
    assert Alerts.config()["heartbeat_url"] == "https://elsewhere.example.test/ping"
  end

  test "the API uses and stops it" do
    {:ok, _, _} = Alerts.update(%{"webhook_url" => "https://hooks.example.test/x"})
    {admin, _} = Dokkit.Keys.mint(:user, %{scopes: ["admin"]})

    call = fn method ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> admin)
      |> dispatch(@endpoint, method, "/api/v1/alerts/heartbeat/shared", %{})
    end

    assert %{"heartbeat_url" => "https://beat.example.test/beat/t1", "kind" => "webhook"} =
             json_response(call.(:post), 200)

    assert %{"heartbeat_url" => nil} = json_response(call.(:delete), 200)
    assert Alerts.config()["heartbeat_url"] in [nil, ""]
  end
end
