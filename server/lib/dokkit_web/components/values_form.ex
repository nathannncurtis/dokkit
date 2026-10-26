defmodule DokkitWeb.ValuesForm do
  @moduledoc "A group of settings that folds open: each row with its control, its default and a Reset. Used on Settings, a machine's page and Jobs."
  use Phoenix.Component
  import DokkitWeb.Show, only: [ic: 1]
  alias Dokkit.Values

  attr :id, :string, required: true
  attr :group, :string, required: true
  attr :scope, :any, required: true
  attr :icon, :string, default: "sliders-horizontal"
  attr :title, :string, required: true
  attr :sub, :string, required: true
  attr :open, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :result, :any, default: nil
  attr :target, :string, default: nil
  attr :draft, :map, default: %{}
  attr :change, :string, default: nil

  def fold(assigns) do
    view = Values.view(assigns.scope)
    rows = Values.rows(assigns.group, assigns.scope)

    assigns =
      assign(assigns,
        rows: rows,
        values: Map.merge(view["values"], Map.take(assigns.draft, Map.keys(view["values"]))),
        base: view["defaults"],
        changed: view["changed"]
      )

    ~H"""
    <details
      :if={@rows != []}
      class="card fold"
      id={@id}
      open={@open}
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
    >
      <summary>
        <span class="fold-ic" aria-hidden="true"><.ic name={@icon} /></span>
        <span class="fold-t"><b>{@title}</b><span class="mute">{@sub}</span></span>
        <.ic name="caret-down" />
      </summary>
      <form phx-submit="values_save" phx-change={@change} id={"#{@id}-form"}>
        <input type="hidden" name="group" value={@group} />
        <input :if={@target} type="hidden" name="target" value={@target} />
        <div
          :for={r <- @rows}
          class={["cfg-row", differs?(r, @changed) && "changed", off?(r, @values) && "off"]}
          id={"#{@id}-#{r.id}"}
        >
          <div>
            <h3>{r.title}</h3>
            <p class="mute">{r.sub}</p>
          </div>
          <div class="ctl">
            <%= if r[:toggle] do %>
              <input type="hidden" name={"values[#{elem(r.toggle, 0)}]"} value="false" />
              <input
                type="checkbox"
                class="switch"
                name={"values[#{elem(r.toggle, 0)}]"}
                value="true"
                checked={on?(@values[elem(r.toggle, 0)])}
                disabled={@disabled}
                aria-label={r.title}
              />
            <% end %>
            <%= for {w, f} <- pairs(r) do %>
              <span :if={w != ""}>{w}</span>
              <input
                :if={f && tuple_size(f) == 4}
                class="inp sm"
                type="number"
                name={"values[#{elem(f, 0)}]"}
                value={@values[elem(f, 0)]}
                min={elem(f, 2)}
                max={elem(f, 3)}
                step="1"
                disabled={@disabled}
                aria-label={"#{r.title}: #{String.trim(w)}"}
              />
              <input
                :if={f && tuple_size(f) == 3}
                class="inp"
                type="text"
                name={"values[#{elem(f, 0)}]"}
                value={@values[elem(f, 0)]}
                disabled={@disabled}
                aria-label={r.title}
              />
            <% end %>
          </div>
          <span class="def">
            Default: {Values.say(r, @base)}
            <button
              :if={differs?(r, @changed) and not @disabled}
              type="button"
              phx-click="values_reset"
              phx-value-group={@group}
              phx-value-row={r.id}
              phx-value-target={@target}
            >
              Reset
            </button>
          </span>
        </div>
        <div class="foot">
          <span
            :if={@result && elem(@result, 0) == (@target || @group)}
            class={elem(@result, 1) == :error && "bad"}
            role="status"
          >
            {elem(@result, 2)}
          </span>
          <span :if={!(@result && elem(@result, 0) == (@target || @group))} class="mute">
            Changes apply as soon as you save.
          </span>
          <span class="end">
            <button class="btn primary" type="submit" disabled={@disabled}>Save</button>
          </span>
        </div>
      </form>
    </details>
    """
  end

  defp pairs(r) do
    n = max(length(r.words), length(r.fields))
    for i <- 0..(n - 1)//1, do: {Enum.at(r.words, i) || "", Enum.at(r.fields, i)}
  end

  defp keys(r),
    do: Enum.map(if(r[:toggle], do: [r.toggle | r.fields], else: r.fields), &elem(&1, 0))

  defp differs?(r, changed), do: Enum.any?(keys(r), &(&1 in changed))
  defp off?(%{toggle: {on, _}}, values), do: not on?(values[on])
  defp off?(_, _), do: false
  defp on?(v), do: v in [true, "true"]

  @doc "Saves a submitted fold, or resets one row, for the scope. Returns the result line for the fold."
  def save(scope, %{"group" => group} = params) do
    group = params["target"] || group

    case Values.save(scope, params["values"] || %{}) do
      {:ok, view} ->
        n = length(view["changed"])

        {group, :ok,
         if(n == 0,
           do: "Saved. Everything here is on its default.",
           else:
             "Saved. #{n} #{if n == 1, do: "setting differs", else: "settings differ"} from the default."
         )}

      {:error, why} ->
        {group, :error, why}
    end
  end

  def reset(scope, %{"group" => group, "row" => row} = params) do
    group = params["target"] || group

    case Values.reset(scope, row) do
      {:ok, _} -> {group, :ok, "Back to the default."}
      {:error, why} -> {group, :error, why}
    end
  end
end
