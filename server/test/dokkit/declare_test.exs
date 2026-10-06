defmodule Dokkit.DeclareTest do
  use DokkitWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias Dokkit.{Check, Issues, Keys, Machine, Repo, Service}

  setup do
    machine = Repo.insert!(%Machine{name: "vault", kind: :enrolled})
    {key, _} = Keys.mint(:machine, %{machine_id: machine.id})
    %{key: key}
  end

  defp put_doc(key, doc) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> key)
    |> put("/api/v1/declare", doc)
  end

  @doc_one %{
    schema: 1,
    service: %{id: "upload-portal", name: "Upload portal"},
    check: [
      %{type: "http", url: "http://localhost:8080/healthz", every: "30s"},
      %{type: "tcp", port: 5432},
      %{type: "tcp", port: 6379}
    ],
    job: [%{id: "nightly-purge", schedule: "0 1 * * *", grace: "30m"}],
    alert: %{down: "push"}
  }

  test "a declaration makes the service and its checks, and the file stays in charge", %{
    conn: conn,
    key: key
  } do
    assert %{"service" => id} = json_response(put_doc(key, @doc_one), 200)
    assert %{"service" => ^id} = json_response(put_doc(key, @doc_one), 200)

    service = Repo.get!(Service, id)

    assert %{name: "Upload portal", kind: :service, route_down: "push", route_degraded: nil} =
             service

    checks = Repo.all(from c in Check, where: c.service_id == ^id, order_by: c.name)
    assert ["http", "nightly-purge", "tcp", "tcp-2"] = Enum.map(checks, & &1.name)
    assert Enum.all?(checks, &(&1.source == :file))
    assert %{type: :job, fail_after: 1, config: %{"schedule" => "0 1 * * *"}} = Enum.at(checks, 1)

    # Three failed checks in a row open an issue, as for any check.
    bad =
      Jason.encode!(%{
        type: "state",
        service: "upload-portal",
        check: "http",
        state: "down",
        note: "connection refused"
      })

    report(key, [bad, bad, bad])

    assert [%{title: "Upload portal: http is down"}] = Issues.open_list()
    assert Repo.get_by!(Check, service_id: id, name: "http").type == :http

    {:ok, _, html} = live(signed_in(conn), "/s/#{id}")
    assert html =~ "http http://localhost:8080/healthz"
    assert html =~ "from dokkit.toml"
    assert html =~ "connection refused"

    # The file drops a check and changes the routing suggestion: the check goes, the routing stays.
    changed = %{
      @doc_one
      | check: [%{type: "http", url: "http://localhost:8080/healthz"}],
        alert: %{down: "page"}
    }

    assert json_response(put_doc(key, changed), 200)

    assert ["http", "nightly-purge"] =
             Repo.all(
               from c in Check, where: c.service_id == ^id, order_by: c.name, select: c.name
             )

    assert Repo.get!(Service, id).route_down == "push"
  end

  test "a declaration that does not fit is refused with the reason", %{key: key} do
    assert %{"error" => %{"message" => "This server reads schema 1."}} =
             json_response(put_doc(key, %{@doc_one | schema: 2}), 422)

    assert json_response(put_doc(key, %{@doc_one | check: [%{type: "ping"}]}), 422)["error"][
             "message"
           ] =~ "ping"

    assert json_response(put_doc(key, %{schema: 1}), 422)
    assert json_response(put_doc("dkm_nope", @doc_one), 401)
    {app, _} = Keys.mint(:app, %{})
    assert json_response(put_doc(app, @doc_one), 403)
  end
end
