defmodule Dokkit.NumbersTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Issues, Keys, Machine, Read, Repo, Service}

  test "metrics are kept and charted, a threshold opens an issue, and stats are read", %{
    conn: conn
  } do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})
    {mkey, _} = Keys.mint(:machine, %{machine_id: machine.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> mkey)

    doc = %{
      schema: 1,
      service: %{id: "portal", name: "Upload portal"},
      check: [%{type: "threshold", name: "disk", metric: "disk.used_percent.C", limit: 90}]
    }

    assert %{"service" => id} = json_response(put(as, "/api/v1/declare", doc), 200)

    answer =
      report(mkey, [
        %{type: "metric", name: "cpu.percent", value: 93.4},
        %{type: "metric", name: "disk.used_percent.C", value: 95},
        %{type: "metric", name: "queue.depth", value: 4, service: "portal"},
        %{type: "metric", name: "nope"},
        %{
          type: "stats",
          service: "portal",
          document: %{
            schema: 1,
            version: "2.3.0",
            requests: %{"5m" => %{per_minute: 12.5, error_rate: 0.02, p95_ms: 250}}
          }
        },
        %{type: "stats", service: "portal", document: %{schema: 9}}
      ])

    assert %{"accepted" => 4, "refused" => [%{"line" => 4}, %{"line" => 6}]} =
             json_response(answer, 200)

    # Like any check, a threshold has to fail three times in a row.
    assert Issues.open_list() == []
    over = %{type: "metric", name: "disk.used_percent.C", value: 95}
    report(mkey, [over, over])
    assert [%{title: title}] = Issues.open_list()
    assert title =~ "disk"
    under = %{type: "metric", name: "disk.used_percent.C", value: 80}
    report(mkey, [under, under, under])
    assert Issues.open_list() == []

    assert Repo.get!(Service, id).version == "2.3.0"
    assert [%{vitals: %{"cpu.percent" => 93.4}}] = Read.machines()

    assert %{
             metrics: [
               "queue.depth",
               "requests.error_rate",
               "requests.p95_ms",
               "requests.per_minute"
             ]
           } =
             Read.series(id, %{})

    assert %{points: points} = Read.series(id, %{"metric" => "queue.depth", "points" => "4"})
    assert [nil, nil, nil, 4.0] = Enum.map(points, & &1.value)

    conn = signed_in(conn)
    {:ok, _, html} = live(conn, "/s/#{id}")
    assert html =~ "requests.p95_ms"
    assert html =~ "<rect"
    {:ok, _, html} = live(conn, "/all")
    assert html =~ "cpu"
    assert html =~ "93%"
  end
end
