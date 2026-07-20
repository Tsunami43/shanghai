# Distributed tests start peer nodes and need a running epmd, so they are opt-in:
#
#     mix test --include distributed
ExUnit.start(exclude: [:distributed])
