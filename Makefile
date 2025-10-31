SHELL       := /bin/bash
.SHELLFLAGS += -e -u -o pipefail

export REPOSITORY_ROOT := $(CURDIR)
export IMAGE_NAME      ?= mailserver-testing:ci
export NAME            ?= $(IMAGE_NAME)

MAKEFLAGS              += --no-print-directory
BATS_FLAGS             ?= --timing
BATS_PARALLEL_JOBS     ?= 2

.PHONY: ALWAYS_RUN

# -----------------------------------------------
# --- Generic Targets ---------------------------
# -----------------------------------------------

all: lint build generate-accounts tests clean

build: ALWAYS_RUN
	@ docker build --tag $(IMAGE_NAME) .

generate-accounts: ALWAYS_RUN
	@ cp test/config/templates/postfix-accounts.cf test/config/postfix-accounts.cf
	@ cp test/config/templates/dovecot-masters.cf test/config/dovecot-masters.cf

# `docker ps`:  Remove any lingering test containers
# `.gitignore`: Remove `test/duplicate_configs` and files copied via `make generate-accounts`
clean: ALWAYS_RUN
	-@ while read -r LINE; do CONTAINERS+=("$${LINE}"); done < <(docker ps -qaf name='^(dms-test|mail)_.*') ; \
		for CONTAINER in "$${CONTAINERS[@]}"; do docker rm -f "$${CONTAINER}"; done
	-@ while read -r LINE; do [[ $${LINE} =~ test/.+ ]] && FILES+=("/mnt$${LINE#test}"); done < .gitignore ; \
		docker run --rm -v "$(REPOSITORY_ROOT)/test/:/mnt" alpine ash -c "rm -rf $${FILES[@]}"

run-local-instance: ALWAYS_RUN
	bash -c 'sleep 8 ; ./setup.sh email add postmaster@example.test 123' &
	docker run --rm --interactive --tty --name dms-test_example \
		--env OVERRIDE_HOSTNAME=mail.example.test \
		--env POSTFIX_INET_PROTOCOLS=ipv4 \
		--env DOVECOT_INET_PROTOCOLS=ipv4 \
		--env ENABLE_CLAMAV=0 \
		--env ENABLE_AMAVIS=0 \
		--env ENABLE_RSPAMD=0 \
		--env ENABLE_OPENDKIM=0 \
		--env ENABLE_OPENDMARC=0 \
		--env ENABLE_POLICYD_SPF=0 \
		--env ENABLE_SPAMASSASSIN=0 \
		--env LOG_LEVEL=trace \
		$(IMAGE_NAME)

# -----------------------------------------------
# --- Tests  ------------------------------------
# -----------------------------------------------

tests: ALWAYS_RUN
# See https://github.com/docker-mailserver/docker-mailserver/pull/2857#issuecomment-1312724303
# on why `generate-accounts` is run before each set (TODO/FIXME)
	@ for DIR in tests/{serial,parallel/set{1,2,3}} ; do $(MAKE) generate-accounts "$${DIR}" ; done

tests/serial: ALWAYS_RUN
	@ shopt -s globstar ; ./test/bats/bin/bats $(BATS_FLAGS) test/$@/*.bats

tests/parallel/set%: ALWAYS_RUN
	@ shopt -s globstar ; $(REPOSITORY_ROOT)/test/bats/bin/bats $(BATS_FLAGS) \
		--no-parallelize-within-files \
		--jobs $(BATS_PARALLEL_JOBS) \
		test/$@/**/*.bats

test/%: ALWAYS_RUN
	@ shopt -s globstar nullglob ; ./test/bats/bin/bats $(BATS_FLAGS) test/tests/**/{$*,}.bats

# -----------------------------------------------
# --- Lints -------------------------------------
# -----------------------------------------------

lint: ALWAYS_RUN eclint hadolint bashcheck shellcheck

hadolint: ALWAYS_RUN
	@ ./test/linting/lint.sh hadolint

bashcheck: ALWAYS_RUN
	@ ./test/linting/lint.sh bashcheck

shellcheck: ALWAYS_RUN
	@ ./test/linting/lint.sh shellcheck

eclint: ALWAYS_RUN
	@ ./test/linting/lint.sh eclint
