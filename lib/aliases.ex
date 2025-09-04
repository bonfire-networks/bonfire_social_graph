defmodule Bonfire.Social.Graph.Aliases do
  @moduledoc """
  Implements aliases (i.e. "also known as") for characters in Bonfire.

  This module provides functionality for managing aliases, including adding,
  removing, and querying aliases. It also implements ActivityPub federation
  for the "Move" activity.
  """

  alias Bonfire.Data.Identity.Alias

  # alias Bonfire.Me.Boundaries
  # alias Bonfire.Me.Characters
  # alias Bonfire.Me.Users

  # alias Bonfire.Social.Activities
  alias Bonfire.Social.Edges
  # alias Bonfire.Social.FeedActivities
  # alias Bonfire.Social.Feeds
  alias Bonfire.Social
  alias Bonfire.Social.Graph.Follows

  # alias Bonfire.Data.Identity.User
  # alias Ecto.Changeset
  # alias Needle.Changesets
  # import Bonfire.Boundaries.Queries
  import Untangle
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo

  @behaviour Bonfire.Common.QueryModule
  @behaviour Bonfire.Common.ContextModule
  def schema_module, do: Alias
  def query_module, do: __MODULE__

  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  def federation_module,
    do: [
      "Move"
    ]

  @doc """
  Checks if an alias relationship exists between a subject and a target.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.exists?(subject, target)
      true

  """
  # TODO: privacy
  def exists?(subject, target),
    # current_user: subject)
    do: Edges.exists?(__MODULE__, subject, target, skip_boundary_check: true)

  @doc """
  Retrieves an alias between a subject and an object, if one exists

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.get(subject, object)
      {:ok, %Alias{}}

  """
  def get(subject, object, opts \\ []),
    do: Edges.get(__MODULE__, subject, object, opts)

  def get!(subject, object, opts \\ []),
    do: Edges.get!(__MODULE__, subject, object, opts)

  @doc """
  Adds an alias to a user, linking it to a another character.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.add(user, target)
      {:ok, %Alias{}}

  """
  def add(user, target, opts \\ [])

  def add(%{} = user, target, opts) when is_struct(target) do
    with {:ok, result} <- do_add(user, target, opts) do
      # debug(result, "add or request result")
      {:ok, result}
    end
  end

  def add(%{} = user, target, opts) when is_binary(target) do
    opts =
      Keyword.merge(opts,
        return_html_as_fallback: true,
        rel_me_urls: [URIs.url_path(user), URIs.canonical_url(user)]
      )
      |> debug("urllls")

    with {:ok, target} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
             target,
             opts
           ) do
      add(user, target, opts)
    else
      {:ok, %{body: body}} ->
        info(target, "was not an AP actor, add as URL instead")

        add_link_preview(
          user,
          target,
          fn url, opts -> Unfurl.unfurl_html(url, body, opts) end,
          opts
        )

      {:error, e} ->
        info(e, "could not find an AP actor for `#{target}`, maybe add as URL instead")
        add_link_preview(user, target, nil, opts)
    end
  end

  def add(%{} = user, {:provider, provider, provider_name, user_external_url, params}, opts) do
    opts = to_options(opts)

    meta = %{
      metadata: %{
        "name" => provider_name,
        provider => Enums.filter_empty(params, nil),
        verified: true
      }
      # marking OpenID/oAuth links as verified
    }

    add_link(user, user_external_url, provider, meta, opts)
  end

  defp add_link_preview(user, target, fetch_fn, opts) do
    # add_link(user, target, "link", %{}, opts)
    with %{} = media <-
           maybe_apply(Bonfire.Files.Acts.URLPreviews, :maybe_fetch_and_save, [
             user,
             target,
             opts
             |> Keyword.merge(
               fetch_fn: fetch_fn,
               type_fn: fn meta ->
                 # e(meta, "wikibase", "publicationTitle", nil) || 
                 (e(meta, "facebook", "site_name", nil) ||
                    e(meta, "oembed", "provider_name", nil) ||
                    e(meta, "other", "expected-hostname", nil) ||
                    URI.parse(target).host ||
                    "link")
                 |> String.replace("www.", "")
                 |> String.replace_trailing(".com", "")
               end
             )
           ]) do
      add(user, media, opts)
    else
      e -> error(e, l("Could not find or save the link"))
    end
  end

  defp add_link(%{} = user, external_url, type, meta, opts) do
    trigger_fun = fn target ->
      maybe_apply(
        Config.get([__MODULE__, :triggers, :add_link, type]),
        :trigger,
        [:add_link, user, target],
        opts
      )
    end

    with {:error, :not_found} <- Bonfire.Files.Media.get_by_path(external_url),
         # TODO: avoid storing access tokens in DB?
         {:ok, target} <-
           Bonfire.Files.Media.insert(
             user,
             external_url,
             %{media_type: to_string(type), size: 0},
             meta
             |> Map.put(:url, external_url)
           )
           |> debug() do
      trigger_fun.(target)
      add(user, target, opts)
    else
      {:ok, %{} = existing_media} ->
        with {:ok, target} <- Bonfire.Files.Media.update(user, existing_media, meta) do
          trigger_fun.(target)
          add(user, target, opts)
        end

      e ->
        error(e)
    end
  end

  defp do_add(%_user_struct{} = user, %{} = target, opts) do
    repo().transact_with(fn ->
      case create(user, target, opts) do
        {:ok, add} ->
          Social.maybe_federate(user, :update, add)

          {:ok, add}

        e ->
          error(e)
      end
    end)
  rescue
    e in Ecto.ConstraintError ->
      error(e)
      get(user, target, skip_boundary_check: true)
  end

  @doc """
  Removes an alias relationship between a user and a target.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.remove(user, target)

  """
  def remove(user, %{} = target) do
    if exists?(user, target) do
      Edges.delete_by_both(user, Alias, target)

      # If the target is a Media, delete it too
      maybe_delete_media(target)

      # TODO: update AP user?
      # Social.maybe_federate(user, :update, user)
      # ap_publish_activity(user, :update, target)
    else
      error("Does not exist")
    end
  end

  def remove(%{} = user, target) when is_binary(target) do
    with {:ok, target} <-
           Bonfire.Common.Needles.get(target,
             current_user: user,
             skip_boundary_check: true
           ) do
      remove(user, target)
    end
  end

  defp maybe_delete_media(%{__struct__: Bonfire.Files.Media} = target) do
    Bonfire.Files.Media.hard_delete(target)
  end

  defp maybe_delete_media(_), do: :ok

  # TODO: abstract the next few functions into Edges

  @doc """
  Retrieves all aliases for a given subject.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.all_by_subject(user)
      [%Alias{}, ...]

  """
  def all_by_subject(user, opts \\ []) do
    opts
    # |> Keyword.put_new(:current_user, user)
    |> Keyword.put_new(:skip_boundary_check, true)
    |> Keyword.put_new(:preload, :object)
    |> query([subjects: user], ...)
    |> repo().many()
  end

  @doc """
  Retrieves all aliased objects for a given subject.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.all_objects_by_subject(user)
      [%Object{}, ...]

  """
  def all_objects_by_subject(user, opts \\ []) do
    all_by_subject(user, opts)
    |> Enum.map(&e(&1, :edge, :object, nil))
  end

  @doc """
  Retrieves all aliases for a given object (i.e target).

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.all_by_object(object)
      [%Alias{}, ...]

  """
  def all_by_object(object, opts \\ []) do
    opts
    |> Keyword.put_new(:skip_boundary_check, true)
    |> Keyword.put_new(:preload, :subject)
    |> query([objects: object], ...)
    |> repo().many()
  end

  @doc """
  Retrieves all alias subjects for a given object (i.e target).

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.all_subjects_by_object(object)
      [%Subject{}, ...]

  """
  def all_subjects_by_object(object, opts \\ [])

  def all_subjects_by_object({:provider, provider, user_external_url, params}, opts) do
    opts = opts ++ [skip_boundary_check: true]

    Bonfire.Files.Media.one([path: user_external_url, media_type: to_string(provider)], opts)
    |> debug("found a match?")
    ~> all_subjects_by_object(opts)
  end

  def all_subjects_by_object(object, opts) do
    all_by_object(object, opts)
    |> Enum.map(&e(&1, :edge, :subject, nil))
  end

  defp query_base(filters, opts) do
    filters = e(opts, :filters, []) ++ filters

    Edges.query_parent(Alias, filters, debug(opts))
    |> query_filter(Keyword.drop(filters, [:objects, :subjects]))

    # |> debug("follows query")
  end

  def query(filters, opts) do
    query_base(filters, opts)
  end

  @doc """
  Lists aliases for the current user.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.list_my_aliases(current_user)
      [%Alias{}, ...]

  """
  def list_my_aliases(current_user, opts \\ []) do
    to_options(opts)
    |> Keyword.put(:current_user, current_user)
    |> list_aliases(
      current_user,
      ...
    )
  end

  @doc """
  Lists aliases for a given user.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.list_aliases(user)
      [%Alias{}, ...]

  """
  def list_aliases(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :object_profile]

    [subjects: uid!(user), object_types: opts[:type]]
    |> debug()
    |> query(opts)
    |> where([object: object], object.id not in ^e(opts, :exclude_ids, []))
    |> debug()
    |> Social.many(opts[:paginate], opts)
    # follow pointers
    |> repo().maybe_preload([edge: [:object]], opts)
    |> debug()
  end

  @doc """
  Lists entities who aliased the current user.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.list_my_aliased(current_user)
      [%AliasedEntity{}, ...]

  """
  def list_my_aliased(current_user, opts \\ []),
    do:
      list_aliased(
        current_user,
        Keyword.put(to_options(opts), :current_user, current_user)
      )

  @doc """
  Lists entities who aliased a a given user.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.list_aliased(user)
      [%AliasedEntity{}, ...]

  """
  def list_aliased(user, opts \\ []) do
    opts = to_options(opts) ++ [skip_boundary_check: true, preload: :subject]

    [objects: uid(user), subject_types: opts[:type]]
    |> query(opts)
    |> where([subject: subject], subject.id not in ^e(opts, :exclude_ids, []))
    # |> maybe_with_user_profile_only(opts)
    |> Social.many(opts[:paginate], opts)
  end

  # defp maybe_with_user_profile_only(q, true),
  #   do: where(q, [user_profile: p], not is_nil(p.id))

  # defp maybe_with_user_profile_only(q, _), do: q

  # def changeset(:create, subject, target, boundary) do
  #   Changesets.cast(%Alias{}, %{}, [])
  #   |> Edges.put_assoc(subject, target, :add, boundary)
  # end

  defp create(%{} = user, target, opts) do
    insert(user, target, opts)
  end

  defp insert(subject, object, options) do
    Edges.changeset_base(Alias, subject, object, options)
    |> Edges.insert(subject, object)
  end

  ### ActivityPub integration

  @doc """
  Initiates a move operation for migrating a local user to another instance.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.move(subject, target)
      {:ok, :moved}

  """
  def move(subject, %ActivityPub.Actor{} = target) do
    target = repo().maybe_preload(target, :edge)

    with {:ok, actor} <-
           ActivityPub.Actor.get_cached(pointer: subject)
           |> debug("from actor") do
      ActivityPub.move(actor, target)
    else
      e ->
        error(e, "Could not federate")
        raise "Could not federate the move"
    end
  end

  def move(subject, %Alias{} = target) do
    target = repo().maybe_preload(target, :edge)

    move(
      subject || e(target, :edge, :subject, nil) || e(target, :edge, :subject_id, nil),
      e(target.edge, :object, nil) || e(target, :edge, :object_id, nil)
    )
  end

  def move(subject, target) do
    with {:ok, target} <-
           ActivityPub.Actor.get_cached(pointer: target)
           |> debug("aliased actor") do
      move(subject, target)
    end
  end

  @doc """
  Checks if a local user is also known as the target.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.also_known_as?("http://example.com/user", target)
      true

      iex> Bonfire.Social.Graph.Aliases.also_known_as?(%User{}, target)
      true

  """
  def also_known_as?(local_ap_id, target) when is_binary(local_ap_id) do
    with {:ok, %{data: data}} <-
           ActivityPub.Actor.get_cached(pointer: target)
           |> debug("aliased actor") do
      ActivityPub.Actor.also_known_as?(
        local_ap_id
        |> debug("local_ap_id"),
        data
      )
    end
  end

  def also_known_as?(%{} = character, target),
    do: also_known_as?(Bonfire.Common.URIs.canonical_url(character), target)

  @doc """
  Publishes an ActivityPub activity for a move operation.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.ap_publish_activity(subject, :move, target)

  """
  def ap_publish_activity(subject, :move, target) do
    move(subject, target)
  end

  def ap_publish_activity(subject, _, _target) do
    ActivityPub.Actor.get_cached(pointer: subject)
    ~> ActivityPub.Actor.invalidate_cache()

    # TODO: send an Update activity to target
  end

  @doc """
  Processes an incoming ActivityPub Move activity.

  ## Examples

      iex> Bonfire.Social.Graph.Aliases.ap_receive_activity(subject, activity, origin_object)
      {:ok, :moved}

  """
  def ap_receive_activity(
        subject,
        %{data: %{"type" => "Move", "target" => target} = data} = _activity,
        origin_object
      ) do
    info(data, "Follows: attempt to process an incoming Move activity...")

    debug(origin_object, "origin")
    debug(target, "target")

    with {:ok, origin_character} <-
           Bonfire.Federate.ActivityPub.AdapterUtils.get_or_fetch_character_by_ap_id(
             origin_object
           ),
         true <- id(origin_character) == id(subject),
         [:ok] <- move_following(origin_character, target) |> Enum.uniq() do
      {:ok, :moved}
    else
      result when is_list(result) ->
        if result
           |> debug("move_result")
           |> Enum.uniq() == [:error],
           do: {:error, :move_failed},
           else: {:ok, :moved_partially}

      false ->
        error("Invalid move activity, subject and object don't match")
    end
  end

  defp move_following(origin, target) do
    Follows.all_subjects_by_object(origin)
    # |> repo().maybe_preload(character: :peered)
    # |> Enum.filter(&Social.is_local?/1)
    |> Enum.map(fn third_party_subject ->
      with {:ok, _} <- Follows.follow(third_party_subject, target),
           {:ok, _} <- Follows.unfollow(third_party_subject, origin) do
        :ok
      else
        e ->
          error(e)
          :error
      end
    end)
  end
end
