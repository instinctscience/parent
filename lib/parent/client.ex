defmodule Parent.Client do
  @moduledoc """
  Functions for interacting with parent's children from other processes.

  All of these functions by default issue a call to the parent process. Therefore, they can't be
  used from inside the parent process. Use functions from the `Parent` module instead to interact
  with the children from within the process.

  Likewise these functions can't be invoked inside the child process during its initialization.
  Defer interacting with the parent to `c:GenServer.handle_continue/2`, or if you're using another
  behaviour which doesn't support such callback, send yourself a message to safely do the post-init
  interaction with the parent.

  If parent is configured with the `registry?: true` option, some query functions, such as
  `child_pid/2` will perform an ETS lookup instead of issuing a call, so the caveats above won't
  apply.
  """
  alias Parent.Registry

  @doc false
  def whereis_name({parent, child_id}) do
    case child_pid(parent, child_id) do
      {:ok, pid} -> pid
      :error -> :undefined
    end
  end

  @spec children(GenServer.server()) :: [Parent.child()]
  def children(parent) do
    case Registry.table(parent) do
      {:ok, table} -> Registry.children(table)
      :error -> call(parent, :children)
    end
  end

  @spec child_pid(GenServer.server(), Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(parent, child_id) do
    case Registry.table(parent) do
      {:ok, table} -> Registry.child_pid(table, child_id)
      :error -> call(parent, {:child_pid, child_id})
    end
  end

  @spec child_meta(GenServer.server(), Parent.child_id()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(parent, child_id) do
    case Registry.table(parent) do
      {:ok, table} -> Registry.child_meta(table, child_id)
      :error -> call(parent, {:child_meta, child_id})
    end
  end

  @spec start_child(GenServer.server(), Parent.start_spec()) :: Supervisor.on_start_child()
  def start_child(parent, child_spec), do: call(parent, {:start_child, child_spec}, :infinity)

  @spec shutdown_child(GenServer.server(), Parent.child_id()) ::
          {:ok, Parent.stopped_children()} | {:error, :unknown_child}
  def shutdown_child(parent, child_id), do: call(parent, {:shutdown_child, child_id}, :infinity)

  @spec restart_child(GenServer.server(), Parent.child_id()) ::
          {:ok, Parent.stopped_children()} | {:error, :unknown_child}
  def restart_child(parent, child_id), do: call(parent, {:restart_child, child_id}, :infinity)

  @spec shutdown_all(GenServer.server()) :: Parent.stopped_children()
  def shutdown_all(server), do: call(server, :shutdown_all, :infinity)

  @spec return_children(GenServer.server(), Parent.stopped_children()) ::
          {:ok, Parent.stopped_children()}
          | {:error, :unknown_child}
  def return_children(parent, stopped_children),
    do: call(parent, {:return_children, stopped_children}, :infinity)

  @spec update_child_meta(
          GenServer.server(),
          Parent.child_id(),
          (Parent.child_meta() -> Parent.child_meta())
        ) :: :ok | :error
  def update_child_meta(parent, child_id, updater),
    do: call(parent, {:update_child_meta, child_id, updater}, :infinity)

  @doc false
  def handle_request(:children), do: Parent.children()
  def handle_request({:child_pid, child_id}), do: Parent.child_pid(child_id)
  def handle_request({:child_meta, child_id}), do: Parent.child_meta(child_id)
  def handle_request({:start_child, child_spec}), do: Parent.start_child(child_spec)
  def handle_request(:shutdown_all), do: Parent.shutdown_all()

  def handle_request({:shutdown_child, child_id}) do
    if Parent.child?(child_id),
      do: {:ok, Parent.shutdown_child(child_id)},
      else: {:error, :unknown_child}
  end

  def handle_request({:restart_child, child_id}) do
    if Parent.child?(child_id),
      do: Parent.restart_child(child_id),
      else: {:error, :unknown_child}
  end

  def handle_request({:return_children, stopped_children}),
    do: Parent.return_children(stopped_children)

  def handle_request({:update_child_meta, child_id, updater}),
    do: Parent.update_child_meta(child_id, updater)

  defp call(server, request, timeout \\ 5000)
       when (is_integer(timeout) and timeout >= 0) or timeout == :infinity do
    request = {__MODULE__, request}

    case GenServer.whereis(server) do
      nil ->
        exit({:noproc, {__MODULE__, :call, [server, request, timeout]}})

      pid when pid == self() ->
        exit({:calling_self, {__MODULE__, :call, [server, request, timeout]}})

      pid ->
        try do
          :gen.call(pid, :"$parent_call", request, timeout)
        catch
          :exit, reason ->
            exit({reason, {__MODULE__, :call, [server, request, timeout]}})
        else
          {:ok, res} -> res
        end
    end
  end
end