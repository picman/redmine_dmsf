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

# Public URL controller
class DmsfPublicUrlsController < ApplicationController
  model_object DmsfPublicUrl
  before_action :authorize, only: [:create]
  skip_before_action :check_if_login_required, only: [:show]

  def show
    dmsf_public_url = DmsfPublicUrl.where('token = ? AND expire_at >= ?', params[:token], DateTime.current).first
    if dmsf_public_url
      revision = dmsf_public_url.dmsf_file.last_revision
      begin
        # IE has got a tendency to cache files
        expires_in 0.years, 'must-revalidate' => true
        if ActiveStorage::Blob.service.is_a?(ActiveStorage::Service::DiskService)
          # Speed up, if files are stored locally
          key = revision.file.blob.key
          path = File.join(ActiveStorage::Blob.service.root, key[0..1], key[2..3], key)
          send_file path,
                    filename: filename_for_content_disposition(revision.name),
                    type: revision.content_type,
                    disposition: dmsf_public_url.dmsf_file.disposition
        else
          send_data revision.file.download,
                    filename: filename_for_content_disposition(revision.name),
                    type: revision.content_type,
                    disposition: dmsf_public_url.dmsf_file.disposition
        end
      rescue StandardError => e
        Rails.logger.error e.message
        render_404
      end
    else
      render_404
    end
  end

  def create; end
end
