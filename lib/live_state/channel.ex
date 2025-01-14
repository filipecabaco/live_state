defmodule LiveState.Channel do
  @moduledoc """
  To build a LiveState application, you'll first want to add a channel that implements this
  behaviour.
  """
  import Phoenix.Socket

  alias LiveState.Event

  @doc """
  Returns the initial application state. Called just after connection
  """
  @callback init(channel :: binary(), payload :: term(), socket :: Socket.t()) ::
              {:ok, state :: map()}
              | {:ok, state :: map(), Socket.t()}
              | {:error, reason :: any()}

  @doc """
  Called from join to authorize the connection. Return `{:ok, socket}` to authorize or
  `{:error, reason}` to deny. Default implementation returns `{:ok, socket}`
  """
  @callback authorize(channel :: binary(), payload :: term(), socket :: Socket.t()) ::
              {:ok, socket :: Socket.t()} | {:error, binary()}

  @doc """
  Receives an event an payload from the client and current state. Return a `:reply` tuple if
  you need to send events to the client, otherwise return `:noreply`. `:reply` tuples
  can contain a single `LiveState.Event` or a list of events as well as the new state.
  """
  @callback handle_event(event_name :: binary(), payload :: term(), state :: term()) ::
              {:reply, reply :: %LiveState.Event{} | list(%LiveState.Event{}), new_state :: any()}
              | {:noreply, new_state :: map()}

  @doc """
  Receive an event name, payload, the current state, and the socket. Use this callback
  if you need to receive the socket as well as the state. Return a `:reply` tuple if
  you need to send events to the client, otherwise return `:noreply`.  `:reply` tuples
  can contain a single `LiveState.Event` or a list of events, as well as the new state and
  the socket. `:noreply` tuples must contain the new state and and socket.
  """
  @callback handle_event(
              event_name :: binary(),
              payload :: term(),
              state :: term(),
              socket :: Socket.t()
            ) ::
              {:reply, reply :: %LiveState.Event{} | list(%LiveState.Event{}), new_state :: map(),
               Socket.t()}
              | {:noreply, new_state :: map(), Socket.t()}

  @optional_callbacks handle_event: 4, handle_event: 3

  @doc """
  The key on assigns to hold application state. Defaults to `:state`.
  """
  @callback state_key() :: atom()

  @doc """
  The key on assigns to hold application state version. Defaults to `:version`.
  """
  @callback state_version_key() :: atom()

  @doc """
  Receives pubsub message and current state. Returns new state
  """
  @callback handle_message(message :: term(), state :: term()) ::
              {:reply, reply :: %LiveState.Event{} | list(%LiveState.Event{}), new_state :: any()}
              | {:noreply, new_state :: term}

  defmacro __using__(opts) do
    quote do
      use unquote(Keyword.get(opts, :web_module)), :channel

      @dialyzer {:nowarn_function, handle_info: 2}
      @dialyzer {:nowarn_function, join: 3}
      @dialyzer {:nowarn_function, update_state: 2}

      @behaviour unquote(__MODULE__)
      @json_patch unquote(Keyword.get(opts, :json_patch))

      def join(channel, payload, socket) do
        case authorize(channel, payload, socket) do
          {:ok, socket} ->
            send(self(), {:after_join, channel, payload})
            {:ok, socket}

          {:error, reason} ->
            {:error, reason}
        end
      end

      def handle_info({:after_join, channel, payload}, socket) do
        case init(channel, payload, socket) do
          {:ok, state, socket} ->
            {:noreply, initialize_state(state, socket)}

          {:ok, state} ->
            {:noreply, initialize_state(state, socket)}

          {:error, error} ->
            {:error, error}
        end
      end

      defp initialize_state(state, socket) do
        push_state_change(socket, state, 0)
        socket |> assign(state_key(), state) |> assign(state_version_key(), 0)
      end

      def handle_info(message, %{assigns: assigns} = socket) do
        handle_message(message, Map.get(assigns, state_key())) |> maybe_handle_reply(socket)
      end

      def handle_in("lvs_evt:" <> event_name, payload, %{assigns: assigns} = socket) do
        if function_exported?(__MODULE__, :handle_event, 4) do
          apply(__MODULE__, :handle_event, [
            event_name,
            payload,
            Map.get(assigns, state_key()),
            socket
          ])
        else
          apply(__MODULE__, :handle_event, [event_name, payload, Map.get(assigns, state_key())])
        end
        |> maybe_handle_reply(socket)
      end

      def authorize(_channel, _payload, socket), do: {:ok, socket}

      def state_key, do: :state

      def state_version_key, do: :version

      def handle_message(_message, state), do: {:noreply, state}

      def handle_event(_message, _payload, state), do: {:noreply, state}

      defp update_state(%{assigns: assigns} = socket, new_state) do
        current_state = Map.get(assigns, state_key())
        new_state_version = Map.get(assigns, state_version_key()) + 1

        if @json_patch do
          push_json_patch(socket, current_state, new_state, new_state_version)
        else
          push_state_change(socket, new_state, new_state_version)
        end

        {:noreply,
         socket
         |> assign(state_key(), new_state)
         |> assign(state_version_key(), new_state_version)}
      end

      defp maybe_handle_reply({:noreply, new_state}, socket), do: update_state(socket, new_state)

      defp maybe_handle_reply({:noreply, new_state, new_socket}, socket),
        do: update_state(new_socket, new_state)

      defp maybe_handle_reply({:reply, event_or_events, new_state}, socket) do
        push_events(socket, event_or_events)
        update_state(socket, new_state)
      end

      defp maybe_handle_reply({:reply, event_or_events, new_state, new_socket}, socket) do
        push_events(new_socket, event_or_events)
        update_state(new_socket, new_state)
      end

      def push_events(socket, events) when is_list(events) do
        events |> Enum.map(&push_event(socket, &1))
      end

      def push_events(socket, event), do: push_event(socket, event)

      def push_event(socket, %Event{name: name, detail: detail}) do
        push(socket, name, detail)
      end

      defp push_state_change(socket, state, version) do
        payload = %{} |> Map.put(state_key(), state) |> Map.put(state_version_key(), version)
        push(socket, "state:change", payload)
      end

      defp push_json_patch(socket, current_state, new_state, version) do
        push(socket, "state:patch", %{
          patch: JSONDiff.diff(current_state, new_state),
          version: version
        })
      end

      defoverridable state_key: 0,
                     handle_message: 2,
                     handle_in: 3,
                     handle_info: 2,
                     handle_event: 3,
                     authorize: 3,
                     join: 3
    end
  end
end
