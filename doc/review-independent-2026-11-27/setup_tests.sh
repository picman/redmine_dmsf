#!/bin/sh
# Run in the existing QA container after copying Redmine to this temporary root.
set -eu
cd /tmp/dmsf-review-tests
export BUNDLE_APP_CONFIG=/tmp/dmsf-review-bundle
export RAILS_ENV=test
export SECRET_KEY_BASE="$(cat /run/secrets/secret-key-base)"
export DATABASE_URL="postgres://redmine:$(cat /run/secrets/db-password)@postgres/qa_dmsf_fixes_test"
ruby -rpg -e 'c = PG.connect(host: "postgres", dbname: "postgres", user: "redmine", password: File.read("/run/secrets/db-password").strip); c.exec("CREATE DATABASE qa_dmsf_fixes_test") unless c.exec("SELECT 1 FROM pg_database WHERE datname = '\''qa_dmsf_fixes_test'\''").ntuples.positive?'
cat > config/database.yml <<'YAML'
test:
  adapter: postgresql
  url: <%= ENV.fetch('DATABASE_URL') %>
YAML
cat > config/storage.yml <<'YAML'
test:
  service: Disk
  root: /tmp/dmsf-review-tests-storage
YAML
cp config/additional_environment.rb.example config/additional_environment.rb
cat > config/initializers/zz_lab_active_storage.rb <<'RUBY'
Rails.application.config.active_storage.service = :test
RUBY
cat >> config/additional_environment.rb <<'RUBY'
require 'active_storage/engine'
config.active_storage.service = :test
config.action_mailer.delivery_method = :test
config.action_mailer.perform_deliveries = false
require Rails.root.join('plugins/redmine_dmsf/lib/redmine_dmsf/webdav/custom_middleware').to_s
config.middleware.insert_before ActionDispatch::Cookies, RedmineDmsf::Webdav::CustomMiddleware
RUBY
# Reinitialize only this task's disposable database, then exercise real migrations.
ruby -rpg -e 'c = PG.connect(host: "postgres", dbname: "qa_dmsf_fixes_test", user: "redmine", password: File.read("/run/secrets/db-password").strip); raise "Unsafe database" unless c.db == "qa_dmsf_fixes_test"; c.exec("DROP SCHEMA public CASCADE; CREATE SCHEMA public")'
if [ -f db/schema.rb ]; then mv db/schema.rb db/schema.review_snapshot.rb; fi
bundle exec rake db:migrate redmine:plugins:migrate NAME=redmine_dmsf
