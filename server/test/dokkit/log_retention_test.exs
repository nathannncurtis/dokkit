defmodule Dokkit.LogRetentionTest do
  # Not async: dropping a month locks the whole logs table.
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Log, Logs, Machine, Repo}

  @today ~D[2026-10-06]
  @months [
    ~U[2026-05-15 10:00:00.000000Z],
    ~U[2026-06-15 10:00:00.000000Z],
    ~U[2026-07-15 10:00:00.000000Z]
  ]

  setup do
    machine = Repo.insert!(%Machine{name: "ret-#{System.unique_integer([:positive])}"})

    for at <- @months do
      Logs.ensure_partition(at)

      Repo.insert_all(Log, [
        %{
          at: at,
          received_at: at,
          level: "info",
          msg: "m",
          fields: %{},
          cut: false,
          machine_id: machine.id
        }
      ])
    end

    on_exit(fn ->
      for at <- @months, do: :persistent_term.erase({Logs, {at.year, at.month}})
    end)
  end

  defp names, do: for({_, y, m} <- Logs.months(), do: "#{y}-#{m}")

  test "twelve months and archive until changed" do
    assert Logs.retention() == %{"months" => 12, "action" => "archive"}
    assert {:ok, %{"months" => 3}} = Logs.save_retention(%{"months" => "3"})
    assert Logs.retention() == %{"months" => 3, "action" => "archive"}
  end

  @tag :tmp_dir
  test "three months archive the older ones and keep the rest", %{tmp_dir: dir} do
    {:ok, _} = Logs.save_retention(%{"months" => 3})
    files = Logs.archive(dir, @today)

    assert Enum.map(files, &Path.basename/1) == [
             "logs-2026-05.ndjson.gz",
             "logs-2026-06.ndjson.gz"
           ]

    assert "2026-07" in names()
    refute "2026-05" in names()
  end

  @tag :tmp_dir
  test "three months delete the older ones and write no file", %{tmp_dir: dir} do
    {:ok, _} = Logs.save_retention(%{"months" => 3, "action" => "delete", "confirm" => true})
    assert length(Logs.archive(dir, @today)) == 2
    assert File.ls!(dir) == [] or not File.exists?(dir)
    assert "2026-07" in names()
    refute "2026-06" in names()
  end

  @tag :tmp_dir
  test "delete leaves archive files already there loadable", %{tmp_dir: dir} do
    {:ok, _} = Logs.save_retention(%{"months" => 3})
    [path | _] = Logs.archive(dir, @today)
    {:ok, _} = Logs.save_retention(%{"action" => "delete", "confirm" => "true"})
    assert File.exists?(path)
    assert Logs.restore(path) == 1
  end

  test "the limit is 1 to 120 and deleting needs the confirmation" do
    for bad <- [0, 121, "x", "3.5", nil, 2.5],
        do: assert({:error, _} = Logs.save_retention(%{"months" => bad}))

    assert {:ok, _} = Logs.save_retention(%{"months" => 1})
    assert {:ok, _} = Logs.save_retention(%{"months" => "120"})
    assert {:error, _} = Logs.save_retention(%{"action" => "delete"})
    assert {:error, _} = Logs.save_retention(%{"action" => "delete", "confirm" => "false"})
    assert {:error, _} = Logs.save_retention(%{"action" => "burn"})
    assert Logs.retention()["action"] == "archive"
  end

  test "Settings shows the section, says what saving does, and saves", %{conn: conn} do
    {:ok, view, html} = live(signed_in(conn), "/settings")
    assert html =~ "Months that stay live"
    assert html =~ "can still be loaded back"

    html = view |> form("#log-retention form", retention: %{months: "2"}) |> render_change()
    assert html =~ "oldest months will be archived on the next sweep"

    html =
      view
      |> form("#log-retention form", retention: %{months: "2", action: "delete"})
      |> render_change()

    assert html =~ "deleted on the next sweep"
    assert html =~ "I understand old logs will be deleted, not archived"

    html =
      view
      |> form("#log-retention form", retention: %{months: "2", action: "delete"})
      |> render_submit()

    assert html =~ "Deleting old logs needs confirm"
    assert Logs.retention()["action"] == "archive"

    view
    |> form("#log-retention form", retention: %{months: "2", action: "delete", confirm: "true"})
    |> render_submit()

    assert Logs.retention() == %{"months" => 2, "action" => "delete"}
  end

  describe "the API" do
    defp call(method, token, body \\ %{}) do
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> dispatch(@endpoint, method, "/api/v1/logs/retention", body)
    end

    test "needs admin, validates, and round-trips" do
      {admin, _} = Keys.mint(:user, %{scopes: ["admin"]})
      {logs, _} = Keys.mint(:user, %{scopes: ["read", "read-logs", "act"]})

      assert json_response(call(:get, logs), 403)["error"]["code"] == "no_scope"
      assert json_response(call(:put, logs, %{months: 3}), 403)["error"]["code"] == "no_scope"

      assert %{"months" => 12, "action" => "archive", "older" => _} =
               json_response(call(:get, admin), 200)

      assert json_response(call(:put, admin, %{months: 500}), 422)["error"]["code"] ==
               "bad_settings"

      assert json_response(call(:put, admin, %{action: "delete"}), 422)["error"]["code"] ==
               "bad_settings"

      assert %{"months" => 3, "action" => "delete"} =
               json_response(
                 call(:put, admin, %{months: 3, action: "delete", confirm: true}),
                 200
               )

      assert %{"months" => 3, "action" => "delete"} = json_response(call(:get, admin), 200)
    end
  end
end
