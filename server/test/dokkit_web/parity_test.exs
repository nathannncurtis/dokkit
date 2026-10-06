defmodule DokkitWeb.ParityTest do
  # The first rule of the API: nothing can be done in the interface that the API cannot do.
  # Every event of every page is listed with the API calls that do the same, or why it has none.
  use ExUnit.Case, async: true

  @view :view
  @session :session
  # view: only changes what the page shows. session: the full-control token, which is made in
  # Settings on purpose.
  @events %{
    "AlertsLive" => %{
      "save" => ["PUT /api/v1/alerts"],
      "changed" => @view,
      "rule" => ["POST /api/v1/rules", "PUT /api/v1/rules/:id", "DELETE /api/v1/rules/:id"],
      "suggestion" => [
        "POST /api/v1/alerts/suggestions/:id/accept",
        "POST /api/v1/alerts/suggestions/:id/dismiss"
      ],
      "test" => ["POST /api/v1/alerts/test"]
    },
    "DeploysLive" => %{"fetch" => ["POST /api/v1/machines/:id/update"]},
    "EnrolLive" => %{"token" => ["POST /api/v1/keys"]},
    "InboxLive" => %{
      "tab" => @view,
      "pick" => @view,
      "pick_all" => @view,
      "span" => @view,
      "snooze" => ["POST /api/v1/issues/:id/snooze", "POST /api/v1/issues/bulk"],
      "seen" => ["POST /api/v1/issues/:id/acknowledge"],
      "back" => ["POST /api/v1/issues/:id/unsnooze"],
      "watch" => ["POST /api/v1/proposals/:id/accept"],
      "leave" => ["POST /api/v1/proposals/:id/dismiss"]
    },
    "JobsLive" => %{"add" => ["POST /api/v1/jobs"]},
    "LogsLive" => %{"filter" => ["GET /api/v1/logs"]},
    "ServiceLive" => %{
      "timing_typed" => @view,
      "timing" => ["PUT /api/v1/jobs/:id/timing"],
      "route" => ["PUT /api/v1/services/:id/routing"],
      "watching" => ["POST /api/v1/services/:id/watch", "POST /api/v1/services/:id/unwatch"],
      "hold" => ["PUT /api/v1/services/:id/hold"],
      "restart" => ["PUT /api/v1/services/:id/restart"],
      "messages" => ["PUT /api/v1/services/:id/messages"],
      "note" => ["POST /api/v1/issues/:id/notes"],
      "seen" => ["POST /api/v1/issues/:id/acknowledge"],
      "snooze" => ["POST /api/v1/issues/:id/snooze"],
      "back" => ["POST /api/v1/issues/:id/unsnooze"]
    },
    "SettingsLive" => %{
      "add" => ["POST /api/v1/users"],
      "remove" => ["DELETE /api/v1/users/:id"],
      "restore" => ["POST /api/v1/logs/archives/:name/restore"],
      "revoke" => ["DELETE /api/v1/keys/:id"],
      "token" => ["POST /api/v1/keys"],
      "full" => @view,
      "full_typed" => @view,
      "full_token" => @session
    },
    "TasksLive" => %{
      "accepted" => ["POST /api/v1/tasks/:id/accept"],
      "dismissed" => ["POST /api/v1/tasks/:id/dismiss"],
      "sweep" => ["POST /api/v1/proposals/:id/accept", "POST /api/v1/proposals/:id/dismiss"],
      "run" => ["POST /api/v1/tasks/:id/run"]
    }
  }

  @live Path.expand("../../lib/dokkit_web/live", __DIR__)

  test "every event of every page is listed with the API calls that do the same" do
    for file <- Path.wildcard(Path.join(@live, "*.ex")) do
      module = file |> Path.basename(".ex") |> Macro.camelize()
      listed = @events |> Map.get(module, %{}) |> Map.keys() |> Enum.sort()

      assert events(file) == listed,
             "#{module} events changed. List each in test/dokkit_web/parity_test.exs with the API calls that do the same, or as view or session."
    end
  end

  test "every API call listed is a route the server has" do
    routes =
      MapSet.new(DokkitWeb.Router.__routes__(), &(String.upcase("#{&1.verb}") <> " " <> &1.path))

    for {module, events} <- @events, {event, calls} <- events, is_list(calls), call <- calls do
      assert call in routes, "#{module} #{event}: no route #{call}"
    end
  end

  defp events(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_, found} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:when, _, [{:handle_event, _, [name | _]}, guard]} | _]} = n, acc ->
          {n, names(name, guard) ++ acc}

        {:def, _, [{:handle_event, _, [name | _]} | _]} = n, acc ->
          {n, names(name, nil) ++ acc}

        n, acc ->
          {n, acc}
      end)

    found |> Enum.uniq() |> Enum.sort()
  end

  defp names(name, _) when is_binary(name), do: [name]

  defp names({_, _, _}, {:in, _, [_, {:sigil_w, _, [{:<<>>, _, [words]}, _]}]}),
    do: String.split(words)

  defp names(_, _), do: flunk("A handle_event clause this test cannot read: name it as text.")
end
