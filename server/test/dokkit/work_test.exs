defmodule Dokkit.WorkTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Dokkit.{Keys, Machine, Repo, Work, WorkRun}

  setup do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{key: key, machine: machine}
  end

  defp as(key), do: put_req_header(build_conn(), "authorization", "Bearer " <> key)

  @tag :tmp_dir
  test "an update is only fetched: queued, taken, answered", %{
    conn: conn,
    key: key,
    machine: machine,
    tmp_dir: dir
  } do
    assert Work.update(machine.id, "sam") == nil
    assert json_response(get(as(key), "/api/v1/program/windows-amd64"), 404)

    Application.put_env(:dokkit, :programs, dir)
    on_exit(fn -> Application.delete_env(:dokkit, :programs) end)
    File.write!(Path.join(dir, "version.txt"), "0.2.0\n")
    File.write!(Path.join(dir, "dokkit-windows-amd64.exe"), "the newer copy")
    assert json_response(get(as(key), "/api/v1/program/..%2Fversion.txt"), 404)
    assert response(get(as(key), "/api/v1/program/windows-amd64"), 200) == "the newer copy"

    Repo.update_all(Machine, set: [program_version: "0.1.0"])
    {:ok, _view, html} = live(signed_in(conn), "/versions")
    refute html =~ "Fetch the newer copy"

    assert response(get(as(key), "/api/v1/work?wait=0"), 204)
    assert %WorkRun{id: id} = Work.update(machine.id, "sam")

    assert %{"run" => ^id, "task" => "dokkit:update"} =
             work = json_response(get(as(key), "/api/v1/work?wait=0"), 200)

    assert Map.keys(work) |> Enum.sort() == ~w(run task)
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)

    out = as(key) |> put_req_header("content-type", "text/plain")
    assert json_response(post(out, "/api/v1/work/#{id}/output", "Fetched\n"), 200)

    assert json_response(
             post(as(key), "/api/v1/work/#{id}/result", %{exit_code: 0, duration_ms: 900}),
             200
           )

    assert json_response(post(as(key), "/api/v1/work/#{id}/result", %{exit_code: 0}), 404)
    assert %{state: :ok, output: "Fetched\n", exit_code: 0} = Repo.get!(WorkRun, id)
  end

  test "an older program's task calls are answered without a failure", %{key: key} do
    doc = %{
      schema: 1,
      service: %{id: "portal"},
      task: [%{id: "restart", run: "true", file: "/srv/dokkit.toml", pin: "pin-1"}]
    }

    assert %{"service" => _} = json_response(put(as(key), "/api/v1/declare", doc), 200)
    assert response(get(as(key), "/api/v1/work?wait=0"), 204)
    assert response(get(as(key), "/api/v1/tasks/accepted"), 404)
  end

  test "runs whose result never came, or that nobody took, are ended", %{machine: m} do
    old = DateTime.add(DateTime.utc_now(), -2, :day)

    stuck =
      Repo.insert!(%WorkRun{
        machine_id: m.id,
        name: "dokkit:update",
        state: :running,
        started_at: old,
        output: "kept"
      })

    waiting =
      Repo.insert!(%WorkRun{
        machine_id: m.id,
        name: "dokkit:update",
        state: :queued,
        inserted_at: old
      })

    fresh = Repo.insert!(%WorkRun{machine_id: m.id, name: "dokkit:update", state: :queued})

    assert Work.expire() == 2
    assert Repo.reload!(stuck).state == :fail
    assert Repo.reload!(stuck).output == "kept\nNo result arrived from the machine."
    assert Repo.reload!(waiting).state == :refused
    assert Repo.reload!(fresh).state == :queued
  end
end
