load "${REPOSITORY_ROOT}/test/helper/common"

BATS_TEST_NAME_PREFIX='[Scripts] (helper functions) '
SOURCE_BASE_PATH="${REPOSITORY_ROOT:?Expected REPOSITORY_ROOT to be set}/target/scripts/helpers"

@test '(network.sh) _sanitize_ipv4_to_subnet_cidr' {
  # shellcheck source=../../../../../target/scripts/helpers/network.sh
  source "${SOURCE_BASE_PATH}/network.sh"

  run _sanitize_ipv4_to_subnet_cidr '255.255.255.255/0'
  assert_output '0.0.0.0/0'

  run _sanitize_ipv4_to_subnet_cidr '192.168.255.14/20'
  assert_output '192.168.240.0/20'

  run _sanitize_ipv4_to_subnet_cidr '192.168.255.14/32'
  assert_output '192.168.255.14/32'
}

@test '(utils.sh) _env_var_expect_zero_or_one' {
  # shellcheck source=../../../../../target/scripts/helpers/log.sh
  source "${SOURCE_BASE_PATH}/log.sh"
  # shellcheck source=../../../../../target/scripts/helpers/utils.sh
  source "${SOURCE_BASE_PATH}/utils.sh"

  ZERO=0
  ONE=1
  TWO=2

  run _env_var_expect_zero_or_one ZERO
  assert_success

  run _env_var_expect_zero_or_one ONE
  assert_success

  run _env_var_expect_zero_or_one TWO
  assert_failure
  assert_output --partial "The value of 'TWO' (= '2') is not 0 or 1, but was expected to be"

  run _env_var_expect_zero_or_one UNSET
  assert_failure
  assert_output --partial "'UNSET' is not set, but was expected to be"

  run _env_var_expect_zero_or_one
  assert_failure
  assert_output --partial "ENV var name must be provided to _env_var_expect_zero_or_one"
}

@test '(utils.sh) _env_var_expect_integer' {
  # shellcheck source=../../../../../target/scripts/helpers/log.sh
  source "${SOURCE_BASE_PATH}/log.sh"
  # shellcheck source=../../../../../target/scripts/helpers/utils.sh
  source "${SOURCE_BASE_PATH}/utils.sh"

  INTEGER=1234
  NEGATIVE=-${INTEGER}
  NaN=not_an_integer

  run _env_var_expect_integer INTEGER
  assert_success

  run _env_var_expect_integer NEGATIVE
  assert_success

  run _env_var_expect_integer NaN
  assert_failure
  assert_output --partial "The value of 'NaN' is not an integer ('not_an_integer'), but was expected to be"

  run _env_var_expect_integer
  assert_failure
  assert_output --partial "ENV var name must be provided to _env_var_expect_integer"
}

@test '(utils.sh) _convert_crlf_to_lf_if_necessary' {
  # shellcheck source=../../../../../target/scripts/helpers/log.sh
  source "${SOURCE_BASE_PATH}/log.sh"
  # shellcheck source=../../../../../target/scripts/helpers/utils.sh
  source "${SOURCE_BASE_PATH}/utils.sh"

  # Create a temporary file in the BATS test-case folder:
  local TMP_DMS_CONFIG=$(mktemp -p "${BATS_TEST_TMPDIR}" -t 'dms_XXX.cf')
  # A file with mixed line-endings including CRLF:
  echo -en 'line one\nline two\r\n' > "${TMP_DMS_CONFIG}"

  # Confirm CRLF detected:
  run file "${TMP_DMS_CONFIG}"
  assert_output --partial 'CRLF'

  # Helper method detects and fixes:
  _convert_crlf_to_lf_if_necessary "${TMP_DMS_CONFIG}"
  run file "${TMP_DMS_CONFIG}"
  refute_output --partial 'CRLF'
}

@test '(utils.sh) _append_final_newline_if_missing' {
  # shellcheck source=../../../../../target/scripts/helpers/log.sh
  source "${SOURCE_BASE_PATH}/log.sh"
  # shellcheck source=../../../../../target/scripts/helpers/utils.sh
  source "${SOURCE_BASE_PATH}/utils.sh"

  # Create a temporary file in the BATS test-case folder:
  local TMP_DMS_CONFIG=$(mktemp -p "${BATS_TEST_TMPDIR}" -t 'dms_XXX.cf')
  # A file missing a final newline:
  echo -en 'line one\nline two' > "${TMP_DMS_CONFIG}"

  # Confirm missing newline:
  run bash -c "tail -c 1 '${TMP_DMS_CONFIG}' | wc -l"
  assert_output '0'

  # Helper method detects and fixes:
  _append_final_newline_if_missing "${TMP_DMS_CONFIG}"
  run bash -c "tail -c 1 '${TMP_DMS_CONFIG}' | wc -l"
  assert_output '1'
}
