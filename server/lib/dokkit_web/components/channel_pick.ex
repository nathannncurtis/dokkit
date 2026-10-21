defmodule DokkitWeb.ChannelPick do
  @moduledoc "The choice of channels, as a row of boxes: tick as many as should each send their own alert."
  use Phoenix.Component

  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :label, :string, required: true
  attr :blank, :string, default: nil
  attr :disabled, :boolean, default: false

  def pick(assigns) do
    assigns = assign(assigns, selected: Dokkit.Alerts.split(assigns.value))

    ~H"""
    <span
      role="group"
      aria-label={@label}
      style="display: inline-flex; flex-wrap: wrap; align-items: center; gap: 4px 14px"
    >
      <input type="hidden" name={@name <> "[]"} value="" />
      <label
        :for={{text, value} <- @options}
        style="display: inline-flex; align-items: center; gap: 6px"
      >
        <input
          type="checkbox"
          class="chk"
          name={@name <> "[]"}
          value={value}
          checked={value in @selected}
          disabled={@disabled}
        /> {text}
      </label>
       <span :if={@selected == [] and @blank} class="hint" style="flex-basis: auto">{@blank}</span>
    </span>
    """
  end
end
