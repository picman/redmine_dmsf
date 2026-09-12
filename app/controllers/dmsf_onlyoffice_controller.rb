# frozen_string_literal: true

# Handles ONLYOFFICE editor, download, and callback requests for DMSF files.
class DmsfOnlyofficeController < ApplicationController
  menu_item :dmsf

  before_action :require_onlyoffice
  before_action :find_file, only: %i[view edit]
  before_action :authorize, only: %i[view edit]
  before_action :check_dmsf_permissions, only: %i[view edit]
  skip_before_action :verify_authenticity_token, only: :callback

  def view
    render_editor('view')
  end

  def edit
    return render_403 if User.current.anonymous?
    return render_403 unless RedmineDmsf::OnlyOffice.editable?(@file.name)
    return render_403 if @file.locked_for_user?

    render_editor('edit')
  end

  def download
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: 'download')
    file = DmsfFile.visible.find(claims.fetch('file_id'))
    revision = DmsfFileRevision.visible.find(claims.fetch('revision_id'))
    user = token_user(claims)
    raise ActiveRecord::RecordNotFound unless revision.dmsf_file_id == file.id && revision.file.attached?

    previous_user = User.current
    User.current = user
    unless (user.active? || user.anonymous?) && user.allowed_to?(:view_dmsf_files, file.project) &&
           DmsfFolder.permissions?(file.dmsf_folder, allow_system: true, file: true)
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
    User.current = previous_user if defined?(previous_user)
  end

  def callback
    body = RedmineDmsf::OnlyOffice.callback_payload(request)
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: 'callback')
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'Document key mismatch' unless body['key'] == claims['key']

    status = body['status'].to_i
    case status
    when 2
      save_revision(body, claims)
    when 1, 4, 6
      # Status 6 is a force-save. We intentionally persist only the final status 2,
      # otherwise repeated force-saves with the same document key would create revision spam.
    when 3, 7
      Rails.logger.error "ONLYOFFICE reported save error status #{status} for #{body['key']}"
      return render json: { error: 1 }
    end

    render json: { error: 0 }
  rescue RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordNotFound => e
    Rails.logger.error "ONLYOFFICE DMSF callback failed: #{e.class}: #{e.message}"
    render json: { error: 1 }
  rescue StandardError => e
    backtrace = e.backtrace&.first(10)&.join("\n")
    Rails.logger.error "ONLYOFFICE DMSF callback failed: #{e.class}: #{e.message}\n#{backtrace}"
    render json: { error: 1 }
  end

  private

  def require_onlyoffice
    return if RedmineDmsf::OnlyOffice.enabled?

    render_404
  end

  def find_file
    @file = DmsfFile.visible.find(params[:id])
    @project = @file.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def check_dmsf_permissions
    return if DmsfFolder.permissions?(@file.dmsf_folder, allow_system: true, file: true)

    render_403
  end

  def token_user(claims)
    return User.anonymous if claims['anonymous']

    User.find(claims.fetch('user_id'))
  end

  def render_editor(mode)
    @revision = @file.last_revision
    raise ActiveRecord::RecordNotFound unless @revision&.file&.attached?
    raise ActiveRecord::RecordNotFound unless RedmineDmsf::OnlyOffice.viewable?(@revision.name)

    key = RedmineDmsf::OnlyOffice.document_key(@file, @revision)
    # Keep view-only sessions separate from collaborative edit sessions. Otherwise a viewer
    # joining last could replace the callback URL selected by ONLYOFFICE for the edit session.
    key = "#{key}-view" if mode == 'view'
    download_token = RedmineDmsf::OnlyOffice.storage_token(
      file: @file, revision: @revision, user: User.current, purpose: 'download', key: key
    )
    callback_token = RedmineDmsf::OnlyOffice.storage_token(
      file: @file, revision: @revision, user: User.current, purpose: 'callback', key: key, mode: mode
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
    back_url = dmsf_file_url(
      @file,
      protocol: Setting.protocol,
      host: Setting.host_name
    )

    @onlyoffice_api_url = RedmineDmsf::OnlyOffice.api_url
    @onlyoffice_config = RedmineDmsf::OnlyOffice.editor_config(
      revision: @revision,
      user: User.current,
      mode: mode,
      key: key,
      download_url: RedmineDmsf::OnlyOffice.internal_redmine_url(public_download_url),
      callback_url: RedmineDmsf::OnlyOffice.internal_redmine_url(public_callback_url),
      back_url: back_url
    )
    @mode = mode
    response.headers['Cache-Control'] = 'no-store'
    render action: 'editor'
  end

  def save_revision(body, claims)
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'The ONLYOFFICE session is view-only' unless claims['mode'] == 'edit'

    file = DmsfFile.visible.find(claims.fetch('file_id'))
    source = DmsfFileRevision.visible.find(claims.fetch('revision_id'))
    user = token_user(claims)
    raise ActiveRecord::RecordNotFound unless source.dmsf_file_id == file.id
    return if DmsfFileRevision.exists?(onlyoffice_key: claims.fetch('key'))
    raise RedmineDmsf::OnlyOffice::Error, 'Missing callback file URL' if body['url'].blank?

    previous_user = User.current
    User.current = user
    unless user.active? && user.allowed_to?(:file_manipulation, file.project) &&
           DmsfFolder.permissions?(file.dmsf_folder, allow_system: true, file: true)
      raise RedmineDmsf::OnlyOffice::Error, 'The editing user is no longer allowed to update this DMSF file'
    end
    raise RedmineDmsf::OnlyOffice::Error, 'The DMSF file is locked by another user' if file.locked_for_user?

    max_bytes = Setting.attachment_max_size.to_i.kilobytes
    max_bytes = nil unless max_bytes.positive?
    tempfile = RedmineDmsf::OnlyOffice.download_to_tempfile(body['url'], max_bytes: max_bytes)
    revision_created = false

    DmsfFile.transaction do
      file = DmsfFile.visible.lock.find(file.id)
      next if DmsfFileRevision.exists?(onlyoffice_key: claims.fetch('key'))

      current_revision = file.dmsf_file_revisions.visible.first
      unless current_revision&.id == source.id
        raise RedmineDmsf::OnlyOffice::Error,
              'A newer DMSF revision was created while the ONLYOFFICE editor was open'
      end
      raise RedmineDmsf::OnlyOffice::Error, 'The DMSF file is locked by another user' if file.locked_for_user?

      revision = source.clone
      revision.user = user
      revision.source_revision = source
      revision.onlyoffice_key = claims.fetch('key')
      revision.comment = I18n.with_locale(user.language.presence || I18n.default_locale) do
        I18n.t(:comment_dmsf_onlyoffice_revision)
      end
      revision.reset_workflow
      version_component = RedmineDmsf.onlyoffice_version_constant
      if version_component == DmsfFileRevision::PATCH_VERSION && revision.minor_version.nil?
        revision.minor_version = 0
        revision.increase_version(version_component)
      elsif version_component == DmsfFileRevision::MINOR_VERSION && revision.minor_version.nil?
        revision.minor_version = 1
      else
        revision.increase_version(version_component)
      end
      revision.size = tempfile.size
      revision.shared_file.attach(
        io: tempfile,
        filename: source.name,
        content_type: source.content_type,
        identify: false
      )

      custom_values = source.custom_field_values.to_h do |value|
        [value.custom_field_id.to_s, value.value]
      end
      revision.copy_custom_field_values(ActionController::Parameters.new(custom_values), source)
      revision.save!

      file.last_revision = revision
      file.save!
      revision_created = true
    end

    return unless revision_created

    Rails.logger.info "Created DMSF revision #{file.last_revision.id} from ONLYOFFICE document #{claims['key']}"
    call_hook :dmsf_helper_upload_after_commit, { file: file }

    begin
      DmsfMailer.deliver_files_updated(file.project, [file])
    rescue StandardError => e
      Rails.logger.error "Could not send ONLYOFFICE update notifications: #{e.message}"
    end
  rescue ActiveRecord::RecordNotUnique
    raise unless DmsfFileRevision.exists?(onlyoffice_key: claims['key'])

    Rails.logger.info "Ignoring duplicate ONLYOFFICE callback for #{claims['key']}"
  ensure
    User.current = previous_user if defined?(previous_user)
    tempfile&.close!
  end
end
