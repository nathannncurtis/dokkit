defmodule Dokkit.Client.MixProject do
  use Mix.Project

  def project do
    [app: :dokkit, version: "0.1.0", elixir: "~> 1.18", deps: [], package: [licenses: ["Apache-2.0"]]]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end
end
