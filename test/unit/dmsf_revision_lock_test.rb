# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)
require 'timeout'

# Exercise the common publication lock using independent database connections.
class DmsfRevisionLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def test_ordinary_revision_insert_waits_for_the_editor_file_lock
    skip 'PostgreSQL lock_timeout regression' unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'

    file = DmsfFile.create!(project: Project.find(1))
    worker = nil
    outcome = Queue.new
    file.with_lock do
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          DmsfFileRevision.transaction do
            connection.execute("SET LOCAL lock_timeout = '200ms'")
            DmsfFileRevision.create!(dmsf_file_id: file.id, user: User.find(1),
                                     name: "lock-test-#{file.id}.txt", title: 'Concurrent revision',
                                     major_version: 1, minor_version: 0, size: 0)
          end
          outcome << :committed
        rescue ActiveRecord::LockWaitTimeout
          outcome << :blocked
        rescue StandardError => e
          outcome << e
        end
      end
      assert_equal :blocked, Timeout.timeout(5) { outcome.pop }
      worker.join
      assert_empty file.dmsf_file_revisions
    end
  ensure
    worker&.join(5)
    file&.destroy!
  end
end
