# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.
#
# Puma starts a configurable number of processes (workers) and each process
# serves each request in a thread from an internal thread pool.
#
# You can control the number of workers using ENV["WEB_CONCURRENCY"]. You
# should only set this value when you want to run 2 or more workers. The
# default is already 1.
#
# The ideal number of threads per worker depends both on how much time the
# application spends waiting for IO operations and on how much you wish to
# prioritize throughput over latency.
#
# As a rule of thumb, increasing the number of threads will increase how much
# traffic a given process can handle (throughput), but due to CRuby's
# Global VM Lock (GVL) it has diminishing returns and will degrade the
# response time (latency) of the application.
#
# The default is set to 3 threads as it's deemed a decent compromise between
# throughput and latency for the average Rails application.
#
# Any libraries that use a connection pool or another resource pool should
# be configured to provide at least as many connections as the number of
# threads. This includes Active Record's `pool` parameter in `database.yml`.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Mailroom's listeners. MAILROOM_PORT (default 3100) is the internal listener: owner UI, MCP and API.
# MAILROOM_PUBLIC_PORT is the public listener: the Postmark webhook and /up, nothing else
# (Mailroom::IngressGate decides by the listener a connection arrived on). Both bind loopback only.
# Production refuses to boot without the public one (config/initializers/preflight.rb).
# `rails server -b/-p` replaces these binds, which is why bin/mailroom-server starts Puma directly.
internal_port = ENV.fetch("MAILROOM_PORT", "3100")
public_port = ENV["MAILROOM_PUBLIC_PORT"].to_s.strip
if public_port.empty?
  # Development: one listener, the internal one.
  port ENV.fetch("PORT", internal_port)
else
  bind "tcp://127.0.0.1:#{internal_port}"
  bind "tcp://127.0.0.1:#{public_port}"
end

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
