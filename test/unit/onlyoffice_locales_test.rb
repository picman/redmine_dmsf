# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Marco Tenti <tentimarco0@gmail.com>, Karel Pičman <karel.picman@kontron.com>
#
# This file is part of Redmine DMSF plugin.
#
# Redmine DMSF plugin is free software: you can redistribute it and/or modify it under the terms of the GNU General
# Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any
# later version.
#
# Redmine DMSF plugin is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
# the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with Redmine DMSF plugin. If not, see
# <https://www.gnu.org/licenses/>.

require 'minitest/autorun'
require 'yaml'

# Read each locale directly: I18n fallbacks must not hide missing translations.
# This test also runs without Rails: ruby test/unit/onlyoffice_locales_test.rb
class OnlyOfficeLocalesTest < Minitest::Test
  LOCALES_PATH = File.expand_path('../../config/locales', __dir__)
  REQUIRED_KEYS = %w[
    label_dmsf_onlyoffice
    label_dmsf_onlyoffice_view
    label_dmsf_onlyoffice_edit
    label_dmsf_onlyoffice_use_official_settings
    note_dmsf_onlyoffice_use_official_settings
    label_dmsf_onlyoffice_document_server_url
    note_dmsf_onlyoffice_document_server_url
    label_dmsf_onlyoffice_document_server_internal_url
    note_dmsf_onlyoffice_document_server_internal_url
    label_dmsf_onlyoffice_jwt_secret
    note_dmsf_onlyoffice_jwt_secret
    label_dmsf_onlyoffice_jwt_algorithm
    note_dmsf_onlyoffice_jwt_algorithm
    label_dmsf_onlyoffice_jwt_header
    note_dmsf_onlyoffice_jwt_header
    label_dmsf_onlyoffice_disable_certificate_verification
    note_dmsf_onlyoffice_disable_certificate_verification
    label_dmsf_onlyoffice_editable_extensions
    note_dmsf_onlyoffice_editable_extensions
    label_dmsf_onlyoffice_version_type
    note_dmsf_onlyoffice_version_type
    label_dmsf_onlyoffice_token_ttl
    note_dmsf_onlyoffice_token_ttl
    comment_dmsf_onlyoffice_revision
  ].freeze

  def test_english_contains_all_required_keys
    english = load_locale(File.join(LOCALES_PATH, 'en.yml'))

    REQUIRED_KEYS.each { |key| assert english.key?(key), "Missing English source: #{key}" }
  end

  def test_all_locales_contain_the_new_keys_without_fallbacks
    locale_files.each do |path|
      translations = load_locale(path)
      missing = required_keys - translations.keys

      assert_empty missing, "#{File.basename(path)} is missing #{missing.join(', ')}"
    end
  end

  def test_all_values_are_nonempty_strings_with_matching_interpolation
    english = load_locale(File.join(LOCALES_PATH, 'en.yml'))

    locale_files.each do |path|
      translations = load_locale(path)
      required_keys.each do |key|
        value = translations.fetch(key)
        message = "#{File.basename(path)}: #{key}"
        assert_kind_of String, value, message
        assert value.strip.present?, message
        assert_equal english.fetch(key).scan(/%\{[^}]+\}/).sort, value.scan(/%\{[^}]+\}/).sort, message
      end
    end
  end

  def test_each_new_key_occurs_exactly_once
    locale_files.each do |path|
      document = Psych.parse_file(path)
      locale_mapping = document.root.children.fetch(1)
      keys = locale_mapping.children.each_slice(2).map { |key, _value| key.value }
      required_keys.each do |key|
        assert_equal 1, keys.count(key), "#{File.basename(path)}: duplicate or missing #{key}"
      end
    end
  end

  private

  def locale_files
    Dir.glob File.join(LOCALES_PATH, '*.yml')
  end

  def load_locale(path)
    YAML.safe_load_file(path).fetch(File.basename(path, '.yml'))
  end

  def required_keys
    english = load_locale(File.join(LOCALES_PATH, 'en.yml'))
    (REQUIRED_KEYS + english.keys.grep(/onlyoffice/)).uniq
  end
end
