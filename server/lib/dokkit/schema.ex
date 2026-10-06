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

  @types ~w(http tcp process windows-service beat job stats threshold expiry custom)a

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
    field :notes, {:array, :map}, default: []
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    belongs_to :check, Dokkit.Check
    has_one :alert, Dokkit.Alert
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

defmodule Dokkit.Task do
  use Dokkit.Schema

  schema "tasks" do
    field :name, :string
    field :command, :string
    field :accepted, :string
    field :dismissed, :string
    field :as_system, :boolean, default: false
    belongs_to :machine, Dokkit.Machine
    belongs_to :service, Dokkit.Service
    timestamps()
  end
end

defmodule Dokkit.TaskRun do
  use Dokkit.Schema

  schema "task_runs" do
    field :state, Ecto.Enum, values: [:queued, :running, :ok, :fail, :refused], default: :queued
    field :by, :string
    field :exit_code, :integer
    field :duration_ms, :integer
    field :output, :string, default: ""
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    belongs_to :task, Dokkit.Task
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
    timestamps()
  end
end

defmodule Dokkit.Alert do
  use Dokkit.Schema

  schema "alerts" do
    field :channel, :string

    field :status, Ecto.Enum,
      values: [:pending, :sent, :failed, :skipped, :closing, :closed],
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
