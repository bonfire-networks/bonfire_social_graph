defmodule Bonfire.Social.Graph.FollowAcceptedNotificationTest do
  @moduledoc """
  Someone who asked to follow is told when the answer is yes: the Follow made by accepting their request reaches their own notifications, read from their side as "you are now following". A follow that needed no approval tells them nothing, since they saw it happen.
  """
  use Bonfire.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.Activities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Graph.Follows

  # the Follows in this person's notifications, as feed rows carry them
  defp follows_in_notifications(user) do
    follow_verb_id = Bonfire.Boundaries.Verbs.get(:follow)[:id]

    %{edges: edges} = FeedLoader.feed(:notifications, current_user: user, preload: false)

    edges
    |> Enum.map(& &1.activity)
    |> Enum.filter(&(&1.verb_id == follow_verb_id))
  end

  test "accepting a request puts the Follow in the requester's notifications, read as now following" do
    follower = fake_user!()
    followed = fake_user!(%{}, %{}, request_before_follow: true)

    {:ok, request} = Follows.follow(follower, followed)
    assert Follows.requested?(follower, followed), "control: a request, not a follow"
    assert [] == follows_in_notifications(follower), "control: nothing to tell them yet"

    {:ok, _follow} = Follows.accept(request, current_user: followed)
    assert Follows.following?(follower, followed), "control: the accept made the follow"

    assert [activity] = follows_in_notifications(follower)
    assert activity.object_id == id(followed)

    assert Activities.experienced_as(activity, id(follower)) == :follow

    assert Activities.experienced_as(activity, id(followed)) == :follow,
           "the person followed reads the same Follow as someone following them"

    # what tells them apart is the wording, by what the reader is to it
    assert Bonfire.Social.Notifications.phrase_for(
             :follow,
             activity.object_id,
             id(follower),
             activity.subject_id
           ) == "You are now following"

    assert Bonfire.Social.Notifications.phrase_for(
             :follow,
             activity.object_id,
             id(followed),
             activity.subject_id
           ) == "followed you"
  end

  test "control: following an open account notifies the follower of nothing" do
    follower = fake_user!()
    followed = fake_user!()

    {:ok, _follow} = Follows.follow(follower, followed)
    assert Follows.following?(follower, followed), "control: they follow"

    assert [] == follows_in_notifications(follower)
  end
end
