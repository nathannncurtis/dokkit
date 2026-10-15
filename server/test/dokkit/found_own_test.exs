defmodule Dokkit.FoundOwnTest do
  use Dokkit.DataCase, async: false
  import Ecto.Query
  alias Dokkit.{Check, Finding, Found, Issue, Machine, Repo, Service}

  defp machine(name), do: Repo.insert!(%Machine{name: name, kind: :enrolled})

  defp service(m, slug, name, check_name) do
    s = Repo.insert!(%Service{machine_id: m.id, slug: slug, name: name, kind: :service})

    Repo.insert!(%Check{
      service_id: s.id,
      name: "windows-service",
      type: :"windows-service",
      config: %{"name" => check_name},
      fail_after: 3
    })

    s
  end

  defp keys(m), do: Repo.all(from f in Finding, where: f.machine_id == ^m.id, select: f.key)

  test "a scan that still sends Dokkit's own pieces has them dropped" do
    m = machine("own-box")

    body = %{
      "os" => "windows",
      "found" => %{
        "services" => [
          %{
            "name" => "dokkit01dd59e0d4f44eb0",
            "display" => "dokkit_dokkit",
            "state" => "running"
          },
          %{"name" => "dokkit-postgres", "state" => "running"},
          %{"name" => "dokkit-server", "display" => "Dokkit", "state" => "running"},
          %{
            "name" => "Gone",
            "display" => "Elsewhere",
            "state" => "running",
            "why" => "Dokkit itself"
          },
          %{"name" => "dokkit-lookalike", "display" => "Dokkit lookalike", "state" => "running"},
          %{"name" => "Spooler", "state" => "running"}
        ],
        "ports" => [%{"port" => 4000, "program" => "erl.exe", "why" => "Dokkit itself"}]
      }
    }

    assert {:ok, 2} = Found.propose(m.id, body)
    assert Enum.sort(keys(m)) == ["Spooler", "dokkit-lookalike"]
  end

  test "an older proposal's undecided findings of that kind are removed, decided ones are kept" do
    m = machine("old-box")

    for {key, dismissed} <- [{"dokkit01dd59e0d4f44eb0", false}, {"dokkit01dd59e3a0276ed0", true}] do
      Repo.insert!(%Finding{
        machine_id: m.id,
        kind: "service",
        key: key,
        detail: %{},
        dismissed: dismissed
      })
    end

    Repo.insert!(%Finding{
      machine_id: m.id,
      kind: "job",
      key: "x",
      detail: %{},
      why: "Dokkit itself"
    })

    assert {:ok, 0} = Found.propose(m.id, %{"os" => "windows", "found" => %{"services" => []}})
    assert keys(m) == ["dokkit01dd59e3a0276ed0"]
  end

  test "watches of the server's own service stop, with their issues closed and nothing deleted" do
    m = machine("watch-box")
    a = service(m, "a", "dokkit_dokkit", "dokkit01dd59e0d4f44eb0")
    b = service(m, "b", "dokkit_dokkit", "dokkit-postgres")
    other = service(m, "c", "Spooler", "Spooler")
    two = service(m, "d", "Mixed", "dokkit01dd59f5c9944560")

    Repo.insert!(%Check{
      service_id: two.id,
      name: "tcp",
      type: :tcp,
      config: %{"port" => 1},
      fail_after: 3
    })

    check = Repo.get_by!(Check, service_id: a.id)

    issue =
      Repo.insert!(%Issue{
        service_id: a.id,
        check_id: check.id,
        machine_id: m.id,
        kind: "down",
        state: :down,
        since: DateTime.utc_now(),
        title: "down"
      })

    Found.stop_watching_own()

    refute Repo.get!(Service, a.id).watched
    refute Repo.get!(Service, b.id).watched
    assert Repo.get!(Service, other.id).watched
    assert Repo.get!(Service, two.id).watched
    assert Repo.get!(Issue, issue.id).closed_at
    assert Repo.get!(Check, check.id)
  end
end
