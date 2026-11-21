defmodule Dokkit.HardwareTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Issues, Keys, Machine, Metric, Numbers, Repo, Values}

  @names Path.expand("../../../spec/hardware-names.json", __DIR__)

  defp machine(name) do
    m = Repo.insert!(%Machine{name: name, kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: m.id})
    {m, key}
  end

  defp at(start, seconds), do: DateTime.to_iso8601(DateTime.add(start, seconds))

  defp reading(name, value, start, seconds, extra \\ %{}),
    do: Map.merge(%{type: "metric", name: name, value: value, at: at(start, seconds)}, extra)

  defp open_on(m), do: Enum.filter(Issues.open_list(), &(&1.machine_id == m.id))

  defp ago, do: DateTime.add(DateTime.utc_now(), -3600)

  test "each direction of limit" do
    assert Numbers.beyond?(:over, 91, 90, nil)
    refute Numbers.beyond?(:over, 90, 90, nil)
    assert Numbers.beyond?(:under, 0, 1, nil)
    refute Numbers.beyond?(:under, 1, 1, nil)
    assert Numbers.beyond?(:band, -15, 10, nil)
    assert Numbers.beyond?(:band, 15, 10, nil)
    refute Numbers.beyond?(:band, -10, 10, nil)
    assert Numbers.beyond?(:rose, 3, nil, 2)
    refute Numbers.beyond?(:rose, 2, nil, 2)
    refute Numbers.beyond?(:rose, 2, nil, nil)
  end

  test "a hot GPU opens after its minutes, as a sentence, goes down at its down level and closes" do
    {m, key} = machine("gpu-01")
    t = ago()

    report(key, [reading("gpu.0.temp_c", 93, t, 0), reading("gpu.0.temp_c", 93, t, 60)])
    assert open_on(m) == []

    report(key, [reading("gpu.0.temp_c", 93, t, 120)])
    assert [%{title: "GPU at 93 °C on gpu-01", state: :down}] = open_on(m)

    report(key, [reading("gpu.0.temp_c", 88, t, 180)])
    assert [%{title: "GPU at 88 °C on gpu-01", state: :degraded}] = open_on(m)

    report(key, [reading("gpu.0.temp_c", 70, t, 240)])
    assert open_on(m) == []
  end

  test "a reading sent again only every five minutes still opens on time" do
    {m, key} = machine("gpu-02")
    t = ago()
    report(key, [reading("gpu.1.memory_percent", 99, t, 0)])
    report(key, [reading("gpu.1.memory_percent", 99, t, 300)])
    assert open_on(m) == []
    report(key, [reading("gpu.1.memory_percent", 99, t, 600)])
    assert [%{title: "GPU 1 memory at 99% on gpu-02", state: :degraded}] = open_on(m)
  end

  test "a limit opens when its time is up, though the unchanged reading is not sent again yet" do
    {m, key} = machine("gpu-08")
    now = DateTime.utc_now()
    report(key, [reading("gpu.0.temp_c", 93, now, -200)])
    assert open_on(m) == []

    Numbers.overdue(DateTime.add(now, -100))
    assert open_on(m) == []

    Numbers.overdue(now)
    assert [%{title: "GPU at 93 °C on gpu-08", state: :down}] = open_on(m)
  end

  test "a machine that stopped reporting does not open a limit on its last reading" do
    {m, key} = machine("gpu-09")
    now = DateTime.utc_now()
    report(key, [reading("gpu.0.temp_c", 93, now, -200)])
    Numbers.overdue(DateTime.add(now, 600))
    assert open_on(m) == []
  end

  test "a machine's own minutes or down level for a hardware row replaces a file's threshold" do
    {m, key} = machine("gpu-10")

    doc = %{
      schema: 1,
      service: %{id: "trainer"},
      check: [%{type: "threshold", name: "hot", metric: "gpu.0.temp_c", limit: 99, fail_after: 1}]
    }

    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)
    assert %{"service" => _} = json_response(put(as, "/api/v1/declare", doc), 200)
    {:ok, _} = Values.save({:machine, m.id}, %{"gpu_temp_minutes" => 2})

    t = ago()
    report(key, for(s <- [0, 60], do: reading("gpu.0.temp_c", 93, t, s)))
    assert [%{title: "GPU at 93 °C on gpu-10"}] = open_on(m)
  end

  test "a stats line between two metric lines keeps the threshold's count" do
    {m, key} = machine("web-06")

    doc = %{
      schema: 1,
      service: %{id: "portal"},
      check: [
        %{
          type: "threshold",
          name: "busy",
          metric: "requests.per_minute",
          limit: 10,
          fail_after: 3
        }
      ]
    }

    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)
    assert %{"service" => _} = json_response(put(as, "/api/v1/declare", doc), 200)
    busy = %{type: "metric", service: "portal", name: "requests.per_minute", value: 50}

    stats = %{
      type: "stats",
      service: "portal",
      document: %{schema: 1, requests: %{"5m" => %{per_minute: 50}}}
    }

    report(key, [busy, stats, busy])
    assert [%{service: %{slug: "portal"}}] = open_on(m)
  end

  test "a fan that never turned is not watched; one that stops is" do
    {m, key} = machine("web-01")
    t = ago()
    report(key, for(s <- [0, 300, 600, 900], do: reading("fan.case_rpm", 0, t, s)))
    assert open_on(m) == []

    report(key, [reading("fan.cpu_fan_rpm", 716, t, 0)])
    report(key, for(s <- [60, 360, 660], do: reading("fan.cpu_fan_rpm", 0, t, s)))
    assert [%{title: "Fan cpu fan stopped on web-01", state: :degraded}] = open_on(m)
  end

  test "a clock off either way is judged against a band" do
    {m, key} = machine("web-02")
    t = ago()
    report(key, for(s <- [0, 60, 120], do: reading("clock.offset_seconds", -15, t, s)))
    assert [%{title: "Clock 15 seconds behind on web-02", state: :degraded}] = open_on(m)
    report(key, [reading("clock.offset_seconds", 130, t, 180)])
    assert [%{title: "Clock 130 seconds ahead on web-02", state: :down}] = open_on(m)
  end

  test "a processor's own critical temperature counts until the setting is changed" do
    {m, key} = machine("gpu-03")
    t = ago()
    hot = fn v, s -> reading("temp.cpu_c", v, t, s, %{crit: 105}) end

    report(key, for(s <- [0, 60, 120, 180, 240], do: hot.(93, s)))
    assert open_on(m) == []

    report(key, for(s <- [300, 360, 420, 480, 540], do: hot.(96, s)))
    assert [%{title: "Processor at 96 °C on gpu-03", state: :degraded}] = open_on(m)

    {:ok, _} = Values.save({:machine, m.id}, %{"cpu_temp_limit" => 99, "cpu_temp_down" => 120})
    report(key, [hot.(96, 600)])
    assert open_on(m) == []
  end

  test "an air temperature and a QNAP's system temperature share a row" do
    {m, key} = machine("nas-01")
    t = ago()
    report(key, for(s <- [0, 60, 120], do: reading("temp.system_c", 46, t, s)))
    assert [%{title: "Inside the case at 46 °C on nas-01", state: :down}] = open_on(m)
  end

  test "a limit switched off for one machine opens nothing" do
    {m, key} = machine("gpu-04")
    {:ok, _} = Values.save({:machine, m.id}, %{"gpu_temp_on" => false})
    t = ago()
    report(key, for(s <- [0, 60, 120, 180], do: reading("gpu.0.temp_c", 99, t, s)))
    assert open_on(m) == []
  end

  test "a hardware state goes on the machine itself with a sentence for its title" do
    {m, key} = machine("gpu-05")
    line = %{type: "state", check: "hw.gpu.0", state: "degraded", note: "power brake"}

    assert %{"accepted" => 3, "refused" => []} =
             json_response(report(key, [line, line, line]), 200)

    assert [%{title: "GPU is held back on gpu-05", service: %{slug: "machine"}}] = open_on(m)
    report(key, for(_ <- 1..3, do: %{line | state: "ok"}))
    assert open_on(m) == []
  end

  test "the report's answer carries the server's time for the clock reading" do
    {_, key} = machine("web-03")
    before = System.os_time(:millisecond)
    assert %{"server_ms" => ms} = json_response(report(key, []), 200)
    assert ms >= before
  end

  test "a batch reads its machine's checks once, not once a line" do
    {_, key} = machine("web-04")
    reads = :counters.new(1, [])
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:dokkit, :repo, :query],
      fn _, _, meta, _ ->
        if meta.source == "checks" and String.starts_with?(meta.query, "SELECT"),
          do: :counters.add(reads, 1, 1)
      end,
      nil
    )

    report(key, for(i <- 1..20, do: %{type: "metric", name: "temp.video_c", value: 40 + i}))
    :telemetry.detach(id)
    assert :counters.get(reads, 1) == 1
  end

  test "hardware settings save and reset for a machine" do
    {m, _} = machine("gpu-06")
    scope = {:machine, m.id}
    assert Values.get("gpu_temp_limit", scope) == 85
    assert {:error, _} = Values.save(scope, %{"gpu_temp_limit" => 95, "gpu_temp_down" => 90})
    {:ok, view} = Values.save(scope, %{"gpu_temp_limit" => 80})
    assert "gpu_temp_limit" in view["changed"]
    {:ok, view} = Values.reset(scope, "gpu_temp")
    assert view["changed"] == []
    assert Values.get("gpu_temp_limit", scope) == 85

    for {k, v} <- [
          {"gpu_temp_on", true},
          {"gpu_temp_down", 92},
          {"gpu_memory_limit", 98},
          {"gpu_memory_minutes", 10},
          {"cpu_temp_limit", 90},
          {"cpu_temp_down", 100},
          {"cpu_temp_minutes", 5},
          {"ambient_temp_limit", 40},
          {"ambient_temp_down", 45},
          {"fan_stop_minutes", 10},
          {"clock_limit", 10},
          {"clock_down", 120},
          {"hardware_days", 30}
        ],
        do: assert(Values.default(k) == v, k)
  end

  test "hardware readings are kept for their own number of days" do
    {m, _} = machine("web-05")
    now = DateTime.utc_now()
    old = DateTime.add(now, -10 * 86_400)
    Values.save(:server, %{"hardware_days" => 5})

    for name <- ["temp.cpu_c", "cpu.percent"],
        do: Repo.insert!(%Metric{machine_id: m.id, name: name, value: 1.0, at: old})

    Numbers.prune(now)
    assert Numbers.names({:machine, m.id}) == ["cpu.percent"]
  end

  test "every name in spec/hardware-names.json is a hardware reading the server knows" do
    spec = @names |> File.read!() |> Jason.decode!()

    for name <- spec["examples"]["metrics"], do: assert(Numbers.hardware?(name), name)
    for name <- spec["examples"]["states"], do: assert(String.starts_with?(name, "hw."), name)

    for %{"name" => pattern} <- spec["metrics"],
        do: assert(Numbers.hardware?(pattern), pattern)

    watched = for {p, s, _, _} <- Numbers.machine_limits(), Numbers.hardware?(p), do: p <> s
    assert "gpu..temp_c" in watched
    assert "clock.offset_seconds" in watched
  end

  test "the machine page has a Hardware section with limits beside the readings", %{conn: conn} do
    {m, key} = machine("gpu-07")
    report(key, [%{type: "metric", name: "gpu.0.temp_c", value: 61}])

    {:ok, view, html} = live(signed_in(conn), "/machines/#{m.id}")
    assert html =~ "GPU 0 temperature"
    assert html =~ "61 °C"
    assert has_element?(view, "#hw-gpu-form")
    assert has_element?(view, "#hw-fans-none")
    refute has_element?(view, "#hw-fans-form")
    refute render(element(view, "#history")) =~ "GPU 0 temperature"

    view |> form("#hw-gpu-form", %{"values" => %{"gpu_temp_limit" => "80"}}) |> render_submit()
    assert Values.get("gpu_temp_limit", {:machine, m.id}) == 80
    assert render(view) =~ "Saved."
  end
end
