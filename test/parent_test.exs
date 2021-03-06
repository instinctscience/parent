defmodule ParentTest do
  use ExUnit.Case, async: true

  defmodule TestChild do
    use GenServer
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts || [])

    @impl GenServer
    def init(opts) do
      if Keyword.get(opts, :trap_exit?), do: Process.flag(:trap_exit, true)
      Keyword.get(opts, :init, &{:ok, &1}).(opts)
    end

    @impl GenServer
    def terminate(_reason, opts) do
      if Keyword.get(opts, :block_terminate?), do: Process.sleep(:infinity)
    end
  end

  describe "initialize/0" do
    test "traps exists" do
      Process.flag(:trap_exit, false)
      Parent.initialize()
      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    end

    test "raises if called multiple times" do
      Parent.initialize()
      assert_raise RuntimeError, "Parent state is already initialized", &Parent.initialize/0
    end
  end

  describe "start_child" do
    test "returns the pid of the started process on success" do
      Parent.initialize()
      parent = self()
      assert {:ok, child} = Parent.start_child({Task, fn -> send(parent, self()) end})
      assert_receive ^child
    end

    test "accepts module as a single argument" do
      Parent.initialize()
      assert {:ok, _child} = Parent.start_child(TestChild)
    end

    test "accepts a child specification map" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: {TestChild, :start_link, []}})
    end

    test "accepts a zero arity function in the :start key of the child spec" do
      Parent.initialize()

      assert {:ok, _child} =
               Parent.start_child(%{id: :child, start: fn -> TestChild.start_link() end})
    end

    test "fails if the process fails to start" do
      Parent.initialize()
      assert Parent.start_child({TestChild, init: fn _ -> :ignore end}) == :ignore

      assert Parent.start_child({TestChild, init: fn _ -> {:stop, :some_reason} end}) ==
               {:error, :some_reason}
    end

    test "fails if the id is already taken" do
      Parent.initialize()
      assert {:ok, child} = start_child(id: :child)
      assert start_child(id: :child) == {:error, {:already_started, child}}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &start_child/0
    end
  end

  describe "shutdown_child/1" do
    test "stops the child synchronously, handling the exit message" do
      Parent.initialize()

      {:ok, child} = Parent.start_child(Supervisor.child_spec(TestChild, id: :child))

      Parent.shutdown_child(:child)
      refute Process.alive?(child)
      refute_receive {:EXIT, ^child, _reason}
    end

    test "forcefully terminates the child if shutdown is `:brutal_kill`" do
      Parent.initialize()

      {:ok, child} =
        Parent.start_child(
          Supervisor.child_spec({TestChild, block_terminate?: true, trap_exit?: true},
            id: :child,
            shutdown: :brutal_kill
          )
        )

      Process.monitor(child)
      Parent.shutdown_child(:child)
      assert_receive {:DOWN, _mref, :process, ^child, :killed}
    end

    test "forcefully terminates a child if it doesn't stop in the given time" do
      Parent.initialize()

      {:ok, child} =
        Parent.start_child(
          Supervisor.child_spec({TestChild, block_terminate?: true, trap_exit?: true},
            id: :child,
            shutdown: 10
          )
        )

      Process.monitor(child)
      Parent.shutdown_child(:child)
      assert_receive {:DOWN, _mref, :process, ^child, :killed}
    end

    test "fails if an unknown child is given" do
      Parent.initialize()

      assert_raise RuntimeError, "trying to terminate an unknown child", fn ->
        Parent.shutdown_child(:child)
      end
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.shutdown_child(1) end
    end
  end

  describe "shutdown_all/1" do
    test "terminates all children in the opposite startup order" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      Process.monitor(child1)

      child2 = start_child!(id: :child2)
      Process.monitor(child2)

      Parent.shutdown_all()
      refute_receive {:EXIT, _pid, _reason}

      assert_receive {:DOWN, _mref, :process, pid1, _reason}
      assert_receive {:DOWN, _mref, :process, pid2, _reason}

      assert [pid1, pid2] == [child2, child1]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.shutdown_all/0
    end
  end

  describe "await_child_termination/1" do
    test "waits for the child to stop" do
      Parent.initialize()

      child = start_child!(id: :child, meta: :meta)

      Task.start_link(fn ->
        Process.sleep(50)
        GenServer.stop(child)
      end)

      assert Parent.await_child_termination(:child, 1000) == {child, :meta, :normal}
      refute Process.alive?(child)
    end

    test "returns timeout if the child didn't stop" do
      Parent.initialize()
      child = start_child!(id: :child, meta: :meta)
      assert Parent.await_child_termination(:child, 0) == :timeout
      assert Process.alive?(child)
    end

    test "raises if unknown child is given" do
      Parent.initialize()

      assert_raise RuntimeError, "unknown child", fn ->
        Parent.await_child_termination(:child, 1000)
      end
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.await_child_termination(:foo, :infinity)
      end
    end
  end

  describe "children/0" do
    test "returns child processes" do
      Parent.initialize()
      assert Parent.children() == []

      child1 = start_child!(id: :child1, meta: :meta1)
      assert Parent.children() == [{:child1, child1, :meta1}]

      child2 = start_child!(id: :child2, meta: :meta2)
      assert Parent.children() == [{:child1, child1, :meta1}, {:child2, child2, :meta2}]

      Parent.shutdown_child(:child1)
      assert Parent.children() == [{:child2, child2, :meta2}]
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.children/0
    end
  end

  describe "num_children/0" do
    test "returns the number of child processes" do
      Parent.initialize()
      assert Parent.num_children() == 0

      start_child!(id: :child1)
      assert Parent.num_children() == 1

      start_child!()
      assert Parent.num_children() == 2

      Parent.shutdown_child(:child1)
      assert Parent.num_children() == 1
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", &Parent.num_children/0
    end
  end

  describe "child?/0" do
    test "returns true for known children, false otherwise" do
      Parent.initialize()

      refute Parent.child?(:child1)
      refute Parent.child?(:child2)

      start_child!(id: :child1)
      start_child!(id: :child2)

      assert Parent.child?(:child1)
      assert Parent.child?(:child2)

      Parent.shutdown_child(:child1)
      refute Parent.child?(:child1)
      assert Parent.child?(:child2)
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child?(:foo) end
    end
  end

  describe "child_pid/1" do
    test "returns the pid of the given child, error otherwise" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.child_pid(:child1) == {:ok, child1}
      assert Parent.child_pid(:child2) == {:ok, child2}
      assert Parent.child_pid(:unknown_child) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_pid(:child1) == :error
      assert Parent.child_pid(:child2) == {:ok, child2}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_pid(:foo) end
    end
  end

  describe "child_id/1" do
    test "returns the id of the given child, error otherwise" do
      Parent.initialize()

      child1 = start_child!(id: :child1)
      child2 = start_child!(id: :child2)

      assert Parent.child_id(child1) == {:ok, :child1}
      assert Parent.child_id(child2) == {:ok, :child2}
      assert Parent.child_id(self()) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_id(child1) == :error
      assert Parent.child_id(child2) == {:ok, :child2}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_id(self()) end
    end
  end

  describe "child_meta/1" do
    test "returns the meta of the given child, error otherwise" do
      Parent.initialize()

      start_child!(id: :child1, meta: :meta1)
      start_child!(id: :child2, meta: :meta2)

      assert Parent.child_meta(:child1) == {:ok, :meta1}
      assert Parent.child_meta(:child2) == {:ok, :meta2}
      assert Parent.child_meta(:unknown_child) == :error

      Parent.shutdown_child(:child1)
      assert Parent.child_meta(:child1) == :error
      assert Parent.child_meta(:child2) == {:ok, :meta2}
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn -> Parent.child_meta(:child) end
    end
  end

  describe "update_child_meta/2" do
    test "updates meta of the known child, fails otherwise" do
      Parent.initialize()

      start_child!(id: :child1, meta: 1)
      start_child!(id: :child2, meta: 2)

      Parent.update_child_meta(:child2, &(&1 + 1))

      assert Parent.child_meta(:child1) == {:ok, 1}
      assert Parent.child_meta(:child2) == {:ok, 3}

      Parent.shutdown_child(:child1)
      assert Parent.update_child_meta(:child1, & &1) == :error
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.update_child_meta(:child, & &1)
      end
    end
  end

  describe "handle_message/1" do
    test "handles child termination" do
      Parent.initialize()
      child = start_child!(id: :child, meta: :meta)
      GenServer.stop(child)
      assert_receive {:EXIT, ^child, _reason} = message

      assert Parent.handle_message(message) == {:EXIT, child, :child, :meta, :normal}

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
    end

    test "handles child timeout by stopping the child" do
      Parent.initialize()
      child = start_child!(id: :child, meta: :meta, timeout: 0)

      assert_receive {Parent, :child_timeout, ^child} = message

      assert Parent.handle_message(message) == {:EXIT, child, :child, :meta, :timeout}

      assert Parent.num_children() == 0
      assert Parent.children() == []
      assert Parent.child_id(child) == :error
      assert Parent.child_pid(:child) == :error
    end

    test "handles supervisor calls" do
      Parent.initialize()
      parent = self()
      child = start_child!(id: :child)

      task =
        Task.async(fn ->
          assert :supervisor.which_children(parent) == [{:child, child, :worker, [TestChild]}]

          assert :supervisor.count_children(parent) ==
                   [active: 1, specs: 1, supervisors: 0, workers: 1]
        end)

      assert_receive message
      assert Parent.handle_message(message) == :ignore

      assert_receive message
      assert Parent.handle_message(message) == :ignore

      Task.await(task)
    end

    test "ignores unknown messages" do
      Parent.initialize()
      assert is_nil(Parent.handle_message({:EXIT, self(), :normal}))
      assert is_nil(Parent.handle_message(:unknown_message))
    end

    test "fails if the parent is not initialized" do
      assert_raise RuntimeError, "Parent is not initialized", fn ->
        Parent.handle_message(:foo)
      end
    end
  end

  defp start_child(overrides \\ []) do
    %{
      id: :erlang.unique_integer([:positive, :monotonic]),
      start: {TestChild, :start_link, []}
    }
    |> Map.merge(Map.new(overrides))
    |> Parent.start_child()
  end

  defp start_child!(overrides \\ []) do
    {:ok, pid} = start_child(overrides)
    pid
  end
end
