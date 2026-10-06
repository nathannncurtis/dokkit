defmodule Dokkit.BeatsTest do
  use DokkitWeb.ConnCase, async: true
  alias Dokkit.{Issues, Keys, Machine, Repo, Service, Watch}

  test "an app that stops beating opens an issue, and a beat closes it" do
    machine = Repo.insert!(%Machine{name: "vault"})

    service =
      Repo.insert!(%Service{machine_id: machine.id, slug: "portal", name: "Upload portal"})

    {app, _} = Keys.mint(:app, %{service_id: service.id})
    beat = %{type: "beat", name: "worker", every_seconds: 30}

    assert %{"accepted" => 1, "refused" => [%{"code" => "bad_line"}]} =
             json_response(report(app, [beat, %{type: "beat"}]), 200)

    now = DateTime.utc_now()
    assert Watch.sweep(DateTime.add(now, 100)) == 0
    assert Watch.sweep(DateTime.add(now, 130)) == 1
    assert Watch.sweep(DateTime.add(now, 190)) == 0

    assert [
             %{
               title: "Upload portal: worker went quiet",
               check: %{note: "No beat for 2 min" <> _}
             }
           ] =
             Issues.open_list()

    report(app, [beat])
    assert Issues.open_list() == []
  end
end
