defmodule Dokkit.DeclareCasesTest do
  use Dokkit.DataCase, async: false
  alias Dokkit.{Estate, Machine, Repo}

  @cases Path.expand("../../../spec/declare-cases.json", __DIR__)
         |> File.read!()
         |> Jason.decode!()

  test "the files in spec/declare-cases.json are taken or refused as the program's check says" do
    for %{"name" => name, "ok" => ok, "doc" => doc} <- @cases do
      m =
        Repo.insert!(%Machine{
          name: "case-#{System.unique_integer([:positive])}",
          kind: :enrolled
        })

      result = Estate.declare(m.id, doc)

      assert match?({:ok, _}, result) == ok, "#{name}: #{inspect(result)}"
    end
  end
end
