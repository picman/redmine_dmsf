#!/bin/sh
set -eu
cd /tmp/dmsf-review-tests
export BUNDLE_APP_CONFIG=/tmp/dmsf-review-bundle
export RAILS_ENV=test
export SECRET_KEY_BASE="$(cat /run/secrets/secret-key-base)"
export DATABASE_URL="postgres://redmine:$(cat /run/secrets/db-password)@postgres/qa_dmsf_fixes_test"
bundle exec rails runner 'raise "Unsafe database" unless ActiveRecord::Base.connection_db_config.database == "qa_dmsf_fixes_test"; raise "Unsafe storage" unless ActiveStorage::Blob.service.root.to_s == "/tmp/dmsf-review-tests-storage"'
exec bundle exec "$@"
