# frozen_string_literal: true

# Recovery copies have their own lifetime and are never part of minor-revision retention.
class DmsfOnlyofficeRecoveryController < ApplicationController
  menu_item :dmsf
  before_action :load_file
  before_action :load_recovery, except: :index

  rescue_from RedmineDmsf::OnlyOffice::Error, ActiveRecord::RecordInvalid, with: :operation_error

  def index
    scope = DmsfOnlyofficeRecovery.joins(:dmsf_onlyoffice_session)
                                 .where(dmsf_onlyoffice_sessions: { dmsf_file_id: @file.id })
    @page = [params[:page].to_i, 1].max
    @total = scope.count
    @recoveries = scope.order(created_at: :desc).offset((@page - 1) * 50).limit(50)
  end

  def download
    response.headers['Cache-Control'] = 'no-store'
    @recovery.payload.open do |io|
      send_data io.read, filename: @recovery.filename, type: @recovery.content_type,
                        disposition: 'attachment'
    end
  end

  def restore
    return render_403 unless User.current.allowed_to?(:file_manipulation, @project)
    with_recovery_lock do
      # Check under the session lock: a submission can arrive during recovery.
      raise RedmineDmsf::OnlyOffice::Error, 'Save this form as a new document' if @recovery.form_submission?

      unless @recovery.restored_revision_id
        source = @file.dmsf_file_revisions.visible.first
        @recovery.payload.open do |io|
          revision = DmsfOnlyofficeRevisionWriter.call(
            file: @file, source: source, user: User.current, io: io,
            filename: @recovery.filename, content_type: @recovery.content_type,
            comment: "Recovered ONLYOFFICE #{@recovery.kind} ##{@recovery.id}",
            expected_revision_id: params.require(:expected_revision_id).to_i
          )
          @recovery.update!(state: 'imported', restored_revision_id: revision.id)
        end
      end
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to dmsf_file_path(@file)
  end

  def save_copy
    return render_403 unless User.current.allowed_to?(:file_manipulation, @project)

    with_recovery_lock do
      unless @recovery.restored_revision_id
        filename = DmsfOnlyofficeDocumentCreator.filename(
          params[:title].presence || "recovered-#{@recovery.id}-#{@recovery.filename}",
          RedmineDmsf::OnlyOffice.extension(@recovery.filename)
        )
        @recovery.payload.open do |io|
          created = DmsfOnlyofficeDocumentCreator.call(source: @file.dmsf_file_revisions.visible.first, user: User.current,
                                                       io: io, filename: filename,
                                                       comment: "Recovered ONLYOFFICE #{@recovery.kind} ##{@recovery.id}")
          @recovery.update!(state: 'imported', restored_revision_id: created.last_revision.id)
        end
      end
    end
    revision = DmsfFileRevision.find_by(id: @recovery.restored_revision_id)
    redirect_to dmsf_file_path(revision&.dmsf_file || @file)
  end

  # Explicitly apply only the administrator's allowlisted fields, with Redmine's issue permissions and journaling.
  def apply_form
    raise RedmineDmsf::OnlyOffice::Error, 'This recovery does not contain submitted form data' unless
      @recovery.kind == 'form'

    issue = Issue.visible(User.current).find_by!(id: params[:issue_id], project_id: @project.id)
    return render_403 unless User.current.allowed_to?(:edit_issues, @project) && issue.editable?(User.current)

    updates = mapped_form_fields(issue)
    raise RedmineDmsf::OnlyOffice::Error, 'No editable mapped fields were present in this form' if updates.empty?

    issue.with_lock do
      raise RedmineDmsf::OnlyOffice::Error, 'The issue changed; reload before importing the form' unless
        issue.lock_version == params.require(:lock_version).to_i

      issue.init_journal(User.current, "ONLYOFFICE form submission ##{@recovery.id}")
      issue.safe_attributes = { 'custom_field_values' => updates }
      issue.save!
    end
    flash[:notice] = l(:notice_successful_update)
    redirect_to issue_path(issue)
  end

  def form_preview
    raise RedmineDmsf::OnlyOffice::Error, 'This recovery does not contain submitted form data' unless
      @recovery.kind == 'form'

    @issue = Issue.visible(User.current).find_by!(id: params[:issue_id], project_id: @project.id)
    return render_403 unless User.current.allowed_to?(:edit_issues, @project) && @issue.editable?(User.current)

    @updates = mapped_form_fields(@issue)
  end

  private

  def with_recovery_lock(&block)
    # Match callback publication: file, session, recovery. All collaborators use
    # the same lock order, including an administrator restoring a working copy.
    @file.with_lock do
      @recovery.dmsf_onlyoffice_session.with_lock do
        @recovery.with_lock(&block)
      end
    end
  end

  def load_file
    return render_404 unless RedmineDmsf::OnlyOffice.enabled?

    @file = DmsfFile.visible.find(params[:id])
    @project = @file.project
    return if User.current.active? && DmsfOnlyofficeSession.allowed_mode?(file: @file, user: User.current, mode: 'view') &&
              User.current.allowed_to?(:file_manipulation, @project) &&
              DmsfFolder.permissions?(@file.dmsf_folder, allow_system: true, file: true)

    render_403
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def load_recovery
    @recovery = DmsfOnlyofficeRecovery.joins(:dmsf_onlyoffice_session)
                                     .where(dmsf_onlyoffice_sessions: { dmsf_file_id: @file.id })
                                     .find(params[:recovery_id])
    raise ActiveRecord::RecordNotFound unless @recovery.payload.attached?
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def form_values(data)
    items = data.is_a?(Hash) ? (data['forms'] || data['data']) : data
    return {} unless items.is_a?(Array)

    items.first(1000).each_with_object({}) do |item, result|
      next unless item.is_a?(Hash) && item['key'].is_a?(String)
      value = item['value']
      next unless value.is_a?(String) || value.is_a?(Numeric) || [true, false].include?(value)

      result[item['key']] = value.to_s.first(10_000)
    end
  end

  def mapped_form_fields(issue)
    values = form_values(@recovery.metadata['forms_data'])
    editable_ids = issue.editable_custom_field_values(User.current).map(&:custom_field_id)
    RedmineDmsf.onlyoffice_form_field_mapping.each_with_object({}) do |(key, id), fields|
      fields[id.to_s] = values[key] if values.key?(key) && editable_ids.include?(id.to_i)
    end
  end

  def operation_error(error)
    flash[:error] = error.message
    redirect_to dmsf_onlyoffice_recovery_path(@file)
  end
end
