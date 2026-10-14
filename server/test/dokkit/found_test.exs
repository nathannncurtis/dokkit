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

  test "a watched port is checked on its own address only when that is a specific one" do
    machine = Repo.insert!(%Machine{name: "found-ports", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)

    ports =
      for {port, address} <- [
            {8443, "64.62.155.195"},
            {8444, "2001:db8::5"},
            {8445, "0.0.0.0"},
            {8446, "::"},
            {8447, "*"},
            {8448, "127.0.0.1"},
            {8449, "::1"},
            {8450, nil},
            {8451, "not an address"}
          ] do
        Map.merge(
          %{port: to_string(port), program: "svc.exe"},
          if(address, do: %{address: address}, else: %{})
        )
      end

    containers = [
      %{name: "web", image: "nginx", port: "9000", address: "10.1.2.3"},
      %{name: "db", image: "postgres", port: "9001", address: "0.0.0.0"}
    ]

    post(as, "/api/v1/proposals", %{os: "windows", found: %{ports: ports, containers: containers}})

    Found.watch(for f <- Found.list(), f.machine_id == machine.id, do: f.id)

    config = fn slug ->
      Repo.one!(
        from c in Dokkit.Check,
          join: s in Dokkit.Service,
          on: s.id == c.service_id,
          where: s.machine_id == ^machine.id and s.slug == ^slug,
          select: c.config
      )
    end

    assert config.("port-8443") == %{"port" => 8443, "host" => "64.62.155.195"}
    assert config.("port-8444") == %{"port" => 8444, "host" => "2001:db8::5"}
    for p <- 8445..8451, do: assert(config.("port-#{p}") == %{"port" => p})
    assert config.("container-web") == %{"port" => 9000, "host" => "10.1.2.3"}
    assert config.("container-db") == %{"port" => 9001}
  end

  test "on Linux, systemd units are kept and watched", %{conn: _} do
    machine = Repo.insert!(%Machine{name: "found-linux", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    as = put_req_header(build_conn(), "authorization", "Bearer " <> key)

    proposal = %{
      os: "linux",
      found: %{
        services: [%{name: "nginx", state: "running"}],
        tasks: [%{name: "backup.timer"}]
      }
    }

    assert json_response(post(as, "/api/v1/proposals", proposal), 200) == %{"waiting" => 1}
    found = Enum.filter(Found.list(), &(&1.machine_id == machine.id))
    Found.watch(Enum.map(found, & &1.id))

    assert %{config: %{"name" => "nginx"}, type: :systemd} = check(machine, "nginx")

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
