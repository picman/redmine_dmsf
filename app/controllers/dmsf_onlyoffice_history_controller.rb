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

require 'securerandom'

# Serves DMSF's retained revisions to the native ONLYOFFICE history UI. History
# assets have a separate token purpose and recheck the user's current access.
class DmsfOnlyofficeHistoryController < ApplicationController
  COMPARABLE_EXTENSIONS = %w[doc docm docx dot dotm dotx epub fodt odt ott rtf wps].freeze
  COMPARISON_ACTIONS = %w[compare combine insert-text].freeze

  menu_item :dmsf

  before_action :require_onlyoffice
  before_action :find_file, except: :asset
  before_action :check_history_permissions, except: :asset
  skip_before_action :check_if_login_required, only: :asset

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def index
    revisions = retained_revisions(@file).to_a
    records = DmsfOnlyofficeHistory.where(dmsf_file_revision_id: revisions.map(&:id))
                                   .includes(changes_archive_attachment: :blob)
                                   .index_by(&:dmsf_file_revision_id)
    current = @file.last_revision
    render json: {
      currentVersion: current&.id,
      history: revisions.reverse.map { |revision| history_entry(revision, records[revision.id]) }
    }
  end

  def show
    revision = retained_revisions(@file).find(params[:revision_id])
    payload = revision_payload(@file, revision).merge(version: revision.id)
    record = DmsfOnlyofficeHistory.find_by(dmsf_file_revision_id: revision.id)
    source = history_source(record, @file)
    if source
      payload[:changesUrl] = history_asset_url(@file, revision)
      payload[:previous] = revision_payload(@file, source)
    end
    render json: RedmineDmsf::OnlyOffice.sign_payload(payload)
  end

  # The native document picker can compare a retained revision of the current
  # document or another authorized document in the same project. Searching is
  # explicit, so opening the picker does not enumerate every project document.
  def compare
    operation = params[:c].presence || 'compare'
    return render_history_error(:error_dmsf_onlyoffice_invalid_comparison, :unprocessable_entity) unless
      COMPARISON_ACTIONS.include?(operation)

    target = if params[:file_id].present?
               DmsfFile.visible.where(project_id: @project.id).find(params[:file_id])
             else
               @file
             end
    return render_history_error(:error_dmsf_onlyoffice_history_forbidden, :forbidden) unless history_allowed?(target)

    files, truncated = comparison_files
    files.unshift(target) unless files.any? { |file| file.id == target.id }
    revisions = retained_revisions(target).select do |revision|
      COMPARABLE_EXTENSIONS.include?(RedmineDmsf::OnlyOffice.extension(revision.name)) && revision.file.attached?
    end
    render json: {
      files: files.map { |file| { id: file.id, name: file.title.presence || file.name } },
      selected_file_id: target.id,
      truncated: truncated,
      revisions: revisions.map do |revision|
        payload = revision_payload(target, revision).slice(:fileType, :url).merge(c: operation)
        {
          id: revision.id,
          version: revision.version,
          name: revision.name,
          created: revision.created_at.iso8601,
          request: RedmineDmsf::OnlyOffice.sign_payload(payload)
        }
      end
    }
  end

  def restore
    unless User.current.active? && User.current.allowed_to?(:file_manipulation, @project) && !@file.locked_for_user?
      return render_history_error(:error_dmsf_onlyoffice_history_forbidden, :forbidden)
    end

    expected = Integer(params[:expected_revision_id].to_s, 10)
    unless expected.positive?
      return render_history_error(:error_dmsf_onlyoffice_expected_revision,
                                  :unprocessable_entity)
    end

    source = retained_revisions(@file).find(params[:revision_id])
    raise ActiveRecord::RecordNotFound unless source.file.attached?

    revision = DmsfOnlyofficeRevisionWriter.call(
      file: @file, source: source, user: User.current, expected_revision_id: expected,
      comment: l(:comment_dmsf_onlyoffice_restored_revision, version: source.version),
      key: "dmsf-restore-#{SecureRandom.uuid}"
    )
    render json: { revision_id: revision.id, version: revision.version, url: dmsf_file_path(@file) }
  rescue ArgumentError, TypeError
    render_history_error(:error_dmsf_onlyoffice_expected_revision, :unprocessable_entity)
  rescue DmsfOnlyofficeRevisionWriter::Conflict
    render_history_error(:error_dmsf_onlyoffice_revision_conflict, :conflict)
  rescue DmsfOnlyofficeRevisionWriter::PermissionDenied
    render_history_error(:error_dmsf_onlyoffice_history_forbidden, :forbidden)
  rescue RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordInvalid => e
    Rails.logger.warn "ONLYOFFICE history restore failed: #{e.class}: #{e.message}"
    render_history_error(:error_dmsf_onlyoffice_restore_failed, :unprocessable_entity)
  end

  def asset
    previous_user = User.current
    document = params[:kind] == 'document'
    purpose = document ? 'history_document' : 'history'
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: purpose)
    raise ActiveRecord::RecordNotFound unless params[:id].to_i == claims.fetch('file_id').to_i

    file = DmsfFile.visible.find(claims.fetch('file_id'))
    revision = retained_revisions(file).find(claims.fetch('revision_id'))
    user = claims['anonymous'] ? User.anonymous : User.find(claims.fetch('user_id'))
    User.current = user
    raise ActiveRecord::RecordNotFound unless (user.active? || user.anonymous?) && history_allowed?(file)

    allow_document_server_origin
    response.headers['Cache-Control'] = 'no-store'
    if document
      raise ActiveRecord::RecordNotFound unless revision.file.attached?

      send_data revision.file.download, filename: revision.name, type: revision.content_type, disposition: 'attachment'
    else
      record = DmsfOnlyofficeHistory.find_by(dmsf_file_revision_id: revision.id)
      raise ActiveRecord::RecordNotFound unless history_source(record, file)

      send_data record.changes_archive.download, filename: "dmsf-#{file.id}-#{revision.id}-changes.zip",
                                                 type: 'application/zip', disposition: 'attachment'
    end
  rescue RedmineDmsf::OnlyOffice::InvalidToken, ActiveRecord::RecordNotFound, KeyError
    not_found
  ensure
    User.current = previous_user
  end

  private

  def require_onlyoffice
    return if RedmineDmsf::OnlyOffice.enabled?

    not_found
  end

  def find_file
    @file = DmsfFile.visible.find(params[:id])
    @project = @file.project
    response.headers['Cache-Control'] = 'no-store'
  end

  def check_history_permissions
    return if history_allowed?(@file)

    render_history_error(:error_dmsf_onlyoffice_history_forbidden, :forbidden)
  end

  def history_allowed?(file)
    DmsfOnlyofficeSession.allowed_mode?(file: file, user: User.current, mode: 'view') &&
      User.current.allowed_to?(:view_dmsf_file_revisions, file.project)
  end

  def retained_revisions(file)
    file.dmsf_file_revisions.visible
  end

  def history_entry(revision, record)
    entry = {
      version: revision.id,
      key: RedmineDmsf::OnlyOffice.document_key(@file, revision),
      created: revision.created_at.iso8601,
      user: { id: revision.user_id.to_s, name: revision.user&.name.to_s }
    }
    metadata = history_metadata(record)
    if history_source(record, @file)
      entry[:changes] = metadata['changes']
      entry[:serverVersion] = metadata['serverVersion']
    end
    entry
  end

  # Metadata-only historical revisions still work. Highlighting needs both the
  # saved changes archive and its original retained base; never substitute a
  # different predecessor after retention has removed the original base.
  def history_source(record, file)
    return unless record&.changes_archive&.attached? && record.source_revision_id.present?

    metadata = history_metadata(record)
    return unless metadata['changes'].is_a?(Array) && metadata['changes'].present? && metadata['serverVersion'].present?

    source = retained_revisions(file).find_by(id: record.source_revision_id)
    source if source&.file&.attached?
  end

  def history_metadata(record)
    metadata = record&.metadata
    return {} unless metadata.is_a?(Hash)

    metadata['history'].is_a?(Hash) ? metadata['history'] : metadata
  end

  def revision_payload(file, revision)
    raise ActiveRecord::RecordNotFound unless revision.file.attached? &&
                                              RedmineDmsf::OnlyOffice.viewable?(revision.name)

    token = RedmineDmsf::OnlyOffice.storage_token(
      file: file, revision: revision, user: User.current, purpose: 'history_document'
    )
    public_url = dmsf_onlyoffice_history_asset_url(file, kind: 'document', token: token,
                                                         protocol: Setting.protocol, host: Setting.host_name)
    {
      fileType: RedmineDmsf::OnlyOffice.extension(revision.name),
      key: RedmineDmsf::OnlyOffice.document_key(file, revision),
      url: RedmineDmsf::OnlyOffice.internal_redmine_url(public_url)
    }
  end

  def history_asset_url(file, revision)
    token = RedmineDmsf::OnlyOffice.storage_token(
      file: file, revision: revision, user: User.current, purpose: 'history'
    )
    # Changes archives are requested by the browser in the Document Server's
    # frame, so this URL must remain public even when document downloads use an
    # internal Redmine address.
    dmsf_onlyoffice_history_asset_url(file, kind: 'changes', token: token,
                                            protocol: Setting.protocol, host: Setting.host_name)
  end

  def comparison_files
    query = params[:q].to_s.strip.first(200)
    return [[@file], false] if query.blank?

    names = DmsfFileRevision.visible.where('LOWER(name) LIKE :q OR LOWER(title) LIKE :q',
                                           q: "%#{DmsfFileRevision.sanitize_sql_like(query.downcase)}%")
    files = DmsfFile.visible.where(project_id: @project.id, id: names.select(:dmsf_file_id))
    matches = []
    files.find_each do |file|
      next unless history_allowed?(file)
      next unless COMPARABLE_EXTENSIONS.include?(RedmineDmsf::OnlyOffice.extension(file.name))

      matches << file
      break if matches.size > 50
    end
    [matches.first(50), matches.size > 50]
  end

  def allow_document_server_origin
    uri = URI.parse(RedmineDmsf.onlyoffice_document_server_url)
    origin = "#{uri.scheme}://#{uri.host}"
    origin += ":#{uri.port}" unless uri.port == uri.default_port
    response.headers['Access-Control-Allow-Origin'] = origin
    response.headers['Vary'] = 'Origin'
  end

  def not_found
    render_history_error(:error_dmsf_onlyoffice_history_not_found, :not_found)
  end

  def render_history_error(message, status)
    render json: { error: l(message) }, status: status
  end
end
