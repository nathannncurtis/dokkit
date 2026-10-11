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

  attr :values, :list, required: true

  @doc "A row of bars, one for each value. A gap is a time with no number."
  def spark(assigns) do
    top = assigns.values |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, top: if(top > 0, do: top, else: 1), n: length(assigns.values))

    ~H"""
    <svg class="spark" width={@n * 5 - 1} height="28" role="img" aria-label="The last 24 hours">
      <rect
        :for={{v, i} <- Enum.with_index(@values)}
        :if={v}
        x={i * 5}
        width="4"
        y={28 - max(2, round(v / @top * 28))}
        height={max(2, round(v / @top * 28))}
      />
    </svg>
    """
  end

  attr :points, :list, required: true
  attr :limit, :any, default: nil
  attr :label, :string, required: true

  @doc "A line of percent readings across the points' span. A gap is a time with no number."
  def line(assigns) do
    values = assigns.points |> Enum.map(& &1.value) |> Enum.reject(&is_nil/1)
    limit = assigns.limit
    all = if limit, do: [limit | values], else: values
    lo = max(0, floor((Enum.min(all, fn -> 0 end) - 3) / 10) * 10)
    hi = min(100, max(lo + 10, ceil((Enum.max(all, fn -> 100 end) + 3) / 10) * 10))
    n = max(length(assigns.points) - 1, 1)
    x = fn i -> Float.round(54 + 538 * i / n, 1) end
    y = fn v -> Float.round(120 - 110 * (v - lo) / (hi - lo), 1) end

    path =
      assigns.points
      |> Enum.with_index()
      |> Enum.chunk_by(fn {p, _} -> is_nil(p.value) end)
      |> Enum.reject(fn [{p, _} | _] -> is_nil(p.value) end)
      |> Enum.map_join(" ", fn [{p, i} | rest] ->
        "M#{x.(i)} #{y.(p.value)}" <>
          if(rest == [],
            do: " h0.1",
            else: Enum.map_join(rest, "", fn {q, j} -> " L#{x.(j)} #{y.(q.value)}" end)
          )
      end)

    first = List.first(assigns.points)
    last = List.last(assigns.points)

    assigns =
      assign(assigns,
        lo: lo,
        hi: hi,
        mid: (lo + hi) / 2,
        path: path,
        y: y,
        first: first && first.at,
        last: last && last.at
      )

    ~H"""
    <svg viewBox="0 0 600 150" role="img" aria-label={@label} class="line">
      <line :for={v <- [@lo, @mid, @hi]} x1="54" x2="592" y1={@y.(v)} y2={@y.(v)} />
      <text :for={v <- [@lo, @mid, @hi]} x="48" y={@y.(v) + 4} text-anchor="end">{round(v)}%</text>
       <line :if={@limit} class="mk" x1="54" x2="592" y1={@y.(@limit)} y2={@y.(@limit)} />
      <text :if={@limit} class="mk" x="592" y={@y.(@limit) - 4} text-anchor="end">
        limit {round(@limit)}%
      </text>
       <path d={@path} />
      <text x="54" y="144">{at(@first)}</text>
      
      <text x="592" y="144" text-anchor="end">{at(@last)}</text>
    </svg>
    """
  end

  def at(nil), do: nil
  def at(%DateTime{} = t), do: Calendar.strftime(t, "%b %-d %H:%M")

  def took(nil), do: ""
  def took(ms) when ms < 1000, do: "#{ms} ms"
  def took(ms) when ms < 120_000, do: "#{div(ms, 1000)} s"

  def took(ms) do
    minutes = round(ms / 60_000)

    cond do
      minutes < 120 -> "#{minutes} minutes"
      minutes < 2880 -> "#{whole(minutes / 60)} hours"
      true -> "#{whole(minutes / 1440)} days"
    end
  end

  defp whole(n) do
    n = Float.round(n, 1)
    if n == trunc(n), do: trunc(n), else: n
  end

  def kind(:job), do: "Job"
  def kind(:dependency), do: "Dependency"
  def kind(:app), do: "Desktop app"
  def kind(_), do: "Service"
end
