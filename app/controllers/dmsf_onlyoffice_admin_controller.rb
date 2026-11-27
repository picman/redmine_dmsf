# frozen_string_literal: true

# Global Document Server inventory is restricted to administrators and intersected with this instance's registry.
class DmsfOnlyofficeAdminController < ApplicationController
  layout 'admin'
  before_action :require_admin

  def index
    @pending_count = DmsfOnlyofficeRecovery.where(state: 'pending').count
    @recoveries = DmsfOnlyofficeRecovery.where(state: 'pending').order(created_at: :desc).limit(200)
    @sessions = DmsfOnlyofficeSession.where(state: %w[recovery error]).order(updated_at: :desc).limit(100)
  end

  def download
    recovery = DmsfOnlyofficeRecovery.find(params[:recovery_id])
    response.headers['Cache-Control'] = 'no-store'
    recovery.payload.open do |io|
      send_data io.read, filename: recovery.filename, type: recovery.content_type, disposition: 'attachment'
    end
  end

  def diagnostics
    result = RedmineDmsf::OnlyOffice.command('version')
    raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE version error #{result['error']}" unless result['error'].to_i.zero?

    @diagnostics = { version: result['version'], jwt: RedmineDmsf.onlyoffice_jwt_secret.present?,
                     tls_verification: !RedmineDmsf.onlyoffice_ssl_verification_disabled?,
                     callback_ttl: RedmineDmsf.onlyoffice_session_ttl }
    index
    render :index
  rescue RedmineDmsf::OnlyOffice::Error => e
    flash[:error] = e.message
    redirect_to dmsf_onlyoffice_admin_path
  end

  def forgotten
    result = RedmineDmsf::OnlyOffice.command('getForgottenList')
    raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE forgotten error #{result['error']}" unless result['error'].to_i.zero?

    keys = Array(result['keys']).select { |key| key.is_a?(String) }
    @forgotten = DmsfOnlyofficeSession.where(document_key: keys).includes(:dmsf_file).to_a
    @unknown_count = keys.size - @forgotten.size
    index
    render :index
  rescue RedmineDmsf::OnlyOffice::Error => e
    flash[:error] = e.message
    redirect_to dmsf_onlyoffice_admin_path
  end

  def recover_forgotten
    session = DmsfOnlyofficeSession.find(params[:session_id])
    source = session.source_revision
    filename = source&.name || session.source_filename
    content_type = source&.content_type || session.source_content_type || 'application/octet-stream'
    raise RedmineDmsf::OnlyOffice::Error, 'The source filename is no longer available' if filename.blank?

    result = RedmineDmsf::OnlyOffice.command('getForgotten', key: session.document_key)
    raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE recovery error #{result['error']}" unless
      result['error'].to_i.zero? && result['url'].present?

    limit = Setting.attachment_max_size.to_i.kilobytes
    tempfile = RedmineDmsf::OnlyOffice.download_to_tempfile(result['url'], max_bytes: limit.positive? ? limit : nil)
    extension = DmsfOnlyofficeDocumentCreator.detect_extension(tempfile, default: RedmineDmsf::OnlyOffice.extension(filename))
    filename = "#{File.basename(filename, File.extname(filename))}.#{extension}"
    content_type = Redmine::MimeType.of(filename).presence || content_type
    recovery = DmsfOnlyofficeRecovery.store!(session: session, kind: 'forgotten', io: tempfile,
                                             filename: filename, content_type: content_type,
                                             reason: 'Imported from ONLYOFFICE forgotten storage')
    session.update!(state: 'recovery') unless session.state == 'saved'
    flash[:notice] = l(:notice_dmsf_onlyoffice_recovered, id: recovery.id)
    redirect_to dmsf_onlyoffice_admin_path
  rescue RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordInvalid => e
    flash[:error] = e.message
    redirect_to dmsf_onlyoffice_admin_path
  ensure
    tempfile&.close!
  end

  def delete_forgotten
    session = DmsfOnlyofficeSession.find(params[:session_id])
    if %w[active snapshot].include?(session.state) && session.expires_at > Time.current
      raise RedmineDmsf::OnlyOffice::Error, 'Close the editing session before deleting its forgotten copy'
    end
    info = RedmineDmsf::OnlyOffice.command('info', key: session.document_key)
    unless info['error'] == 1 || (info['error'].zero? && info['users'].is_a?(Array) && info['users'].empty?)
      raise RedmineDmsf::OnlyOffice::Error, 'The Document Server has not confirmed an inactive editing session'
    end
    recovery = DmsfOnlyofficeRecovery.where(dmsf_onlyoffice_session: session, kind: 'forgotten')
                                     .order(created_at: :desc).first!
    # Re-read durable storage and check its digest before deleting the server's recovery copy.
    recovery.payload.open do |io|
      raise RedmineDmsf::OnlyOffice::Error, 'Recovery integrity check failed' unless
        Digest::SHA256.file(io.path).hexdigest == recovery.checksum
    end
    # Forgotten content can change after a previous recovery. Check the current
    # remote bytes too; never delete a newer copy using an older local receipt.
    result = RedmineDmsf::OnlyOffice.command('getForgotten', key: session.document_key)
    raise RedmineDmsf::OnlyOffice::Error, 'The forgotten copy is no longer available' unless
      result['error'].to_i.zero? && result['url'].present?

    limit = Setting.attachment_max_size.to_i.kilobytes
    current = RedmineDmsf::OnlyOffice.download_to_tempfile(result['url'], max_bytes: limit.positive? ? limit : nil)
    unless Digest::SHA256.file(current.path).hexdigest == recovery.checksum
      raise RedmineDmsf::OnlyOffice::Error, 'The forgotten file changed; recover the new copy before deleting it'
    end
    result = RedmineDmsf::OnlyOffice.command('deleteForgotten', key: session.document_key)
    raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE delete error #{result['error']}" unless result['error'].to_i.zero?

    flash[:notice] = l(:notice_successful_update)
    redirect_to dmsf_onlyoffice_admin_path
  rescue RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordNotFound => e
    flash[:error] = e.is_a?(ActiveRecord::RecordNotFound) ? l(:error_dmsf_onlyoffice_recover_first) : e.message
    redirect_to dmsf_onlyoffice_admin_path
  ensure
    current&.close!
  end
end
