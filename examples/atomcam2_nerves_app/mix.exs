defmodule Atomcam2NervesApp.MixProject do
  use Mix.Project

  @app :atomcam2_nerves_app
  @version "0.5.0"
  @system_version "0.5.0"
  @system_repository "piyopiyoex/nerves_system_atomcam2"
  @all_targets [:atomcam2]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.16",
      archives: [nerves_bootstrap: "~> 1.10"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      mod: {Atomcam2NervesApp.Application, []},
      extra_applications: extra_applications()
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      # Dependencies for host and target
      {:nerves, "~> 1.11", runtime: false},
      {:shoehorn, "~> 0.9.0"},
      {:ring_logger, "~> 0.9"},
      {:toolshed, "~> 0.5"},

      # Runtime services
      {:nerves_time, "~> 0.4.12"},
      {:nerves_motd, "~> 0.1.17", targets: @all_targets},

      # Explicit networking and remote access dependencies
      {:nerves_runtime, "~> 0.13.0", targets: @all_targets},
      {:nerves_ssh, "~> 1.2", targets: @all_targets},
      {:mdns_lite, "~> 0.9", targets: @all_targets},
      {:vintage_net, "~> 0.13", targets: @all_targets},
      {:vintage_net_wifi, "~> 0.12", targets: @all_targets},
      {:vintage_net_ethernet, "~> 0.11", targets: @all_targets},
      {:muontrap, "~> 1.0"},

      # Dependencies for specific targets
      atomcam2_system()
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end

  defp extra_applications do
    applications = [:logger, :runtime_tools, :inets, :ssl]

    if Mix.target() in @all_targets do
      [:ssh | applications]
    else
      applications
    end
  end

  defp atomcam2_system do
    case System.get_env("ATOMCAM2_SYSTEM_SOURCE", "release") do
      "release" ->
        {:nerves_system_atomcam2,
         github: @system_repository,
         tag: "v#{@system_version}",
         runtime: false,
         targets: :atomcam2}

      "local" ->
        {:nerves_system_atomcam2,
         path: "../..", runtime: false, targets: :atomcam2, nerves: [compile: true]}

      source ->
        raise "unsupported ATOMCAM2_SYSTEM_SOURCE: #{inspect(source)}"
    end
  end

  defp release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: [keep: ["Docs"]]
    ]
  end
end
