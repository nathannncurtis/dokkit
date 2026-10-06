defmodule DokkitWeb.OpenapiTest do
  use ExUnit.Case, async: true

  @verbs ~w(get post put delete patch options head)

  test "spec/openapi.json lists exactly the API routes the router serves" do
    doc = Path.expand("../../../spec/openapi.json", __DIR__) |> File.read!() |> Jason.decode!()

    documented =
      for {path, item} <- doc["paths"], verb <- Map.keys(item), verb in @verbs, into: MapSet.new() do
        {verb, path}
      end

    routed =
      for %{path: path, verb: verb} <- DokkitWeb.Router.__routes__(),
          String.starts_with?(path, "/api/") or path == "/mcp",
          into: MapSet.new() do
        {verb |> to_string() |> String.downcase(), Regex.replace(~r/:(\w+)/, path, "{\\1}")}
      end

    assert MapSet.to_list(MapSet.difference(routed, documented)) == []
    assert MapSet.to_list(MapSet.difference(documented, routed)) == []
  end
end
