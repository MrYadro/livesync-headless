.PHONY: bootstrap install update status verify test test-e2e-local pull-once readonly-on readonly-off import-uri check-uri

bootstrap:
	@bash scripts/bootstrap.sh $(ARGS)

install:
	@bash scripts/install.sh $(ARGS)

update:
	@bash scripts/update.sh $(ARGS)

status:
	@systemctl --user status livesync-cli --no-pager || true
	@journalctl --user -u livesync-cli -n 50 --no-pager || true

verify:
	@bash scripts/verify.sh $(ARGS)

test:
	@bash tests/run-all.sh

test-e2e-local:
	@bash scripts/test-e2e-local.sh

pull-once:
	@bash scripts/pull-once.sh $(ARGS)

readonly-on:
	@bash scripts/couchdb-readonly.sh on

readonly-off:
	@bash scripts/couchdb-readonly.sh off

import-uri:
	@bash scripts/import-uri.sh $(URI)

check-uri:
	@bash scripts/check-uri.sh $(URI)
