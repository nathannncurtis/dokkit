defmodule Dokkit.IntakeLimitsTest do
  use DokkitWeb.ConnCase, async: false
  alias Dokkit.{Accounts, Envelope, Intake, Key, Keys, Machine, Releases, Repo}

  test "a report of a million short lines is refused without splitting them all" do
    parent = self()
    body = String.duplicate("x\n", 1_000_000)

    {_, ref} =
      :erlang.spawn_opt(
        fn -> send(parent, {:done, Intake.report(%Key{kind: :machine}, nil, body)}) end,
        [:monitor, max_heap_size: %{size: 1_000_000, kill: true, error_logger: false}]
      )

    assert_receive {:done, {:error, :too_large}}, 10_000
    assert_receive {:DOWN, ^ref, _, _, :normal}
  end

  test "an envelope gives at most 100 items" do
    event = Jason.encode!(%{exception: %{values: [%{type: "E", value: "m"}]}})
    text = "{}\n" <> String.duplicate(~s({"type":"event"}\n#{event}\n), 150)
    assert {nil, reports} = Envelope.read(text)
    assert length(reports) == 100
  end

  test "an envelope timestamp too large for a date keeps the report with no time" do
    event =
      Jason.encode!(%{exception: %{values: [%{type: "E", value: "m"}]}, timestamp: 1.0e308})

    assert {nil, [%{"at" => nil, "type" => "E"}]} =
             Envelope.read(~s({}\n{"type":"event"}\n#{event}\n))
  end

  test "a late result for an older version leaves a newer wanted version alone" do
    m = Repo.insert!(%Machine{name: "late-result", wanted_version: "v1.2.4"})

    assert Releases.result(m.id, %{"version" => "v1.2.3", "ok" => true}) == :ok
    assert %{wanted_version: "v1.2.4", update_version: "v1.2.3"} = Repo.get!(Machine, m.id)

    assert Releases.result(m.id, %{"version" => "v1.2.4", "ok" => true}) == :ok
    assert %{wanted_version: nil} = Repo.get!(Machine, m.id)
  end

  test "enrolling a host named like a group is refused and leaves the group alone" do
    group = Repo.insert!(%Machine{name: "Apps", kind: :group})
    {token, _} = Keys.mint_enrol(nil)

    assert Intake.enrol(token, %{"hostname" => "Apps"}) == {:error, :taken}
    assert %{kind: :group} = Repo.get!(Machine, group.id)
  end

  test "behind a proxy, X-Forwarded-For from a host that is not the proxy is ignored", %{
    conn: conn
  } do
    Application.put_env(:dokkit, :behind_proxy, true)
    on_exit(fn -> Application.delete_env(:dokkit, :behind_proxy) end)
    {:ok, _} = Accounts.add("spoof-sam", "member", "correct horse battery")
    conn = Map.put(conn, :remote_ip, {10, 0, 0, 40})

    for n <- 1..10 do
      spoofed = put_req_header(conn, "x-forwarded-for", "10.9.9.#{n}")
      assert response(post(spoofed, "/login", %{name: "spoof-sam", password: "no"}), 401)
    end

    spoofed = put_req_header(conn, "x-forwarded-for", "10.9.9.99")
    assert response(post(spoofed, "/login", %{name: "spoof-sam", password: "no"}), 429)
  end
end
