defmodule Bonfire.Social.Graph.FamiliarFollowersTest do
  @moduledoc """
  `Follows.familiar_followers/3`: the people I follow who also follow someone, as up to `limit` users plus how many there are in all, in one query. Shown in the profile hover card's "Followed by" row.
  """
  use Bonfire.DataCase, async: true

  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Me.Fake

  test "the people I follow who follow them: the first few, and how many in all" do
    me = Fake.fake_user!()
    target = Fake.fake_user!()
    friends = for _ <- 1..4, do: Fake.fake_user!()

    for friend <- friends do
      {:ok, _} = Follows.follow(me, friend)
      {:ok, _} = Follows.follow(friend, target)
    end

    assert {users, 4} = Follows.familiar_followers(me, target)
    assert length(users) == 3
    assert Enum.all?(users, &(&1.id in Enum.map(friends, fn f -> f.id end)))
    # ready for the avatar row without another query
    assert Enum.all?(users, &(&1.profile && &1.profile.name))
  end

  test "only people I follow count, not others who follow them" do
    me = Fake.fake_user!()
    target = Fake.fake_user!()
    friend = Fake.fake_user!()
    stranger = Fake.fake_user!()

    {:ok, _} = Follows.follow(me, friend)
    {:ok, _} = Follows.follow(friend, target)
    {:ok, _} = Follows.follow(stranger, target)

    assert {[%{id: id}], 1} = Follows.familiar_followers(me, target)
    assert id == friend.id
  end

  test "nobody when I follow nobody who follows them" do
    me = Fake.fake_user!()
    target = Fake.fake_user!()
    {:ok, _} = Follows.follow(Fake.fake_user!(), target)

    assert {[], 0} = Follows.familiar_followers(me, target)
  end

  test "neither I nor they appear, even though I follow them" do
    me = Fake.fake_user!()
    target = Fake.fake_user!()

    {:ok, _} = Follows.follow(me, target)
    {:ok, _} = Follows.follow(target, me)

    assert {[], 0} = Follows.familiar_followers(me, target)
  end
end
