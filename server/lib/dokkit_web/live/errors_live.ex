defmodule DokkitWeb.ErrorsLive do
  use DokkitWeb, :live_view
  alias Dokkit.Errors

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(params, _uri, socket), do: {:noreply, load(assign(socket, id: params["id"]))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  defp load(%{assigns: %{id: nil}} = socket) do
    errors = Errors.list(limit: 201)

    assign(socket,
      page_title: "Errors",
      errors: Enum.take(errors, 200),
      more: length(errors) > 200,
      error: nil
    )
  end

  defp load(%{assigns: %{id: id}} = socket) do
    case Errors.get(id) do
      nil -> push_navigate(socket, to: ~p"/errors")
      error -> assign(socket, page_title: error.group.type, error: error)
    end
  end

  defp lede([], _), do: "No errors have been reported. Apps send theirs here as they happen."

  defp lede(_, true),
    do: "The 200 kinds of error seen most recently, newest first. Older ones are not shown."

  defp lede(errors, _),
    do: "#{plural(length(errors), "kind of error", "kinds of error")}, the most recent first."

  defp plural(1, one, _), do: "1 #{one}"
  defp plural(n, _, many), do: "#{n} #{many}"

  def render(%{error: nil} = assigns) do
    ~H"""
    <Layouts.app active={:errors} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">Errors</h1>

        <p class="lede">{lede(@errors, assigns[:more])}</p>
      </div>

      <div class="body">
        <div class="card">
          <div :if={@errors == []} class="empty">
            <.ic name="check-circle" />No errors have been reported.
          </div>

          <div :if={@errors != []} class="lh cols-inbox cols-err">
            <span>Error</span><span></span><span class="r">Count</span><span class="pl">Machine</span><span>Last seen</span><span></span>
          </div>

          <.link :for={g <- @errors} class="li cols-inbox cols-err" navigate={~p"/errors/#{g.id}"}>
            <div>
              <div class="ti"><.ic name="bug" /><span>{g.type}</span></div>

              <div class="sub mono">{g.top}</div>

              <div class="meta">
                <span class="tag">{g.service.name}</span>
                <span :if={g.release} class="tag mono">{g.release}</span>
                <span :if={g.handled} class="tag">Caught by the app</span>
              </div>
            </div>
            <span></span>
            <div class="num">{g.count}<small>reports</small></div>

            <span class="tag" title={g.host || g.service.machine.name}>{g.host ||
              g.service.machine.name}</span> <span class="mono">{at(g.last_seen)}</span>
            <.ic name="caret-right" />
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, g: assigns.error.group, latest: assigns.error.latest)

    ~H"""
    <Layouts.app active={:errors} shell={@shell} user={@current_user}>
      <div class="crumb">
        <.link navigate={~p"/errors"}>Errors</.link><.ic name="caret-right" /><span>{@g.type}</span>
      </div>

      <div class="head">
        <h1 tabindex="-1"><.ic name="bug" /> {@g.type}</h1>

        <div class="end">
          <.link class="btn" navigate={~p"/logs?#{[s: @g.service_id]}"}><.ic name="scroll" />Logs</.link>
        </div>
      </div>

      <div class="filters" style="padding-top:10px">
        <span class="tag">{@g.count} reports</span>
        <span class="st">since <span class="mono">{at(@g.first_seen)}</span></span>
      </div>

      <div class="body rail">
        <div :if={@latest && @latest.message} class="card">
          <h2>Message<span class="end">From the latest report</span></h2>

          <p class="lead mono">{@latest.message}</p>
        </div>

        <div class="card">
          <h2>Stack<span class="end">The app's own code is marked</span></h2>

          <p :if={!@latest or @latest.frames == []} class="lead">
            No stack came with the latest report.
          </p>

          <div
            :for={f <- Enum.reverse((@latest && @latest.frames) || [])}
            class={["li slim fr", if(f["own"], do: "own", else: "lib")]}
          >
            <span class="mono">{f["file"]} <span :if={f["own"]} class="tag">App</span></span>
            <span class="mono mute">{f["function"]}</span>
            <span class="mono mute r">{f["line"] && "line #{f["line"]}"}</span>
          </div>

          <div class="foot">Dokkit does not keep the message text of an error.</div>
        </div>

        <div class="card">
          <h2>Details</h2>

          <dl class="kv">
            <dt>Service</dt>

            <dd><.link navigate={~p"/s/#{@g.service_id}"}>{@g.service.name}</.link></dd>

            <dt>Release</dt>

            <dd class="mono">{@g.release}</dd>

            <dt>First seen</dt>

            <dd class="mono">{at(@g.first_seen)}</dd>

            <dt>Last seen</dt>

            <dd class="mono">{at(@g.last_seen)}</dd>

            <dt>Machine</dt>

            <dd>{@g.host || @g.service.machine.name}</dd>

            <dt>Caught</dt>

            <dd>{if @g.handled, do: "By the app", else: "No"}</dd>

            <dt :if={@latest && @latest.tags != %{}}>Tags</dt>

            <dd :if={@latest && @latest.tags != %{}}>
              <span :for={{k, v} <- @latest.tags} class="tag">{k}: {v}</span>
            </dd>
          </dl>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
