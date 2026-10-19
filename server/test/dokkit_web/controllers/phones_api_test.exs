defmodule DokkitWeb.PhonesApiTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.Keys

  @mailbox "92bea4d52a1d53f0c8111edf39e26a89"
  @upload_key "dkr_729nLrMYIgy8I0YoubM6pyvho0c71L4IJO9Y"

  setup do
    Req.Test.stub(Dokkit.Alerts, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"ok":true,"slots":{}}))
    end)

    {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
    {act, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act"]})
    %{admin: admin, act: act}
  end

  defp call(method, path, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  test "only admin may use any of it", %{act: act} do
    for {method, path} <- [
          get: "/phones",
          post: "/phones",
          get: "/phones/relay",
          put: "/phones/relay",
          post: "/phones/relay/shared",
          delete: "/phones/x"
        ] do
      assert %{"error" => %{"code" => "no_scope"}} = json_response(call(method, path, act), 403)
    end
  end

  test "the relay is saved, uploaded once, and its key is only ever set or not set", %{
    admin: admin
  } do
    assert %{"key" => "not set", "address" => ""} =
             json_response(call(:get, "/phones/relay", admin), 200)

    assert %{"code" => "bad_relay"} =
             json_response(
               call(:put, "/phones/relay", admin, %{"address" => "http://x.example.test"}),
               422
             )["error"]

    body = %{
      "address" => "https://relay.example.test",
      "mailbox" => @mailbox,
      "key" => @upload_key
    }

    saved = json_response(call(:put, "/phones/relay", admin, body), 200)
    assert saved["key"] == "set"
    assert saved["mailbox"] == @mailbox
    assert saved["uploaded"]
    assert saved["result"] =~ "took"
    refute Jason.encode!(saved) =~ @upload_key

    refute json_response(call(:get, "/phones/relay", admin), 200) |> Jason.encode!() =~
             @upload_key
  end

  test "a phone is added with its code once, listed without it, and removed", %{admin: admin} do
    assert %{"error" => %{"code" => "bad_phone"}} =
             json_response(call(:post, "/phones", admin, %{"name" => "Work"}), 422)

    body = %{
      "address" => "https://relay.example.test",
      "mailbox" => @mailbox,
      "key" => @upload_key
    }

    call(:put, "/phones/relay", admin, body)

    assert %{"error" => %{"code" => "bad_phone"}} =
             json_response(call(:post, "/phones", admin, %{"name" => " "}), 422)

    made = json_response(call(:post, "/phones", admin, %{"name" => "Work iPhone"}), 200)
    assert "dokkit-phone:1:" <> _ = made["code"]

    assert %{"items" => [listed], "next" => nil} =
             json_response(call(:get, "/phones", admin), 200)

    assert listed["id"] == made["id"]
    assert listed["name"] == "Work iPhone"
    refute Map.has_key?(listed, "code")
    refute Jason.encode!(listed) =~ "key"

    assert %{"ok" => true} = json_response(call(:delete, "/phones/#{made["id"]}", admin), 200)
    assert %{"items" => []} = json_response(call(:get, "/phones", admin), 200)
    assert json_response(call(:delete, "/phones/#{made["id"]}", admin), 404)
  end
end
