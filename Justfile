tests: nvim_tests

nvim_tests:
	./tests/run.sh

# Run some Neovim test files, e.g. `just nvim_test tests/repl.lua`.
nvim_test +files:
	./tests/run.sh {{files}}
