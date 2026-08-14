# frozen_string_literal: true

require "minitest/autorun"
require "corvid/secret_reader"

class Corvid::SecretReaderBaseTest < Minitest::Test
  def test_fetch_raises_not_implemented
    assert_raises(NotImplementedError) { Corvid::SecretReader::Base.new.fetch("anything") }
  end
end

class Corvid::SecretReaderEnvTest < Minitest::Test
  ENV_KEY = "CORVID_TEST_SECRET_READER_ENV_VAR"

  def teardown
    ENV.delete(ENV_KEY)
  end

  def test_fetch_returns_env_var_value
    ENV[ENV_KEY] = "shh-its-a-secret"
    assert_equal "shh-its-a-secret", Corvid::SecretReader::Env.new.fetch(ENV_KEY)
  end

  def test_fetch_accepts_symbol_ref
    ENV[ENV_KEY] = "shh-its-a-secret"
    assert_equal "shh-its-a-secret", Corvid::SecretReader::Env.new.fetch(ENV_KEY.to_sym)
  end

  def test_fetch_raises_key_error_when_env_var_unset
    ENV.delete(ENV_KEY)
    error = assert_raises(KeyError) { Corvid::SecretReader::Env.new.fetch(ENV_KEY) }
    assert_match(/#{ENV_KEY}/, error.message)
  end
end
