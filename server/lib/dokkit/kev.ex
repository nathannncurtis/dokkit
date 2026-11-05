defmodule Dokkit.Kev do
  @moduledoc "CISA's Known Exploited Vulnerabilities list, fetched at most twice a day and kept in memory."
  require Logger

  @url "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
  @fresh_ms 12 * 60 * 60 * 1000
  @retry_ms 15 * 60 * 1000
  @key {__MODULE__, :cache}

  def listed?(cve) when is_binary(cve) and cve != "",
    do: MapSet.member?(ids(), String.upcase(String.trim(cve)))

  def listed?(_), do: false

  @doc false
  def reset, do: :persistent_term.erase(@key)

  # The cache is {ids, last try, last success}, in monotonic milliseconds.
  defp ids do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@key, nil) do
      {ids, _tried, ok_at} when now - ok_at < @fresh_ms -> ids
      {ids, tried, _} when now - tried < @retry_ms -> ids
      cached -> refresh(now, cached)
    end
  end

  defp refresh(now, cached) do
    {old, ok_at} = if cached, do: {elem(cached, 0), elem(cached, 2)}, else: {MapSet.new(), nil}

    case fetch() do
      {:ok, ids} ->
        :persistent_term.put(@key, {ids, now, now})
        ids

      {:error, why} ->
        Logger.warning("The known exploited vulnerabilities list was not fetched: #{why}")
        :persistent_term.put(@key, {old, now, ok_at || now - @fresh_ms})
        old
    end
  end

  defp fetch do
    opts =
      [retry: false, receive_timeout: 15_000, redirect: false] ++
        Application.get_env(:dokkit, :req_options, [])

    case Req.get(@url, opts) do
      {:ok, %{status: 200, body: %{"vulnerabilities" => list}}} when is_list(list) ->
        {:ok, for(%{"cveID" => id} <- list, into: MapSet.new(), do: String.upcase(id))}

      {:ok, %{status: s}} ->
        {:error, "answered #{s}"}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
