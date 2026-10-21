defmodule DokkitWeb.WhoPick do
  @moduledoc "The choice of who is told, as a row of boxes that saves itself. Used on the Alerts page, a service and a check."
  use Phoenix.Component
  alias Dokkit.People

  attr :scope, :string, required: true
  attr :id, :string, default: ""
  attr :people, :list, required: true
  attr :who, :map, required: true
  attr :above, :string, required: true
  attr :disabled, :boolean, default: false

  def pick(assigns) do
    assigns = assign(assigns, selected: assigns.who[{assigns.scope, assigns.id}] || [])

    ~H"""
    <form
      phx-change="who"
      id={"who-#{@scope}-#{@id}"}
      style="display: flex; flex-wrap: wrap; align-items: center; gap: 4px 14px"
    >
      <input type="hidden" name="who[scope]" value={@scope} />
      <input type="hidden" name="who[id]" value={@id} />
      <input type="hidden" name="who[to][]" value="" />
      <label style="display: inline-flex; align-items: center; gap: 6px">
        <input
          type="checkbox"
          class="chk"
          name="who[to][]"
          value="everyone"
          checked={"everyone" in @selected}
          disabled={@disabled}
        /> Everyone
      </label>
      
      <label style="display: inline-flex; align-items: center; gap: 6px">
        <input
          type="checkbox"
          class="chk"
          name="who[to][]"
          value="oncall"
          checked={"oncall" in @selected}
          disabled={@disabled}
        /> Whoever is on call in PagerDuty
      </label>
      
      <label :for={p <- @people} style="display: inline-flex; align-items: center; gap: 6px">
        <input
          type="checkbox"
          class="chk"
          name="who[to][]"
          value={p.id}
          checked={p.id in @selected}
          disabled={@disabled}
        /> {p.name}
      </label>
       <span :if={@selected == []} class="hint" style="flex-basis: auto">{@above}</span>
    </form>
    """
  end

  @doc "Saves what a pick sent. Ticking Everyone or on call clears the rest; ticking a name clears both."
  def save(%{"scope" => scope, "id" => id, "to" => to}) when is_list(to) do
    to = Enum.reject(to, &(&1 == ""))
    before = People.who(scope, scope_id(scope, id)) || []
    ticked = Enum.find(People.lone(), &(&1 in to and [&1] != before))

    to =
      cond do
        to == before -> to
        ticked -> [ticked]
        true -> to -- People.lone()
      end

    People.set_who(scope, id, to)
  end

  def save(_), do: {:error, "Nothing to save."}

  defp scope_id("default", _), do: ""
  defp scope_id(_, id), do: id
end
