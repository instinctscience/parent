defmodule Parent.State do
  @moduledoc false

  alias Parent.RestartCounter

  @opaque t :: %{
            opts: Parent.opts(),
            id_to_pid: %{Parent.child_id() => pid},
            children: %{pid => child()},
            startup_index: non_neg_integer,
            restart_counter: RestartCounter.t(),
            registry?: boolean,
            deps: %{pid => [pid]},
            shutdown_groups: %{Parent.shutdown_group() => [pid]}
          }

  @type child :: %{
          spec: Parent.child_spec(),
          pid: pid,
          timer_ref: reference() | nil,
          startup_index: non_neg_integer(),
          restart_counter: RestartCounter.t(),
          meta: Parent.child_meta()
        }

  @spec initialize(Parent.opts()) :: t
  def initialize(opts) do
    opts = Keyword.merge([max_restarts: 3, max_seconds: 5, registry?: false], opts)

    %{
      opts: opts,
      id_to_pid: %{},
      children: %{},
      startup_index: 0,
      restart_counter: RestartCounter.new(opts[:max_restarts], opts[:max_seconds]),
      registry?: Keyword.fetch!(opts, :registry?),
      deps: %{},
      shutdown_groups: %{}
    }
  end

  @spec reinitialize(t) :: t
  def reinitialize(state), do: %{initialize(state.opts) | startup_index: state.startup_index}

  @spec registry?(t) :: boolean
  def registry?(state), do: state.registry?

  @spec register_child(t, pid, Parent.child_spec(), reference | nil) :: t
  def register_child(state, pid, spec, timer_ref) do
    false = Map.has_key?(state.children, pid)

    child = %{
      spec: spec,
      pid: pid,
      timer_ref: timer_ref,
      startup_index: state.startup_index,
      restart_counter: RestartCounter.new(spec.max_restarts, spec.max_seconds),
      meta: spec.meta
    }

    state =
      if is_nil(spec.id),
        do: state,
        else: Map.update!(state, :id_to_pid, &Map.put(&1, spec.id, pid))

    state
    |> Map.update!(:children, &Map.put(&1, pid, child))
    |> Map.update!(:startup_index, &(&1 + 1))
    |> update_bindings(pid, spec)
    |> update_shutdown_groups(pid, spec)
  end

  @spec register_child(t, pid, child, reference | nil) :: t
  def reregister_child(state, child, pid, timer_ref) do
    false = Map.has_key?(state.children, pid)

    child = %{child | pid: pid, timer_ref: timer_ref, meta: child.spec.meta}

    state =
      if is_nil(child.spec.id),
        do: state,
        else: Map.update!(state, :id_to_pid, &Map.put(&1, child.spec.id, pid))

    state
    |> Map.update!(:children, &Map.put(&1, child.pid, child))
    |> update_bindings(pid, child.spec)
    |> update_shutdown_groups(pid, child.spec)
  end

  @spec children(t) :: [child()]
  def children(state), do: Map.values(state.children)

  @spec children_in_shutdown_group(t, Parent.shutdown_group()) :: [child]
  def children_in_shutdown_group(state, shutdown_group),
    do: Map.get(state.shutdown_groups, shutdown_group, []) |> Enum.map(&child!(state, &1))

  @spec record_restart(t) :: {:ok, t} | :error
  def record_restart(state) do
    with {:ok, counter} <- RestartCounter.record_restart(state.restart_counter),
         do: {:ok, %{state | restart_counter: counter}}
  end

  @spec pop_child_with_bound_siblings(t, Parent.child_ref()) :: {:ok, [child], t} | :error
  def pop_child_with_bound_siblings(state, child_ref) do
    with {:ok, child} <- child(state, child_ref) do
      {children, state} = pop_child_and_bound_children(state, child.pid)
      {:ok, children, state}
    end
  end

  @spec num_children(t) :: non_neg_integer
  def num_children(state), do: Enum.count(state.children)

  @spec child(t, Parent.child_ref()) :: {:ok, child} | :error
  def child(_state, nil), do: :error
  def child(state, pid) when is_pid(pid), do: Map.fetch(state.children, pid)
  def child(state, id), do: with({:ok, pid} <- child_pid(state, id), do: child(state, pid))

  @spec child?(t, Parent.child_ref()) :: boolean()
  def child?(state, child_ref), do: match?({:ok, _child}, child(state, child_ref))

  @spec child!(t, Parent.child_ref()) :: child
  def child!(state, child_ref) do
    {:ok, child} = child(state, child_ref)
    child
  end

  @spec child_id(t, pid) :: {:ok, Parent.child_id()} | :error
  def child_id(state, pid) do
    with {:ok, child} <- child(state, pid), do: {:ok, child.spec.id}
  end

  @spec child_pid(t, Parent.child_id()) :: {:ok, pid} | :error
  def child_pid(state, id), do: Map.fetch(state.id_to_pid, id)

  @spec child_meta(t, Parent.child_ref()) :: {:ok, Parent.child_meta()} | :error
  def child_meta(state, child_ref) do
    with {:ok, child} <- child(state, child_ref), do: {:ok, child.meta}
  end

  @spec update_child_meta(t, Parent.child_ref(), (Parent.child_meta() -> Parent.child_meta())) ::
          {:ok, Parent.child_meta(), t} | :error
  def update_child_meta(state, child_ref, updater) do
    with {:ok, child, state} <- update(state, child_ref, &update_in(&1.meta, updater)),
         do: {:ok, child.meta, state}
  end

  defp update_bindings(state, pid, child_spec) do
    Enum.reduce(
      child_spec.binds_to,
      state,
      fn child_ref, state ->
        bound = child!(state, child_ref)
        %{state | deps: Map.update(state.deps, bound.pid, [pid], &[pid | &1])}
      end
    )
  end

  defp update_shutdown_groups(state, _pid, %{shutdown_group: nil}), do: state

  defp update_shutdown_groups(state, pid, spec) do
    Map.update!(
      state,
      :shutdown_groups,
      &Map.update(&1, spec.shutdown_group, [pid], fn pids -> [pid | pids] end)
    )
  end

  defp update(state, child_ref, updater) do
    with {:ok, child} <- child(state, child_ref),
         updated_child = updater.(child),
         updated_children = Map.put(state.children, child.pid, updated_child),
         do: {:ok, updated_child, %{state | children: updated_children}}
  end

  defp pop_child_and_bound_children(state, child_ref) do
    child = child!(state, child_ref)
    children = child_with_deps(state, child)
    state = Enum.reduce(children, state, &remove_child(&2, &1))
    {children, state}
  end

  defp child_with_deps(state, child),
    do: Map.values(child_with_deps(state, child, %{}))

  defp child_with_deps(state, child, collected) do
    # collect all siblings in the same shutdown group
    group_children =
      if is_nil(child.spec.shutdown_group),
        do: [child],
        else: children_in_shutdown_group(state, child.spec.shutdown_group)

    collected = Enum.reduce(group_children, collected, &Map.put_new(&2, &1.pid, &1))

    for child <- group_children,
        dep <- Map.get(state.deps, child.pid, []),
        bound_sibling = child!(state, dep),
        sibling_pid = bound_sibling.pid,
        not Map.has_key?(collected, bound_sibling.pid),
        reduce: collected do
      %{^sibling_pid => _} = collected ->
        collected

      collected ->
        child_with_deps(
          state,
          bound_sibling,
          Map.put(collected, bound_sibling.pid, bound_sibling)
        )
    end
  end

  defp remove_child(state, child) do
    group = child.spec.shutdown_group

    state
    |> Map.update!(:id_to_pid, &Map.delete(&1, child.spec.id))
    |> Map.update!(:children, &Map.delete(&1, child.pid))
    |> Map.update!(:deps, &Map.delete(&1, child.pid))
    |> Map.update!(:shutdown_groups, fn
      groups ->
        with %{^group => children} <- groups do
          case children -- [child.pid] do
            [] -> Map.delete(groups, group)
            children -> %{groups | group => children}
          end
        end
    end)
  end
end
