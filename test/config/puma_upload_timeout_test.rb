require "test_helper"
require "puma"
require "puma/configuration"
require "puma/server"
require_relative "../support/outbound_stubs"

class PumaUploadTimeoutTest < ActiveSupport::TestCase
  using OutboundStubs

  test "a stalled body is closed and its tempfile released within ten seconds" do
    config = Puma::Configuration.new(config_files: [ Rails.root.join("config/puma.rb").to_s ])
    config.load
    config.clamp
    server = Puma::Server.new(->(*) { flunk "an incomplete upload must not reach the app" }, nil, config.options)
    reader, writer = UNIXSocket.pair
    client = Puma::Client.new(reader, {})
    client.supported_http_methods = :any
    writer.write("POST / HTTP/1.1\r\nHost: example.org\r\nContent-Length: 1000000\r\n\r\npartial body")
    assert_not client.try_to_finish
    tempfile = client.tempfile
    assert_not tempfile.closed?
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.stub(:clock_gettime, ->(*) { clock }) do
      client.set_timeout(server.first_data_timeout)
      clock += 11
      server.reactor_wakeup(client)
    end
    assert reader.closed?, "a stalled body must time out before the old thirty-second default"
    assert tempfile.closed?, "timing out must release the partial body storage"
    assert_operator server.persistent_timeout, :<=, 10
  ensure
    client&.close
    writer&.close
  end
end
