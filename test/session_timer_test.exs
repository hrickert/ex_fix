defmodule ExFix.SessionTimerTest do
  use ExUnit.Case

  alias ExFix.SessionTimer

  test "SessionTimer test" do
    timer = SessionTimer.setup_timer("timer1", 100)
    send(timer, :msg)
    assert_receive {:timeout, "timer1"}, 200
  end
end