defmodule Bonfire.Social.Graph.Follows do
  @moduledoc """
  Module for handling follow relationships in the Bonfire social graph.
  """

  alias Bonfire.Data.Social.Follow
  alias Bonfire.Data.Social.Request

  # alias Bonfire.Me.Boundaries
  alias Bonfire.Me.Characters
  # alias Bonfire.Me.Users

  alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social
  alias Bonfire.Social.Requests

  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # alias Needle.Changesets
  import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Follow
  def query_module, do: Follow

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Follow",
      {"Create", "Follow"},
      {"Undo", "Follow"},
      {"Delete", "Follow"},
      {"Accept", "Follow"},
      {"Reject", "Follow"}
    ]

  @doc """
  Checks if a subject is following an object.

  ## Parameters

  - `subject`: The subject (follower)
  - `object`: The object (followed)

  ## Returns

  Boolean indicating if the subject is following the object.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.following?(user, profile)
      true
  """

  # TODO: privacy
  def following?(subject, object),
    # current_user: subject)
    do: Edges.exists?(__MODULE__, subject, object, verbs: [:follow], skip_boundary_check: true)

  @doc """
  Checks if a follow request has been made.

  ## Parameters

  - `subject`: The subject (requester)
  - `object`: The object (requested)

  ## Returns

  Boolean indicating if a follow request exists.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.requested?(user, profile)
      true
  """
  def requested?(subject, object),
    do: Requests.requested?(subject, Follow, object)

  @doc """
  Follows someone or something. In case of success, publishes to feeds and federates.

  If the user is not permitted to follow the object, or the object is
  a remote actor, it will instead send a request to follow.

  ## Parameters

  - `user`: The user who wants to follow
  - `object`: The object to be followed
  - `opts`: Additional options

  ## Returns

  `{:ok, result}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.follow(me, user2)
      {:ok, %Follow{}}

      iex> Bonfire.Social.Graph.Follows.follow(me, user3)
      {:ok, %Request{}}
  """
  def follow(user, object, opts \\ [])

  def follow(%{} = follower, object, opts) do
    with {:ok, result} <- maybe_follow_or_request(follower, object, opts) do
      # debug(result, "follow or request result")
      {:ok, result}
    end
  end

  defp maybe_follow_or_request(follower, object, opts) do
    opts = Keyword.put_new(to_options(opts), :current_user, follower)
    follower = repo().preload(follower, :peered)

    case check_follow(follower, object, opts) do
      {:local, object} ->
        info("following local, do the follow")
        do_follow(follower, object, opts)

      # Note: we now rely on Boundaries instead of making an arbitrary difference here
      # if Social.is_local?(follower) do
      # info("remote following local, attempting a request")
      # Requests.request(follower, Follow, object, opts)
      # else
      #   info("local following local, attempting follow")
      #   do_follow(follower, object, opts)
      # end

      {:remote, object} ->
        if Social.is_local?(follower) do
          info(
            "local following remote, attempting a request instead of follow (which *may* be auto-accepted by the remote instance)"
          )

          Requests.request(follower, Follow, object, opts)
        else
          warn("remote following remote, should not be possible!")
          {:error, :not_permitted}
        end

      :not_permitted ->
        info("not permitted to follow, attempting a request instead")
        Requests.request(follower, Follow, object, opts)
    end
  end

  defp check_follow(follower, object, opts) do
    # debug(opts)
    # debug(id(follower))
    # debug(id(object))
    skip? = skip_boundary_check?(opts, object)
    # debug(skip?)
    skip? =
      skip? == true ||
        (skip? == :admins and maybe_apply(Bonfire.Me.Accounts, :is_admin?, follower) == true)

    opts =
      opts
      |> Keyword.put_new(:verbs, [:follow])
      |> Keyword.put_new(:current_user, follower)

    if skip? do
      debug(skip?, "skip boundary check")
      local_or_remote_object(object)
    else
      case uid(object) do
        id when is_binary(id) ->
          case Bonfire.Boundaries.load_pointer(id, opts) |> debug("loaded_pointer") do
            object when is_struct(object) ->
              local_or_remote_object(object)

            _ ->
              :not_permitted
          end

        _ ->
          error(object, "no object ID, attempting with username")

          case maybe_apply(Characters, :by_username, [object, opts]) do
            object when is_struct(object) ->
              local_or_remote_object(object)

            _ ->
              :not_permitted
          end
      end
    end
  end

  # Notes for future refactor:
  # * Make it pay attention to options passed in
  # * When we start allowing to follow things that aren't users, we might need to adjust the circles.
  # * Figure out how to avoid the advance lookup and ensuing race condition.
  defp do_follow(%{} = user, %{} = object, opts) do
    # character is needed for boxes & graphDB
    user =
      user
      |> repo().maybe_preload(:character)

    object =
      object
      |> repo().maybe_preload(:character)

    to = [
      # we include follows in feeds, since user has control over whether or not they want to see them in settings
      outbox: [user],
      notifications: [object]
    ]

    opts =
      Keyword.merge(
        [
          # TODO: make configurable (currently public is required so follows can be listed by AP adapter)
          boundary: "public",
          # also allow the followed user to see it
          to_circles: [id(object)],
          # put it in our outbox and their notifications
          to_feeds: to
        ],
        opts
      )

    repo().transact_with(fn ->
      case create(user, object, opts) do
        {:ok, follow} ->
          invalidate_followed_outboxes_cache(id(user))

          # FIXME: should not compute feed ids twice
          maybe_apply(Bonfire.Social.LivePush, :push_activity_object, [
            FeedActivities.get_publish_feed_ids(opts[:to_feeds]),
            follow,
            object,
            [push_to_thread: false, notify: true]
          ])

          follower_type = Types.object_type(user)
          object_type = Types.object_type(object)

          if follower_type == Bonfire.Data.Identity.User,
            do:
              Bonfire.Boundaries.Circles.add_to_circles(
                object,
                Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed)
              )

          if object_type == Bonfire.Data.Identity.User,
            do:
              Bonfire.Boundaries.Circles.add_to_circles(
                user,
                Bonfire.Boundaries.Circles.get_stereotype_circles(
                  object,
                  :followers
                )
              )

          if follower_type == Bonfire.Data.Identity.User and
               object_type == Bonfire.Data.Identity.User,
             do: Bonfire.Social.Graph.graph_add(user, object, Follow)

          if opts[:incoming] != true,
            do: Social.maybe_federate_and_gift_wrap_activity(user, follow),
            else: {:ok, follow}

        e ->
          error(e)
          maybe_already_followed(user, object)
      end
    end)
  rescue
    e in Ecto.ConstraintError ->
      error(e)
      maybe_already_followed(user, object)
  end

  @doc """
  Accepts a follow request, publishes to feeds and federates.

  ## Parameters

  - `subject`: The requester
  - `opts`: Additional options including the current user

  ## Returns

  `{:ok, follow}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.accept_from(requester, current_user: acceptor)
      {:ok, %Follow{}}
  """
  def accept_from(subject, opts) do
    Requests.get(subject, Follow, current_user_required!(opts), opts)
    |> debug()
    ~> accept(opts)
  end

  @doc """
  Accepts a follow request, publishes to feeds and federates.

  ## Parameters

  - `request`: A `Request` struct or its ID
  - `opts`: Additional options including the current user

  ## Returns

  `{:ok, follow}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.accept(request, current_user: acceptor)
      {:ok, %Follow{}}
  """
  def accept(request, opts) do
    debug(opts, "opts")

    repo().transact_with(fn ->
      with {:ok, %{edge: %{object: object, subject: subject}} = request} <-
             Requests.accept(request, opts)
             |> repo().maybe_preload(edge: [:subject, :object])
             |> debug("accepted"),
           # remove the Edge so we can recreate one linked to the Follow, because of the unique key on subject/object/table_id
           _ <- Edges.delete_by_both(subject, Follow, object),
           # remove the Request Activity from notifications
           _ <-
             Activities.delete_by_subject_verb_object(subject, :request, object),
           {:ok, follow} <- do_follow(subject, object, opts) |> debug("accept_do_follow"),
           :ok <-
             if(opts[:incoming] != true,
               do: Requests.ap_publish_activity(subject, {:accept, request}, follow),
               else: :ok
             ) do
        {:ok, follow}
      else
        e ->
          error(e, l("An error occurred while accepting the follow request"))
      end
    end)
  end

  @doc """
  Unfollows someone or something.

  ## Parameters

  - `user`: The user who wants to unfollow
  - `object`: The object to be unfollowed
  - `opts`: Additional options

  ## Returns

  Result of the unfollow operation.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.unfollow(me, user2)
      {:ok, deleted_follow}
  """
  def unfollow(user, object, opts \\ [])

  def unfollow(user, %{} = object, opts) do
    if following?(user, object) do
      deleted_edges =
        Edges.delete_by_both(user, Follow, object)
        |> debug("deleted")

      # with [_id] <- Edges.delete_by_both(user, Follow, object) do

      # delete the like activity & feed entries
      deleted_activities = Activities.delete_by_subject_verb_object(user, :follow, object)

      invalidate_followed_outboxes_cache(id(user))

      Bonfire.Boundaries.Circles.get_stereotype_circles(user, :followed)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(object, ...)

      Bonfire.Boundaries.Circles.get_stereotype_circles(object, :followers)
      ~> Bonfire.Boundaries.Circles.remove_from_circles(user, ...)

      Bonfire.Social.Graph.graph_remove(user, object, Follow)

      if opts[:incoming] != true,
        do: ap_publish_activity(user, :delete, object),
        else: deleted_edges || deleted_activities

      # Social.maybe_federate(user, :unfollow, object)

      # end
    else
      if requested?(user, object) do
        Requests.unrequest(user, Follow, object)
      else
        error("Cannot unfollow because not following")
      end
    end
  end

  def unfollow(%{} = user, object, opts) when is_binary(object) do
    with {:ok, object} <-
           Bonfire.Common.Needles.get(object,
             current_user: user,
             skip_boundary_check: true
           ) do
      unfollow(user, object, opts)
    end
  end

  @doc """
  Ignores a follow request.

  ## Parameters

  - `request`: The request to ignore
  - `opts`: Additional options

  ## Returns

  Result of the ignore operation.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ignore(request, current_user: user)
      {:ok, ignored_request}
  """
  def ignore(request, opts) do
    Requests.ignore(request, opts)
  end

  @doc """
  Gets a follow relationship between a subject and an object, if one exists.

  ## Parameters

  - `subject`: The subject (follower)
  - `object`: The object (followed)
  - `opts`: Additional options

  ## Returns

  `{:ok, follow}` if found, `{:error, :not_found}` otherwise.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.get(user, profile)
      {:ok, %Follow{}}
  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  @doc """
    Gets a follow relationship between a subject and an object, raising an error if not found.
  """
  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  # TODO: abstract the next few functions into Edges

  @doc """
  Lists all follows by a subject.

  ## Parameters

  - `user`: The user whose follows to list
  - `opts`: Additional options

  ## Returns

  List of follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_by_subject(user)
      [%Follow{}, ...]
  """
  def all_by_subject(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :object_character)
    |> query([subjects: user], ...)
    |> repo().many()
  end

  @doc """
  Lists all objects followed by a subject.

  ## Parameters

  - `user`: The user whose followed objects to list
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_objects_by_subject(user)
      [%FollowedObject{}, ...]
  """
  def all_objects_by_subject(user, opts \\ []) do
    all_by_subject(user, opts)
    |> Enum.map(&e(&1, :edge, :object, nil))
  end

  @doc """
  Lists all follows for an object.

  ## Parameters

  - `user`: The object whose followers to list
  - `opts`: Additional options

  ## Returns

  List of follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_by_object(user)
      [%Follow{}, ...]
  """
  def all_by_object(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:preload, :subject_character)
    |> query([objects: user], ...)
    |> repo().many()
  end

  @doc """
  Lists all subjects following an object.

  ## Parameters

  - `user`: The object whose followers to list
  - `opts`: Additional options

  ## Returns

  List of follower subjects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_subjects_by_object(user)
      [%FollowerSubject{}, ...]
  """
  def all_subjects_by_object(user, opts \\ []) do
    all_by_object(user, opts)
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  @doc """
  Lists all followed outboxes for a user.

  ## Parameters

  - `user`: The user whose followed outboxes to list
  - `opts`: Additional options

  ## Returns

  List of followed outbox IDs.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.all_followed_outboxes(user)
      ["outbox_id_1", ...]

      iex> Bonfire.Social.Graph.Follows.all_followed_outboxes(user, include_followed_categories: true)
      ["outbox_id_1", "category_outbox_id_1", ...]
  """
  def all_followed_outboxes(user, opts \\ []) do
    include_followed_categories = opts[:include_followed_categories]

    Cache.maybe_apply_cached(
      &fetch_all_followed_outboxes/3,
      [user, include_followed_categories, opts],
      opts ++ [cache_key: "my_followed:#{include_followed_categories == true}:#{id(user)}"]
    )
  end

  defp invalidate_followed_outboxes_cache(user) do
    Cache.remove("my_followed:true:#{id(user)}")
    Cache.remove("my_followed:false:#{id(user)}")
  end

  defp fetch_all_followed_outboxes(user, include_categories, opts) do
    if(include_categories != true,
      do: opts ++ [filters: [exclude_object_types: Bonfire.Classify.Category]],
      else: opts
    )
    |> all_objects_by_subject(user, ...)
    |> debug()
    |> Enum.map(&e(&1, :character, :outbox_id, nil))
  end

  # defp query_base(filters, opts) do
  #   vis = filter_invisible(current_user(opts))
  #   from(f in Follow, join: v in subquery(vis), on: f.id == v.object_id)
  #   |> proload(:edge)
  #   |> query_filter(filters)
  # end

  defp query_base(filters, opts) do
    filters = e(opts, :filters, []) ++ filters

    Edges.query_parent(Follow, filters, opts)
    |> query_filter(Keyword.drop(filters, [:object, :subject]))

    # |> debug("follows query")
  end

  @doc """
  Queries follows based on filters and options.

  ## Parameters

  - `filters`: List of filters to apply to the query
  - `opts`: Additional query options

  ## Returns

  An Ecto query for follows.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.query([my: :objects], current_user: user)
      # following

      iex> Bonfire.Social.Graph.Follows.query([my: :followers], current_user: user)
      # followers
  """
  def query([my: :objects], opts),
    do: query([subjects: current_user_required!(opts)], opts)

  def query([my: :followers], opts),
    do: query([objects: current_user_required!(opts)], opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end

  @doc """
  Lists followed objects for the current user.

  ## Parameters

  - `current_user`: The current user
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_my_followed(current_user)
      [%Object{}, ...]
  """
  def list_my_followed(current_user, opts \\ []),
    do:
      list_followed(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  @doc """
  Lists followed objects for a given user.

  ## Parameters

  - `user`: The user whose followed objects to list
  - `opts`: Additional options

  ## Returns

  List of followed objects.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_followed(user)
      [%Object{}, ...]
  """
  def list_followed(user, opts \\ []) do
    # TODO: configurable boundaries for follows
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :object]

    [subjects: uid(user), object_types: opts[:type]]
    |> query(opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_followed_profile_only(opts)
    |> Social.many(opts[:paginate], opts)
  end

  @doc """
  Lists followers for the current user.

  ## Parameters

  - `current_user`: The current user
  - `opts`: Additional options

  ## Returns

  List of followers.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_my_followers(current_user)
      [%User{}, ...]
  """
  def list_my_followers(current_user, opts \\ []),
    do:
      list_followers(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  @doc """
  Lists followers for a given user.

  ## Parameters

  - `user`: The user whose followers to list
  - `opts`: Additional options

  ## Returns

  List of followers.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.list_followers(user)
      [%User{}, ...]
  """
  def list_followers(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :subject]

    [objects: uid(user), subject_types: opts[:type]]
    |> query(opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_follower_profile_only(opts)
    |> Social.many(opts[:paginate], opts)
  end

  # defp maybe_with_follower_profile_only(q, true),
  #   do: where(q, [follower_profile: p], not is_nil(p.id))

  # defp maybe_with_follower_profile_only(q, _), do: q

  # def changeset(:create, subject, object, boundary) do
  #   Changesets.cast(%Follow{}, %{}, [])
  #   |> Edges.put_assoc(subject, object, :follow, boundary)
  # end

  # defp local_or_remote_object(id) when is_binary(id) do
  #   Bonfire.Common.Needles.get(id, skip_boundary_check: true)
  #   ~> local_or_remote_object()
  # end
  defp local_or_remote_object(object) do
    object = repo().maybe_preload(object, [:peered, created: [creator: :peered]])
    # |> info()

    if Social.is_local?(object) do
      {:local, object}
    else
      {:remote, object}
    end
  end

  defp maybe_already_followed(user, object) do
    case get(user, object, skip_boundary_check: true) do
      {:ok, follow} ->
        debug("the user already follows this object")
        {:ok, follow}

      e ->
        error(e)
    end
  end

  defp create(%{} = follower, object, opts) do
    Edges.insert(Follow, follower, :follow, object, opts)
  end

  ### ActivityPub integration

  @doc """
  Publishes an ActivityPub activity for a follow-related action.

  ## Parameters

  - `subject`: The subject of the activity
  - `verb`: The verb of the activity (e.g., :delete)
  - `follow`: The follow object or ID

  ## Returns

  `{:ok, activity}` on success, `{:error, reason}` on failure.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ap_publish_activity(user, :delete, follow)
      {:ok, %ActivityPub.Activity{}}
  """
  def ap_publish_activity(subject, :delete, %Follow{edge: edge}) do
    ap_publish_activity(
      subject || e(edge, :subject, nil) || edge.subject_id,
      :delete,
      e(edge, :object, nil) || edge.object_id
    )
  end

  def ap_publish_activity(subject, :delete, object) do
    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(pointer: subject),
         {:ok, ap_object} <-
           ActivityPub.Actor.get_cached(pointer: object) do
      ActivityPub.unfollow(%{actor: follower, object: ap_object, local: true})
    end
  end

  def ap_publish_activity(subject, _verb, follow) do
    error_msg = l("Could not federate the follow")

    follow = repo().maybe_preload(follow, :edge)

    with {:ok, follower} <-
           ActivityPub.Actor.get_cached(
             pointer:
               subject || e(follow, :edge, :subject, nil) || e(follow, :edge, :subject_id, nil)
           )
           |> info("follower actor"),
         {:ok, object} <-
           ActivityPub.Actor.get_cached(
             pointer: e(follow.edge, :object, nil) || e(follow, :edge, :object_id, nil)
           )
           |> info("followed actor"),
         {:ok, activity} <-
           ActivityPub.follow(%{
             actor: follower,
             object: object,
             local: true,
             pointer: uid(follow)
           }) do
      {:ok, activity}
    else
      {:error, :not_found} ->
        error("Actor not found", error_msg)
        {:ok, :ignore}

      {:reject, reason} ->
        {:reject, reason}

      e ->
        error(e, error_msg)
        raise error_msg
    end
  end

  @doc """
  Receives and processes an ActivityPub activity related to follows.

  ## Parameters

  - `follower`: The follower
  - `activity`: The ActivityPub activity
  - `object`: The object of the activity

  ## Returns

  `{:ok, result}` on success, `{:ignore, reason}` on failure or when ignored.

  ## Examples

      iex> Bonfire.Social.Graph.Follows.ap_receive_activity(follower, activity, object)
      {:ok, %Follow{}}
  """
  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Follow"} = data} = _activity,
        object
      )
      when is_binary(follower) or is_struct(follower) do
    info(data, "Follows: attempt to record an incoming follow...")

    with {:ok, followed} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(object),
         # check if not already following
         false <- following?(follower, followed),
         {:ok, %Follow{} = follow} <-
           follow(follower, followed, current_user: follower, incoming: true) do
      with {:ok, _accept_activity, _adapter_object, _accepted_activity} = accept <-
             ActivityPub.accept_activity(%{
               actor: object,
               to: [data["actor"]],
               object: data,
               local: true
             }) do
        debug(accept, "Follow was auto-accepted")

        {:ok, follow}
      else
        e ->
          error(e, "Unable to auto-accept the follow")
          {:ok, follow}
      end
    else
      true ->
        warn("Federated follow already exists")
        # reaffirm that the follow has gone through when following? was already == true

        ActivityPub.accept(%{
          actor: object,
          to: [data["actor"]],
          object: data,
          local: true
        })

      {:ok, %Request{} = request} ->
        info("Follow was requested and remains pending")
        {:ok, request}

      e ->
        error(e, "Could not follow")
        {:ignore, "Could not follow"}
    end
  end

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Accept"} = _data} = _activity,
        %{data: %{"actor" => ap_follower}} = _object
      ) do
    info(followed, "Accept incoming request")

    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(ap_follower) do
      with {:ok, request} <-
             Requests.get(follower, Follow, followed, skip_boundary_check: true),
           {:ok, accepted} <- accept(request, current_user: followed, incoming: true) do
        debug(accepted, "acccccepted")
        {:ok, accepted}
      else
        {:error, :not_found} ->
          case following?(follower, followed) do
            false ->
              error("No such Follow")

            true ->
              # already followed
              {:ok, nil}
          end

        e ->
          error(e)
      end
    else
      {:error, :not_found} ->
        error(ap_follower, "No actor found for the follower")

      e ->
        error(e)
    end
  end

  def ap_receive_activity(
        followed,
        %{data: %{"type" => "Reject"} = _data} = _activity,
        %{data: %{"actor" => follower}} = _object
      ) do
    with {:ok, follower} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(follower) do
      case following?(follower, followed) do
        false ->
          reject(follower, followed, incoming: true)

        true ->
          request =
            with {:ok, request} <- reject(follower, followed, incoming: true) do
              request
              |> debug("rejected previously accepted request")
            end

          unfollow(follower, followed, incoming: true)
          |> debug("unfollow rejected follow")

          {:ok, request}
      end
    end
  end

  def ap_receive_activity(
        follower,
        %{data: %{"type" => "Undo"} = _data} = _activity,
        %{data: %{"object" => followed_ap_id}} = _object
      ) do
    with {:ok, object} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
             followed_ap_id
           ),
         [id] <- unfollow(follower, object, incoming: true) do
      {:ok, id}
    end
  end

  defp reject(follower, followed, opts \\ []) do
    with {:ok, request} <-
           Requests.get(follower, Follow, followed, skip_boundary_check: true),
         {:ok, request} <- ignore(request, opts ++ [current_user: followed]) do
      {:ok, request}
    end
  end
end
