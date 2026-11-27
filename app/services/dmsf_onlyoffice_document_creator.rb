# frozen_string_literal: true

# Creates an independent document; editor copies and recovered files never overwrite a head implicitly.
class DmsfOnlyofficeDocumentCreator
  def self.call(source:, user:, io:, filename:, folder: source.dmsf_file.dmsf_folder, comment: nil)
    previous_user = User.current
    User.current = user
    project = source.dmsf_file.project
    unless user.active? && user.allowed_to?(:file_manipulation, project) &&
           project.active? && (!folder || (folder.project_id == project.id && !folder.locked_for_user?)) &&
           DmsfOnlyofficeSession.folder_available?(folder) &&
           DmsfFolder.permissions?(folder, allow_system: true, file: true)
      raise RedmineDmsf::OnlyOffice::Error, 'You are not allowed to create a document in this folder'
    end

    DmsfFile.transaction do
      # Serialize same-project copies to preserve filename uniqueness under concurrent requests.
      project.lock!
      file = DmsfFile.create!(project: project, dmsf_folder: folder)
      revision = source.clone
      revision.dmsf_file = file
      revision.user = user
      revision.name = filename
      revision.title = File.basename(filename, '.*')
      revision.source_revision = source
      revision.onlyoffice_key = nil
      revision.major_version = 1
      revision.minor_version = 0
      revision.patch_version = nil
      revision.reset_workflow
      revision.comment = comment
      revision.size = io.size
      values = source.custom_field_values.to_h { |value| [value.custom_field_id.to_s, value.value] }
      revision.copy_custom_field_values(ActionController::Parameters.new(values), source)
      # Reject names, extensions, custom-field errors and size violations before uploading bytes.
      raise ActiveRecord::RecordInvalid, revision unless revision.valid?

      io.rewind
      blob = DmsfOnlyofficeBlob.upload!(
        io: io, filename: filename, content_type: Redmine::MimeType.of(filename) || 'application/octet-stream',
        identify: false
      )
      revision.shared_file.attach(blob)
      revision.save!
      file.last_revision = revision
      file.save!
      file
    end
  ensure
    User.current = previous_user
  end

  def self.filename(title, extension)
    ext = extension.to_s.delete_prefix('.').downcase
    unless RedmineDmsf::OnlyOffice::VIEWABLE_EXTENSIONS.include?(ext)
      raise RedmineDmsf::OnlyOffice::Error, 'Unsupported document format'
    end
    name = title.to_s.strip
    if name.blank? || name.match?(/[\x00-\x1f\/\\]/) || %w[. ..].include?(name)
      raise RedmineDmsf::OnlyOffice::Error, 'Invalid document filename'
    end

    name = "#{name}.#{ext}" unless File.extname(name).casecmp?(".#{ext}")
    raise RedmineDmsf::OnlyOffice::Error, 'The filename is too long' if name.length > 255

    name
  end

  # Forgotten responses have no filetype field. Recognize common assembled
  # containers instead of blindly labelling a converted DOCX as the source ODT.
  def self.detect_extension(io, default:)
    io.rewind
    header = io.read(8).to_s
    return 'pdf' if header.start_with?('%PDF-')
    return default unless header.start_with?('PK') && io.respond_to?(:path)

    Zip::File.open(io.path) do |zip|
      if zip.find_entry('word/document.xml')
        return zip.find_entry('word/vbaProject.bin') ? 'docm' : 'docx'
      end
      if zip.find_entry('xl/workbook.xml')
        return zip.find_entry('xl/vbaProject.bin') ? 'xlsm' : 'xlsx'
      end
      return 'xlsb' if zip.find_entry('xl/workbook.bin')
      if zip.find_entry('ppt/presentation.xml')
        return zip.find_entry('ppt/vbaProject.bin') ? 'pptm' : 'pptx'
      end
      return 'vsdx' if zip.find_entry('visio/document.xml')

      mime = zip.find_entry('mimetype')
      if mime && mime.size < 200
        types = { 'application/vnd.oasis.opendocument.text' => 'odt',
                  'application/vnd.oasis.opendocument.spreadsheet' => 'ods',
                  'application/vnd.oasis.opendocument.presentation' => 'odp' }
        return types.fetch(mime.get_input_stream.read.strip, default)
      end
    end
    default
  rescue Zip::Error
    default
  ensure
    io.rewind
  end
end
