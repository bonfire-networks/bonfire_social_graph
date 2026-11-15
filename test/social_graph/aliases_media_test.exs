# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.Social.Graph.AliasesMediaTest do
  @moduledoc """
  A link alias is a Media row shared by every user who aliases the same URL. Adding the URL again reuses the row, and removing an alias deletes the row only when nothing else references it.
  """
  use Bonfire.Social.Graph.DataCase, async: false
  @moduletag :backend

  alias Bonfire.Social.Graph.Aliases
  alias Bonfire.Files.Media

  defp url, do: "https://provider.example/profile/#{System.unique_integer([:positive])}"

  defp add_link(user, url),
    do: Aliases.add(user, {:provider, :orcid, "ORCID", url, %{"sub" => "someone"}})

  test "the sole user removing their alias deletes the media (control)" do
    me = fake_user!()
    url = url()

    assert {:ok, _} = add_link(me, url)
    assert {:ok, media} = Media.get_by_path(url)
    assert Aliases.exists?(me, media)

    Aliases.remove(me, media)

    refute Aliases.exists?(me, media)
    assert {:error, :not_found} = Media.get_by_path(url)
  end

  test "a second user can alias a URL the first already added" do
    a = fake_user!()
    b = fake_user!()
    url = url()

    assert {:ok, _} = add_link(a, url)
    assert {:ok, media} = Media.get_by_path(url)

    assert {:ok, _} = add_link(b, url)
    assert Aliases.exists?(b, media)
    assert Aliases.exists?(a, media)
  end

  test "removing one user's alias keeps the media the other user still aliases" do
    a = fake_user!()
    b = fake_user!()
    url = url()

    assert {:ok, _} = add_link(a, url)
    assert {:ok, _} = add_link(b, url)
    assert {:ok, media} = Media.get_by_path(url)

    Aliases.remove(b, media)

    refute Aliases.exists?(b, media)
    assert Aliases.exists?(a, media)
    assert {:ok, _} = Media.get_by_path(url)

    # and once the last alias goes, so does the row
    Aliases.remove(a, media)
    assert {:error, :not_found} = Media.get_by_path(url)
  end
end
