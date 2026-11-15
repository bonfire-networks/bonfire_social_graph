defmodule Bonfire.Social.Graph.BatchFollowCirclesTest do
  @moduledoc "A batch follow records who follows whom in the followers and followed circles only for the follows that took effect: asking someone who first needs to approve a request does not make the asker one of their followers."
  use Bonfire.DataCase, async: true

  alias Bonfire.Boundaries.Circles
  alias Bonfire.Social.Graph.Follows

  defp follower_of?(follower, followed),
    do: Circles.is_encircled_by?(follower, Circles.get_stereotype_circles(followed, :followers))

  test "control: following someone open to follows puts me in their followers circle" do
    me = fake_user!()
    open = fake_user!()

    assert [{_, {:ok, _}}] = Follows.batch_follow(me, [open])

    assert Follows.following?(me, open)
    assert follower_of?(me, open)
  end

  test "asking someone who needs to approve first does not put me in their followers circle" do
    me = fake_user!()
    locked = fake_user!(%{}, %{}, request_before_follow: true)

    Follows.batch_follow(me, [locked])

    assert Follows.requested?(me, locked), "control: a request was made"
    refute Follows.following?(me, locked), "control: not a follow yet"
    refute follower_of?(me, locked)
  end

  test "the same, when only the id is given (as the browser sends it)" do
    me = fake_user!()
    locked = fake_user!(%{}, %{}, request_before_follow: true)

    Follows.batch_follow(me, [locked.id])

    assert Follows.requested?(me, locked), "control: a request was made"
    refute Follows.following?(me, locked), "control: not a follow yet"
    refute follower_of?(me, locked)
  end
end
