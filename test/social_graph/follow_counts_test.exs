defmodule Bonfire.Social.Graph.FollowCountsTest do
  @moduledoc """
  `Follows.follow_counts/1`: how many follow someone and how many they follow, read from the follow totals in one query. Shared by the profile header and the profile hover card, so both show the same numbers.
  """
  use Bonfire.DataCase, async: true

  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Me.Fake

  test "nobody, both ways" do
    assert {0, 0} = Follows.follow_counts(Fake.fake_user!())
  end

  test "followers and following counted from each side" do
    me = Fake.fake_user!()
    {:ok, _} = Follows.follow(Fake.fake_user!(), me)
    {:ok, _} = Follows.follow(Fake.fake_user!(), me)
    {:ok, _} = Follows.follow(me, Fake.fake_user!())

    assert {2, 1} = Follows.follow_counts(me)
  end

  test "a pending follow request isn't counted as a follower or a follow" do
    asker = Fake.fake_user!()
    approver = Fake.fake_user!(%{}, %{}, request_before_follow: true)
    {:ok, _} = Follows.follow(asker, approver)
    assert Follows.requested?(asker, approver)

    assert {0, 0} = Follows.follow_counts(approver)
    assert {0, 0} = Follows.follow_counts(asker)
  end

  test "the same numbers as the profile page's live counts" do
    me = Fake.fake_user!()
    {:ok, _} = Follows.follow(Fake.fake_user!(), me)
    {:ok, _} = Follows.follow(me, Fake.fake_user!())

    live =
      {Bonfire.Social.Edges.count(Bonfire.Data.Social.Follow, [objects: me], skip_boundary_check: true),
       Bonfire.Social.Edges.count(Bonfire.Data.Social.Follow, [subjects: me], skip_boundary_check: true)}

    assert Follows.follow_counts(me) == live
  end
end
