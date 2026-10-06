defmodule Dokkit.FoundTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Found, Keys, Machine, Repo}

  test "a scan is proposed, part of it is watched, and the machine is given the checks", %{
    conn: conn
  } do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)

    proposal = %{
      machine: "vault",
      os: "windows",
      found: %{
        services: [
          %{name: "Spooler", display: "Print Spooler", state: "running"},
          %{name: "Fax", display: "Fax", state: "stopped"}
        ],
        ports: [%{port: "5432", program: "postgres.exe"}, %{port: "nope"}],
        disks: [%{mount: "C:\\"}]
      }
    }

    assert json_response(post(as, "/api/v1/proposals", proposal), 200) == %{"waiting" => 2}
    assert json_response(post(as, "/api/v1/proposals", proposal), 200) == %{"waiting" => 2}
    assert json_response(post(as, "/api/v1/proposals", %{}), 422)
    assert Found.count() == 2

    {:ok, view, html} = live(signed_in(conn), "/found")
    assert html =~ "Print Spooler"
    assert html =~ "postgres.exe"
    refute html =~ "Fax"
    assert html =~ ~s(aria-label="Found, 2")

    [port, service] = Found.list()
    html = render_submit(view, "sweep", %{"do" => "watch", "ids" => [service.id]})
    refute html =~ "Print Spooler"
    render_submit(view, "sweep", %{"do" => "dismiss", "ids" => [port.id]})
    assert Found.count() == 0

    assert %{
             "items" => [
               %{
                 "service" => "spooler",
                 "name" => "windows-service",
                 "type" => "windows-service",
                 "config" => %{"name" => "Spooler"}
               }
             ]
           } = json_response(get(as, "/api/v1/checks"), 200)

    # What is watched or dismissed is not offered again.
    assert json_response(post(as, "/api/v1/proposals", proposal), 200) == %{"waiting" => 0}

    report(key, [%{type: "state", service: "spooler", check: "windows-service", state: "ok"}])
    {:ok, _, html} = live(signed_in(conn), "/all")
    assert html =~ "Print Spooler"
  end

  test "tasks and, on Linux, systemd units are kept and watched", %{conn: _} do
    machine = Repo.insert!(%Machine{name: "found-linux", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)

    proposal = %{
      os: "linux",
      found: %{
        services: [%{name: "nginx", state: "running"}],
        tasks: [
          %{name: "backup.timer"},
          %{name: "\Nightly", runs: "C:\run.bat", schedule: "0 1 * * *"},
          %{name: "\Odd", schedule: "@reboot"}
        ]
      }
    }

    assert json_response(post(as, "/api/v1/proposals", proposal), 200) == %{"waiting" => 4}
    found = Enum.filter(Found.list(), &(&1.machine_id == machine.id))
    Found.watch(Enum.map(found, & &1.id))

    assert %{config: %{"name" => "nginx"}, type: :systemd} = check(machine, "nginx")
    assert %{config: %{"schedule" => "0 1 * * *"}, type: :job} = check(machine, "nightly")
    assert %{config: config, type: :job} = check(machine, "odd")
    assert config == %{}
    assert %{type: :job} = check(machine, "backup-timer")

    assert %{"items" => [%{"type" => "systemd", "name" => "systemd"}]} =
             json_response(get(as, "/api/v1/checks"), 200)
  end

  defp check(machine, slug) do
    Repo.one!(
      from c in Dokkit.Check,
        join: s in assoc(c, :service),
        where: s.machine_id == ^machine.id and s.slug == ^slug
    )
  end
end
