# The application starts with `start_fetchers: false` and `start_tui: false`
# (see config/test.exs), so tests get the processing layer and nothing else:
# no 30s polls racing assertions, no fight over the terminal.
ExUnit.start()
