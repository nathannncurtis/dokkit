defmodule Dokkit.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end

defmodule Dokkit.Machine do
  use Dokkit.Schema

  schema "machines" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:enrolled, :seen, :group], default: :enrolled
    field :os, :string
    field :arch, :string
    field :program_version, :string
    field :last_seen_at, :utc_datetime_usec
    field :seen_by, :binary_id
    field :server_version, :string
    field :updater_version, :string
    field :has_updater, :boolean, default: false
    field :hosts_server, :boolean, default: false
    field :wanted_version, :string
    field :update_version, :string
    field :update_ok, :boolean
    field :update_note, :string
    field :update_at, :utc_datetime_usec
    field :update_started_at, :utc_datetime_usec
    field :update_asked_at, :utc_datetime_usec
    field :updater_checked_at, :utc_datetime_usec
    field :silent_route, :string
    field :silent_wake, :boolean, default: true
    has_many :services, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.Service do
  use Dokkit.Schema

  schema "services" do
    field :slug, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:service, :job, :dependency, :app], default: :service
    field :environment, :string, default: "production"
    field :version, :string
    field :listens, :string
    field :state, Ecto.Enum, values: [:ok, :degraded, :down, :unknown], default: :unknown
    field :note, :string
    field :route_down, :string
    field :route_degraded, :string
    field :night, :boolean, default: true
    field :watched, :boolean, default: true
    field :held, :string
    field :restart, :boolean, default: false
    field :keep_messages, :boolean, default: false
    field :declared, :map
    field :stats, :map
    field :stats_at, :utc_datetime_usec
    belongs_to :machine, Dokkit.Machine
    has_many :checks, Dokkit.Check
    timestamps()
  end
end

defmodule Dokkit.Check do
  use Dokkit.Schema

  @types ~w(http tcp process windows-service systemd beat job stats threshold expiry custom)a

  schema "checks" do
    field :name, :string
    field :type, Ecto.Enum, values: @types
    field :source, Ecto.Enum, values: [:file, :reported], default: :reported
    field :config, :map, default: %{}
    field :fail_after, :integer, default: 3
    field :state, Ecto.Enum, values: [:ok, :degraded, :down, :unknown], default: :unknown
    field :fails, :integer, default: 0
    field :passes, :integer, default: 0
    field :value, :float
    field :note, :string
    field :checked_at, :utc_datetime_usec
    belongs_to :service, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.Issue do
  use Dokkit.Schema

  schema "issues" do
    field :number, :integer, read_after_writes: true
    field :kind, :string
    field :state, Ecto.Enum, values: [:degraded, :down]
    field :title, :string
    field :count, :integer, default: 1
    field :since, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :snoozed_until, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec
    field :soon, :boolean, default: false
    field :notes, {:array, :map}, default: []
    field :processes, :map
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    belongs_to :check, Dokkit.Check
    has_many :alerts, Dokkit.Alert
    timestamps()
  end

  def short_id(%__MODULE__{number: n}), do: "DOK-#{n}"
end

defmodule Dokkit.Key do
  use Dokkit.Schema

  schema "keys" do
    field :kind, Ecto.Enum, values: [:enrol, :machine, :app, :user]
    field :hash, :binary
    field :hint, :string
    field :label, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    belongs_to :user, Dokkit.User
    timestamps()
  end
end

defmodule Dokkit.JobRun do
  use Dokkit.Schema

  schema "job_runs" do
    field :run, :string
    field :result, Ecto.Enum, values: [:running, :ok, :fail], default: :running
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :exit_code, :integer
    field :duration_ms, :integer
    field :done, :integer
    field :total, :integer
    field :tail, :string
    belongs_to :check, Dokkit.Check
    timestamps()
  end
end

defmodule Dokkit.WorkRun do
  use Dokkit.Schema

  schema "work_runs" do
    field :state, Ecto.Enum, values: [:queued, :running, :ok, :fail, :refused], default: :queued
    field :by, :string
    field :exit_code, :integer
    field :duration_ms, :integer
    field :output, :string, default: ""
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :payload, :map
    field :name, :string
    belongs_to :machine, Dokkit.Machine
    belongs_to :alert, Dokkit.Alert
    timestamps()
  end
end

defmodule Dokkit.Finding do
  use Dokkit.Schema

  schema "found" do
    field :kind, :string
    field :key, :string
    field :detail, :map, default: %{}
    field :dismissed, :boolean, default: false
    field :origin, :string
    field :why, :string
    belongs_to :machine, Dokkit.Machine
    timestamps()
  end
end

defmodule Dokkit.Install do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id

  schema "installs" do
    field :version, :string
    field :seen_at, :utc_datetime_usec
    belongs_to :service, Dokkit.Service, primary_key: true
    belongs_to :machine, Dokkit.Machine, primary_key: true
  end
end

defmodule Dokkit.MachineSlot do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id

  schema "machine_slots" do
    field :slot, :utc_datetime, primary_key: true
    belongs_to :machine, Dokkit.Machine, primary_key: true
  end
end

defmodule Dokkit.Deploy do
  use Dokkit.Schema

  schema "deploys" do
    field :from, :string
    field :version, :string
    field :commit, :string
    field :by, :string
    field :how, :string
    field :at, :utc_datetime_usec
    belongs_to :service, Dokkit.Service
  end
end

defmodule Dokkit.ErrorGroup do
  use Dokkit.Schema

  schema "error_groups" do
    field :fingerprint, :string
    field :type, :string
    field :top, :string
    field :count, :integer
    field :first_seen, :utc_datetime_usec
    field :last_seen, :utc_datetime_usec
    field :release, :string
    field :host, :string
    field :handled, :boolean
    belongs_to :service, Dokkit.Service
  end
end

defmodule Dokkit.ErrorEvent do
  use Dokkit.Schema

  schema "error_events" do
    field :at, :utc_datetime_usec
    field :release, :string
    field :host, :string
    field :handled, :boolean
    field :frames, {:array, :map}, default: []
    field :tags, :map, default: %{}
    field :message, :string
    belongs_to :group, Dokkit.ErrorGroup
  end
end

defmodule Dokkit.Metric do
  use Ecto.Schema
  @foreign_key_type :binary_id

  schema "metrics" do
    field :name, :string
    field :value, :float
    field :at, :utc_datetime_usec
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
  end
end

defmodule Dokkit.User do
  use Dokkit.Schema

  schema "users" do
    field :name, :string
    field :password_hash, :string, redact: true
    field :role, Ecto.Enum, values: [:owner, :member, :viewer]
    field :sessions_after, :integer, default: 0
    field :totp_secret, :string, redact: true
    field :totp_on, :boolean, default: false
    field :totp_step, :integer, default: 0
    timestamps()
  end
end

defmodule Dokkit.Alert do
  use Dokkit.Schema

  schema "alerts" do
    field :channel, :string

    field :status, Ecto.Enum,
      values: [:pending, :sending, :sent, :failed, :skipped, :closing, :closed, :held],
      default: :pending

    field :attempts, :integer, default: 0
    field :error, :string
    belongs_to :issue, Dokkit.Issue
    timestamps()
  end
end

defmodule Dokkit.Log do
  use Ecto.Schema
  @primary_key false
  @foreign_key_type :binary_id

  schema "logs" do
    field :id, :integer
    field :at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :level, :string
    field :msg, :string
    field :fields, :map
    field :cut, :boolean
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
  end
end

defmodule Dokkit.Setting do
  use Ecto.Schema
  @primary_key {:key, :string, autogenerate: false}

  schema "settings" do
    field :value, :map
    timestamps(type: :utc_datetime_usec)
  end

  def get(key), do: (Dokkit.Repo.get(__MODULE__, key) || %__MODULE__{value: %{}}).value

  def put(key, value) do
    Dokkit.Repo.insert!(%__MODULE__{key: key, value: value},
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )
  end
end

defmodule Dokkit.QuietWindow do
  use Dokkit.Schema

  schema "quiet_windows" do
    field :started_at, :utc_datetime_usec
    field :until, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :silent_at, :utc_datetime_usec
    field :reason, :string
    field :by, :string
    field :ended_by, :string
    field :hold, :boolean, default: false
    belongs_to :machine, Dokkit.Machine
  end
end

defmodule Dokkit.QuietSchedule do
  use Dokkit.Schema

  schema "quiet_schedules" do
    field :repeat, :string
    field :at, :utc_datetime_usec
    field :time, :string
    field :days, {:array, :integer}, default: []
    field :seconds, :integer
    field :reason, :string
    field :by, :string
    field :last_started_on, :date
    belongs_to :machine, Dokkit.Machine
    timestamps(updated_at: false)
  end
end

defmodule Dokkit.Batch do
  use Dokkit.Schema

  schema "batches" do
    field :accepted, :integer
    field :refused, {:array, :map}, default: []
    belongs_to :key, Dokkit.Key
    timestamps(updated_at: false)
  end
end

defmodule Dokkit.Phone do
  use Dokkit.Schema

  schema "phones" do
    field :name, :string
    field :slot, :string
    field :token_hash, :binary
    field :key, :binary
    field :last_fetch_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end

defmodule Dokkit.ProcessList do
  use Ecto.Schema
  @primary_key {:machine_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "process_lists" do
    field :at, :utc_datetime_usec
    field :total_memory_bytes, :integer
    field :items, {:array, :map}
  end
end

defmodule Dokkit.ProcessTop do
  use Ecto.Schema
  @foreign_key_type :binary_id

  schema "process_tops" do
    field :kind, :string
    field :at, :utc_datetime_usec
    field :items, {:array, :map}
    belongs_to :machine, Dokkit.Machine
  end
end
