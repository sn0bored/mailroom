require "test_helper"
require_relative "../../config/listener_check"

class ListenerCheckTest < ActiveSupport::TestCase
  ENV_PORTS = { "MAILROOM_PORT" => "3100", "MAILROOM_PUBLIC_PORT" => "3101" }.freeze

  def problem(binds, env = ENV_PORTS) = Mailroom::ListenerCheck.problem(binds, env)

  test "the two loopback listeners pass" do
    assert_nil problem(%w[tcp://127.0.0.1:3100 tcp://127.0.0.1:3101])
    assert_nil problem(%w[tcp://127.0.0.1:3101 tcp://127.0.0.1:3100 tcp://[::1]:3100])
    assert_nil problem(%w[tcp://127.0.0.1:3100 tcp://127.0.0.1:3101], ENV_PORTS.except("MAILROOM_PORT"))
  end

  test "what `rails server -p`, PORT or Thruster leave behind is refused" do
    assert_match "nowhere else", problem(%w[tcp://0.0.0.0:3100])
    assert_match "nowhere else", problem(%w[tcp://127.0.0.1:3100])
    assert_match "nowhere else", problem(%w[tcp://[::]:3100 tcp://0.0.0.0:3101])
    assert_match "nowhere else", problem(%w[tcp://127.0.0.1:3100 tcp://127.0.0.1:3101 tcp://0.0.0.0:3000])
    assert_match "nowhere else", problem(%w[tcp://localhost:3100 tcp://localhost:3101])
    assert_match "nowhere else", problem(%w[tcp://127.0.0.1:3100 unix:///tmp/mailroom.sock])
    assert_match "not on nothing", problem([])
  end

  test "missing or shared ports are refused" do
    assert problem(%w[tcp://127.0.0.1:3100 tcp://127.0.0.1:3101], ENV_PORTS.except("MAILROOM_PUBLIC_PORT"))
    assert problem(%w[tcp://127.0.0.1:3100], ENV_PORTS.merge("MAILROOM_PUBLIC_PORT" => "3100"))
  end

  test "an opened socket is described as the bind it came from" do
    listener = TCPServer.new("127.0.0.1", 0)
    assert_equal "tcp://127.0.0.1:#{listener.local_address.ip_port}", Mailroom::ListenerCheck.bind_for(listener)
  ensure
    listener&.close
  end
end
