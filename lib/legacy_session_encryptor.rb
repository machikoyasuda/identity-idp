# frozen_string_literal: true

class LegacySessionEncryptor
  CIPHERTEXT_HEADER = 'v2'
  def load(value)
    _v2, ciphertext = value.split(':')
    decrypted = outer_decrypt(ciphertext)

    session = JSON.parse(decrypted, quirks_mode: true).with_indifferent_access
    kms_decrypt_sensitive_paths!(session)

    session
  end

  def dump(value)
    value.deep_stringify_keys!

    kms_encrypt_pii!(value)
    kms_encrypt_sensitive_paths!(value, SessionEncryptor::SENSITIVE_PATHS)
    alert_or_raise_if_contains_sensitive_keys!(value)
    plain = JSON.generate(value, quirks_mode: true)
    alert_or_raise_if_contains_sensitive_value!(plain, value)
    CIPHERTEXT_HEADER + ':' + outer_encrypt(plain)
  end

  def kms_encrypt(text)
    Base64.encode64(Encryption::KmsClient.new.encrypt(text, 'context' => 'session-encryption'))
  end

  def kms_decrypt(text)
    Encryption::KmsClient.new.decrypt(
      Base64.decode64(text), 'context' => 'session-encryption'
    )
  end

  def outer_encrypt(plaintext)
    Encryption::Encryptors::AesEncryptor.new.encrypt(plaintext, session_encryption_key)
  end

  def outer_decrypt(ciphertext)
    Encryption::Encryptors::AesEncryptor.new.decrypt(ciphertext, session_encryption_key)
  end

  private

  # The PII bundle is stored in the user session in the 'decrypted_pii' key.
  # The PII is decrypted with the user's password when they successfully submit it and then
  # stored in the session.  Before saving the session, this method encrypts the PII with KMS and
  # stores it in the 'encrypted_pii' key.
  #
  # The PII is not frequently needed in its KMS-decrypted state. To reduce the
  # risks around holding plaintext PII in memory during requests, this PII is KMS-decrypted
  # on-demand by the Pii::Cacher.
  def kms_encrypt_pii!(session)
    return unless session.dig('warden.user.user.session', 'decrypted_pii')
    decrypted_pii = session['warden.user.user.session'].delete('decrypted_pii')
    session['warden.user.user.session']['encrypted_pii'] =
      kms_encrypt(decrypted_pii)
    nil
  end

  # This method extracts all of the sensitive paths that exist into a
  # separate hash.  This separate hash is then encrypted and placed in the session.
  # We use #reduce to build the nested empty hash if needed. If Hash#bury
  # (https://bugs.ruby-lang.org/issues/11747) existed, we could use that instead.
  def kms_encrypt_sensitive_paths!(session, sensitive_paths)
    sensitive_data = {}

    sensitive_paths.each do |path|
      *all_but_last_key, last_key = path

      if all_but_last_key.blank?
        value = session.delete(last_key)
      else
        value = session.dig(*all_but_last_key)&.delete(last_key)
      end

      if value
        all_but_last_key.reduce(sensitive_data) do |hash, key|
          hash[key] ||= {}

          hash[key]
        end

        if all_but_last_key.blank?
          sensitive_data[last_key] = value
        else
          sensitive_data.dig(*all_but_last_key).store(last_key, value)
        end
      end
    end

    raise "invalid session, 'sensitive_data' is reserved key" if session['sensitive_data'].present?
    return if sensitive_data.blank?
    session['sensitive_data'] = kms_encrypt(JSON.generate(sensitive_data))
  end

  # This method reverses the steps taken in #kms_encrypt_sensitive_paths!
  # The encrypted hash is decrypted and then deep merged into the session hash.
  # The merge must be a deep merge to avoid collisions with existing hashes in the
  # session.
  def kms_decrypt_sensitive_paths!(session)
    sensitive_data = session.delete('sensitive_data')
    return if sensitive_data.blank?

    sensitive_data = JSON.parse(
      kms_decrypt(sensitive_data), quirks_mode: true
    )

    session.deep_merge!(sensitive_data)
  end

  def alert_or_raise_if_contains_sensitive_value!(string, hash)
    if SessionEncryptor::SENSITIVE_REGEX.match?(string)
      exception = SessionEncryptor::SensitiveValueError.new
      if IdentityConfig.store.session_encryptor_alert_enabled
        NewRelic::Agent.notice_error(
          exception, custom_params: {
            session_structure: hash.deep_transform_values { |v| nil },
          }
        )
      else
        raise exception
      end
    end
  end

  def alert_or_raise_if_contains_sensitive_keys!(hash)
    hash.deep_transform_keys do |key|
      if SessionEncryptor::SENSITIVE_KEYS.include?(key.to_s)
        exception = SessionEncryptor::SensitiveKeyError.new(
          "#{key} unexpectedly appeared in session",
        )
        if IdentityConfig.store.session_encryptor_alert_enabled
          NewRelic::Agent.notice_error(
            exception, custom_params: {
              session_structure: hash.deep_transform_values { |_v| '' },
            }
          )
        else
          raise exception
        end
      end
    end
  end

  def session_encryption_key
    IdentityConfig.store.session_encryption_key
  end
end
