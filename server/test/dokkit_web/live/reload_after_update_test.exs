defmodule DokkitWeb.ReloadAfterUpdateTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    config = Application.get_env(:dokkit, DokkitWeb.Endpoint)
    latest = %{"css/dokkit.css" => "css/dokkit-new.css"}
    change = &DokkitWeb.Endpoint.config_change([{DokkitWeb.Endpoint, &1}], [])
    change.(Keyword.put(config, :cache_static_manifest_latest, latest))
    on_exit(fn -> change.(config) end)
    %{conn: signed_in(conn)}
  end

  test "a page from before the update reloads itself", %{conn: conn} do
    conn = put_connect_params(conn, %{"_track_static" => ["http://localhost/css/dokkit-old.css"]})
    assert {:error, {:redirect, %{to: "http://www.example.com/"}}} = live(conn, "/")
  end

  test "a page from this build stays", %{conn: conn} do
    conn = put_connect_params(conn, %{"_track_static" => ["http://localhost/css/dokkit-new.css"]})
    assert {:ok, _, _} = live(conn, "/")
  end
end
