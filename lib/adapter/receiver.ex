defmodule Bonfire.Federate.ActivityPub.Receiver do
  require Logger
  alias Bonfire.Search.Indexer
  alias Bonfire.Common.Utils

  # the following constants are derived from config, so please make any changes/additions there

  # @actor_modules Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :actor_modules]) # TODO
  @activity_modules Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :activity_modules])
  @object_modules Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :object_modules])

  @actor_types Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :actor_types])
  @activity_types Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :activity_types])
  @object_types Bonfire.Common.Config.get!([Bonfire.Federate.ActivityPub.Adapter, :object_types])

  @doc """
  load the activity data
  """
  def receive_activity(activity_id) when is_binary(activity_id) do
    activity = ActivityPub.Object.get_by_id(activity_id)

    receive_activity(activity)
  end

  def receive_activity(activity) when not is_map_key(activity, :data) do
    # for cases when the worker gives us an activity
    receive_activity(%{data: activity})
  end

  # load the object data
  def receive_activity(
        %{
          data: %{
            "object" => object_id
          }
        } = activity
      ) do
    object = Bonfire.Federate.ActivityPub.Utils.get_object_or_actor_by_ap_id!(object_id)

    #IO.inspect(activity: activity)
    #IO.inspect(object: object)

    receive_activity(activity, object)
  end

  def receive_activity(activity, object) when not is_map_key(object, :data) do
    # for cases when the object comes to us embeded in the activity
    receive_activity(activity, %{data: object})
  end

  # Activity: Update + Object: actor/character
  def receive_activity(
        %{data: %{"type" => "Update"}} = _activity,
        %{data: %{"type" => object_type, "id" => ap_id}} = _object
      )
      when object_type in @actor_types do
    log("AP Match#0 - update actor")

    with {:ok, actor} <- ActivityPub.Actor.get_cached_by_ap_id(ap_id),
         {:ok, actor} <- Bonfire.Federate.ActivityPub.Adapter.update_remote_actor(actor) do
      Indexer.maybe_index_object(actor)
      :ok
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        %{data: %{"type" => object_type}} = object
      )
      when activity_type in @activity_types and object_type in @object_types do
    log(
      "AP Match#1 - by activity_type and object_type: #{activity_type} + #{object_type} = #{
        @activity_modules[activity_type]
      } or #{@object_modules[object_type]}"
    )

    if @activity_modules[activity_type] == @object_modules[object_type] do
      handle_activity_with(
        @activity_modules[activity_type],
        activity,
        object
      )
    else
      log(
        "AP Match#1.5 - mismatched activity_type and object_type, try first based on activity, otherwise on object"
      )

      with {:error, e1} <-
             handle_activity_with(
               @activity_modules[activity_type],
               activity,
               object
             ),
           {:error, e2} <-
             handle_activity_with(
               @object_modules[object_type],
               activity,
               object
             ) do
        {:error, e1 || e2}
      end
    end
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        %{data: %{"type" => object_type}} = object
      )
      when activity_type in @activity_types do
    log(
      "AP Match#2 - by activity_type: #{activity_type} + #{object_type} = #{
        @activity_modules[activity_type]
      }"
    )

    handle_activity_with(
      @activity_modules[activity_type],
      activity,
      object
    )
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        %{data: %{"type" => object_type}} = object
      )
      when object_type in @object_types do
    log(
      "AP Match#3 - by object_type: #{activity_type} + #{object_type} = #{
        @object_modules[object_type]
      }"
    )

    handle_activity_with(
      @object_modules[object_type],
      activity,
      object
    )
  end

  def receive_activity(
        %{
          data: %{
            "type" => activity_type
          }
        } = activity,
        object
      )
      when activity_type in @activity_types do
    log(
      "AP Match#4 - Only activity_type known: #{activity_type} = #{
        @activity_modules[activity_type]
      }"
    )

    handle_activity_with(
      @activity_modules[activity_type],
      activity,
      object
    )
  end

  def receive_activity(activity, object) do
    # TODO actually save this rather than discard
    error = "ActivityPub - ignored incoming activity - unhandled activity or object type"
    Logger.error("#{error}")
    log("activity: #{inspect(activity, pretty: true)}")
    log("object: #{inspect(object, pretty: true)}")
    {:error, error}
  end

  def handle_activity_with(module, activity, object) do
    Utils.maybe_apply(
      module,
      :ap_receive_activity,
      [activity, object],
      &error/2
    )
  end

  @deprecated "Define in host application context modules instead"
  def create_remote_character(actor, username) do
    uri = URI.parse(actor["id"])
    ap_base = uri.scheme <> "://" <> uri.host

    peer = Bonfire.Federate.ActivityPub.Peers.get_or_create(ap_base, uri.host)

    name =
      case actor["name"] do
        nil -> actor["preferredUsername"]
        "" -> actor["preferredUsername"]
        _ -> actor["name"]
      end

    icon_url = Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(actor["icon"])
    image_url = Bonfire.Federate.ActivityPub.Utils.maybe_fix_image_object(actor["image"])

    create_attrs = %{
      preferred_username: username,
      name: name,
      summary: actor["summary"],
      is_public: true,
      is_local: false,
      is_disabled: false,
      peer_id: peer.id,
      canonical_url: actor["id"]
    }

    {:ok, created_character, creator} =
      case actor["type"] do
        "Person" ->
          {:ok, created_character} = Bonfire.Me.Users.ActivityPub.create(create_attrs)
          {:ok, created_character, created_character}

        "Organization" ->
            {:ok, created_character} = Bonfire.Me.SharedUsers.create(create_attrs, :remote) # TODO
            {:ok, created_character, created_character}

        "Group" ->
          {:ok, creator} =
            Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_ap_id(actor["attributedTo"])

          {:ok, created_character} = Bonfire.Groups.create(creator, create_attrs, :remote) # FIXME when we have Groups
          {:ok, created_character, creator}

        _ ->
          {:ok, creator} =
            Bonfire.Federate.ActivityPub.Utils.get_raw_character_by_ap_id(actor["attributedTo"])

          {:ok, created_character} =
            Bonfire.Me.Characters.create(creator, create_attrs, :remote) # TODO as fallback

          {:ok, created_character, creator}
      end

    icon_id = Bonfire.Federate.ActivityPub.Utils.maybe_create_icon_object(icon_url, creator)
    image_id = Bonfire.Federate.ActivityPub.Utils.maybe_create_image_object(image_url, creator)

    {:ok, updated_actor} =
      case created_character do
        %Bonfire.Data.Identity.User{} ->
          Bonfire.Me.Users.ActivityPub.update(created_character, %{icon_id: icon_id, image_id: image_id})

        # %CommonsPub.Communities.Community{} ->
        #   CommonsPub.Communities.update(%Bonfire.Data.Identity.User{}, created_character, %{
        #     icon_id: icon_id,
        #     image_id: image_id
        #   })

        # %CommonsPub.Collections.Collection{} ->
        #   CommonsPub.Collections.update(%Bonfire.Data.Identity.User{}, created_character, %{
        #     icon_id: icon_id,
        #     image_id: image_id
        #   })
      end

    object = ActivityPub.Object.get_cached_by_ap_id(actor["id"])

    ActivityPub.Object.update(object, %{pointer_id: created_character.id})

    # Indexer.maybe_index_object(updated_actor) # this should be done in the context function being called

    {:ok, updated_actor}
  end

  def log(l) do
    if(Bonfire.Common.Config.get([:logging, :tests_output_ap])) do
      Logger.warn(l)
    end
  end

  def error(error, attrs) do
    Logger.error("ActivityPub - Unable to process incoming federated activity - #{error}")

    IO.inspect(attrs: attrs)

    {:error, error}
  end
end
