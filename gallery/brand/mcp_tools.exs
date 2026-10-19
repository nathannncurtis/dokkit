# Writes mcp-tools.json from the server's MCP tool list. From server/: mix run --no-start ../gallery/brand/mcp_tools.exs ../gallery/brand/mcp-tools.json
lines = File.read!("lib/dokkit_web/controllers/mcp_controller.ex") |> String.split("\n")
from = Enum.find_index(lines, &String.starts_with?(&1, "  @data_note"))
to = Enum.find_index(lines, &String.starts_with?(&1, "  def rpc(")) - 1
body = lines |> Enum.slice(from..to) |> Enum.join("\n")
Code.compile_string("defmodule McpDump do\n" <> body <> "\n def t, do: @tools\nend")
out = for {n, s, d, p, r} <- McpDump.t(), do: %{name: n, scope: s, description: d, args: Map.keys(p), required: r}
File.write!(System.argv() |> hd(), Jason.encode!(out, pretty: true))
IO.puts(length(out))
