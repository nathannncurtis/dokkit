defmodule Dokkit.Demo.Sample do
  @moduledoc "Builds the invented company the demo and the sample server show. Every name in it is invented."
  import Ecto.Query
  alias Dokkit.{Alert, Check, Issue, Machine, MachineSlot, Repo}

  @doc "Empties every table, then builds the company again, as of now."
  def reset do
    tables =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      ).rows

    Repo.query!("TRUNCATE " <> Enum.map_join(tables, ", ", &~s("#{hd(&1)}")) <> " CASCADE")
    build()
  end

  def build do
    now = DateTime.utc_now()
    ago = fn minutes -> DateTime.add(now, -minutes * 60) end
    iso = &DateTime.to_iso8601/1

    # Alerts are not sent from here, so the ones waiting are marked sent.
    sent = fn ->
      Repo.update_all(from(a in Alert, where: a.status == :pending), set: [status: :sent])
    end

    # Lines go in through the function the intake endpoint calls.
    send! = fn key, lines ->
      {:ok, %{refused: refused}} =
        Dokkit.Intake.report(key, nil, Enum.map_join(lines, "\n", &Jason.encode!/1))

      if refused != [], do: IO.inspect(refused, label: "REFUSED")
    end

    # A result for a named check, with a title of my choosing.
    record! = fn machine, slug, check, state, opts ->
      c =
        Repo.one!(
          from c in Check,
            join: s in assoc(c, :service),
            join: m in assoc(s, :machine),
            where: m.name == ^machine and s.slug == ^slug and c.name == ^check
        )

      Dokkit.Issues.record(c, state, opts)
      sent.()
    end

    Dokkit.Alerts.add_rule(%{
      "kind" => "job",
      "state" => "down",
      "machine" => "db-01",
      "channel" => "page"
    })

    Dokkit.Alerts.add_rule(%{"kind" => "check", "state" => "degraded", "channel" => "push"})
    {:ok, _} = Dokkit.Accounts.add("sample", "owner", "sample-password-1")

    # Machines are enrolled with a token, as the program does it.
    estate = [
      {"db-01", "linux",
       ~w(postgres pgbouncer wal-archive pg-exporter replica-sync log-shipper nightly-purge)},
      {"web-02", "linux",
       ~w(nginx upload-portal api worker-queue redis resize-worker session-store search-index image-cache cdn-sync)},
      {"nas", "linux",
       ~w(smb-share nfs-export backup snapshot-keeper smart-monitor replication media-index photo-sync)},
      {"mail", "linux",
       ~w(postfix dovecot spam-filter mail-queue mail-tls dkim-signer webmail antivirus list-server)},
      {"build", "windows",
       ~w(ci-runner artifact-store docker-daemon package-mirror nightly-build web-preview cache-cleaner)},
      {"sql", "windows",
       ~w(sql-server sql-agent report-builder ssis ssrs linked-server etl-loader reporting-portal)}
    ]

    keys =
      for {name, os, _} <- estate, into: %{} do
        {token, _} = Dokkit.Keys.mint(:enrol, %{label: name})
        params = %{"hostname" => name, "os" => os, "arch" => "amd64", "dokkit" => "0.4.2"}
        {:ok, %{key: key}} = Dokkit.Intake.enrol(token, params)
        {:ok, key} = Dokkit.Keys.verify(key, :machine)
        {name, key}
      end

    # Each service is declared as a dokkit.toml would declare it.
    jobs = %{
      "nightly-purge" => %{"schedule" => "0 1 * * *", "grace" => "20m", "max_runtime" => "1h"},
      "backup" => %{"max_runtime" => "2h"},
      "nightly-build" => %{}
    }

    extra = %{
      "upload-portal" => [%{"type" => "custom", "name" => "latency"}],
      "mail-tls" => [%{"type" => "expiry", "name" => "certificate"}]
    }

    for {name, _, slugs} <- estate, slug <- slugs do
      job? = Map.has_key?(jobs, slug)

      checks =
        if job?,
          do: [],
          else: [%{"type" => "http", "name" => "up", "url" => "http://localhost/#{slug}"}]

      doc = %{
        "schema" => 1,
        "service" => %{
          "id" => slug,
          "name" => slug |> String.replace("-", " ") |> String.capitalize(),
          "kind" => if(job?, do: "job", else: "service"),
          "environment" => if(slug == "web-preview", do: "dev", else: "production")
        },
        "check" => Enum.map(checks ++ Map.get(extra, slug, []), &Map.put(&1, "fail_after", 1)),
        "job" => if(job?, do: [Map.put(jobs[slug], "id", slug)], else: [])
      }

      {:ok, _} = Dokkit.Estate.declare(Repo.get_by!(Machine, name: name).id, doc)
    end

    # Everything is fine to begin with.
    for {name, _, slugs} <- estate do
      send!.(
        keys[name],
        for(
          slug <- slugs,
          not Map.has_key?(jobs, slug),
          do: %{"type" => "state", "service" => slug, "check" => "up", "state" => "ok"}
        ) ++
          for(
            slug <- ~w(upload-portal mail-tls),
            slug in slugs,
            c <- extra[slug],
            do: %{"type" => "state", "service" => slug, "check" => c["name"], "state" => "ok"}
          )
      )
    end

    # Job runs with output, in time order. The purge ran well on the three nights before today.
    base = %{DateTime.utc_now() | hour: 1, minute: 30, second: 0, microsecond: {0, 6}}
    base = if DateTime.compare(base, now) == :gt, do: DateTime.add(base, -86_400), else: base

    run = fn slug, id, from, minutes, tail ->
      line = %{"type" => "job", "service" => slug, "run" => id}

      [
        Map.merge(line, %{"event" => "start", "at" => iso.(from)}),
        Map.merge(line, %{
          "event" => "ok",
          "at" => iso.(DateTime.add(from, minutes * 60)),
          "exit_code" => 0,
          "duration_ms" => minutes * 60_000,
          "tail" => tail
        })
      ]
    end

    send!.(
      keys["db-01"],
      for(
        d <- 3..1//-1,
        line <-
          run.(
            "nightly-purge",
            "purge-#{d}",
            DateTime.add(base, -d * 86_400 - 1800 + 5),
            4,
            "Purged #{17_000 + d * 211} rows\nVacuum finished"
          ),
        do: line
      )
    )

    send!.(
      keys["nas"],
      for(
        {d, minutes} <- [{6, 50}, {5, 180}, {4, 48}, {3, 44}, {2, 52}, {1, 180}],
        line <-
          run.(
            "backup",
            "backup-#{d}",
            ago.(d * 1440 + 200),
            minutes,
            "Copied 412 GB in #{div(minutes, 60)} h #{rem(minutes, 60)} min"
          ),
        do: line
      )
    )

    send!.(keys["build"], run.("nightly-build", "build-1", ago.(600), 22, "All 311 tests passed"))

    # The purge did not run today: the same sweep the server makes once a minute.
    Repo.update_all(from(c in Check, where: c.name == "nightly-purge"),
      set: [inserted_at: DateTime.add(base, -5 * 86_400)]
    )

    1 = Dokkit.Watch.sweep(base)
    sent.()

    # The disk on the nas climbs for a week and goes over its limit of 90.
    disk = "disk.used_percent.data"

    reading = fn at, v ->
      %{"type" => "metric", "name" => disk, "value" => v, "at" => iso.(at)}
    end

    send!.(
      keys["nas"],
      for(i <- 0..13, do: reading.(ago.((13 - i) * 720 + 30), 79.0 + i * 0.7)) ++
        [reading.(ago.(20), 90.4), reading.(ago.(10), 90.8)]
    )

    Dokkit.Numbers.forecast(now)
    send!.(keys["nas"], [reading.(now, 91.0)])
    sent.()

    # Earlier today two things went wrong and came back by themselves.
    send!.(keys["db-01"], [
      %{
        "type" => "state",
        "service" => "postgres",
        "check" => "up",
        "state" => "down",
        "note" => "Connection refused",
        "at" => iso.(ago.(300))
      }
    ])

    sent.()

    send!.(keys["db-01"], [
      %{
        "type" => "state",
        "service" => "postgres",
        "check" => "up",
        "state" => "ok",
        "at" => iso.(ago.(270))
      }
    ])

    send!.(keys["web-02"], [
      %{
        "type" => "state",
        "service" => "nginx",
        "check" => "up",
        "state" => "degraded",
        "note" => "Answering in 3 s",
        "at" => iso.(ago.(180))
      }
    ])

    sent.()

    send!.(keys["web-02"], [
      %{
        "type" => "state",
        "service" => "nginx",
        "check" => "up",
        "state" => "ok",
        "at" => iso.(ago.(140))
      }
    ])

    # What is wrong now.
    record!.("web-02", "upload-portal", "latency", :degraded,
      at: ago.(40),
      title: "Upload portal answers slowly",
      note: "Three checks in a row took over two seconds."
    )

    record!.("mail", "mail-tls", "certificate", :degraded,
      at: ago.(120),
      title: "Certificate for mail expires in 21 days",
      note: "It expires on #{Date.add(Date.utc_today(), 21)}."
    )

    record!.("sql", "report-builder", "up", :degraded,
      at: ago.(360),
      title: "Report builder is slow",
      note: "Reports take over a minute."
    )

    record!.("build", "web-preview", "up", :down,
      at: ago.(90),
      title: "Web preview is down",
      note: "Connection refused"
    )

    Dokkit.Issues.snooze(Repo.get_by!(Issue, title: "Report builder is slow").id, 8 * 3600)

    # What the scans found and nobody has decided about.
    Dokkit.Found.propose(Repo.get_by!(Machine, name: "build").id, %{
      "os" => "windows",
      "found" => %{
        "ports" => [%{"port" => 22, "program" => "sshd"}],
        "services" => [%{"name" => "Spooler", "display" => "Print Spooler", "state" => "running"}]
      }
    })

    Dokkit.Found.propose(Repo.get_by!(Machine, name: "sql").id, %{
      "os" => "windows",
      "found" => %{
        "jobs" => [%{"name" => "defrag", "source" => "task-scheduler", "schedule" => "0 3 * * 0"}]
      }
    })

    Dokkit.Found.propose(Repo.get_by!(Machine, name: "web-02").id, %{
      "os" => "linux",
      "found" => %{"ports" => [%{"port" => 8443}]}
    })

    # A deploy an hour ago, and the errors after it.
    send!.(keys["web-02"], [
      %{"type" => "deploy", "service" => "upload-portal", "version" => "2.4.0"}
    ])

    send!.(keys["web-02"], [
      %{
        "type" => "deploy",
        "service" => "upload-portal",
        "version" => "2.4.1",
        "commit" => "9f3c2ab",
        "by" => "ci"
      }
    ])

    Repo.update_all(Dokkit.Deploy, set: [at: ago.(60)])

    portal = Repo.get_by!(Dokkit.Service, slug: "upload-portal")
    {app, _} = Dokkit.Keys.mint(:app, %{service_id: portal.id, label: "upload-portal"})
    {:ok, app} = Dokkit.Keys.verify(app, :app)

    frames = [
      %{
        "file" => "site-packages/urllib3/connection.py",
        "function" => "create_connection",
        "line" => 85
      },
      %{"file" => "server.py", "function" => "handle_upload", "line" => 41, "own" => true},
      %{"file" => "resize.py", "function" => "resize_image", "line" => 88, "own" => true}
    ]

    for i <- 1..14 do
      :ok =
        Dokkit.Intake.error(app, %{
          "type" => "TimeoutError",
          "frames" => frames,
          "release" => "2.4.1",
          "host" => "web-02",
          "handled" => false,
          "at" => iso.(ago.(55 - i * 3))
        })
    end

    # Log lines, mostly the portal's.
    msgs = ["upload received", "thumbnail made", "virus scan passed", "stored in the share"]

    logs =
      for i <- 1..32 do
        slow? = i > 20 and rem(i, 3) == 0

        %{
          "type" => "log",
          "service" => "upload-portal",
          "at" => iso.(ago.(95 - i * 3)),
          "level" => if(slow?, do: "error", else: "info"),
          "msg" => if(slow?, do: "resize timed out after 30 s", else: Enum.at(msgs, rem(i, 4))),
          "size_kb" => 200 + i * 37
        }
      end

    send!.(keys["web-02"], logs)

    send!.(
      keys["db-01"],
      for(
        i <- 1..8,
        do: %{
          "type" => "log",
          "at" => iso.(ago.(i * 11)),
          "level" => if(i == 5, do: "warn", else: "info"),
          "msg" => if(i == 5, do: "checkpoint took 38 s", else: "checkpoint complete")
        }
      )
    )

    # A job part way through, a dependency, a staging copy of the portal and a week of memory readings.
    send!.(keys["build"], [
      %{
        "type" => "job",
        "service" => "nightly-build",
        "run" => "build-2",
        "event" => "start",
        "at" => iso.(ago.(6))
      },
      %{
        "type" => "job",
        "service" => "nightly-build",
        "run" => "build-2",
        "event" => "progress",
        "done" => 4000,
        "total" => 9000,
        "at" => iso.(ago.(1))
      }
    ])

    {:ok, _} =
      Dokkit.Estate.add_dependency(%{
        "name" => "Payment gateway",
        "machine" => "web-02",
        "check" => %{"type" => "http", "url" => "https://payments.example.com/health"}
      })

    send!.(keys["web-02"], [
      %{"type" => "state", "service" => "payment-gateway", "check" => "http", "state" => "ok"}
    ])

    staging = %{
      "schema" => 1,
      "service" => %{
        "id" => "upload-portal-staging",
        "name" => "Upload portal",
        "kind" => "service",
        "environment" => "staging"
      },
      "check" => [%{"type" => "http", "name" => "up", "url" => "http://localhost:8081/healthz"}]
    }

    {:ok, _} = Dokkit.Estate.declare(Repo.get_by!(Machine, name: "web-02").id, staging)

    send!.(keys["web-02"], [
      %{"type" => "state", "service" => "upload-portal-staging", "check" => "up", "state" => "ok"}
    ])

    memory = fn at, v ->
      %{"type" => "metric", "name" => "memory.used_percent", "value" => v, "at" => iso.(at)}
    end

    send!.(
      keys["db-01"],
      for(i <- 0..13, do: memory.(ago.((13 - i) * 720 + 30), 55.0 + rem(i * 7, 11)))
    )

    # The last day: every enrolled machine was heard from in all 48 half hours; the PC only in office hours.
    last = Dokkit.Slots.slot(now)
    slots = for n <- 0..47, do: DateTime.add(last, -n * 1800)

    pc =
      Repo.insert!(%Machine{
        name: "front-desk-pc",
        kind: :seen,
        last_seen_at:
          slots |> Enum.filter(&(&1.hour in 8..17)) |> hd() |> Map.put(:microsecond, {0, 6})
      })

    rows = fn m, list -> for s <- list, do: %{machine_id: m.id, slot: s} end

    for m <- Repo.all(from m in Machine, where: m.kind == :enrolled),
        do: Repo.insert_all(MachineSlot, rows.(m, slots), on_conflict: :nothing)

    Repo.insert_all(MachineSlot, rows.(pc, Enum.filter(slots, &(&1.hour in 8..17))),
      on_conflict: :nothing
    )

    Dokkit.Issues.changed(false)
  end
end
