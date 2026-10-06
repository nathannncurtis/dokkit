defmodule DokkitWeb.Show do
  @moduledoc "How states, times and durations are written on every page."
  use Phoenix.Component

  attr :state, :atom, required: true

  def lvl(assigns) do
    ~H"""
    <span class={["lvl", lvl_class(@state)]} role="img" aria-label={say(@state)}></span>
    """
  end

  attr :name, :string, required: true

  def ic(assigns) do
    ~H"""
    <i class={"ph ph-#{@name}"} aria-hidden="true"></i>
    """
  end

  def lvl_class(:ok), do: ""
  def lvl_class(state) when state in [:degraded, :down], do: "warn"
  def lvl_class(_), do: "away"

  def say(:ok), do: "Fine"
  def say(state) when state in [:degraded, :down], do: "Needs a look"
  def say(_), do: "No signal yet"

  def at(nil), do: nil
  def at(%DateTime{} = t), do: Calendar.strftime(t, "%b %-d %H:%M")

  def took(nil), do: ""
  def took(ms) when ms < 1000, do: "#{ms} ms"
  def took(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  def took(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"

  def kind(:job), do: "Job"
  def kind(:dependency), do: "Dependency"
  def kind(:app), do: "Desktop app"
  def kind(_), do: "Service"
end
