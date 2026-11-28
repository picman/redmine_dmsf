# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Karel Pičman <karel.picman@kontron.com>
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
