defmodule Dokkit.FoundOriginTest do
  use DokkitWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Dokkit.{Finding, Found, Keys, Machine, Repo}

  defp scan(origin_of, extra \\ %{}) do
    Map.merge(
      %{
        "os" => "windows",
        "found" => %{
          "services" => [
            %{"name" => "Dnscache", "state" => "running"}
            |> origin_of.("system", "Windows component"),
            %{"name" => "ContosoAgent", "state" => "running"}
            |> origin_of.("software", "Installed under C:\\Program Files\\Contoso"),
            %{"name" => "OrderSync", "state" => "running"}
            |> origin_of.("yours", "Set up with NSSM")
          ],
          "ports" => [
            %{"port" => 135, "program" => "svchost.exe"}
            |> origin_of.("system", "Port of service Dnscache"),
            %{"port" => 9000, "program" => "python.exe"} |> origin_of.("yours", "owner not known")
          ]
        }
      },
      extra
    )
  end

  defp with_origin(map, origin, why), do: Map.merge(map, %{"origin" => origin, "why" => why})
  defp without_origin(map, _, _), do: map

  defp token(scopes) do
    {token, _} = Keys.mint(:user, %{scopes: scopes})
    token
  end

  defp api(method, path, token, body \\ %{}) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> dispatch(@endpoint, method, "/api/v1" <> path, body)
  end

  setup do
    m = Repo.insert!(%Machine{name: "origin-box", kind: :enrolled})
    {:ok, 3} = Found.propose(m.id, scan(&with_origin/3))
    %{machine: m}
  end

  test "origin and why are kept, and the system's own are not offered unless asked for", %{
    machine: m
  } do
    assert Found.count() == 3
    assert Enum.map(Found.list(), & &1.origin) == ["yours", "yours", "software"]

    assert ["Windows component", "Port of service Dnscache"] ==
             for(f <- Found.list(system: true), f.origin == "system", do: f.why)
             |> Enum.sort(:desc)

    assert length(Found.list(system: true)) == 5
    assert Enum.all?(Found.list(system: true), &(&1.machine_id == m.id))
  end

  test "a program that sends no origin is stored unknown and always shown" do
    m = Repo.insert!(%Machine{name: "old-program", kind: :enrolled})
    Found.propose(m.id, scan(&without_origin/3))
    old = Enum.filter(Found.list(), &(&1.machine_id == m.id))
    assert length(old) == 5
    assert Enum.all?(old, &(&1.origin == nil and &1.why == nil))
  end

  test "an origin outside the three is stored as unknown" do
    m = Repo.insert!(%Machine{name: "odd", kind: :enrolled})

    Found.propose(m.id, %{
      "os" => "windows",
      "found" => %{
        "services" => [%{"name" => "X", "state" => "running", "origin" => "operating-system"}]
      }
    })

    assert [%{origin: nil}] = Enum.filter(Found.list(), &(&1.machine_id == m.id))
  end

  test "a repeat scan gives an undecided finding its origin and leaves a dismissed one alone" do
    m = Repo.insert!(%Machine{name: "rescanned", kind: :enrolled})
    Found.propose(m.id, scan(&without_origin/3))
    [port] = Enum.filter(Found.list(), &(&1.machine_id == m.id and &1.key == "135"))
    Found.dismiss([port.id])
    assert is_nil(Repo.get!(Finding, port.id).origin)

    Found.propose(m.id, scan(&with_origin/3))
    mine = Enum.filter(Found.list(system: true), &(&1.machine_id == m.id))
    assert Enum.map(mine, & &1.origin) |> Enum.sort() == ["software", "system", "yours", "yours"]
    assert Enum.find(mine, &(&1.key == "ContosoAgent")).why =~ "Contoso"
    dismissed = Repo.get!(Finding, port.id)
    assert dismissed.dismissed and is_nil(dismissed.origin)
  end

  test "a program that sends no origin does not erase the one a finding has" do
    m = Repo.insert!(%Machine{name: "downgraded", kind: :enrolled})
    Found.propose(m.id, scan(&with_origin/3))
    Found.propose(m.id, scan(&without_origin/3))
    mine = Enum.filter(Found.list(system: true), &(&1.machine_id == m.id))
    assert Enum.count(mine, &(&1.origin == "system")) == 2
  end

  test "the API leaves system findings out, counts them, and takes system=true", %{machine: m} do
    read = token(["read"])
    body = json_response(api(:get, "/proposals", read), 200)

    assert %{"items" => items, "hidden" => %{"total" => 2, "machines" => %{"origin-box" => 2}}} =
             body

    assert length(items) == 3
    assert Enum.all?(items, &(&1["origin"] in ["yours", "software"] and is_binary(&1["why"])))

    body = json_response(api(:get, "/proposals?system=true", read), 200)
    assert length(body["items"]) == 5
    assert body["hidden"] == %{"total" => 0, "machines" => %{}}
    assert Enum.count(body["items"], &(&1["origin"] == "system")) == 2

    only = json_response(api(:get, "/proposals?kind=port", read), 200)
    assert length(only["items"]) == 1 and only["hidden"]["total"] == 1
    assert m.name == "origin-box"
  end

  test "a hidden finding is accepted or dismissed by id, and all acts on what is shown" do
    all = token(["read", "act"])

    %{"items" => shown} = json_response(api(:get, "/proposals", all), 200)
    %{"items" => every} = json_response(api(:get, "/proposals?system=true", all), 200)
    [system_one, system_two] = Enum.filter(every, &(&1["origin"] == "system"))

    assert json_response(api(:post, "/proposals/#{system_one["id"]}/dismiss", all), 200)

    assert %{"done" => done} =
             json_response(api(:post, "/proposals/accept", all, %{"all" => true}), 200)

    assert Enum.sort(done) == Enum.sort(for s <- shown, do: s["id"])
    assert [%{id: id}] = Found.list(system: true)
    assert id == system_two["id"]

    assert json_response(
             api(:post, "/proposals/accept", all, %{"all" => true, "system" => true}),
             200
           )["done"] == [system_two["id"]]
  end

  test "an AI tool gets the same switch and the hidden count" do
    all = token(["read", "act"])

    call = fn name, args ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> all)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: args}
      })
      |> json_response(200)
      |> get_in(["result", "content"])
      |> List.last()
      |> Map.fetch!("text")
      |> Jason.decode!()
    end

    assert %{"items" => items, "hidden" => %{"total" => 2, "machines" => %{"origin-box" => 2}}} =
             call.("proposals", %{})

    assert length(items) == 3

    assert %{"items" => every, "hidden" => %{"total" => 0}} =
             call.("proposals", %{"system" => true})

    assert length(every) == 5
    assert %{"done" => done} = call.("dismiss_proposal", %{"all" => true})
    assert length(done) == 3
    assert %{"done" => two} = call.("dismiss_proposal", %{"all" => true, "system" => true})
    assert length(two) == 2
  end

  test "the page hides system findings, says how many, and shows them with the switch", %{
    conn: conn
  } do
    {:ok, view, html} = live(signed_in(conn), "/found")
    assert html =~ "2 hidden"
    assert html =~ "Show system services"
    assert html =~ "ContosoAgent" and html =~ "OrderSync"
    refute html =~ "Dnscache"
    assert html =~ ~s(title="Set up with NSSM")
    assert html =~ ~s(aria-label="Found, 3")

    html = view |> element("#system-form") |> render_change(%{"system" => "true"})
    assert_patched(view, "/found?system=true")
    assert html =~ "Dnscache" and html =~ "Port 135"
    refute html =~ "2 hidden"

    {:ok, _, html} = live(signed_in(conn), "/found?system=true")
    assert html =~ "Dnscache"
    assert html =~ ~r/checked/

    [first | _] = Found.list(system: true)
    assert first.origin == "yours"
    assert List.last(Found.list(system: true)).origin == "system"
  end

  test "a machine with only system findings still shows how many are hidden", %{conn: conn} do
    m = Repo.insert!(%Machine{name: "quiet-box", kind: :enrolled})

    Found.propose(m.id, %{
      "os" => "windows",
      "found" => %{
        "services" => [
          %{
            "name" => "Dnscache",
            "state" => "running",
            "origin" => "system",
            "why" => "Windows component"
          }
        ]
      }
    })

    {:ok, _, html} = live(signed_in(conn), "/found")
    assert html =~ "quiet-box"
    assert html =~ "1 hidden"
  end
end
