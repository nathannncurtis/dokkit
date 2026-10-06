defmodule DokkitWeb.ConnCase do
  @moduledoc "Tests that make requests."
  use ExUnit.CaseTemplate
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint DokkitWeb.Endpoint

  using do
    quote do
      @endpoint DokkitWeb.Endpoint

      use DokkitWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import DokkitWeb.ConnCase
    end
  end

  setup tags do
    Dokkit.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def signed_in(conn) do
    user =
      Dokkit.Repo.get_by(Dokkit.User, name: "sam") ||
        Dokkit.Repo.insert!(%Dokkit.User{name: "sam", password_hash: "-", role: :owner})

    Plug.Test.init_test_session(conn, %{
      "user_id" => user.id,
      "signed_at" => Dokkit.Accounts.stamp()
    })
  end

  @doc "Posts lines to the report address. A line is a map, or text sent as it is."
  def report(key, lines, headers \\ []) do
    body = Enum.map_join(lines, "\n", &if(is_binary(&1), do: &1, else: Jason.encode!(&1)))

    Enum.reduce(headers, build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> put_req_header("authorization", "Bearer " <> key)
    |> put_req_header("content-type", "application/x-ndjson")
    |> post("/api/v1/report", body)
  end
end
