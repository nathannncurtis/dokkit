defmodule Dokkit.ProcessesTest do
  use DokkitWeb.ConnCase, async: false
  import Ecto.Query

  alias Dokkit.{
    Check,
    Intake,
    Issue,
    Issues,
    Keys,
    Machine,
    ProcessList,
    ProcessTop,
    Repo,
    Service
  }

  @gb 1_073_741_824

  setup do
    machine = Repo.insert!(%Machine{name: "sql1", kind: :enrolled})
    {mkey, key} = Keys.mint(:machine, %{machine_id: machine.id})
    %{machine: machine, mkey: mkey, key: key}
  end

  defp proc(n, memory, cpu, extra \\ %{}) do
    Map.merge(
      %{pid: n, ppid: 4, name: "p#{n}.exe", memory_bytes: memory, cpu_percent: cpu},
      extra
    )
  end

  defp line(items, at \\ nil) do
    base = %{type: "processes", total_memory_bytes: 32 * @gb, items: items}
    if at, do: Map.put(base, :at, DateTime.to_iso8601(at)), else: base
  end

  defp send_line(key, line, now \\ DateTime.utc_now()) do
    {:ok, answer} = Intake.report(key, nil, Jason.encode!(line), now)
    answer
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds)

  test "a line is stored and the next one replaces it", %{machine: m, key: key} do
    assert %{accepted: 1, refused: []} = send_line(key, line([proc(1, 5 * @gb, 1.5)], ago(120)))
    assert %{accepted: 1} = send_line(key, line([proc(2, 7 * @gb, nil)], ago(60)))

    assert %ProcessList{total_memory_bytes: total, items: [%{"pid" => 2, "name" => "p2.exe"}]} =
             Repo.get!(ProcessList, m.id)

    assert total == 32 * @gb
    assert Repo.aggregate(ProcessList, :count) == 1
    assert Repo.aggregate(ProcessTop, :count) == 4
  end

  test "a line older than the stored one is ignored", %{machine: m, key: key} do
    send_line(key, line([proc(1, 1, 1.0)], ago(60)))
    assert %{accepted: 1} = send_line(key, line([proc(9, 1, 1.0)], ago(300)))

    assert %ProcessList{items: [%{"pid" => 1}]} = Repo.get!(ProcessList, m.id)
    assert Repo.aggregate(ProcessTop, :count) == 2
  end

  test "a bad item is dropped, not the line", %{machine: m, key: key} do
    long = String.duplicate("x", 400)

    items = [
      proc(1, 100, 10.0, %{path: long, user: "svc", session: 0}),
      proc(-2, 100, 1.0),
      proc(3, -5, 1.0),
      proc(4, 100, 101.0),
      proc(5, 100, -1.0),
      Map.put(proc(6, 100, 1.0), :ppid, "x"),
      Map.delete(proc(7, 100, 1.0), :name),
      "junk",
      proc(8, 100, nil)
    ]

    assert %{accepted: 1, refused: []} = send_line(key, line(items))
    assert %ProcessList{items: [one, two]} = Repo.get!(ProcessList, m.id)
    assert %{"pid" => 1, "user" => "svc", "session" => 0} = one
    assert String.length(one["path"]) == 260
    assert %{"pid" => 8, "cpu_percent" => nil, "path" => nil} = two
  end

  test "a line without a total or a list is refused", %{key: key} do
    assert %{accepted: 0, refused: [%{"code" => "bad_line"}]} =
             send_line(key, %{type: "processes", items: []})

    assert %{accepted: 0, refused: [%{"code" => "bad_line"}]} =
             send_line(key, %{type: "processes", total_memory_bytes: 1, items: "x"})
  end

  test "more than 10,000 items keep the first 10,000", %{machine: m, key: key} do
    items = for n <- 1..10_050, do: proc(n, n, nil)
    send_line(key, line(items))
    assert length(Repo.get!(ProcessList, m.id).items) == 10_000
  end

  test "a line of 900 KB is taken and one of 1.2 MB is refused", %{machine: m, mkey: mkey} do
    ok = pad(line([]), 900 * 1024)
    big = pad(line([]), 1_200 * 1024)
    assert byte_size(ok) in 900_000..1_048_576
    assert byte_size(big) > 1_048_576

    answer = json_response(report(mkey, [ok, big]), 200)
    assert %{"accepted" => 1, "refused" => [%{"line" => 2, "code" => "too_large"}]} = answer
    assert length(Repo.get!(ProcessList, m.id).items) > 3000
  end

  # Many small items, so the line is long and still valid.
  defp pad(base, bytes) do
    one = %{pid: 1, ppid: 1, name: "n", memory_bytes: 1, cpu_percent: 1.0}
    n = div(bytes, byte_size(Jason.encode!(one)) + 1)
    Jason.encode!(%{base | items: for(i <- 1..n, do: %{one | pid: i})})
  end

  test "an app key and a missing key may not send it", %{machine: m} do
    service = Repo.insert!(%Service{machine_id: m.id, slug: "web", name: "Web"})
    {app, _} = Keys.mint(:app, %{service_id: service.id})

    assert %{"refused" => [%{"code" => "not_allowed"}]} =
             json_response(report(app, [line([proc(1, 1, 1.0)])]), 200)

    assert Repo.aggregate(ProcessList, :count) == 0
    assert json_response(report("dkm_nope", [line([])]), 401)
  end

  test "each line keeps the top 10 by memory and by processor, and the sweep drops them after 24 hours",
       %{key: key} do
    items = for n <- 1..15, do: proc(n, n * 100, if(n == 15, do: nil, else: n / 1))
    old = ago(25 * 3600)
    send_line(key, line(items, old), old)
    send_line(key, line(items, ago(30)))

    assert Repo.aggregate(ProcessTop, :count) == 4

    newest = fn kind ->
      Repo.one!(from t in ProcessTop, where: t.kind == ^kind, order_by: [desc: t.at], limit: 1)
    end

    memory = newest.("memory")
    cpu = newest.("cpu")

    assert Enum.map(memory.items, & &1["pid"]) == Enum.to_list(15..6//-1)
    assert Enum.map(cpu.items, & &1["pid"]) == Enum.to_list(14..5//-1)
    assert Map.keys(hd(memory.items)) |> Enum.sort() == ~w(cpu_percent memory_bytes name pid)

    Dokkit.Processes.prune(DateTime.utc_now())
    assert Repo.aggregate(ProcessTop, :count) == 2
    assert Repo.aggregate(ProcessList, :count) == 1
  end

  test "a machine's process data goes with the machine", %{machine: m, key: key} do
    send_line(key, line([proc(1, 1, 1.0)]))
    Repo.delete!(m)
    assert Repo.aggregate(ProcessList, :count) == 0
    assert Repo.aggregate(ProcessTop, :count) == 0
  end

  describe "the snapshot kept with an issue" do
    setup %{machine: m, key: key} do
      items = for n <- 1..12, do: proc(n, n * 1000, n / 1)
      service = Repo.insert!(%Service{machine_id: m.id, slug: "machine", name: "The machine"})
      %{items: items, service: service, key: key}
    end

    defp check(service, type, config, name \\ "c") do
      Repo.insert!(%Check{
        service_id: service.id,
        name: name,
        type: type,
        config: config,
        fail_after: 1
      })
    end

    defp opened(check, state \\ :down) do
      now = DateTime.utc_now()
      Issues.record(check, state, now: now, at: now)
      Repo.one!(from i in Issue, where: i.check_id == ^check.id)
    end

    test "a memory, processor or stopped-service issue gets the fresh top lists", ctx do
      send_line(ctx.key, line(ctx.items, ago(30)))

      for check <- [
            check(
              ctx.service,
              :threshold,
              %{"metric" => "memory.used_percent", "limit" => 1},
              "m"
            ),
            check(ctx.service, :threshold, %{"metric" => "cpu.percent", "limit" => 1}, "p"),
            check(ctx.service, :"windows-service", %{"name" => "Spooler"}, "w"),
            check(ctx.service, :systemd, %{"name" => "nginx"}, "s"),
            check(ctx.service, :process, %{"name" => "nginx"}, "x")
          ] do
        assert %Issue{processes: %{"top_memory" => mem, "top_cpu" => cpu, "at" => at}} =
                 opened(check)

        assert length(mem) == 10 and length(cpu) == 10 and is_binary(at)
        assert hd(mem)["pid"] == 12
      end
    end

    test "an old list is not kept, and nothing is added to an issue afterwards", ctx do
      send_line(ctx.key, line(ctx.items, ago(600)), ago(600))
      c = check(ctx.service, :"windows-service", %{"name" => "Spooler"})
      assert %Issue{processes: nil} = opened(c)

      send_line(ctx.key, line(ctx.items, ago(10)))
      assert %Issue{processes: nil} = Repo.one!(from i in Issue, where: i.check_id == ^c.id)
    end

    test "an unrelated issue, or a service that is only degraded, gets none", ctx do
      send_line(ctx.key, line(ctx.items, ago(30)))
      assert %Issue{processes: nil} = opened(check(ctx.service, :http, %{"url" => "http://x"}))

      assert %Issue{processes: nil} =
               opened(check(ctx.service, :"windows-service", %{"name" => "A"}, "d"), :degraded)

      assert %Issue{processes: nil} =
               opened(check(ctx.service, :threshold, %{"metric" => "disk.used_percent.C"}, "k"))
    end
  end
end
