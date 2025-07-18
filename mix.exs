Code.eval_file("mess.exs", (if File.exists?("../../lib/mix/mess.exs"), do: "../../lib/mix/"))

defmodule Bonfire.Social.Graph.MixProject do
  use Mix.Project

  def project do
    if System.get_env("AS_UMBRELLA") == "1" do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
    ++
    [
      app: :bonfire_social_graph,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps:
        Mess.deps([
          {:bonfire_me,
           git: "https://github.com/bonfire-networks/bonfire_me",
           
           optional: true, runtime: false},
          {:bonfire_api_graphql,
           git: "https://github.com/bonfire-networks/bonfire_api_graphql",
           optional: true, runtime: false},
          {:absinthe, "~> 1.7", optional: true}
        ])
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application, do: [extra_applications: [:logger]]
end
