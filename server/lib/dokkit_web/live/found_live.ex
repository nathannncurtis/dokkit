defmodule DokkitWeb.FoundLive do
  @moduledoc "Found: what a scan found on a machine, waiting to be watched or dismissed."
  use DokkitWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, socket),
    do: {:noreply, load(assign(socket, page_title: "Found"))}

  def handle_info(:issues_changed, socket),
    do: {:noreply, DokkitWeb.Auth.debounce(socket, :page, &load/1)}

  def handle_info({:settled, :page}, socket),
    do: {:noreply, DokkitWeb.Auth.settle(socket, :page, &load/1)}

  def handle_event("sweep", %{"do" => what} = params, socket) do
    ids = params["ids"] || []

    case {socket.assigns.current_user.role, what} do
      {:viewer, _} -> nil
      {_, "watch"} -> Dokkit.Found.watch(ids)
      {_, "dismiss"} -> Dokkit.Found.dismiss(ids)
      _ -> nil
    end

    {:noreply, load(socket)}
  end

  defp load(socket),
    do: assign(socket, found: Enum.group_by(Dokkit.Found.list(), & &1.machine))

  def render(assigns) do
    assigns = assign(assigns, viewer: assigns.current_user.role == :viewer)

    ~H"""
    <Layouts.app active={:found} shell={@shell} user={@current_user}>
      <div class="head">
        <h1 tabindex="-1">
          {if @found != %{}, do: "Found, waiting for you", else: @page_title}
        </h1>
      </div>
      
      <div class="body">
        <form class="card" id="found-form" phx-submit="sweep">
          <h2>
            What a scan found<span :if={@found != %{}} class="cnt">{@found
            |> Map.values()
            |> Enum.map(&length/1)
            |> Enum.sum()}</span>
            <span :if={@found != %{}} class="end">
              <button class="btn sm primary" name="do" value="watch" disabled={@viewer}>
                <.ic name="plus" />Watch selected
              </button>
              
              <button class="btn sm" name="do" value="dismiss" disabled={@viewer}>
                Dismiss selected
              </button>
            </span>
          </h2>
          
          <div :if={@found == %{}} class="empty">
            <.ic name="check-circle" />Nothing a scan found is waiting. On a machine, dokkit scan looks and dokkit propose sends what it saw.
          </div>
          
          <div :if={@found != %{}} class="lh cols-found">
            <span></span><span>Found</span><span>How it was found</span><span>What Dokkit saw</span><span></span>
          </div>
          
          <%= for {machine, items} <- @found do %>
            <div class="mg" role="group" aria-labelledby={"fh-#{machine.id}"}>
              <div class="grp">
                <span id={"fh-#{machine.id}"}>{machine.name}</span><span class="end"><span class="tag">{length(
                  items
                )} found</span></span>
              </div>
              
              <label :for={f <- items} class="li slim kid hov cols-found">
                <input
                  class="chk"
                  type="checkbox"
                  name="ids[]"
                  value={f.id}
                  aria-label={"Select " <> f.detail["label"]}
                />
                <div class="ti"><span>{f.detail["label"]}</span></div>
                
                <span class="how">{if f.kind == "port", do: "Listening port", else: "Running service"}</span>
                <span class="mute">{f.detail["saw"]}</span> <span></span>
              </label>
            </div>
          <% end %>
          
          <div :if={@found != %{}} class="foot">
            Nothing here is watched until you say so. Watching one adds a check that dokkit watch runs on that machine.
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
