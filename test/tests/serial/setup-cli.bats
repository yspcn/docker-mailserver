load "${REPOSITORY_ROOT}/test/test_helper/common"

# Globals referenced from `test_helper/common`:
# TEST_NAME (should match the filename, minus the bats extension)

# This is a bare minimal container setup.
# All test-cases run sequentially against the same container instance,
# no state is reset between test-cases.
function setup_file() {
  # Initializes common default vars to prepare a DMS container with:
  init_with_defaults

  # Creates and starts the container with additional ENV needed:
  # `LOG_LEVEL=debug` required for using `wait_until_change_detection_event_completes()`
  # shellcheck disable=SC2034
  local CONTAINER_ARGS_ENV_CUSTOM=(
    --env LOG_LEVEL='debug'
  )

  common_container_setup 'CONTAINER_ARGS_ENV_CUSTOM'
}

function teardown_file() {
  docker rm -f "${TEST_NAME}"
}

@test "checking setup.sh: show usage when no arguments provided" {
  run ./setup.sh
  assert_success
  assert_output --partial "This is the main administration script that you use for all your interactions with"
}

@test "checking setup.sh: exit with error when wrong arguments provided" {
  run ./setup.sh lol troll
  assert_failure
  assert_line --index 0 --partial "The command 'lol troll' is invalid."
}

# Create a new account for subsequent tests to depend upon
@test "checking setup.sh: setup.sh email add and login" {
  local MAIL_ACCOUNT='user@example.com'
  local MAIL_PASS='test_password'
  local DATABASE_ACCOUNTS="${TEST_TMP_CONFIG}/postfix-accounts.cf"

  # Create an account
  run ./setup.sh -c "${TEST_NAME}" email add "${MAIL_ACCOUNT}" "${MAIL_PASS}"
  assert_success

  # Verify account was added to `postfix-accounts.cf`:
  local ACCOUNT
  ACCOUNT=$(grep "${MAIL_ACCOUNT}" "${DATABASE_ACCOUNTS}" | awk -F '|' '{print $1}')
  assert_equal "${ACCOUNT}" "${MAIL_ACCOUNT}"

  # Wait for change detection event to complete (create maildir and add account to Dovecot UserDB+PassDB)
  wait_until_account_maildir_exists "${TEST_NAME}" "${MAIL_ACCOUNT}"
  # Dovecot is stopped briefly at the end of processing a change event (should change to reload in future),
  # to more accurately use `wait_for_service` ensure you wait until `changedetector` is done.
  wait_until_change_detection_event_completes "${TEST_NAME}"
  wait_for_service "${TEST_NAME}" dovecot

  # Verify account authentication is successful:
  local RESPONSE
  RESPONSE=$(docker exec "${TEST_NAME}" doveadm auth test "${MAIL_ACCOUNT}" "${MAIL_PASS}" | grep 'passdb')
  assert_equal "${RESPONSE}" "passdb: ${MAIL_ACCOUNT} auth succeeded"
}

@test "checking setup.sh: setup.sh email list" {
  run ./setup.sh -c "${TEST_NAME}" email list
  assert_success
}

# Update an existing account
@test "checking setup.sh: setup.sh email update" {
  local MAIL_ACCOUNT='user@example.com'
  local MAIL_PASS='test_password'
  local DATABASE_ACCOUNTS="${TEST_TMP_CONFIG}/postfix-accounts.cf"

  # `postfix-accounts.cf` should already have an account with a non-empty hashed password:
  local MAIL_PASS_HASH
  MAIL_PASS_HASH=$(grep "${MAIL_ACCOUNT}" "${DATABASE_ACCOUNTS}" | awk -F '|' '{print $2}')
  assert_not_equal "${MAIL_PASS_HASH}" ""

  # Update the password should be successful:
  local NEW_PASS='new_password'
  run ./setup.sh -c "${TEST_NAME}" email update "${MAIL_ACCOUNT}" "${NEW_PASS}"
  refute_output --partial 'Password must not be empty'
  assert_success

  # NOTE: this was put in place for the next test `setup.sh email del` to properly work.
  wait_until_change_detection_event_completes "${TEST_NAME}"

  # `postfix-accounts.cf` should have an updated password hash stored:
  local NEW_PASS_HASH
  NEW_PASS_HASH=$(grep "${MAIL_ACCOUNT}" "${DATABASE_ACCOUNTS}" | awk -F '|' '{print $2}')
  assert_not_equal "${NEW_PASS_HASH}" ""
  assert_not_equal "${NEW_PASS_HASH}" "${MAIL_PASS_HASH}"

  # Verify Dovecot derives NEW_PASS_HASH from NEW_PASS:
  run docker exec "${TEST_NAME}" doveadm pw -t "${NEW_PASS_HASH}" -p "${NEW_PASS}"
  refute_output 'Fatal: reverse password verification check failed: Password mismatch'
  assert_output "${NEW_PASS_HASH} (verified)"
}

# Delete an existing account
# WARNING: While this feature works via the internal `setup` command, the external `setup.sh`
# has no support to mount a volume to `/var/mail` (only via `-c` to use a running container),
# thus the `-y` option to delete the account maildir has no effect nor informs the user.
# https://github.com/docker-mailserver/docker-mailserver/issues/949
@test "checking setup.sh: setup.sh email del" {
  local MAIL_ACCOUNT='user@example.com'
  local MAIL_PASS='test_password'

  # Account deletion is successful:
  run ./setup.sh -c "${TEST_NAME}" email del -y "${MAIL_ACCOUNT}"
  assert_success

  # NOTE: Sometimes the directory still exists, possibly from change detection
  # of the previous test (`email udpate`) triggering. Therefore, the function
  # `wait_until_change_detection_event_completes was added to the
  # `setup.sh email update` test.
  repeat_in_container_until_success_or_timeout 60 "${TEST_NAME}" bash -c '[[ ! -d /var/mail/example.com/user ]]'

  # Account is not present in `postfix-accounts.cf`:
  run grep "${MAIL_ACCOUNT}" "${TEST_TMP_CONFIG}/postfix-accounts.cf"
  assert_failure

  # NOTE: Actual account will still exist briefly in Dovecot UserDB+PassDB
  # until `changedetector` service is triggered by `postfix-accounts.cf`
  # which will rebuild Dovecots accounts from scratch.
}

@test "checking setup.sh: setup.sh email restrict" {
  run ./setup.sh -c "${TEST_NAME}" email restrict
  assert_failure
  run ./setup.sh -c "${TEST_NAME}" email restrict add
  assert_failure
  ./setup.sh -c "${TEST_NAME}" email restrict add send lorem@impsum.org
  run ./setup.sh -c "${TEST_NAME}" email restrict list send
  assert_output --regexp "^lorem@impsum.org.*REJECT"

  run ./setup.sh -c "${TEST_NAME}" email restrict del send lorem@impsum.org
  assert_success
  run ./setup.sh -c "${TEST_NAME}" email restrict list send
  assert_output --partial "Everyone is allowed"

  ./setup.sh -c "${TEST_NAME}" email restrict add receive rec_lorem@impsum.org
  run ./setup.sh -c "${TEST_NAME}" email restrict list receive
  assert_output --regexp "^rec_lorem@impsum.org.*REJECT"
  run ./setup.sh -c "${TEST_NAME}" email restrict del receive rec_lorem@impsum.org
  assert_success
}

# alias
@test "checking setup.sh: setup.sh alias list" {
  run ./setup.sh -c "${TEST_NAME}" alias list
  assert_success
  assert_output --partial "alias1@localhost.localdomain user1@localhost.localdomain"
  assert_output --partial "@localdomain2.com user1@localhost.localdomain"
}

@test "checking setup.sh: setup.sh alias add" {
  ./setup.sh -c "${TEST_NAME}" alias add alias@example.com target1@forward.com
  ./setup.sh -c "${TEST_NAME}" alias add alias@example.com target2@forward.com
  ./setup.sh -c "${TEST_NAME}" alias add alias2@example.org target3@forward.com
  sleep 5
  run grep "alias@example.com target1@forward.com,target2@forward.com" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_success
}

@test "checking setup.sh: setup.sh alias del" {
  ./setup.sh -c "${TEST_NAME}" alias del alias@example.com target1@forward.com
  run grep "target1@forward.com" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_failure

  run grep "target2@forward.com" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_output "alias@example.com target2@forward.com"

  ./setup.sh -c "${TEST_NAME}" alias del alias@example.org target2@forward.com
  run grep "alias@example.org" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_failure

  run grep "alias2@example.org" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_success

  ./setup.sh -c "${TEST_NAME}" alias del alias2@example.org target3@forward.com
  run grep "alias2@example.org" "${TEST_TMP_CONFIG}/postfix-virtual.cf"
  assert_failure
}

# quota
@test "checking setup.sh: setup.sh setquota" {
  ./setup.sh -c "${TEST_NAME}" email add quota_user@example.com test_password
  ./setup.sh -c "${TEST_NAME}" email add quota_user2@example.com test_password

  run ./setup.sh -c "${TEST_NAME}" quota set quota_user@example.com 12M
  assert_success
  run ./setup.sh -c "${TEST_NAME}" quota set 51M quota_user@example.com
  assert_failure
  run ./setup.sh -c "${TEST_NAME}" quota set unknown@domain.com 150M
  assert_failure

  run ./setup.sh -c "${TEST_NAME}" quota set quota_user2 51M
  assert_failure

  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/dovecot-quotas.cf | grep -E '^quota_user@example.com\:12M\$' | wc -l | grep 1"
  assert_success

  run ./setup.sh -c "${TEST_NAME}" quota set quota_user@example.com 26M
  assert_success
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/dovecot-quotas.cf | grep -E '^quota_user@example.com\:26M\$' | wc -l | grep 1"
  assert_success

  run grep "quota_user2@example.com" "${TEST_TMP_CONFIG}/dovecot-quotas.cf"
  assert_failure
}

# `quota_user@example.com` created in previous `setquota` test
@test "checking setup.sh: setup.sh delquota" {
  run ./setup.sh -c "${TEST_NAME}" quota set quota_user@example.com 12M
  assert_success
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/dovecot-quotas.cf | grep -E '^quota_user@example.com\:12M\$' | wc -l | grep 1"
  assert_success

  run ./setup.sh -c "${TEST_NAME}" quota del unknown@domain.com
  assert_failure
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/dovecot-quotas.cf | grep -E '^quota_user@example.com\:12M\$' | wc -l | grep 1"
  assert_success

  run ./setup.sh -c "${TEST_NAME}" quota del quota_user@example.com
  assert_success
  run grep "quota_user@example.com" "${TEST_TMP_CONFIG}/dovecot-quotas.cf"
  assert_failure
}

@test "checking setup.sh: setup.sh config dkim help correctly displayed" {
  run ./setup.sh -c "${TEST_NAME}" config dkim help
  assert_success
  assert_line --index 3 --partial "    open-dkim - configure DomainKeys Identified Mail (DKIM)"
}

# debug

@test "checking setup.sh: setup.sh debug fetchmail" {
  run ./setup.sh -c "${TEST_NAME}" debug fetchmail
  assert_failure
  assert_output --partial "fetchmail: normal termination, status 11"
}

@test "checking setup.sh: setup.sh debug login ls" {
  run ./setup.sh -c "${TEST_NAME}" debug login ls
  assert_success
}

@test "checking setup.sh: setup.sh relay add-domain" {
  ./setup.sh -c "${TEST_NAME}" relay add-domain example1.org smtp.relay1.com 2525
  ./setup.sh -c "${TEST_NAME}" relay add-domain example2.org smtp.relay2.com
  ./setup.sh -c "${TEST_NAME}" relay add-domain example3.org smtp.relay3.com 2525
  ./setup.sh -c "${TEST_NAME}" relay add-domain example3.org smtp.relay.com 587

  # check adding
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-relaymap.cf | grep -e '^@example1.org\s\+\[smtp.relay1.com\]:2525' | wc -l | grep 1"
  assert_success
  # test default port
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-relaymap.cf | grep -e '^@example2.org\s\+\[smtp.relay2.com\]:25' | wc -l | grep 1"
  assert_success
  # test modifying
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-relaymap.cf | grep -e '^@example3.org\s\+\[smtp.relay.com\]:587' | wc -l | grep 1"
  assert_success
}

@test "checking setup.sh: setup.sh relay add-auth" {
  ./setup.sh -c "${TEST_NAME}" relay add-auth example.org smtp_user smtp_pass
  ./setup.sh -c "${TEST_NAME}" relay add-auth example2.org smtp_user2 smtp_pass2
  ./setup.sh -c "${TEST_NAME}" relay add-auth example2.org smtp_user2 smtp_pass_new

  # test adding
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-sasl-password.cf | grep -e '^@example.org\s\+smtp_user:smtp_pass' | wc -l | grep 1"
  assert_success
  # test updating
  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-sasl-password.cf | grep -e '^@example2.org\s\+smtp_user2:smtp_pass_new' | wc -l | grep 1"
  assert_success
}

@test "checking setup.sh: setup.sh relay exclude-domain" {
  ./setup.sh -c "${TEST_NAME}" relay exclude-domain example.org

  run /bin/sh -c "cat ${TEST_TMP_CONFIG}/postfix-relaymap.cf | grep -e '^@example.org\s*$' | wc -l | grep 1"
  assert_success
}
