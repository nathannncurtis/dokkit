defmodule Dokkit.AppUpdates do
  @moduledoc "App releases fetched from GitHub, installed by the Dokkit updater on monitored machines by their own [app] recipe."
  import Ecto.Query
  alias Dokkit.{AppRelease, AppTarget, Check, Deploy, Issues, Machine, Releases, Repo, Service}
  alias Dokkit.{Setting, Values}

  @kinds ~w(windows-service installer compose systemd launchd)
  @swaps ~w(windows-service systemd launchd)
  @modes ~w(click automatic)
  @flags ~w(hold require_signature)
  @defaults %{
    "repo" => "",
    "assets" => %{},
    "mode" => "click",
    "hold" => false,
    "signer" => "",
    "require_signature" => true
  }
  @fields Map.keys(@defaults)
  @by "Dokkit updater"
  @check "dokkit.app-update"
  @api "https://api.github.com"

  def kinds, do: @kinds
  def defaults, do: @defaults

  @doc "What is wrong with a dokkit.toml's [app] table, in the program's words, or nil."
  def recipe_error(nil), do: nil
  def recipe_error(app) when not is_map(app), do: "[app] is a table."

  def recipe_error(app) do
    kind = app["kind"]

    cond do
      kind not in @kinds ->
        "app.kind is one of #{Enum.join(@kinds, ", ")}."

      kind in @swaps and not text?(app["name"]) ->
        "app.name names the service, unit or label to restart."

      kind in @swaps and text?(app["folder"]) == text?(app["file"]) ->
        "app names a folder or a file to replace, one of the two."

      kind == "compose" and not (text?(app["compose_file"]) and text?(app["compose_service"])) ->
        "app.compose_file and app.compose_service name the Compose file and its service."

      Map.has_key?(app, "health_wait") and not wait?(duration(app["health_wait"])) ->
        "app.health_wait is a time such as 5m, from 10s to 1h."

      Map.has_key?(app, "args") and
          not (is_list(app["args"]) and Enum.all?(app["args"], &is_binary/1)) ->
        "app.args is a list of text."

      true ->
        nil
    end
  end

  defp text?(v), do: is_binary(v) and String.trim(v) != ""
  defp wait?(n), do: is_number(n) and n >= 10 and n <= 3600

  @units %{"ms" => 0.001, "s" => 1, "m" => 60, "h" => 3600}

  defp duration(text) when is_binary(text) do
    if text =~ ~r/\A(\d+(\.\d+)?(ms|s|m|h))+\z/ do
      ~r/(\d+(?:\.\d+)?)(ms|s|m|h)/
      |> Regex.scan(text)
      |> Enum.reduce(0, fn [_, n, u], acc -> acc + elem(Float.parse(n), 0) * @units[u] end)
    end
  end

  defp duration(_), do: nil

  @doc "Keeps what a machine's own dokkit.toml says about installing its service, or forgets it."
  def declared(machine_id, slug, nil) do
    Repo.delete_all(
      from t in AppTarget,
        where: t.machine_id == ^machine_id and t.app == ^slug and is_nil(t.wanted_version)
    )

    :ok
  end

  def declared(machine_id, slug, recipe) do
    Repo.insert!(%AppTarget{app: slug, machine_id: machine_id, recipe: recipe},
      on_conflict: {:replace, [:recipe, :updated_at]},
      conflict_target: [:app, :machine_id]
    )

    :ok
  end

  ## Settings

  defp key(app), do: "app_updates:" <> app

  def settings(app), do: Map.merge(@defaults, Map.take(Setting.get(key(app)), @fields))

  def app?(app),
    do: Releases.name?(app) and Repo.exists?(from s in Service, where: s.slug == ^app)

  @doc """
  Changes an app's settings. A value of nil or an empty text puts it back to its default; a key
  left out stays as it was. `{:ok, view}` or `{:error, code, text}`.
  """
  def save(app, params) when is_map(params) do
    unknown = Map.keys(params) -- @fields

    cond do
      not app?(app) ->
        {:error, "not_found", "No such app."}

      unknown != [] ->
        {:error, "bad_setting",
         "#{Enum.join(Enum.sort(unknown), ", ")} is not an app setting. They are #{Enum.join(Enum.sort(@fields), ", ")}."}

      true ->
        with {:ok, parsed} <- parse_all(params) do
          stored =
            Enum.reduce(parsed, Setting.get(key(app)), fn
              {k, :reset}, acc -> Map.delete(acc, k)
              {k, v}, acc -> Map.put(acc, k, v)
            end)

          was = settings(app)
          Setting.put(key(app), stored)
          next = settings(app)

          # Another repository's release of the same tag is other bytes; nothing held before stays.
          if next["repo"] != was["repo"] do
            Repo.delete_all(from r in AppRelease, where: r.app == ^app)
            File.rm_rf(Path.join([Releases.dir(), ".apps", app]))
          end

          if next["hold"] do
            Repo.update_all(
              from(t in AppTarget,
                where: t.app == ^app and not is_nil(t.wanted_version) and is_nil(t.asked_at)
              ),
              set: [wanted_version: nil, started_at: nil, auto: false]
            )
          end

          Issues.changed(false)
          {:ok, view(app)}
        end
    end
  end

  def save(_, _), do: {:error, "bad_setting", "Send the settings as an object."}

  defp parse_all(params) do
    Enum.reduce_while(params, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case parse(k, v) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, k, value)}}
        {:error, why} -> {:halt, {:error, "bad_setting", why}}
      end
    end)
  end

  defp parse(_, v) when v in [nil, ""], do: {:ok, :reset}

  defp parse("repo", v) when is_binary(v) do
    repo =
      v
      |> String.trim()
      |> String.replace_prefix("https://github.com/", "")
      |> String.replace_suffix(".git", "")
      |> String.trim("/")

    if repo =~ ~r/\A[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}\z/,
      do: {:ok, repo},
      else: {:error, "repo is a GitHub repository, owner/name."}
  end

  defp parse("mode", v) when v in @modes, do: {:ok, v}
  defp parse("mode", _), do: {:error, "mode is click or automatic."}
  defp parse(flag, v) when flag in @flags and is_boolean(v), do: {:ok, v}
  defp parse(flag, v) when flag in @flags and v in ["true", "false"], do: {:ok, v == "true"}
  defp parse(flag, _) when flag in @flags, do: {:error, "#{flag} is true or false."}

  defp parse("signer", v) when is_binary(v) do
    if String.length(String.trim(v)) <= 200,
      do: {:ok, String.trim(v)},
      else: {:error, "signer is at most 200 characters."}
  end

  defp parse("assets", v) when is_binary(v) do
    v
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.split(String.trim(&1), ~r/\s+/, parts: 2))
    |> Enum.reject(&(&1 == [""]))
    |> Enum.reduce_while(%{}, fn
      [platform, pattern], acc -> {:cont, Map.put(acc, platform, pattern)}
      _, _ -> {:halt, :error}
    end)
    |> case do
      :error -> {:error, assets_words()}
      map -> parse("assets", map)
    end
  end

  defp parse("assets", v) when is_map(v) do
    if map_size(v) <= 20 and
         Enum.all?(v, fn {k, p} ->
           is_binary(k) and k =~ ~r/\A[a-z0-9]{1,20}\/[a-z0-9]{1,20}\z/ and is_binary(p) and
             p =~ ~r/\A[A-Za-z0-9._*?+-]{1,200}\z/
         end),
       do: {:ok, if(v == %{}, do: :reset, else: v)},
       else: {:error, assets_words()}
  end

  defp parse(k, _), do: {:error, "#{k} is text."}

  defp assets_words,
    do:
      "assets maps a system and processor, such as windows/amd64, to the release file to install there, such as acme-*-windows-amd64.zip, where * is any text."

  ## The GitHub token

  def token, do: blank_nil(Setting.get("app_updates")["github_token"])

  defp blank_nil(""), do: nil
  defp blank_nil(v), do: v

  @doc "Whether a token is set, and its last four characters. The token itself is never shown."
  def token_view do
    case token() do
      nil -> %{github_token: "not set"}
      t -> %{github_token: "set", ending: String.slice(t, -4, 4)}
    end
  end

  def save_token(text) when is_binary(text) do
    t = String.trim(text)

    if t == "" or t =~ ~r/\A[A-Za-z0-9_]{20,255}\z/ do
      Setting.put("app_updates", Map.put(Setting.get("app_updates"), "github_token", t))
      {:ok, token_view()}
    else
      {:error, "bad_token", "github_token is a GitHub token, such as github_pat_..., or empty."}
    end
  end

  def save_token(_), do: {:error, "bad_token", "github_token is text."}

  ## Releases

  def apps do
    configured =
      Repo.all(from s in Setting, where: like(s.key, "app_updates:%"), select: s.key)
      |> Enum.map(&String.replace_prefix(&1, "app_updates:", ""))

    Enum.sort(
      Enum.uniq(configured ++ Repo.all(from t in AppTarget, distinct: true, select: t.app))
    )
  end

  def newest(app) do
    Repo.all(from r in AppRelease, where: r.app == ^app)
    |> Enum.max_by(&Dokkit.Deploys.number(&1.version), fn -> nil end)
  end

  def dir(app, version), do: Path.join([Releases.dir(), ".apps", app, version])

  @doc "Asks GitHub for the app's newest release and keeps the files its patterns name."
  def fetch(app) do
    s = settings(app)

    cond do
      not app?(app) ->
        {:error, "not_found", "No such app."}

      s["repo"] == "" ->
        {:error, "no_repo", "Name the app's GitHub repository first."}

      true ->
        result = fetch_latest(app, s)

        Setting.put(
          key(app),
          Map.merge(Setting.get(key(app)), %{
            "checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "fetch_note" =>
              case result do
                {:error, _, why} -> why
                _ -> nil
              end
          })
        )

        if match?({:ok, _}, result), do: advance(app)
        Issues.changed(false)
        result
    end
  end

  defp fetch_latest(app, s) do
    with {:ok, rel} <- github(@api <> "/repos/#{s["repo"]}/releases/latest"),
         {:ok, version} <- tag(rel["tag_name"]) do
      held = Repo.get_by(AppRelease, app: app, version: version)
      files = (held && held.files) || %{}
      assets = for a <- List.wrap(rel["assets"]), is_map(a), is_binary(a["name"]), do: a
      patterns = patterns(app, s)

      missing =
        for a <- assets,
            not Map.has_key?(files, a["name"]),
            Enum.any?(patterns, &glob?(&1, a["name"])),
            do: a

      with {:ok, sums} <- checksums(assets, missing),
           {:ok, got} <- download_all(app, version, missing, sums) do
        release =
          Repo.insert!(
            %AppRelease{
              app: app,
              version: version,
              url: rel["html_url"],
              files: Map.merge(files, got),
              published_at: time(rel["published_at"])
            },
            on_conflict: {:replace, [:files, :url, :updated_at]},
            conflict_target: [:app, :version],
            returning: true
          )

        {:ok, release}
      end
    end
  end

  defp tag(v) when is_binary(v) do
    if Releases.name?(v),
      do: {:ok, v},
      else:
        {:error, "bad_release",
         "The release's tag, #{inspect(v)}, is not a version Dokkit keeps."}
  end

  defp tag(_), do: {:error, "bad_release", "GitHub's answer named no release tag."}

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, t, _} -> %{t | microsecond: {elem(t.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp time(_), do: nil

  defp patterns(app, s) do
    Map.values(s["assets"]) ++
      Repo.all(
        from t in AppTarget,
          where: t.app == ^app and fragment("?->>'asset' IS NOT NULL", t.recipe),
          select: fragment("?->>'asset'", t.recipe)
      )
  end

  def glob?(pattern, name) do
    re =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(~r/\A#{re}\z/, name)
  end

  defp sums?(name), do: name =~ ~r/(sha256|checksum)/i

  # The release's own checksum files, as %{file => hash}; fetched only when there is something to check.
  defp checksums(_, []), do: {:ok, %{}}

  defp checksums(assets, _) do
    assets
    |> Enum.filter(&sums?(&1["name"]))
    |> Enum.reduce_while({:ok, %{}}, fn a, {:ok, acc} ->
      case get(a, 1_048_576) do
        {:ok, body} -> {:cont, {:ok, Map.merge(acc, read_sums(a["name"], body))}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_sums(name, body) do
    lines = String.split(body, ["\r\n", "\n"], trim: true)

    listed =
      for line <- lines,
          [_, hash, file] <- [Regex.run(~r/\A([0-9a-fA-F]{64})\s+\*?(\S.*)\z/, String.trim(line))],
          into: %{},
          do: {Path.basename(String.trim(file)), String.downcase(hash)}

    case {listed, lines} do
      {empty, [one]} when empty == %{} ->
        if one =~ ~r/\A[0-9a-fA-F]{64}\z/,
          do: %{String.replace_suffix(name, ".sha256", "") => String.downcase(one)},
          else: %{}

      _ ->
        listed
    end
  end

  defp download_all(app, version, assets, sums) do
    Enum.reduce_while(assets, {:ok, %{}}, fn a, {:ok, acc} ->
      case download(app, version, a, sums) do
        {:ok, file} -> {:cont, {:ok, Map.put(acc, a["name"], file)}}
        error -> {:halt, error}
      end
    end)
  end

  defp max_size, do: Application.get_env(:dokkit, :app_asset_max, 300 * 1024 * 1024)

  defp download(app, version, %{"name" => name} = a, sums) do
    cond do
      not Releases.name?(name) ->
        {:error, "bad_file",
         "#{inspect(name)} is not a file name this server keeps: letters, digits, dots, dashes and underscores."}

      is_integer(a["size"]) and a["size"] > max_size() ->
        {:error, "too_large", "#{name} is larger than #{div(max_size(), 1024 * 1024)} MB."}

      true ->
        tmp = Releases.incoming()

        case get_to(a, tmp) do
          :ok ->
            hash = file_hash(tmp)
            size = File.stat!(tmp).size

            cond do
              size > max_size() ->
                File.rm(tmp)

                {:error, "too_large",
                 "#{name} is larger than #{div(max_size(), 1024 * 1024)} MB."}

              sums[name] && sums[name] != hash ->
                File.rm(tmp)

                {:error, "bad_checksum",
                 "#{name} does not match the release's own checksums (got #{hash}, the release says #{sums[name]}). Nothing was kept."}

              true ->
                target = Path.join(dir(app, version), name)
                File.mkdir_p!(Path.dirname(target))
                File.rename!(tmp, target)
                {:ok, %{"sha256" => hash, "size" => size, "checked" => sums[name] != nil}}
            end

          error ->
            File.rm(tmp)
            error
        end
    end
  end

  defp file_hash(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp headers do
    [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}] ++
      if t = token(), do: [{"authorization", "Bearer " <> t}], else: []
  end

  defp asset_headers,
    do: [{"accept", "application/octet-stream"} | tl(headers())]

  defp req(opts), do: opts ++ Application.get_env(:dokkit, :req_options, [])

  defp github(url) do
    case Req.get(url, req(headers: headers(), receive_timeout: 30_000)) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, response} -> refused(response.status)
      {:error, e} -> {:error, "github", "Could not reach GitHub: #{Exception.message(e)}"}
    end
  end

  defp refused(404),
    do:
      {:error, "no_release",
       "GitHub has no published release for that repository, or the token cannot read it."}

  defp refused(s) when s in [401, 403], do: {:error, "github_refused", "GitHub refused (#{s})."}
  defp refused(s), do: {:error, "github", "GitHub answered #{s}."}

  defp get(a, limit) do
    case Req.get(a["url"] || "", req(headers: asset_headers(), receive_timeout: 30_000)) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= limit ->
        {:ok, body}

      {:ok, %{status: 200}} ->
        {:error, "bad_file", "#{a["name"]} is too large to be a checksum file."}

      {:ok, response} ->
        refused(response.status)

      {:error, e} ->
        {:error, "github", "Could not fetch #{a["name"]}: #{Exception.message(e)}"}
    end
  end

  # GitHub answers an asset with a redirect to its file store; Req does not carry the token there.
  defp get_to(a, path) do
    case Req.get(
           a["url"] || "",
           req(headers: asset_headers(), into: File.stream!(path), receive_timeout: 120_000)
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, response} -> refused(response.status)
      {:error, e} -> {:error, "github", "Could not fetch #{a["name"]}: #{Exception.message(e)}"}
    end
  end

  ## Machines

  defp targets(app) do
    Repo.all(
      from t in AppTarget,
        join: m in assoc(t, :machine),
        where: t.app == ^app,
        order_by: m.name,
        preload: [machine: m]
    )
  end

  def platform(%Machine{os: os, arch: arch}) do
    os = String.downcase(os || "")
    arch = String.downcase(arch || "")

    {cond do
       os =~ "windows" -> "windows"
       os =~ "darwin" or os =~ "mac" -> "darwin"
       os =~ "linux" -> "linux"
       true -> os
     end,
     cond do
       arch in ["x86_64", "x64", "amd64"] -> "amd64"
       arch in ["aarch64", "arm64"] -> "arm64"
       true -> arch
     end}
  end

  def file_for(%AppTarget{} = t, %AppRelease{} = release, {os, arch}) do
    pattern = t.recipe["asset"] || settings(t.app)["assets"]["#{os}/#{arch}"]
    pattern && Enum.find(Enum.sort(Map.keys(release.files)), &glob?(pattern, &1))
  end

  defp silent?(%Machine{last_seen_at: nil}), do: true

  defp silent?(m),
    do:
      DateTime.diff(DateTime.utc_now(), m.last_seen_at) >
        Values.get("silent_minutes", {:machine, m.id}) * 60

  @doc "Why the app cannot be installed on the machine now, or nil. An app key's logging unlocks nothing."
  def refusal(app, %Machine{kind: :enrolled} = m, t, release) do
    cond do
      is_nil(t) ->
        "#{m.name} has no [app] for #{app} in a dokkit.toml its Dokkit program reads, so the updater there has no way to install it."

      t.wanted_version && t.asked_at ->
        "#{m.name} is installing #{t.wanted_version} of #{app} now. Wait for its result."

      not m.has_updater ->
        "#{m.name} has no Dokkit updater. On it, from an administrator prompt: dokkit updater install"

      silent?(m) ->
        "#{m.name} is not reporting, so its Dokkit program is not running."

      release && t.recipe["kind"] != "compose" && is_nil(file_for(t, release, platform(m))) ->
        {os, arch} = platform(m)

        "#{release.version} of #{app} has no file for #{os}/#{arch}. Set its asset pattern in the app's update settings."

      true ->
        nil
    end
  end

  def refusal(_app, %Machine{name: name}, _, _),
    do:
      "#{name} is not a monitored machine. Only a machine where the Dokkit program and updater are installed receives updates; logging through an app key does not unlock them."

  defp current(t, versions) do
    versions[t.machine_id] || if(t.ok, do: t.result_version)
  end

  defp versions(app),
    do:
      Map.new(
        Repo.all(
          from s in Service,
            where: s.slug == ^app and not is_nil(s.version),
            select: {s.machine_id, s.version}
        )
      )

  @doc """
  Asks the updater on one machine, or on every machine that can take it, to install a release of
  the app: the newest held unless `version` names one. `{:ok, machines}` or `{:error, code, text}`.
  """
  def approve(app, machine, opts \\ []) do
    s = settings(app)

    release =
      if v = opts[:version],
        do: Repo.get_by(AppRelease, app: app, version: v),
        else: newest(app)

    cond do
      not app?(app) ->
        {:error, "not_found", "No such app."}

      s["hold"] ->
        {:error, "held", "Updates of #{app} are on hold."}

      is_nil(release) ->
        {:error, "no_release",
         if(opts[:version],
           do: "This server holds no release #{opts[:version]} of #{app}.",
           else: "This server holds no release of #{app} yet."
         )}

      machine == :all ->
        versions = versions(app)

        list =
          for t <- targets(app),
              current(t, versions) != release.version,
              is_nil(refusal(app, t.machine, t, release)),
              do: t

        Enum.each(list, &want(&1, release.version, versions, opts[:auto] || false))
        {:ok, length(list)}

      true ->
        with {:ok, id} <- Ecto.UUID.cast(machine),
             %Machine{} = m <- Repo.get(Machine, id) do
          t = Repo.get_by(AppTarget, app: app, machine_id: id)

          case refusal(app, m, t, release) do
            nil ->
              want(t, release.version, versions(app), opts[:auto] || false)
              {:ok, 1}

            why ->
              {:error, "not_eligible", why}
          end
        else
          _ -> {:error, "not_found", "No such machine."}
        end
    end
  end

  defp want(t, version, versions, auto) do
    Repo.update!(
      Ecto.Changeset.change(t,
        wanted_version: version,
        from_version: current(t, versions),
        auto: auto,
        started_at: DateTime.utc_now(),
        asked_at: nil,
        result_version: nil,
        ok: nil,
        note: nil,
        result_at: nil
      )
    )

    Dokkit.Work.nudge(t.machine_id)
    Issues.changed(false)
  end

  defp health(t) do
    case duration(t.recipe["health_wait"]) do
      n when is_number(n) -> trunc(n)
      _ -> Values.get("app_health_minutes") * 60
    end
  end

  @doc "What the updater on a machine is to install now, for the machine's own key."
  def ask(machine_id, params) do
    m = Repo.get!(Machine, machine_id)

    platform =
      if is_binary(params["os"]) and is_binary(params["arch"]),
        do: {params["os"], params["arch"]},
        else: platform(m)

    if m.has_updater do
      for t <-
            Repo.all(
              from t in AppTarget,
                where: t.machine_id == ^machine_id and not is_nil(t.wanted_version),
                order_by: t.app
            ),
          not settings(t.app)["hold"],
          item = item(t, platform),
          item != nil,
          do: item
    else
      []
    end
  end

  defp item(t, platform) do
    release = Repo.get_by(AppRelease, app: t.app, version: t.wanted_version)
    file = release && t.recipe["kind"] != "compose" && file_for(t, release, platform)

    cond do
      is_nil(release) ->
        finish(t, false, "The server no longer holds #{t.wanted_version}.", t.wanted_version)
        nil

      t.recipe["kind"] != "compose" and is_nil(file) ->
        {os, arch} = platform
        finish(t, false, "#{t.wanted_version} has no file for #{os}/#{arch}.", t.wanted_version)
        nil

      true ->
        if is_nil(t.asked_at),
          do: Repo.update!(Ecto.Changeset.change(t, asked_at: DateTime.utc_now()))

        held = (file && release.files[file]) || %{}

        %{
          service: t.app,
          version: t.wanted_version,
          kind: t.recipe["kind"],
          file: file || "",
          sha256: held["sha256"] || "",
          size: held["size"] || 0,
          signer: settings(t.app)["signer"],
          require_signature: settings(t.app)["require_signature"],
          health_seconds: health(t)
        }
    end
  end

  def file_path(machine_id, app, version, file) do
    with true <- Releases.name?(app) and Releases.name?(version) and Releases.name?(file),
         %AppTarget{wanted_version: ^version} <-
           Repo.get_by(AppTarget, machine_id: machine_id, app: app),
         %AppRelease{files: %{^file => _}} <- Repo.get_by(AppRelease, app: app, version: version),
         path = Path.join(dir(app, version), file),
         true <- File.regular?(path) do
      path
    else
      _ -> nil
    end
  end

  def result(machine_id, %{"service" => app, "version" => v, "ok" => ok} = params)
      when is_binary(app) and is_binary(v) and is_boolean(ok) do
    note = params["note"]
    t = Repo.get_by(AppTarget, machine_id: machine_id, app: app)

    cond do
      not (is_nil(note) or (is_binary(note) and String.length(note) <= 2000)) -> :error
      is_nil(t) or v not in [t.wanted_version, t.result_version] -> :error
      true -> finish(t, ok, note, v)
    end
  end

  def result(_, _), do: :error

  defp finish(t, ok, note, version) do
    t =
      Repo.update!(
        Ecto.Changeset.change(t,
          wanted_version: nil,
          result_version: version,
          ok: ok,
          note: note,
          result_at: DateTime.utc_now()
        )
      )

    service = Repo.get_by(Service, machine_id: t.machine_id, slug: t.app)

    if service do
      if ok, do: deployed(service, t, version), else: failed(service, t, version, note)
    end

    Issues.changed(false)
    if ok and t.auto, do: advance(t.app)
    :ok
  end

  # Every install is a deploy. One the program already noticed from the version file becomes the updater's.
  defp deployed(service, t, version) do
    since = t.started_at || DateTime.add(DateTime.utc_now(), -86_400)

    seen =
      Repo.one(
        from d in Deploy,
          where: d.service_id == ^service.id and d.version == ^version and d.at >= ^since,
          limit: 1
      )

    if seen do
      Repo.update!(Ecto.Changeset.change(seen, by: @by, how: "updated", machine_id: t.machine_id))
    else
      Repo.insert!(%Deploy{
        service_id: service.id,
        machine_id: t.machine_id,
        from: t.from_version || service.version,
        version: version,
        by: @by,
        how: "updated",
        at: DateTime.utc_now()
      })
    end

    if service.version != version,
      do: Repo.update!(Ecto.Changeset.change(service, version: version))

    case update_check(service) do
      %Check{state: state} = check when state != :ok -> Issues.record(check, :ok)
      _ -> nil
    end
  end

  # Only the row this module made: a check of the same name from a dokkit.toml is left alone.
  defp update_check(service) do
    case Repo.get_by(Check, service_id: service.id, name: @check) do
      %Check{source: :reported, config: %{"app_update" => true}} = check -> check
      _ -> nil
    end
  end

  defp failed(service, t, version, note) do
    check =
      update_check(service) ||
        (is_nil(Repo.get_by(Check, service_id: service.id, name: @check)) &&
           Repo.insert!(%Check{
             service_id: service.id,
             name: @check,
             type: :custom,
             fail_after: 1,
             config: %{"app_update" => true}
           }))

    if check,
      do:
        Issues.record(check, :down,
          title:
            "#{service.name} did not update to #{version}" <>
              if(t.auto, do: "; automatic updates stopped", else: ""),
          note: note || "The updater gave no reason."
        )
  end

  def expire(now \\ DateTime.utc_now()) do
    late = Values.get("update_run_minutes")
    cutoff = DateTime.add(now, -late * 60)

    for t <-
          Repo.all(
            from t in AppTarget,
              where: not is_nil(t.wanted_version) and t.started_at < ^cutoff
          ),
        do: finish(t, false, "did not report back within #{late} minutes", t.wanted_version)
  end

  @doc """
  In automatic mode, starts the next machine that is behind the newest release, one at a time,
  and stops at the first failure.
  """
  def advance(app) do
    :global.trans({{__MODULE__, app}, self()}, fn -> step(app) end, [node()])
  end

  defp step(app) do
    s = settings(app)
    release = s["mode"] == "automatic" and not s["hold"] and newest(app)

    if release do
      list = targets(app)
      versions = versions(app)

      cond do
        Enum.any?(list, & &1.wanted_version) ->
          :busy

        Enum.any?(list, &(&1.result_version == release.version and &1.ok == false)) ->
          :stopped

        next =
            Enum.find(
              list,
              &(current(&1, versions) != release.version and
                    is_nil(refusal(app, &1.machine, &1, release)))
            ) ->
          want(next, release.version, versions, true)
          :started

        true ->
          :done
      end
    else
      :off
    end
  end

  @doc "Once a minute: ends installs that went quiet, looks at GitHub when it is time, and moves automatic updates on."
  def tick(now \\ DateTime.utc_now()) do
    :global.trans(
      {{__MODULE__, :tick}, self()},
      fn ->
        expire(now)
        every = Values.get("app_poll_minutes") * 60

        for app <- apps() do
          s = settings(app)
          checked = time(Setting.get(key(app))["checked_at"])

          if s["repo"] != "" and (is_nil(checked) or DateTime.diff(now, checked) >= every),
            do: fetch(app),
            else: advance(app)
        end
      end,
      [node()],
      0
    )
  end

  ## Reading

  @doc "Everything about one app's updates, or nil."
  def view(app) do
    if app?(app) do
      s = settings(app)
      stored = Setting.get(key(app))
      release = newest(app)
      versions = versions(app)

      %{
        app: app,
        repo: s["repo"],
        url: if(s["repo"] != "", do: "https://github.com/" <> s["repo"]),
        mode: s["mode"],
        hold: s["hold"],
        signer: s["signer"],
        require_signature: s["require_signature"],
        assets: s["assets"],
        defaults: @defaults,
        changed: for(k <- Enum.sort(@fields), s[k] != @defaults[k], do: k),
        checked_at: stored["checked_at"],
        check_note: stored["fetch_note"],
        newest:
          release &&
            %{
              version: release.version,
              url: release.url,
              published_at: release.published_at,
              files:
                for(
                  {name, f} <- Enum.sort(release.files),
                  do: %{name: name, sha256: f["sha256"], size: f["size"]}
                )
            },
        machines: for(t <- targets(app), do: row(app, t, release, versions))
      }
    end
  end

  defp row(app, t, release, versions) do
    version = current(t, versions)
    why = refusal(app, t.machine, t, release)

    %{
      id: t.machine_id,
      name: t.machine.name,
      kind: t.recipe["kind"],
      version: version,
      state: state(t),
      wanted: t.wanted_version,
      result_version: t.result_version,
      note: t.note,
      at: t.result_at || t.started_at,
      behind: release != nil and version != release.version,
      can_update: release != nil and version != release.version and is_nil(why),
      why: why
    }
  end

  defp state(%AppTarget{wanted_version: v, asked_at: at}) when is_binary(v) and not is_nil(at),
    do: "installing"

  defp state(%AppTarget{wanted_version: v}) when is_binary(v), do: "waiting"
  defp state(%AppTarget{ok: false}), do: "failed"
  defp state(%AppTarget{ok: true}), do: "done"
  defp state(_), do: "idle"

  def list, do: apps() |> Enum.map(&view/1) |> Enum.reject(&is_nil/1)

  @doc "Apps with a newer release than some machine that can take it: each with its version and how many."
  def pending do
    for v <- list(), v.newest, n = Enum.count(v.machines, & &1.can_update), n > 0 do
      %{
        app: v.app,
        version: v.newest.version,
        behind: n,
        hold: v.hold,
        service_id: Repo.one(from s in Service, where: s.slug == ^v.app, limit: 1, select: s.id)
      }
    end
  end
end
