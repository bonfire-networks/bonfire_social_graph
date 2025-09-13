defmodule Bonfire.Social.Graph.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  use Bonfire.Common.Localise

  @doc """
  NOTE: you can override this default config in your app's runtime.exs, by placing similarly-named config keys below the `Bonfire.Common.Config.LoadExtensionsConfig.load_configs` line
  """
  def config do
    import Config

    case System.get_env("GRAPH_DB_URL") do
      nil ->
        nil

      url ->
        pool_size =
          case System.get_env("POOL_SIZE") do
            pool when is_binary(pool) and pool not in ["", "0"] ->
              String.to_integer(pool)

            # default to twice the number of CPU cores
            _ ->
              System.schedulers_online() * 2
          end

        # config :bolt_sips, Bolt,
        #   url: url,
        #   basic_auth: [username: System.get_env("GRAPH_DB_USER", "memgraph"), password: System.get_env("GRAPH_DB_PW", "memgraph") ],
        #   pool_size: pool_size

        config :boltx, Boltx,
          uri: url,
          auth: [
            username: System.get_env("GRAPH_DB_USER", "memgraph"),
            password: System.get_env("GRAPH_DB_PW", "memgraph")
          ],
          pool_size: pool_size,
          user_agent: "boltxTest/1",
          max_overflow: 3,
          prefix: :default,
          name: Bolt
    end
  end
end
