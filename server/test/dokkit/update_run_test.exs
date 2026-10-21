defmodule Dokkit.UpdateRunTest do
  use Dokkit.DataCase, async: true
  alias Dokkit.{Machine, Repo, UpdateRun}

  @t0 ~U[2026-10-14 10:00:00.000000Z]

  defp machine(name, attrs \\ []) do
    base = [
      name: name,
      kind: :enrolled,
      has_updater: true,
      program_version: "v1.0.0",
      updater_version: "v1.0.0",
      wanted_version: "v1.1.0",
      update_started_at: @t0
    ]

    Repo.insert!(struct(Machine, Keyword.merge(base, attrs)))
  end

  test "nothing is running when no machine was given a version" do
    machine("a", update_started_at: nil, wanted_version: nil)
    assert UpdateRun.current(@t0) == nil
  end

  test "a machine given the version waits, then installs once the updater asked for it" do
    machine("a")
    machine("b", update_asked_at: @t0)

    assert %{version: "v1.1.0", total: 2, done: 0, machines: [a, b]} = UpdateRun.current(@t0)
    assert {a.state, b.state} == {:waiting, :installing}
  end

  test "progress counts the machines that finished, whether they worked or failed" do
    machine("a", wanted_version: nil, update_ok: true, update_version: "v1.1.0")
    machine("b", update_ok: false, update_note: "file in use", update_version: "v1.1.0")
    machine("c")

    run = UpdateRun.current(@t0)
    assert %{total: 3, done: 2} = run

    assert [%{name: "a", state: :done}, %{name: "b", state: :failed, note: "file in use"}, _] =
             run.machines
  end

  test "a machine already on the version counts as done" do
    machine("a", program_version: "v1.1.0", updater_version: "v1.1.0")
    machine("b")
    assert %{done: 1, total: 2} = UpdateRun.current(@t0)
  end

  test "it is over when every machine has finished" do
    machine("a", wanted_version: nil, update_ok: true, update_version: "v1.1.0")
    machine("b", update_ok: false, update_note: "no", update_version: "v1.1.0")
    assert UpdateRun.current(@t0) == nil
    assert [%{name: "b"}] = UpdateRun.failed(@t0)
  end

  test "a machine silent for 50 minutes (the updater's 45 and 5 more) has failed, so the screen cannot stay up" do
    machine("a")
    assert %{done: 0} = UpdateRun.current(DateTime.add(@t0, 2999))
    assert UpdateRun.current(DateTime.add(@t0, 3000)) == nil

    assert [%{state: :failed, note: "did not report back within 50 minutes"}] =
             UpdateRun.failed(DateTime.add(@t0, 3000))
  end

  test "an older finished run is not part of a newer one" do
    machine("old",
      wanted_version: nil,
      update_ok: true,
      update_version: "v1.0.9",
      update_started_at: DateTime.add(@t0, -3600)
    )

    machine("new", update_started_at: DateTime.add(@t0, 60))
    assert %{total: 1, version: "v1.1.0"} = UpdateRun.current(DateTime.add(@t0, 60))
  end

  test "dismissing forgets the failures" do
    machine("b", update_ok: false, update_note: "no", update_version: "v1.1.0")
    UpdateRun.dismiss(@t0)
    assert UpdateRun.failed(@t0) == []
  end
end
