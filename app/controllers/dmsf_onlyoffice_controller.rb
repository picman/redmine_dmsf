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

# Handles ONLYOFFICE editor, download, and callback requests for DMSF files.
class DmsfOnlyofficeController < ApplicationController
  menu_item :dmsf

  before_action :require_onlyoffice
  before_action :find_file, only: %i[view edit refresh]
  before_action :authorize, only: :view
  before_action :check_dmsf_permissions, only: %i[view edit refresh]
  before_action :prepare_action_link, only: %i[view edit refresh]
  # Document Server requests are authenticated by signed tokens, not browser sessions.
  skip_before_action :check_if_login_required, only: %i[download callback]
  skip_before_action :verify_authenticity_token, only: :callback

  def view
    render_editor('view')
  end

  def edit
    mode = params[:mode].presence || 'edit'
    return render_403 unless permitted_edit_mode?(mode)

    render_editor(mode)
  end

  def refresh
    mode = params[:mode].presence || 'view'
    return render_403 unless mode == 'view' || permitted_edit_mode?(mode)

    render_editor(mode, json: true)
  end

  def download
    previous_user = User.current
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: 'download')
    file = DmsfFile.visible.find(claims.fetch('file_id'))
    revision = DmsfFileRevision.visible.find(claims.fetch('revision_id'))
    user = token_user(claims)
    raise ActiveRecord::RecordNotFound unless revision.dmsf_file_id == file.id && revision.file.attached?

    User.current = user
    unless DmsfOnlyofficeSession.allowed_mode?(file: file, user: user, mode: 'view')
      raise RedmineDmsf::OnlyOffice::InvalidToken, 'The user is no longer allowed to download this DMSF file'
    end

    expires_in 0.years, 'must-revalidate' => true
    if ActiveStorage::Blob.service.is_a?(ActiveStorage::Service::DiskService)
      key = revision.file.blob.key
      path = File.join(ActiveStorage::Blob.service.root, key[0..1], key[2..3], key)
      send_file path, filename: revision.name, type: revision.content_type, disposition: 'attachment'
    else
      send_data revision.file.download, filename: revision.name, type: revision.content_type, disposition: 'attachment'
    end
  rescue RedmineDmsf::OnlyOffice::InvalidToken, ActiveRecord::RecordNotFound => e
    Rails.logger.warn "ONLYOFFICE DMSF download rejected: #{e.message}"
    render_404
  ensure
    User.current = previous_user
  end

  def callback
    body = RedmineDmsf::OnlyOffice.callback_payload(request)
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: 'callback')
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'Document key mismatch' unless body['key'] == claims['key']

    session = DmsfOnlyofficeSession.from_claims!(claims)
    status = body['status'].to_i
    case status
    when 2, 3, 6, 7
      result = save_revision(body, claims, session: session)
      if result.published
        file = session.dmsf_file.reload
        call_hook :dmsf_helper_upload_after_commit, { file: file }
      end
    when 1
      session.record_callback!(next_state: 'active', connected_users: body['users'], presence_only: true)
    when 4
      session.record_callback!(next_state: 'closed', connected_users: [], presence_only: true)
    else
      raise RedmineDmsf::OnlyOffice::InvalidToken, 'Unsupported callback status'
    end

    render json: { error: 0 }
  rescue RedmineDmsf::OnlyOffice::InvalidToken, ActiveRecord::RecordNotFound => e
    Rails.logger.error "ONLYOFFICE DMSF callback failed: #{e.class}: #{e.message}"
    render json: { error: 1 }
  rescue RedmineDmsf::OnlyOffice::Error => e
    Rails.logger.error "ONLYOFFICE DMSF capture failed: #{e.class}: #{e.message}"
    render json: { error: 1 }, status: :service_unavailable
  rescue StandardError => e
    backtrace = e.backtrace&.first(10)&.join("\n")
    Rails.logger.error "ONLYOFFICE DMSF callback failed: #{e.class}: #{e.message}\n#{backtrace}"
    render json: { error: 1 }, status: :service_unavailable
  end

  private

  def require_onlyoffice
    return if RedmineDmsf::OnlyOffice.enabled?

    render_404
  end

  def find_file
    @file = DmsfFile.visible.find(params[:id])
    @project = @file.project
    raise ActiveRecord::RecordNotFound unless @project.active? && @project.module_enabled?(:dmsf)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def check_dmsf_permissions
    return if DmsfOnlyofficeSession.allowed_mode?(file: @file, user: User.current, mode: 'view')

    render_403
  end

  def token_user(claims)
    return User.anonymous if claims['anonymous']

    User.find(claims.fetch('user_id'))
  end

  # The context menu passes the page the user came from as a local path. The
  # editor opens goback in a new tab, so an absolute URL would be an open
  # redirect and is ignored.
  def absolute_back_url(candidate)
    path = candidate.to_s
    return nil unless path.start_with?('/') && !path.start_with?('//') && !path.match?(/[\r\n]/)

    "#{Setting.protocol}://#{Setting.host_name}#{path}"
  end

  def permitted_edit_mode?(mode)
    DmsfOnlyofficeSession::MODE_PERMISSIONS.key?(mode) &&
      DmsfOnlyofficeSession.allowed_mode?(file: @file, user: User.current, mode: mode) &&
      RedmineDmsf::OnlyOffice.editable?(@file.name) && !@file.locked_for_user? &&
      (mode != 'review' || RedmineDmsf::OnlyOffice.document_type(@file.name) == 'word') &&
      (mode != 'fill' || RedmineDmsf::OnlyOffice.extension(@file.name) == 'pdf')
  end

  def prepare_action_link
    value = params[:action_link]
    return if value.blank?
    raise JSON::ParserError, 'Invalid action link' unless value.is_a?(String) && value.bytesize <= 8.kilobytes

    @onlyoffice_action_link = JSON.parse(value)
    raise JSON::ParserError, 'Invalid action link' unless @onlyoffice_action_link.is_a?(Hash)
  rescue JSON::ParserError
    render json: { error: 'The requested document location is invalid' }, status: :bad_request
  end

  def editor_type
    requested = params[:editor_type].to_s
    return requested if action_name == 'refresh' && %w[desktop mobile].include?(requested)

    configured = RedmineDmsf.onlyoffice_mobile_mode
    return configured if %w[desktop mobile].include?(configured)

    request.user_agent.to_s.match?(/Android|iPhone|iPad|iPod|Mobile|Tablet/i) ? 'mobile' : 'desktop'
  end

  def render_editor(mode, json: false)
    key = nil
    @file.with_lock do
      @revision = @file.dmsf_file_revisions.visible.first
      raise ActiveRecord::RecordNotFound unless @revision&.file&.attached?
      raise ActiveRecord::RecordNotFound unless RedmineDmsf::OnlyOffice.viewable?(@revision.name)

      key = DmsfOnlyofficeSession.key_for_editor(file: @file, revision: @revision, user: User.current, mode: mode)
      @onlyoffice_session = DmsfOnlyofficeSession.register!(file: @file, revision: @revision,
                                                          user: User.current, mode: mode, document_key: key)
    end
    download_token = RedmineDmsf::OnlyOffice.storage_token(
      file: @file, revision: @revision, user: User.current, purpose: 'download', key: key
    )
    callback_token = RedmineDmsf::OnlyOffice.storage_token(
      file: @file, revision: @revision, user: User.current, purpose: 'callback', key: key, mode: mode,
      ttl: RedmineDmsf.onlyoffice_session_ttl
    )

    public_download_url = dmsf_onlyoffice_download_url(
      @file,
      token: download_token,
      filename: @revision.name,
      protocol: Setting.protocol,
      host: Setting.host_name
    )
    public_callback_url = dmsf_onlyoffice_callback_url(
      token: callback_token,
      protocol: Setting.protocol,
      host: Setting.host_name
    )
    back_url = absolute_back_url(params[:back_url]) ||
               dmsf_file_url(
                 @file,
                 protocol: Setting.protocol,
                 host: Setting.host_name
               )

    @onlyoffice_return_url = back_url
    @onlyoffice_can_edit = permitted_edit_mode?('edit')
    @onlyoffice_modes = ['view'] + DmsfOnlyofficeSession::MODE_PERMISSIONS.keys.select do |candidate|
      permitted_edit_mode?(candidate)
    end

    @onlyoffice_api_url = RedmineDmsf::OnlyOffice.api_url
    @onlyoffice_config = RedmineDmsf::OnlyOffice.editor_config(
      revision: @revision,
      user: User.current,
      mode: mode,
      key: key,
      download_url: RedmineDmsf::OnlyOffice.internal_redmine_url(public_download_url),
      callback_url: RedmineDmsf::OnlyOffice.internal_redmine_url(public_callback_url),
      back_url: back_url,
      type: editor_type,
      action_link: @onlyoffice_action_link
    )
    RedmineDmsf::OnlyOffice.warn_unreachable_endpoints
    @mode = mode
    response.headers['Cache-Control'] = 'no-store'
    if json
      render json: { config: @onlyoffice_config, revision_id: @revision.id, version: @revision.version }
    else
      render action: 'editor'
    end
  end

  def save_revision(body, claims, session: nil)
    unless DmsfOnlyofficeSession::MODE_PERMISSIONS.key?(claims['mode']) && !claims['anonymous']
      raise RedmineDmsf::OnlyOffice::InvalidToken, 'The ONLYOFFICE session is view-only'
    end

    session ||= DmsfOnlyofficeSession.from_claims!(claims)
    # A revoked or inactive actor may still deliver the already-authorized bytes
    # into recovery; the writer separately rechecks current publication rights.
    actor = User.find_by(id: claims['user_id'])
    DmsfOnlyofficeCapture.call(session: session, payload: body, user: actor, mode: claims['mode'])
  end
end
