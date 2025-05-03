defmodule Bonfire.Social.Graph.Integration do
  use Arrows
  use Bonfire.Common.Config
  use Bonfire.Common.Utils
  # alias Bonfire.Data.Social.Follow
  # import Untangle

  def repo, do: Config.repo()

  def mailer, do: Config.get!(:mailer_module)

  declare_extension("Social graph",
    icon: "fluent:people-community-48-filled",
    emoji: "🫂",
    description:
      l(
        "Functionality for following users, managing aliases, importing/exporting follows, and the like."
      )
  )
end
