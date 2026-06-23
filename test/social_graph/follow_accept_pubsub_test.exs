defmodule Bonfire.Social.Graph.FollowAcceptPubSubTest do
  @moduledoc """
  bonfire-app #1907 / #1906 / #1659: when a follow request is accepted, the resulting Follow
  activity's subject (actor) must be the FOLLOWER — not the accepter. The bug: the activity is
  created with `subject = current_user`, and on accept `current_user` is the accepter, so the
  Follow shows the wrong actor (#1907) / an invalid/blank activity (#1906, #1659).

  Proven at two levels: the DB row (the source of truth) AND the live-pushed PubSub payload.
  """
  use Bonfire.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Common.PubSub
  alias Bonfire.Social.Graph.Follows
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.FeedLoader

  test "an accepted follow's activity subject is the follower, not the accepter" do
    follower = fake_user!(%{}, %{}, request_before_follow: true)
    followed = fake_user!(%{}, %{}, request_before_follow: true)

    {:ok, request} = Follows.follow(follower, followed)
    assert Follows.requested?(follower, followed)

    # subscribe to the followed user's notifications feed — accept pushes the Follow activity there
    feed_id = Feeds.feed_id(:notifications, followed)
    :ok = PubSub.subscribe(feed_id, current_user: followed)

    {:ok, _follow} = Follows.accept(request, current_user: followed)

    # 1) DB / "page refresh" source of truth.
    %{edges: edges} = FeedLoader.feed(:notifications, current_user: followed, preload: false)

    # find the FOLLOW activity specifically (not a Request/Accept), and check ITS subject
    follow_verb_id = Bonfire.Boundaries.Verbs.get(:follow)[:id]

    follow_edge =
      Enum.find(edges, fn e -> e(e, :activity, :verb_id, nil) == follow_verb_id end)

    assert follow_edge,
           "no :follow activity in followed's notifications; verbs present: #{inspect(Enum.map(edges, &e(&1, :activity, :verb_id, nil)))}"

    assert follow_edge.activity.subject_id == id(follower),
           "DB Follow activity subject should be the follower (#{id(follower)}), got #{follow_edge.activity.subject_id} (followed/accepter is #{id(followed)})"

    # 2) the live-pushed PubSub payload shows the same correct actor (no wrong/invalid until refresh)
    assert_receive {{Bonfire.Social.Feeds, :new_activity}, [feed_ids: _, activity: activity]},
                   5_000

    assert e(activity, :subject_id, nil) == id(follower),
           "pushed Follow activity subject should be the follower, got #{inspect(e(activity, :subject_id, nil))}"

    # and the subject is loaded enough to render the right person without a refresh
    assert id(e(activity, :subject, nil)) == id(follower)
    assert e(activity, :subject, :profile, nil)
    assert e(activity, :subject, :character, nil)
  end
end
