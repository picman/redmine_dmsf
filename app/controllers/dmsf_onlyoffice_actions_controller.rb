# frozen_string_literal: true

# Browser-initiated operations require a live Redmine session and CSRF protection.
class DmsfOnlyofficeActionsController < ApplicationController
  menu_item :dmsf
  before_action :load_file, except: :builder_script
  before_action :require_file_writer, only: %i[rename save_as publish_pdf create_from_template]
  skip_before_action :check_if_login_required, only: :builder_script

  rescue_from RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordInvalid, with: :operation_error
  rescue_from ActiveRecord::RecordNotFound, with: :missing_record

  def session_status
    item = editing_session
    receipts = item.recoveries.order(created_at: :desc).limit(20).map do |recovery|
      request_ids = Array(recovery.metadata['request_ids']).filter_map do |data|
        next data if data.is_a?(String) && data.match?(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i)

        parsed = JSON.parse(data.to_s)
        parsed['request_id'] if parsed.is_a?(Hash) && parsed['request_id'].is_a?(String)
      rescue JSON::ParserError
        nil
      end
      { id: recovery.id, kind: recovery.kind, state: recovery.state,
        created_at: recovery.created_at, request_ids: request_ids.uniq }
    end
    render json: { key: item.document_key, state: item.state, saved_revision_id: item.saved_revision_id,
                   last_error: item.last_error, last_callback_at: item.last_callback_at,
                   participants: item.participants, connected_users: item.connected_users,
                   last_presence_at: item.last_presence_at, expires_at: item.expires_at, receipts: receipts }
  end

  def forcesave
    return render_403 unless RedmineDmsf.onlyoffice_force_save_enabled?

    item = editing_session
    modes = item.mode == 'fill' ? ['fill'] : %w[edit review comment]
    can_save = item.mode != 'view' && modes.any? do |mode|
      DmsfOnlyofficeSession.allowed_mode?(file: @file, user: User.current, mode: mode)
    end
    return render_403 unless User.current.active? && item.participants.include?(User.current.id.to_s) && can_save
    raise RedmineDmsf::OnlyOffice::Error, 'This editing session has ended; reopen the editor' unless
      %w[active snapshot error recovery submitted].include?(item.state) &&
        item.closed_at.nil? && item.expires_at > Time.current

    request_id = SecureRandom.uuid
    result = RedmineDmsf::OnlyOffice.command('forcesave', key: item.document_key,
                                            userdata: { request_id: request_id, user_id: User.current.id }.to_json)
    raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE forcesave error #{result['error']}" unless
      [0, 4].include?(result['error'].to_i)

    render json: { error: result['error'].to_i, request_id: request_id, pending: result['error'].to_i.zero? }
  end

  def rename
    title = params.require(:title).to_s.strip
    key = params[:key].to_s
    item = editing_session if key.present?
    @file.with_lock do
      revision = check_head!
      extension = RedmineDmsf::OnlyOffice.extension(revision.name)
      name = DmsfOnlyofficeDocumentCreator.filename(title, extension)
      revision.update!(name: name, title: File.basename(name, '.*'))
      @file.last_revision = revision
      @file.save!
    end
    warning = nil
    if key.present?
      begin
        result = RedmineDmsf::OnlyOffice.command('meta', key: item.document_key, meta: { title: @file.name })
        warning = "ONLYOFFICE meta error #{result['error']}" unless result['error'].to_i.zero?
      rescue RedmineDmsf::OnlyOffice::Error => e
        warning = e.message
      end
    end
    render json: { title: @file.name, warning: warning }
  end

  def save_as
    source = @file.last_revision
    filename = DmsfOnlyofficeDocumentCreator.filename(params[:title], params[:file_type] || params[:fileType])
    tempfile = RedmineDmsf::OnlyOffice.download_to_tempfile(params.require(:url), max_bytes: max_bytes)
    created = DmsfOnlyofficeDocumentCreator.call(source: source, user: User.current, io: tempfile,
                                                filename: filename, folder: destination_folder,
                                                comment: "ONLYOFFICE copy of DMSF revision ##{source.id}")
    created_response(created, notify_hook: true)
  ensure
    tempfile&.close!
  end

  def destinations
    folders = []
    folders << { id: nil, name: l(:label_project) } if DmsfFolder.permissions?(nil, allow_system: true, file: true)
    DmsfFolder.visible.where(project_id: @project.id).order(:title).each do |folder|
      next unless DmsfFolder.permissions?(folder, allow_system: true, file: true)

      folders << { id: folder.id, name: folder.dmsf_path_str }
    end
    render json: { folders: folders }
  end

  def templates
    render json: { templates: available_templates.map { |revision| { id: revision.id, name: revision.name } } }
  end

  def publish_pdf
    operation = find_operation('pdf') do
      revision = @file.dmsf_file_revisions.visible.find(params[:revision_id].presence || @file.last_revision.id)
      raise RedmineDmsf::OnlyOffice::Error, 'The historical source is not accessible' unless
        revision.history_accessible_to?(User.current)
      raise RedmineDmsf::OnlyOffice::Error, 'Only an approved revision can be published as PDF' unless
        revision.workflow == DmsfWorkflow::STATE_APPROVED

      create_operation('pdf', revision, "#{File.basename(revision.name, '.*')}-r#{revision.id}.pdf")
    end
    run_operation(operation)
  end

  def create_from_template
    operation = find_operation('template') do
      template = available_templates.find { |revision| revision.id == params[:template_id].to_i }
      raise ActiveRecord::RecordNotFound unless template

      issue = permitted_issue
      filename = DmsfOnlyofficeDocumentCreator.filename(params[:title].presence || "#{@file.title}-copy", 'docx')
      fields = { 'project.id' => @project.id, 'project.name' => @project.name,
                 'author.name' => User.current.name, 'date' => Date.current.iso8601 }
      if issue
        fields.merge!('issue.id' => issue.id, 'issue.subject' => issue.subject, 'issue.description' => issue.description)
        issue.visible_custom_field_values(User.current).each do |value|
          fields["issue.cf.#{value.custom_field_id}"] = Array(value.value).join(', ')
        end
      end
      operation = create_operation('template', template, filename)
      operation.update!(parameters: { 'fields' => fields, 'issue_id' => issue&.id })
      operation
    end
    run_operation(operation)
  end

  # A short-lived purpose-bound token serves only a server-generated script, never user code.
  def builder_script
    previous_user = User.current
    claims = RedmineDmsf::OnlyOffice.decode_storage_token(params[:token], purpose: 'builder_script')
    operation = DmsfOnlyofficeOperation.find(claims.fetch('operation_id'))
    raise ActiveRecord::RecordNotFound unless operation.kind == 'template' && operation.state == 'pending' &&
                                             operation.user_id == claims['user_id'] &&
                                             operation.source_revision_id == claims['revision_id']

    User.current = operation.user
    validate_operation_access!(operation)
    source = operation.source_revision
    token = RedmineDmsf::OnlyOffice.storage_token(file: source.dmsf_file, revision: source, user: operation.user,
                                                  purpose: 'download')
    url = document_download_url(source, token)
    # Literal data is JSON encoded. The script has no user-provided executable fragments.
    script = <<~SCRIPT
      builder.OpenFile(#{url.to_json}, "");
      var fields = #{operation.parameters.fetch('fields', {}).to_json};
      var controls = Api.GetDocument().GetAllContentControls();
      for (var i = 0; i < controls.length; i++) {
        var tag = controls[i].GetTag();
        if (Object.prototype.hasOwnProperty.call(fields, tag)) {
          controls[i].RemoveAllElements();
          controls[i].AddText(String(fields[tag] == null ? "" : fields[tag]));
        }
      }
      builder.SaveFile("docx", "output.docx");
      builder.CloseFile();
    SCRIPT
    response.headers['Cache-Control'] = 'no-store'
    send_data script, filename: 'template.docbuilder', type: 'text/plain', disposition: 'attachment'
  rescue RedmineDmsf::OnlyOffice::InvalidToken
    render_404
  ensure
    User.current = previous_user
  end

  def users
    candidates = @project.users.active.select do |user|
      user.allowed_to?(:view_dmsf_files, @project) && folder_visible_to?(user)
    end
    # Opaque addresses avoid exposing project members' actual email addresses to the editor.
    render json: { users: candidates.map { |user| { id: user.id.to_s, name: user.name,
                                                   email: "dmsf-user-#{user.id}@redmine.invalid" } } }
  end

  def action_link
    render json: { url: document_action_link }
  end

  def notify
    return render_403 unless User.current.active? &&
                             (User.current.allowed_to?(:file_manipulation, @project) ||
                              User.current.allowed_to?(:comment_dmsf_files, @project) ||
                              User.current.allowed_to?(:review_dmsf_files, @project))

    ids = Array(params[:emails]).first(50).filter_map do |email|
      match = /\Admsf-user-(\d+)@redmine\.invalid\z/.match(email.to_s)
      match[1].to_i if match
    end
    recipients = @project.users.active.where(id: ids).select do |user|
      user.allowed_to?(:view_dmsf_files, @project) && folder_visible_to?(user)
    end
    message = params[:message].to_s.first(4000)
    link = document_action_link
    recipients.each do |recipient|
      DmsfOnlyofficeMailer.mention(recipient, User.current, @file, message, link).deliver_later
    end
    render json: { notified: recipients.size }
  end

  private

  def load_file
    return render_404 unless RedmineDmsf::OnlyOffice.enabled?

    @file = DmsfFile.visible.find(params[:id])
    @project = @file.project
    return if DmsfOnlyofficeSession.allowed_mode?(file: @file, user: User.current, mode: 'view')

    render_403
  end

  def require_file_writer
    render_403 unless User.current.active? && User.current.allowed_to?(:file_manipulation, @project)
  end

  def editing_session
    DmsfOnlyofficeSession.find_by!(dmsf_file_id: @file.id, document_key: params.require(:key))
  end

  def check_head!
    revision = @file.dmsf_file_revisions.visible.first
    unless revision && params[:expected_revision_id].to_i == revision.id
      raise RedmineDmsf::OnlyOffice::Error, 'The document changed; refresh before applying this operation'
    end
    raise RedmineDmsf::OnlyOffice::Error, 'The document is locked by another user' if @file.locked_for_user?

    revision
  end

  def destination_folder
    return @file.dmsf_folder unless params.key?(:folder_id)
    return nil if params[:folder_id].blank?

    folder = DmsfFolder.visible.find_by!(id: params[:folder_id], project_id: @project.id)
    raise RedmineDmsf::OnlyOffice::Error, 'The destination folder is not accessible' unless
      DmsfFolder.permissions?(folder, allow_system: true, file: true)

    folder
  end

  def available_templates
    DmsfFileRevision.visible.where(id: RedmineDmsf.onlyoffice_template_revision_ids).select do |revision|
      RedmineDmsf::OnlyOffice.extension(revision.name) == 'docx' && revision.file.attached? &&
        DmsfOnlyofficeSession.allowed_mode?(file: revision.dmsf_file, user: User.current, mode: 'view')
    end
  end

  def permitted_issue
    return nil if params[:issue_id].blank?

    Issue.visible(User.current).find_by!(id: params[:issue_id], project_id: @project.id)
  end

  def create_operation(kind, revision, filename)
    folder = destination_folder
    issue = permitted_issue
    folder = issue.system_folder(create: true) if issue
    DmsfFile.transaction do
      # Lock in stable ID order if a template belongs to another document/project.
      DmsfFile.where(id: [@file.id, revision.dmsf_file_id]).order(:id).lock.load
      revision.reload
      raise ActiveRecord::RecordNotFound unless revision.visible? && revision.file.attached?
      if kind == 'pdf' && revision.workflow != DmsfWorkflow::STATE_APPROVED
        raise RedmineDmsf::OnlyOffice::Error, 'The source revision is no longer approved'
      end
      DmsfOnlyofficeOperation.create!(kind: kind, request_key: SecureRandom.uuid, dmsf_file: @file,
                                      source_revision: revision, user: User.current, folder: folder,
                                      filename: filename, parameters: {})
    end
  end

  def find_operation(kind)
    return yield if params[:operation_id].blank?

    DmsfOnlyofficeOperation.find_by!(id: params[:operation_id], dmsf_file_id: @file.id,
                                     user_id: User.current.id, kind: kind)
  end

  def validate_operation_access!(operation)
    file = operation.dmsf_file
    source = operation.source_revision
    unless RedmineDmsf::OnlyOffice.enabled? && operation.user&.active? && file && !file.deleted? &&
           file.project.active? && DmsfOnlyofficeSession.folder_available?(operation.folder) &&
           (!operation.folder || (operation.folder.project_id == file.project_id && !operation.folder.locked_for_user?)) &&
           source&.visible? && !source.dmsf_file.deleted? &&
           DmsfOnlyofficeSession.allowed_mode?(file: source.dmsf_file, user: operation.user, mode: 'view') &&
           operation.user.allowed_to?(:file_manipulation, file.project) &&
           operation.user.allowed_to?(:view_dmsf_files, source.dmsf_file.project) &&
           DmsfFolder.permissions?(source.dmsf_file.dmsf_folder, allow_system: true, file: true) &&
           DmsfFolder.permissions?(file.dmsf_folder, allow_system: true, file: true) &&
           DmsfFolder.permissions?(operation.folder, allow_system: true, file: true)
      raise RedmineDmsf::OnlyOffice::Error, 'The operation is no longer authorized'
    end
    if operation.kind == 'template' && !RedmineDmsf.onlyoffice_template_revision_ids.include?(source.id)
      raise RedmineDmsf::OnlyOffice::Error, 'This template is no longer enabled'
    end
    if operation.kind == 'pdf' && source.workflow != DmsfWorkflow::STATE_APPROVED
      raise RedmineDmsf::OnlyOffice::Error, 'The source revision is no longer approved'
    end
    return unless operation.kind == 'pdf' && !source.history_accessible_to?(operation.user)

    raise RedmineDmsf::OnlyOffice::Error, 'The historical source is no longer accessible'
  end

  def run_operation(operation)
    return created_response(operation.result_file) if operation.finished?

    if operation.state == 'failed' || operation.created_at < 24.hours.ago
      operation.update_if_pending!(state: 'failed', last_error: 'The document operation expired; start a new operation')
      return created_response(operation.result_file) if operation.finished?

      raise RedmineDmsf::OnlyOffice::Error, operation.last_error
    end
    validate_operation_access!(operation)
    remote_started = true

    source = operation.source_revision
    if operation.kind == 'pdf'
      token = RedmineDmsf::OnlyOffice.storage_token(file: source.dmsf_file, revision: source,
                                                    user: User.current, purpose: 'download',
                                                    extra: { check_history_permission: true })
      result = RedmineDmsf::OnlyOffice.convert(async: true, key: "dmsf-pdf-#{operation.request_key}",
                                               filetype: RedmineDmsf::OnlyOffice.extension(source.name),
                                               outputtype: 'pdf', url: document_download_url(source, token))
      output_url = result['fileUrl'] if result['endConvert'] == true
    else
      token = RedmineDmsf::OnlyOffice.storage_token(file: source.dmsf_file, revision: source, user: User.current,
                                                    purpose: 'builder_script', extra: { operation_id: operation.id })
      script_url = dmsf_onlyoffice_builder_script_url(token: token, protocol: Setting.protocol, host: Setting.host_name)
      request = { async: true, url: RedmineDmsf::OnlyOffice.internal_redmine_url(script_url) }
      request[:key] = operation.remote_key if operation.remote_key.present?
      result = RedmineDmsf::OnlyOffice.build_document(request)
      operation.update_if_pending!(remote_key: result['key']) if result['key'].present?
      output_url = result['urls']&.fetch('output.docx', nil) if result['end'] == true
    end
    unless result['error'].to_i.zero?
      operation.update_if_pending!(state: 'failed', last_error: "ONLYOFFICE #{operation.kind} error #{result['error']}")
      raise RedmineDmsf::OnlyOffice::Error, "ONLYOFFICE #{operation.kind} error #{result['error']}"
    end
    completed = operation.kind == 'pdf' ? result['endConvert'] : result['end']
    unless [true, false].include?(completed)
      operation.update_if_pending!(state: 'failed', last_error: 'Invalid ONLYOFFICE document operation response')
      raise RedmineDmsf::OnlyOffice::Error, 'Invalid ONLYOFFICE document operation response'
    end
    if completed && output_url.blank?
      operation.update_if_pending!(state: 'failed',
                                   last_error: 'ONLYOFFICE completed without returning the generated file')
      raise RedmineDmsf::OnlyOffice::Error, 'ONLYOFFICE completed without returning the generated file'
    end
    return render json: { pending: true, operation_id: operation.id }, status: :accepted if output_url.blank?

    tempfile = RedmineDmsf::OnlyOffice.download_to_tempfile(output_url, max_bytes: max_bytes)
    created = nil
    operation.with_lock do
      unless operation.finished?
        raise RedmineDmsf::OnlyOffice::Error, 'The document operation is no longer pending' unless
          operation.state == 'pending'

        validate_operation_access!(operation)
        # Destination metadata follows the current project, while provenance identifies the exact source revision.
        created = DmsfOnlyofficeDocumentCreator.call(
          source: operation.dmsf_file.last_revision, user: User.current,
          io: tempfile, filename: operation.filename, folder: operation.folder, provenance: source,
          comment: "ONLYOFFICE #{operation.kind} from DMSF revision ##{source.id}"
        )
        operation.update!(state: 'completed', result_file: created, last_error: nil)
      end
    end
    created_response(operation.result_file, notify_hook: created.present?)
  rescue RedmineDmsf::OnlyOffice::Error => e
    # A transient HTTP/download failure still returns the durable operation ID,
    # allowing the browser to resume the same job rather than starting a duplicate.
    operation.reload
    return created_response(operation.result_file) if operation.finished?
    raise unless remote_started && operation.state == 'pending'

    operation.update_if_pending!(last_error: e.message)
    return created_response(operation.result_file) if operation.finished?
    raise unless operation.state == 'pending'

    render json: { pending: true, operation_id: operation.id, last_error: e.message }, status: :accepted
  rescue ActiveRecord::RecordInvalid => e
    operation.update_if_pending!(state: 'failed', last_error: e.message) if operation.persisted?
    return created_response(operation.result_file) if operation.finished?

    raise
  ensure
    tempfile&.close!
  end

  def document_download_url(revision, token)
    RedmineDmsf::OnlyOffice.internal_redmine_url(
      dmsf_onlyoffice_download_url(revision.dmsf_file, filename: revision.name, token: token,
                                   protocol: Setting.protocol, host: Setting.host_name)
    )
  end

  def document_action_link
    link = params[:action_link] || params[:actionLink] || {}
    link = link.to_unsafe_h if link.is_a?(ActionController::Parameters)
    raise RedmineDmsf::OnlyOffice::Error, 'Invalid document action link' unless link.is_a?(Hash) && link.to_json.bytesize <= 4096

    dmsf_onlyoffice_view_url(@file, action_link: link.to_json, protocol: Setting.protocol, host: Setting.host_name)
  end

  def folder_visible_to?(user)
    previous = User.current
    User.current = user
    DmsfOnlyofficeSession.folder_available?(@file.dmsf_folder) &&
      DmsfFolder.permissions?(@file.dmsf_folder, allow_system: true, file: true)
  ensure
    User.current = previous
  end

  def max_bytes
    value = Setting.attachment_max_size.to_i.kilobytes
    value.positive? ? value : nil
  end

  def created_response(file, notify_hook: false)
    raise ActiveRecord::RecordNotFound unless file && !file.deleted? &&
                                             DmsfOnlyofficeSession.allowed_mode?(file: file, user: User.current, mode: 'view')

    call_hook :dmsf_helper_upload_after_commit, { file: file } if notify_hook
    render json: { file_id: file.id, url: dmsf_file_path(file) }
  end

  def operation_error(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def missing_record
    render_404
  end
end
