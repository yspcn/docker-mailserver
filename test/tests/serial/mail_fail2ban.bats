load "${REPOSITORY_ROOT}/test/test_helper/common"

function setup_file() {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG=$(duplicate_config_for_container .)
  docker run --rm -d --name mail_fail2ban \
    -v "${PRIVATE_CONFIG}":/tmp/docker-mailserver \
    -v "$(pwd)/test/test-files":/tmp/docker-mailserver-test:ro \
    -e ENABLE_FAIL2BAN=1 \
    -e POSTSCREEN_ACTION=ignore \
    --cap-add=NET_ADMIN \
    --hostname mail.my-domain.com \
    --tty \
    --ulimit "nofile=$(ulimit -Sn):$(ulimit -Hn)" \
    "${NAME}"

  # Create a container which will send wrong authentications and should get banned
  docker run --name fail-auth-mailer \
    -e MAIL_FAIL2BAN_IP="$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' mail_fail2ban)" \
    -v "$(pwd)/test/test-files":/tmp/docker-mailserver-test \
    -d "${NAME}" \
    tail -f /var/log/faillog

  wait_for_finished_setup_in_container mail_fail2ban
}

function teardown_file() {
  docker rm -f mail_fail2ban fail-auth-mailer
}

#
# processes
#

@test "checking process: fail2ban (fail2ban server enabled)" {
  run docker exec mail_fail2ban /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/bin/python3 /usr/bin/fail2ban-server'"
  assert_success
}

#
# fail2ban
#

@test "checking fail2ban: localhost is not banned because ignored" {
  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client status postfix-sasl | grep 'IP list:.*127.0.0.1'"
  assert_failure
  run docker exec mail_fail2ban /bin/sh -c "grep 'ignoreip = 127.0.0.1/8' /etc/fail2ban/jail.conf"
  assert_success
}

@test "checking fail2ban: fail2ban-fail2ban.cf overrides" {
  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client get loglevel | grep DEBUG"
  assert_success
}

@test "checking fail2ban: fail2ban-jail.cf overrides" {
  FILTERS=(dovecot postfix postfix-sasl)

  for FILTER in "${FILTERS[@]}"; do
    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client get ${FILTER} bantime"
    assert_output 1234

    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client get ${FILTER} findtime"
    assert_output 321

    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client get ${FILTER} maxretry"
    assert_output 2

    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client -d | grep -F \"['set', 'dovecot', 'addaction', 'nftables-multiport']\""
    assert_output "['set', 'dovecot', 'addaction', 'nftables-multiport']"

    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client -d | grep -F \"['set', 'postfix', 'addaction', 'nftables-multiport']\""
    assert_output "['set', 'postfix', 'addaction', 'nftables-multiport']"

    run docker exec mail_fail2ban /bin/sh -c "fail2ban-client -d | grep -F \"['set', 'postfix-sasl', 'addaction', 'nftables-multiport']\""
    assert_output "['set', 'postfix-sasl', 'addaction', 'nftables-multiport']"
  done
}

@test "checking fail2ban: ban ip on multiple failed login" {
  # can't pipe the file as usual due to postscreen. (respecting postscreen_greet_wait time and talking in turn):
  # shellcheck disable=SC1004
  for _ in {1,2}
  do
    docker exec fail-auth-mailer /bin/bash -c \
    'exec 3<>/dev/tcp/${MAIL_FAIL2BAN_IP}/25 && \
    while IFS= read -r cmd; do \
      head -1 <&3; \
      [[ ${cmd} == "EHLO"* ]] && sleep 6; \
      echo ${cmd} >&3; \
    done < "/tmp/docker-mailserver-test/auth/smtp-auth-login-wrong.txt"'
  done

  sleep 5

  FAIL_AUTH_MAILER_IP=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' fail-auth-mailer)
  # Checking that FAIL_AUTH_MAILER_IP is banned in mail_fail2ban
  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client status postfix-sasl | grep '${FAIL_AUTH_MAILER_IP}'"
  assert_success

  # Checking that FAIL_AUTH_MAILER_IP is banned by nftables
  run docker exec mail_fail2ban /bin/sh -c "nft list set inet f2b-table addr-set-postfix-sasl"
  assert_output --partial "elements = { ${FAIL_AUTH_MAILER_IP} }"
}

@test "checking fail2ban: unban ip works" {
  FAIL_AUTH_MAILER_IP=$(docker inspect --format '{{ .NetworkSettings.IPAddress }}' fail-auth-mailer)
  docker exec mail_fail2ban fail2ban-client set postfix-sasl unbanip "${FAIL_AUTH_MAILER_IP}"

  sleep 5

  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client status postfix-sasl | grep 'IP list:.*${FAIL_AUTH_MAILER_IP}'"
  assert_failure

  # Checking that FAIL_AUTH_MAILER_IP is unbanned by nftables
  run docker exec mail_fail2ban /bin/sh -c "nft list set inet f2b-table addr-set-postfix-sasl"
  refute_output --partial "${FAIL_AUTH_MAILER_IP}"
}

@test "checking fail2ban ban" {
  # Ban single IP address
  run docker exec mail_fail2ban fail2ban ban 192.0.66.7
  assert_success
  assert_output "Banned custom IP: 1"

  run docker exec mail_fail2ban fail2ban
  assert_success
  assert_output --regexp "Banned in custom:.*192\.0\.66\.7"

  run docker exec mail_fail2ban nft list set inet f2b-table addr-set-custom
  assert_success
  assert_output --partial "elements = { 192.0.66.7 }"

  run docker exec mail_fail2ban fail2ban unban 192.0.66.7
  assert_success
  assert_output --partial "Unbanned IP from custom: 1"

  run docker exec mail_fail2ban nft list set inet f2b-table addr-set-custom
  refute_output --partial "192.0.66.7"

  # Ban IP network
  run docker exec mail_fail2ban fail2ban ban 192.0.66.0/24
  assert_success
  assert_output "Banned custom IP: 1"

  run docker exec mail_fail2ban fail2ban
  assert_success
  assert_output --regexp "Banned in custom:.*192\.0\.66\.0/24"

  run docker exec mail_fail2ban nft list set inet f2b-table addr-set-custom
  assert_success
  assert_output --partial "elements = { 192.0.66.0/24 }"

  run docker exec mail_fail2ban fail2ban unban 192.0.66.0/24
  assert_success
  assert_output --partial "Unbanned IP from custom: 1"

  run docker exec mail_fail2ban nft list set inet f2b-table addr-set-custom
  refute_output --partial "192.0.66.0/24"
}

@test "checking FAIL2BAN_BLOCKTYPE is really set to drop" {
  run docker exec mail_fail2ban bash -c 'nft list table inet f2b-table'
  assert_success
  assert_output --partial 'tcp dport { 110, 143, 465, 587, 993, 995, 4190 } ip saddr @addr-set-dovecot drop'
  assert_output --partial 'tcp dport { 25, 110, 143, 465, 587, 993, 995 } ip saddr @addr-set-postfix-sasl drop'
  assert_output --partial 'tcp dport { 25, 110, 143, 465, 587, 993, 995, 4190 } ip saddr @addr-set-custom drop'
}

@test "checking setup.sh: setup.sh fail2ban" {
  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client set dovecot banip 192.0.66.4"
  run docker exec mail_fail2ban /bin/sh -c "fail2ban-client set dovecot banip 192.0.66.5"

  sleep 10

  run ./setup.sh -c mail_fail2ban fail2ban
  assert_output --regexp '^Banned in dovecot:.*192\.0\.66\.4'
  assert_output --regexp '^Banned in dovecot:.*192\.0\.66\.5'

  run ./setup.sh -c mail_fail2ban fail2ban unban 192.0.66.4
  assert_output --partial "Unbanned IP from dovecot: 1"

  run ./setup.sh -c mail_fail2ban fail2ban
  assert_output --regexp "^Banned in dovecot:.*192\.0\.66\.5"

  run ./setup.sh -c mail_fail2ban fail2ban unban 192.0.66.5
  assert_output --partial "Unbanned IP from dovecot: 1"

  run ./setup.sh -c mail_fail2ban fail2ban unban
  assert_output --partial "You need to specify an IP address: Run"
}

#
# supervisor
#

@test "checking restart of process: fail2ban (fail2ban server enabled)" {
  run docker exec mail_fail2ban /bin/bash -c "pkill fail2ban && sleep 10 && ps aux --forest | grep -v grep | grep '/usr/bin/python3 /usr/bin/fail2ban-server'"
  assert_success
}
