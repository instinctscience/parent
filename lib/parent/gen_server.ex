defmodule Parent.GenServer do
  @moduledoc """
  A GenServer extension which simplifies parenting of child processes.

  This behaviour helps implementing a GenServer which also needs to directly
  start child processes and handle their termination.

  ## Starting the process

  The usage is similar to GenServer. You need to use the module and start the
  process:

  ```
  def MyParentProcess do
    use Parent.GenServer

    def start_link(arg) do
      Parent.start_link(__MODULE__, arg, options \\\\ [])
    end
  end
  ```

  The expression `use Parent.GenServer` will also inject `use GenServer` into
  your code. Your parent process is a GenServer, and this behaviour doesn't try
  to hide it. Except when starting the process, you work with the parent exactly
  as you work with any GenServer, using the same functions, and writing the same
  callbacks:

  ```
  def MyParentProcess do
    use Parent.GenServer

    def do_something(pid, arg), do: GenServer.call(pid, {:do_something, arg})

    ...

    @impl GenServer
    def init(arg), do: {:ok, initial_state(arg)}

    @impl GenServer
    def handle_call({:do_something, arg}, _from, state),
      do: {:reply, response(state, arg), next_state(state, arg)}
  end
  ```

  Compared to plain GenServer, there are following differences:

  - A Parent.GenServer traps exits by default.
  - The generated `child_spec/1` has the `:shutdown` configured to `:infinity`.
  - The generated `child_spec/1` specifies the `:type` configured to `:supervisor`

  ## Starting child processes

  To start a child process, you can invoke `Parent.start_child/1` in the parent process:

  ```
  def handle_call(...) do
    Parent.start_child(child_spec)
    ...
  end
  ```

  The function takes a child spec map which is similar to Supervisor child
  specs. The map has the following keys:

    - `:id` (required) - a term uniquely identifying the child
    - `:start` (required) - an MFA, or a zero arity lambda invoked to start the child
    - `:meta` (optional) - a term associated with the started child, defaults to `nil`
    - `:shutdown` (optional) - same as with `Supervisor`, defaults to 5000
    - `:timeout` (optional) - timeout after which the child is killed by the parent,
      see the timeout section below, defaults to `:infinity`

  The function described with `:start` needs to start a linked process and return
  the result as `{:ok, pid}`. For example:

  ```
  Parent.start_child(%{
    id: :hello_world,
    start: {Task, :start_link, [fn -> IO.puts "Hello, World!" end]}
  })
  ```

  You can also pass a zero-arity lambda for `:start`:

  ```
  Parent.start_child(%{
    id: :hello_world,
    start: fn -> Task.start_link(fn -> IO.puts "Hello, World!" end) end
  })
  ```

  Finally, a child spec can also be a module, or a `{module, arg}` function.
  This works similarly to supervisor specs, invoking `module.child_spec/1`
  is which must provide the final child specification.

  ## Handling child termination

  When a child process terminates, `handle_child_terminated/5` will be invoked.
  The default implementation is injected into the module, but you can of course
  override it:

  ```
  @impl Parent.GenServer
  def handle_child_terminated(id, child_meta, pid, reason, state) do
    ...
    {:noreply, state}
  end
  ```

  The return value of `handle_child_terminated` is the same as for `handle_info`.

  ## Timeout

  If a positive integer is provided via the `:timeout` option, the parent will
  terminate the child if it doesn't stop within the given time. In this case,
  `handle_child_terminated/5` will be invoked with the exit reason `:timeout`.

  ## Working with child processes

  The `Parent` module provides various functions for managing child processes.
  For example, you can enumerate running children with `Parent.children/0`,
  fetch child meta with `Parent.child_meta/1`, or terminate a child process with
  `Parent.shutdown_child/1`.

  ## Termination

  The behaviour takes down the child processes during termination, to ensure that
  no child process is running after the parent has terminated. The children are
  terminated synchronously, one by one, in the reverse start order.

  The termination of the children is done after the `terminate/1` callback returns.
  Therefore in `terminate/1` the child processes are still running, and you can
  interact with them.

  ## Supervisor compliance

  A process powered by `Parent.GenServer` can handle supervisor specific
  messages, which means that for all intents and purposes, such process is
  treated as a supervisor. As a result, children of parent will be included in
  the hot code reload process.
  """
  use GenServer

  @type state :: term

  @doc "Invoked when a child has terminated."
  @callback handle_child_terminated(
              Parent.child_id(),
              Parent.child_meta(),
              pid,
              reason :: term,
              state
            ) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate}
              | {:stop, reason :: term, new_state}
            when new_state: state

  @doc "Starts the parent process."
  @spec start_link(module, arg :: term, GenServer.options()) :: GenServer.on_start()
  def start_link(module, arg, options \\ []) do
    GenServer.start_link(__MODULE__, {module, arg}, options)
  end

  @deprecated "Use Parent.start_child/1 instead"
  defdelegate start_child(child_spec), to: Parent

  @deprecated "Use Parent.shutdown_child/1 instead"
  defdelegate shutdown_child(child_id), to: Parent

  @deprecated "Use Parent.shutdown_all/1 instead"
  defdelegate shutdown_all(reason \\ :shutdown), to: Parent

  @deprecated "Use Parent.children/0 instead"
  defdelegate children(), to: Parent

  @deprecated "Use Parent.num_children/0 instead"
  defdelegate num_children(), to: Parent

  @deprecated "Use Parent.child_id/1 instead"
  defdelegate child_id(pid), to: Parent

  @deprecated "Use Parent.child_pid/1 instead"
  defdelegate child_pid(id), to: Parent

  @deprecated "Use Parent.child_meta/1 instead"
  defdelegate child_meta(id), to: Parent

  @deprecated "Use Parent.update_child_meta/2 instead"
  defdelegate update_child_meta(id, updater), to: Parent

  @deprecated "Use Parent.await_child_termination/2 instead"
  defdelegate await_child_termination(id, timeout), to: Parent

  @deprecated "Use Parent.child?/1 instead"
  defdelegate child?(id), to: Parent

  @impl GenServer
  def init({callback, arg}) do
    # needed to simulate a supervisor
    Process.put(:"$initial_call", {:supervisor, callback, 1})

    Process.put({__MODULE__, :callback}, callback)
    Parent.initialize()
    invoke_callback(:init, [arg])
  end

  @impl GenServer
  def handle_info(message, state) do
    case Parent.handle_message(message) do
      {:EXIT, pid, id, meta, reason} ->
        invoke_callback(:handle_child_terminated, [id, meta, pid, reason, state])

      :ignore ->
        {:noreply, state}

      nil ->
        invoke_callback(:handle_info, [message, state])
    end
  end

  @impl GenServer
  def handle_call(:which_children, _from, state),
    do: {:reply, Parent.supervisor_which_children(), state}

  def handle_call(:count_children, _from, state),
    do: {:reply, Parent.supervisor_count_children(), state}

  def handle_call(message, from, state), do: invoke_callback(:handle_call, [message, from, state])

  @impl GenServer
  def handle_cast(message, state), do: invoke_callback(:handle_cast, [message, state])

  @impl GenServer
  # Needed to support `:supervisor.get_callback_module`
  def format_status(:normal, [_pdict, state]) do
    [
      data: [{~c"State", state}],
      supervisor: [{~c"Callback", Process.get({__MODULE__, :callback})}]
    ]
  end

  def format_status(:terminate, pdict_and_state),
    do: invoke_callback(:format_status, [:terminate, pdict_and_state])

  @impl GenServer
  def code_change(old_vsn, state, extra),
    do: invoke_callback(:code_change, [old_vsn, state, extra])

  @impl GenServer
  def terminate(reason, state) do
    invoke_callback(:terminate, [reason, state])
  after
    Parent.shutdown_all(reason)
  end

  unless Version.compare(System.version(), "1.7.0") == :lt do
    @impl GenServer
    def handle_continue(continue, state), do: invoke_callback(:handle_continue, [continue, state])
  end

  defp invoke_callback(fun, arg), do: apply(Process.get({__MODULE__, :callback}), fun, arg)

  @doc false
  def child_spec(_arg) do
    raise("#{__MODULE__} can't be used in a child spec.")
  end

  @doc false
  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts, behaviour: __MODULE__] do
      use GenServer, opts
      @behaviour behaviour

      @doc """
      Returns a specification to start this module under a supervisor.
      See `Supervisor`.
      """
      def child_spec(arg) do
        default = %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [arg]},
          shutdown: :infinity,
          type: :supervisor
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end

      @impl behaviour
      def handle_child_terminated(_id, _meta, _pid, _reason, state), do: {:noreply, state}

      defoverridable handle_child_terminated: 5, child_spec: 1
    end
  end
end
