defmodule DokkitWeb.ProcessesLiveTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Check, Intake, Issues, Keys, Machine, Repo, Service}

  @gb 1_073_741_824

  setup %{conn: conn} do
    machine = Repo.insert!(%Machine{name: "sql1", kind: :enrolled})
    service = Repo.insert!(%Service{machine_id: machine.id, slug: "machine", name: "The machine"})
    {_, key} = Keys.mint(:machine, %{machine_id: machine.id})
    %{conn: signed_in(conn), machine: machine, service: service, key: key}
  end

  defp feed(key, items, at \\ DateTime.utc_now()) do
    line = %{
      type: "processes",
      at: DateTime.to_iso8601(at),
      total_memory_bytes: 8 * @gb,
      items: items
    }

    Intake.report(key, nil, Jason.encode!(line), DateTime.utc_now())
  end

  defp many(count) do
    for n <- 1..count do
      %{
        pid: n,
        ppid: 0,
        name: "proc#{n}.exe",
        path: "C:/apps/proc#{n}.exe",
        memory_bytes: n * 1_048_576,
        cpu_percent: if(n == 2, do: 90.0, else: 1.0)
      }
    end
  end

  test "the card says nothing has arrived yet", %{conn: conn, service: service} do
    {:ok, _, html} = live(conn, "/s/#{service.id}")
    assert html =~ "None received yet"
  end

  test "a service that is not the machine has no card", %{conn: conn, machine: m} do
    other = Repo.insert!(%Service{machine_id: m.id, slug: "web", name: "Web"})
    {:ok, view, _} = live(conn, "/s/#{other.id}")
    refute has_element?(view, "#processes")
  end

  test "the card lists the top 50, sorts, filters, shows all and shows the last hour", ctx do
    feed(ctx.key, many(60))
    {:ok, view, html} = live(ctx.conn, "/s/#{ctx.service.id}")

    assert html =~ "Taken"
    assert has_element?(view, "#proc-60")
    assert has_element?(view, "#proc-11")
    refute has_element?(view, "#proc-10")
    assert render(view) =~ "60 MB"
    assert render(view) =~ "0.7%"
    assert has_element?(view, ~s|input[name=q][aria-label]|)

    view |> element("button", "Processor") |> render_click()
    assert [["proc-2"] | _] = Regex.scan(~r/proc-\d+(?=")/, render(view))

    view |> form("#procs-form", q: "PROC5") |> render_change()
    assert has_element?(view, "#proc-5")
    assert has_element?(view, "#proc-50")
    refute has_element?(view, "#proc-6")

    view |> form("#procs-form", q: "") |> render_change()
    view |> element("button", "Show all 60") |> render_click()
    assert has_element?(view, "#proc-1")
    assert render(view) =~ "Show the top 50"

    refute render(view) =~ "Nothing was kept"
    view |> element("button", "Show the last hour") |> render_click()
    assert has_element?(view, "#processes .li.slim span.mono", "proc2.exe 90.0%")
    view |> element("button", "Hide the last hour") |> render_click()
    refute has_element?(view, "#processes .li.slim span.mono", "proc2.exe 90.0%")
  end

  test "an issue shows what was running at the time", ctx do
    feed(ctx.key, many(12))

    check =
      Repo.insert!(%Check{
        service_id: ctx.service.id,
        name: "mem",
        type: :threshold,
        config: %{"metric" => "memory.used_percent", "limit" => 1},
        fail_after: 1
      })

    Issues.record(check, :down)
    {:ok, view, html} = live(ctx.conn, "/s/#{ctx.service.id}")
    assert html =~ "At the time"
    assert has_element?(view, "#at-the-time", "proc12.exe 12 MB")
    refute has_element?(view, "#at-the-time", "proc6.exe")
    assert has_element?(view, "#at-the-time", "proc2.exe 90.0%")
  end
end
