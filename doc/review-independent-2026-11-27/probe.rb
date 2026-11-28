# Run with rails runner against the existing disposable qa_r3 database only.
# Controller methods and their authorization filters are invoked directly;
# presentation and ONLYOFFICE transport are replaced, not permission checks.
require 'stringio'
require 'tmpdir'
require 'json'
require 'action_dispatch/testing/test_request'

raise 'Use qa_r3, never the application database' unless
  ActiveRecord::Base.connection_db_config.database == 'qa_r3'

Rails.logger.level = Logger::ERROR
storage = ActiveStorage::Blob.service
raise 'Expected Disk storage' unless storage.is_a?(ActiveStorage::Service::DiskService)
original_root = storage.root
probe_root = Dir.mktmpdir('dmsf-independent-review-')
storage.instance_variable_set(:@root, probe_root)
ActionMailer::Base.perform_deliveries = false

def report(id, values)
  puts "PROBE #{id}: #{values.to_json}"
end

def controller(klass, parameters)
  instance = klass.new
  instance.set_request!(ActionDispatch::TestRequest.create)
  instance.params = ActionController::Parameters.new(parameters)
  instance.define_singleton_method(:render) { |**options| @probe_response = options }
  instance.define_singleton_method(:redirect_to) { |*args| @probe_redirect = args }
  instance.define_singleton_method(:flash) { @probe_flash ||= {} }
  instance
end

def document(project, user, name, bytes)
  file = DmsfFile.create!(project: project)
  revision = DmsfFileRevision.new(dmsf_file: file, user: user, name: name,
                                 title: name, major_version: 1, minor_version: 0, size: bytes.bytesize)
  blob = DmsfOnlyofficeBlob.upload!(io: StringIO.new(bytes), filename: name,
                                   content_type: Redmine::MimeType.of(name), identify: false)
  revision.shared_file.attach(blob)
  revision.save!
  [file, revision]
end

module ProbeTransport
  def convert(parameters)
    $probe_conversion = parameters
    { 'error' => 0, 'endConvert' => false }
  end

  def command(command, **parameters)
    raise "Unexpected command #{command}" unless command == 'getForgotten'
    { 'error' => 0, 'url' => 'https://office.example.test/forgotten.pdf' }
  end

  def download_to_tempfile(url, **parameters)
    raise 'Unexpected download' unless url == 'https://office.example.test/forgotten.pdf'
    io = Tempfile.new(['independent-forgotten-', '.pdf'])
    io.binmode
    io.write('%PDF-1.7 Filled personal data')
    io.rewind
    io
  end
end
RedmineDmsf::OnlyOffice.singleton_class.prepend(ProbeTransport)

before = [DmsfFile.count, DmsfFileRevision.count, DmsfOnlyofficeSession.count, DmsfOnlyofficeOperation.count]
ActiveRecord::Base.transaction do
  setting = Setting.find_or_initialize_by(name: 'plugin_redmine_dmsf')
  settings = Setting.plugin_redmine_dmsf.to_h.merge(
    'dmsf_onlyoffice_document_server_url' => 'https://office.example.test',
    'dmsf_minor_revision_retention_enabled' => '0'
  )
  setting.write_attribute(:value, settings.to_yaml)
  setting.save!
  Setting.clear_cache
  project = Project.find(1)
  project.enable_module!(:dmsf)
  author = User.find_by!(login: 'jsmith')
  raise 'Expected a non-admin author' if author.admin?
  author.roles_for_project(project).each do |role|
    role.remove_permission!(:view_dmsf_file_revisions)
    role.add_permission!(:view_dmsf_files)
    role.add_permission!(:file_manipulation)
  end
  author = User.find(author.id)
  User.current = author

  # N1: a writer denied historical revisions can request conversion of one.
  file, old = document(project, author, "review-#{SecureRandom.hex(6)}.docx", 'OLD confidential content')
  old.update!(workflow: DmsfWorkflow::STATE_APPROVED)
  newer = old.clone
  newer.minor_version = 1
  newer.reset_workflow
  newer.save!
  actions = controller(DmsfOnlyofficeActionsController, id: file.id, revision_id: old.id)
  actions.send(:load_file)
  actions.send(:require_file_writer)
  raise 'Unexpected authorization rejection' if actions.instance_variable_get(:@probe_response)
  history = controller(DmsfOnlyofficeHistoryController, id: file.id)
  history_allowed = history.send(:history_allowed?, DmsfFile.find(file.id))
  actions.publish_pdf
  claims = RedmineDmsf::OnlyOffice.decode_storage_token(
    URI.decode_www_form(URI.parse($probe_conversion.fetch(:url)).query).to_h.fetch('token'), purpose: 'download'
  )
  download_token = URI.decode_www_form(URI.parse($probe_conversion.fetch(:url)).query).to_h.fetch('token')
  download = controller(DmsfOnlyofficeController, id: file.id, token: download_token)
  download.set_response!(ActionDispatch::Response.new)
  download.define_singleton_method(:send_file) { |path, **options| @probe_bytes = File.binread(path) }
  download.send(:require_onlyoffice)
  download.download
  report('N1', history_allowed: history_allowed,
               can_write: author.allowed_to?(:file_manipulation, project),
               old_revision: old.id, head: newer.id,
               conversion_revision: claims['revision_id'], served_bytes: download.instance_variable_get(:@probe_bytes),
               response: actions.instance_variable_get(:@probe_response))

  # N2: forgotten content from a fill-only session bypasses form restoration isolation.
  admin = User.find_by!(login: 'admin')
  User.current = admin
  template, base = document(project, admin, "form-#{SecureRandom.hex(6)}.pdf", '%PDF-1.7 Blank template')
  session = DmsfOnlyofficeSession.register!(file: template, revision: base, user: admin,
                                          mode: 'fill', document_key: "review-fill-#{SecureRandom.uuid}")
  recovery_admin = controller(DmsfOnlyofficeAdminController, session_id: session.id)
  recovery_admin.send(:require_admin)
  recovery_admin.recover_forgotten
  receipt = session.recoveries.first!
  recovery_controller = controller(DmsfOnlyofficeRecoveryController,
    id: template.id, recovery_id: receipt.id, expected_revision_id: base.id)
  recovery_controller.send(:load_file)
  recovery_controller.send(:load_recovery)
  raise 'Unexpected recovery authorization rejection' if recovery_controller.instance_variable_get(:@probe_response)
  recovery_controller.restore
  head = DmsfFile.find(template.id).last_revision
  report('N2', mode: session.mode, recovery_kind: receipt.kind,
               template_revision: base.id, head_after_restore: head.id,
               template_head_bytes: head.file.download, restored_revision: receipt.reload.restored_revision_id)

  raise ActiveRecord::Rollback
end
after = [DmsfFile.count, DmsfFileRevision.count, DmsfOnlyofficeSession.count, DmsfOnlyofficeOperation.count]
report('ROLLBACK', unchanged_counts: before == after)

# N3: failure during upload occurs before the cleanup record is registered.
module ProbeBrokenUpload
  def upload(key, io, **options)
    super
    $probe_failed_key = key
    raise IOError, 'Simulated storage failure after bytes are written'
  end
end
storage.singleton_class.prepend(ProbeBrokenUpload)
begin
  DmsfOnlyofficeBlob.upload!(io: StringIO.new('orphan bytes'), filename: 'failed.txt', identify: false)
rescue IOError
  report('N3', blob_row_exists: ActiveStorage::Blob.exists?(key: $probe_failed_key),
               orphan_bytes_exist: storage.exist?($probe_failed_key))
ensure
  storage.delete($probe_failed_key) if $probe_failed_key
  storage.instance_variable_set(:@root, original_root)
  Setting.clear_cache
  User.current = nil
end
puts 'PROBE COMPLETE'
