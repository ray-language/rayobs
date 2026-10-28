# rayobs — common tasks. `make` (or `make help`) lists them.

.DEFAULT_GOAL := help
.PHONY: help build test test-native fmt run interop bench clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-12s %s\n", $$1, $$2}'

build: ## The native binary, ./rayobs
	rm -f rayobs
	ray build --native --release -o rayobs src/main.ray

test: ## Tests on the VM
	ray test

test-native: ## The same tests as native binaries
	ray test --native

fmt: ## Format the sources
	ray fmt -w src/*.ray tests/*.ray

run: build ## Serve with ./rayobs.toml (copy rayobs.example.toml first)
	./rayobs serve

interop: build ## raystat shipped and scraped: its counter, its logs, a trace, up going to 0
	scripts/interop.sh

bench: build ## Durable log ingestion by clients and lines per request
	scripts/bench.sh

clean: ## Remove the binary
	rm -f rayobs
