import Config

# :info, not :warning. This runs as a service, and journalctl showing
# nothing at all on a healthy boot is indistinguishable from a service
# that never started. The startup lines — migrations applied, SSH port,
# platform modes — are what someone checks after a deploy.
config :logger, level: :info
