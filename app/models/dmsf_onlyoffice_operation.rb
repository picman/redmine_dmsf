# frozen_string_literal: true

# Durable correlation for asynchronous PDF exports and controlled template generation.
class DmsfOnlyofficeOperation < ApplicationRecord
  belongs_to :dmsf_file, optional: true
  belongs_to :source_revision, class_name: 'DmsfFileRevision', optional: true
  belongs_to :user, optional: true
  belongs_to :folder, class_name: 'DmsfFolder', optional: true
  belongs_to :result_file, class_name: 'DmsfFile', optional: true
  serialize :parameters, coder: JSON

  validates :request_key, :filename, presence: true
  validates :kind, inclusion: { in: %w[pdf template] }
  validates :state, inclusion: { in: %w[pending completed failed] }

  def finished?
    state == 'completed'
  end

  # Responses can arrive out of order from concurrent browser polls.
  # Reload under the lock before changing a pending operation.
  def update_if_pending!(**attributes)
    with_lock { update!(**attributes) if state == 'pending' }
  end
end
