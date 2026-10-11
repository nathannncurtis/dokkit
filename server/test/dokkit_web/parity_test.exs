defmodule DokkitWeb.ParityTest do
  # The first rule of the API: nothing can be done in the interface that the API cannot do, and
  # the API asks for no less than the interface does. Every event of every page is listed with
  # the role the page lets do it (read from how the page guards the event) and the API calls
  # that do the same. The role must match the scope the call needs: a viewer reads, a member
  # acts, an owner has admin. Where they differ the stricter side wins.
  use ExUnit.Case, async: true

  # view: only changes what the page shows. session: the full-control token, which is made in
  # Settings on purpose.
  @view :view
  @session :session
  @scopes %{viewer: ~w(read read-logs), member: ~w(act), owner: ~w(admin)}

  @events %{
    "AlertsLive" => %{
      "save" => {:owner, ["PUT /api/v1/alerts"]},
      "changed" => @view,
      "rule" =>
        {:owner, ["POST /api/v1/rules", "PUT /api/v1/rules/:id", "DELETE /api/v1/rules/:id"]},
      "suggestion" =>
        {:owner,
         [
           "POST /api/v1/alerts/suggestions/:id/accept",
           "POST /api/v1/alerts/suggestions/:id/dismiss"
         ]},
      "test" => {:owner, ["POST /api/v1/alerts/test"]},
      "person" => {:owner, ["PUT /api/v1/alerts/people/:id", "POST /api/v1/alerts/test"]},
      "who" => {:owner, ["PUT /api/v1/alerts/who"]}
    },
    "EverythingLive" => %{
      "dep_open" => @view,
      "dependency" => {:owner, ["POST /api/v1/dependencies"]},
      "update" => {:owner, ["POST /api/v1/machines/:id/update"]},
      "update_all" => {:owner, ["POST /api/v1/update-all"]}
    },
    "EnrolLive" => %{
      "token" => {:owner, ["POST /api/v1/keys"]},
      "revoke" => {:owner, ["DELETE /api/v1/keys/:id"]},
      "form" => @view
    },
    "InboxLive" => %{
      "tab" => @view,
      "pick" => @view,
      "pick_all" => @view,
      "span" => @view,
      "snooze" => {:member, ["POST /api/v1/issues/:id/snooze", "POST /api/v1/issues/bulk"]},
      "seen" => {:member, ["POST /api/v1/issues/:id/acknowledge"]},
      "back" => {:member, ["POST /api/v1/issues/:id/unsnooze"]},
      "watch" => {:member, ["POST /api/v1/proposals/:id/accept"]},
      "leave" => {:member, ["POST /api/v1/proposals/:id/dismiss"]}
    },
    "JobsLive" => %{"add" => {:owner, ["POST /api/v1/jobs"]}},
    "LogsLive" => %{"filter" => {:viewer, ["GET /api/v1/logs"]}},
    "ServiceLive" => %{
      "range" =>
        {:viewer, ["GET /api/v1/services/:id/series", "GET /api/v1/machines/:id/series"]},
      "timing_typed" => @view,
      "timing" => {:member, ["PUT /api/v1/jobs/:id/timing"]},
      "route" => {:member, ["PUT /api/v1/services/:id/routing"]},
      "who" => {:owner, ["PUT /api/v1/alerts/who"]},
      "watching" =>
        {:member, ["POST /api/v1/services/:id/watch", "POST /api/v1/services/:id/unwatch"]},
      "hold" => {:member, ["PUT /api/v1/services/:id/hold"]},
      "restart" => {:owner, ["PUT /api/v1/services/:id/restart"]},
      "messages" => {:member, ["PUT /api/v1/services/:id/messages"]},
      "note" => {:member, ["POST /api/v1/issues/:id/notes"]},
      "seen" => {:member, ["POST /api/v1/issues/:id/acknowledge"]},
      "snooze" => {:member, ["POST /api/v1/issues/:id/snooze"]},
      "back" => {:member, ["POST /api/v1/issues/:id/unsnooze"]}
    },
    "SettingsLive" => %{
      "add" => {:owner, ["POST /api/v1/users"]},
      "remove" => {:owner, ["DELETE /api/v1/users/:id"]},
      "restore" => {:owner, ["POST /api/v1/logs/archives/:name/restore"]},
      "revoke" => {:owner, ["DELETE /api/v1/keys/:id"]},
      "token" => {:owner, ["POST /api/v1/keys"]},
      "certificate_save" => {:owner, ["PUT /api/v1/certificate"]},
      "certificate_remove" => {:owner, ["DELETE /api/v1/certificate"]},
      "acme_save" => {:owner, ["PUT /api/v1/certificate/settings"]},
      "acme_now" => {:owner, ["POST /api/v1/certificate/renew"]},
      "full" => @view,
      "full_typed" => @view,
      "full_token" => @session
    },
    "FoundLive" => %{
      "sweep" =>
        {:member,
         [
           "POST /api/v1/proposals/:id/accept",
           "POST /api/v1/proposals/:id/dismiss",
           "POST /api/v1/proposals/accept",
           "POST /api/v1/proposals/dismiss"
         ]},
      "scan" => {:member, ["POST /api/v1/machines/:id/scan"]}
    }
  }

  # Routes served by a controller for a browser, not for a token. The theme is chosen in the
  # browser and never reaches the server.
  @session_only %{
    "GET /login" => "Signing in is a person at a form; a token is its own proof.",
    "POST /login" => "Signing in is a person at a form; a token is its own proof.",
    "POST /logout" => "A session ends; a token is revoked with DELETE /api/v1/keys/:id.",
    "GET /setup" => "First-run setup makes the first owner, once, with the code in the log.",
    "POST /setup" => "First-run setup makes the first owner, once, with the code in the log.",
    "GET /login/code" => "The second step of signing in belongs to the browser.",
    "POST /login/code" => "The second step of signing in belongs to the browser.",
    "GET /two-step" => "A person turns their own two-step sign-in on and off; a token has none.",
    "POST /two-step" => "A person turns their own two-step sign-in on and off; a token has none.",
    "GET /password" => "A person changes their own password; a token has none.",
    "POST /password" => "A person changes their own password; a token has none."
  }

  @api_controllers [
    DokkitWeb.ApiController,
    DokkitWeb.McpController,
    DokkitWeb.IntakeController,
    DokkitWeb.SeqController,
    DokkitWeb.ReleaseController
  ]
  @live Path.expand("../../lib/dokkit_web/live", __DIR__)

  defp routes,
    do:
      Map.new(DokkitWeb.Router.__routes__(), &{String.upcase("#{&1.verb}") <> " " <> &1.path, &1})

  test "every event of every page is listed with the API calls that do the same" do
    for file <- Path.wildcard(Path.join(@live, "*.ex")) do
      module = file |> Path.basename(".ex") |> Macro.camelize()
      listed = @events |> Map.get(module, %{}) |> Map.keys() |> Enum.sort()

      assert events(file) == listed,
             "#{module} events changed. List each in test/dokkit_web/parity_test.exs with its role and the API calls that do the same, or as view or session."
    end
  end

  test "every API call listed is a route the server has" do
    routes = routes()

    for {module, events} <- @events, {event, {_, calls}} <- events, call <- calls do
      assert Map.has_key?(routes, call), "#{module} #{event}: no route #{call}"
    end
  end

  test "the role the page needs is the scope the API needs" do
    for {module, events} <- @events, {event, {role, calls}} <- events, call <- calls do
      [verb, path] = String.split(call, " ")
      need = DokkitWeb.ApiController.needs(verb, String.split(path, "/", trim: true))

      assert need in @scopes[role],
             "#{module} #{event} is for #{role}, but #{call} needs #{need}. Make them agree; the stricter side wins."
    end
  end

  test "every route a browser session alone reaches is listed with its reason" do
    session =
      for {call, route} <- routes(),
          route.plug not in @api_controllers,
          route.plug != Phoenix.LiveView.Plug,
          do: call

    assert Enum.sort(session) == Enum.sort(Map.keys(@session_only)),
           "A controller route that is not the API changed. List it in @session_only with the reason a token does not need it, or give it an API call."
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
