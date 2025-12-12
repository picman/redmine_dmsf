# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Vít Jonáš <vit.jonas@gmail.com>, Karel Pičman <karel.picman@kontron.com>
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

require "#{File.dirname(__FILE__)}/../../lib/redmine_dmsf/lockable"
require "#{File.dirname(__FILE__)}/../../lib/redmine_dmsf/plugin"
require 'English'

# File
class DmsfFile < ApplicationRecord
  include RedmineDmsf::Lockable

  belongs_to :project
  belongs_to :dmsf_folder
  belongs_to :deleted_by_user, class_name: 'User'

  has_many :dmsf_file_revisions, -> { order(created_at: :desc, id: :desc) }, dependent: :destroy, inverse_of: :dmsf_file
  has_many :locks, -> { where(entity_type: 0).order(updated_at: :desc) },
           class_name: 'DmsfLock', foreign_key: 'entity_id', dependent: :destroy, inverse_of: :dmsf_file
  has_many :referenced_links, -> { where target_type: DmsfFile.model_name.to_s },
           class_name: 'DmsfLink', foreign_key: 'target_id', dependent: :destroy, inverse_of: false
  has_many :dmsf_public_urls, dependent: :destroy

  STATUS_DELETED = 1
  STATUS_ACTIVE = 0

  scope :visible, -> { where(deleted: STATUS_ACTIVE) }
  scope :deleted, -> { where(deleted: STATUS_DELETED) }

  acts_as_event(
    title: proc { |o|
      @searched_revision = nil
      o.dmsf_file_revisions.visible.each do |r|
        key = "DmsfFile-#{o.id}-#{r.id}"
        @desc = Redmine::Search.cache_store.fetch(key)
        next unless @desc

        Redmine::Search.cache_store.delete key
        @searched_revision = r
        break
      end
      if @searched_revision && (@searched_revision != o.last_revision)
        "#{o.name} (r#{@searched_revision.id})"
      else
        o.name
      end
    },
    description: proc { |o|
      unless @desc
        # Set desc to an empty string if o.description is nil
        @desc = o.description.nil? ? +'' : +o.description
        @desc += ' / ' if o.description.present? && o.last_revision.comment.present?
        @desc += o.last_revision.comment if o.last_revision.comment.present?
      end
      @desc
    },
    url: proc { |o|
      if @searched_revision
        { controller: 'dmsf_files', action: 'view', id: o.id, download: @searched_revision.id,
          filename: @searched_revision.name }
      else
        { controller: 'dmsf_files', action: 'view', id: o.id, filename: o.name }
      end
    },
    datetime: proc { |o|
      if @searched_revision
        @searched_revision.updated_at
      else
        o.updated_at
      end
    },
    author: proc { |o|
      if @searched_revision
        @searched_revision.user
      else
        o.last_revision.user
      end
    }
  )
  acts_as_watchable
  acts_as_searchable(
    columns: [
      "#{DmsfFileRevision.table_name}.name",
      "#{DmsfFileRevision.table_name}.title",
      "#{DmsfFileRevision.table_name}.description",
      "#{DmsfFileRevision.table_name}.comment"
    ],
    project_key: 'project_id',
    date_column: "#{table_name}.updated_at"
  )

  before_create :default_values
  before_destroy :delete_system_folder_before
  after_destroy :delete_system_folder_after

  attr_writer :last_revision

  def self.previews_storage_path
    Rails.root.join 'tmp/dmsf_previews'
  end

  def default_values
    return unless RedmineDmsf.dmsf_default_notifications? && (!dmsf_folder || !dmsf_folder.system)

    self.notification = true
  end

  def initialize(*args)
    super
    self.watcher_user_ids = [] if new_record?
  end

  def self.storage_path
    path = RedmineDmsf.dmsf_storage_directory
    pn = Pathname.new(path)
    return pn if pn.absolute?

    Rails.root.join path
  end

  def self.find_file_by_name(project, folder, name)
    dmsf_files = visible.where(dmsf_files: { project_id: project&.id, dmsf_folder_id: folder&.id })
    dmsf_files.each do |file|
      return file if file.name == name
    end
    nil
  end

  def self.find_file_by_title(project, folder, name)
    dmsf_files = visible.where(dmsf_files: { project_id: project&.id, dmsf_folder_id: folder&.id })
    dmsf_files.each do |file|
      return file if file.title == name
    end
    nil
  end

  def approval_allowed_zero_minor
    RedmineDmsf.only_approval_zero_minor_version? ? last_revision.minor_version&.zero? : true
  end

  def last_revision
    @last_revision ||= deleted? ? dmsf_file_revisions.first : dmsf_file_revisions.visible.first
  end

  def deleted?
    deleted == STATUS_DELETED
  end

  def locked_by
    if lock && lock.reverse[0]
      user = lock.reverse[0].user
      return user == User.current ? l(:label_me) : user.name if user
    end
    ''
  end

  def delete(commit: false)
    if locked_for_user? && !User.current.allowed_to?(:force_file_unlock, project)
      Rails.logger.info l(:error_file_is_locked)
      if lock.reverse[0].user
        errors.add :base, l(:title_locked_by_user, user: lock.reverse[0].user)
      else
        errors.add :base, l(:error_file_is_locked)
      end
      return false
    end
    begin
      if commit
        destroy
      else
        self.deleted = STATUS_DELETED
        self.deleted_by_user = User.current
        save
        # Associated revisions should be marked as deleted too
        dmsf_file_revisions.each { |r| r.delete(commit: commit, force: true) }
      end
    rescue StandardError => e
      Rails.logger.error e.message
      errors.add :base, e.message
      false
    end
  end

  def restore
    if dmsf_folder_id && (dmsf_folder.nil? || dmsf_folder.deleted?)
      errors.add(:base, l(:error_parent_folder))
      return false
    end
    dmsf_file_revisions.each(&:restore)
    self.deleted = STATUS_ACTIVE
    self.deleted_by_user = nil
    save
  end

  def name
    last_revision&.name.to_s
  end

  def title
    last_revision&.title.to_s
  end

  def description
    last_revision&.description.to_s
  end

  def version
    last_revision&.version.to_s
  end

  def workflow
    last_revision&.workflow
  end

  def size
    last_revision&.size.to_i
  end

  def dmsf_path
    path = dmsf_folder ? dmsf_folder.dmsf_path : []
    path.push self
    path
  end

  def dmsf_path_str
    dmsf_path.map(&:title).join('/')
  end

  def notify?
    notification || dmsf_folder&.notify? || (!dmsf_folder && project.dmsf_notification)
  end

  def get_all_watchers(watchers)
    watchers.concat notified_watchers
    if dmsf_folder
      watchers.concat dmsf_folder.notified_watchers
    else
      watchers.concat project.notified_watchers
    end
  end

  def notify_deactivate
    self.notification = nil
    save!
  end

  def notify_activate
    self.notification = true
    save!
  end

  # Returns an array of projects that current user can copy file to
  def self.allowed_target_projects_on_copy
    projects = []
    if User.current.admin?
      projects = Project.visible.has_module('dmsf').all
    elsif User.current.logged?
      User.current.memberships.each do |m|
        projects << m.project if m.project.module_enabled?('dmsf') &&
                                 m.roles.detect { |r| r.allowed_to?(:file_manipulation) }
      end
    end
    projects
  end

  def move_to(project, folder)
    unless last_revision
      errors.add :base, l(:error_at_least_one_revision_must_be_present)
      Rails.logger.error l(:error_at_least_one_revision_must_be_present)
      return false
    end
    source = "#{self.project.identifier}:#{dmsf_path_str}"
    self.project = project
    self.dmsf_folder = folder
    new_revision = last_revision.clone
    new_revision.user_id = last_revision.user_id
    new_revision.workflow = nil
    new_revision.dmsf_workflow_id = nil
    new_revision.dmsf_workflow_assigned_by_user_id = nil
    new_revision.dmsf_workflow_assigned_at = nil
    new_revision.dmsf_workflow_started_by_user_id = nil
    new_revision.dmsf_workflow_started_at = nil
    new_revision.dmsf_file = self
    new_revision.comment = l(:comment_moved_from, source: source)
    new_revision.custom_values = []
    last_revision.custom_values.each do |cv|
      new_revision.custom_values << CustomValue.new({ custom_field: cv.custom_field, value: cv.value })
    end
    self.last_revision = new_revision
    save && new_revision.save
  end

  def copy_to(project, folder = nil)
    copy_to_filename project, folder, name
  end

  def copy_to_filename(project, folder, filename)
    file = DmsfFile.new
    file.dmsf_folder_id = folder.id if folder
    file.project_id = project.id
    file.notification = RedmineDmsf.dmsf_default_notifications?
    if file.save && last_revision
      new_revision = last_revision.clone
      new_revision.name = filename
      new_revision.title = File.basename(filename, '.*')
      new_revision.dmsf_file = file
      # Assign the same workflow if it's a global one, or we are in the same project
      new_revision.workflow = nil
      new_revision.dmsf_workflow_id = nil
      new_revision.dmsf_workflow_assigned_by_user_id = nil
      new_revision.dmsf_workflow_assigned_at = nil
      new_revision.dmsf_workflow_started_by_user_id = nil
      new_revision.dmsf_workflow_started_at = nil
      wf = last_revision.dmsf_workflow
      if wf && (wf.project.nil? || (wf.project.id == project.id))
        new_revision.set_workflow wf.id, nil
        new_revision.assign_workflow wf.id
      end
      if last_revision.file.attached?
        begin
          new_revision.shared_file.attach(
            io: StringIO.new(last_revision.file.download),
            filename: filename,
            content_type: new_revision.file.content_type,
            identify: false
          )
        rescue ActiveStorage::FileNotFoundError => e
          Rails.logger.error e
        end
      end
      new_revision.comment = l(:comment_copied_from, source: "#{self.project.identifier}:#{dmsf_path_str}")
      new_revision.custom_values = []
      last_revision.custom_values.each do |cv|
        v = CustomValue.new
        v.custom_field = cv.custom_field
        v.value = cv.value
        new_revision.custom_values << v
      end
      # Check the name and title
      basename = File.basename(filename, '.*')
      extname = File.extname(filename)
      i = 1
      while new_revision.invalid? && i < 1_000
        new_revision.title = "#{basename} (#{i})"
        new_revision.name = "#{new_revision.title}#{extname}"
        i += 1
      end
      if new_revision.save
        file.last_revision = new_revision
      else
        Rails.logger.error new_revision.errors.full_messages.to_sentence
        file.delete commit: true
        file = nil
      end
    else
      Rails.logger.error file.errors.full_messages.to_sentence
      file.delete commit: true
      file = nil
    end
    file
  end

  # To fulfill searchable module expectations
  def self.search(tokens, projects = nil, options = {}, user = User.current)
    tokens = [] << tokens unless tokens.is_a?(Array)
    projects = [] << projects if projects.is_a?(Project)
    project_ids = projects.collect(&:id) if projects
    limit_options = ["dmsf_files.updated_at #{options[:before] ? '<' : '>'} ?", options[:offset]] if options[:offset]
    columns = if options[:titles_only]
                [searchable_options[:columns][1]]
              else
                searchable_options[:columns]
              end

    token_clauses = columns.collect { |column| "(LOWER(#{column}) LIKE ?)" }

    sql = (["(#{token_clauses.join(' OR ')})"] * tokens.size).join(options[:all_words] ? ' AND ' : ' OR ')
    find_options = [sql, * (tokens.collect { |w| "%#{w.downcase}%" } * token_clauses.size).sort]

    project_conditions = []
    project_conditions << Project.allowed_to_condition(user, :view_dmsf_files)
    project_conditions << "#{Project.table_name}.id IN (#{project_ids.join(',')})" if project_ids.present?

    scope = visible
            .joins('JOIN dmsf_file_revisions ON dmsf_file_revisions.dmsf_file_id = dmsf_files.id')
            .joins(:project)
    scope = scope.limit(options[:limit]) if options[:limit].present?
    scope = scope.where(limit_options) if limit_options.present?
    scope = scope.where(project_conditions.join(' AND '))
    results = scope.where(find_options).uniq.to_a
    results.delete_if { |x| !DmsfFolder.permissions?(x.dmsf_folder) }

    if !options[:titles_only] && RedmineDmsf.xapian_available
      database = nil
      begin
        lang = RedmineDmsf.dmsf_stemming_lang
        databasepath = File.join(RedmineDmsf.dmsf_index_database, lang)
        database = Xapian::Database.new(databasepath)
      rescue StandardError => e
        Rails.logger.error "REDMINE_XAPIAN ERROR: Xapian database is not properly set, initiated or it's corrupted."
        Rails.logger.error e.message
      end

      if database
        enquire = Xapian::Enquire.new(database)

        # Combine the rest of the command line arguments with spaces between
        # them, so that simple queries don't have to be quoted at the shell
        # level.
        query_string = tokens.map { |x| x[-1, 1].eql?('*') ? x : "#{x}*" }.join(' ')
        qp = Xapian::QueryParser.new
        stemmer = Xapian::Stem.new(lang)
        qp.stemmer = stemmer
        qp.database = database

        case RedmineDmsf.dmsf_stemming_strategy
        when 'STEM_NONE'
          qp.stemming_strategy = Xapian::QueryParser::STEM_NONE
        when 'STEM_SOME'
          qp.stemming_strategy = Xapian::QueryParser::STEM_SOME
        when 'STEM_ALL'
          qp.stemming_strategy = Xapian::QueryParser::STEM_ALL
        end

        qp.default_op = if options[:all_words]
                          Xapian::Query::OP_AND
                        else
                          Xapian::Query::OP_OR
                        end

        flags = Xapian::QueryParser::FLAG_WILDCARD
        flags |= Xapian::QueryParser::FLAG_CJK_NGRAM if RedmineDmsf.dmsf_enable_cjk_ngrams?

        query = qp.parse_query(query_string, flags)

        enquire.query = query
        matchset = enquire.mset(0, 1000)

        matchset&.matches&.each do |m|
          docdata = m.document.data
          dochash = Hash[*docdata.scan(%r{(url|sample|modtime|author|type|size)=/?([^\n\]]+)}).flatten]
          next unless dochash['url'] =~ %r{^\w{2}/\w{2}/(\w+)$} # /76/df/76dfsp2ubbgq4yvq90zrfoyxt012

          key = Regexp.last_match(1)
          blob = ActiveStorage::Blob.find_by(key: key)
          attachment = blob&.attachments&.first
          dmsf_file_revision = attachment&.record

          next unless dmsf_file_revision

          dmsf_file = dmsf_file_revision.dmsf_file
          next unless dmsf_file && DmsfFolder.permissions?(dmsf_file.dmsf_folder) &&
                      user.allowed_to?(:view_dmsf_files, dmsf_file.project) &&
                      (project_ids.blank? || project_ids.include?(dmsf_file.project_id))

          if dochash['sample']
            Redmine::Search.cache_store.write("DmsfFile-#{dmsf_file.id}-#{dmsf_file_revision.id}",
                                              dochash['sample'].force_encoding('UTF-8'))
          end
          break if options[:limit].present? && results.count >= options[:limit]

          results << dmsf_file
        end
      end
    end

    [results, results.count]
  end

  def self.search_result_ranks_and_ids(tokens, user = User.current, projects = nil, options = {})
    r = search(tokens, projects, options, user)[0]
    r.map { |f| [f.updated_at.to_i, f.id] }
  end

  def display_name
    member = Member.find_by(user_id: User.current.id, project_id: project_id)
    fname = formatted_name(member)
    return "#{fname[0, 25]}...#{fname[-25, 25]}" if fname.length > 50

    fname
  end

  def text?
    return false unless last_revision

    filename = last_revision.file&.blob&.filename.to_s
    last_revision.file&.blob&.text? || Redmine::SyntaxHighlighting.filename_supported?(filename)
  end

  def image?
    last_revision && last_revision.file&.blob&.image?
  end

  def pdf?
    last_revision&.content_type == 'application/pdf'
  end

  def video?
    return false unless last_revision

    Redmine::MimeType.is_type?('video', last_revision.file.blob&.filename&.to_s)
  end

  def html?
    last_revision&.content_type == 'text/html'
  end

  def office_doc?
    return false unless last_revision

    case File.extname(last_revision.file.blob&.filename&.to_s)
    when  '.odt', '.ods', '.odp', '.odg', # LibreOffice
          '.doc', '.docx', '.docm', '.xls', '.xlsx', '.xlsm', '.ppt', '.pptx', '.pptm', # MS Office
          '.rtf' # Universal
      true
    else
      false
    end
  end

  def markdown?
    last_revision&.content_type == 'text/markdown'
  end

  def textile?
    last_revision&.content_type == 'text/textile'
  end

  def disposition
    image? || pdf? || video? || html? ? 'inline' : 'attachment'
  end

  def thumbnailable?
    Redmine::Thumbnail.convert_available? && (image? || (pdf? && Redmine::Thumbnail.gs_available?))
  end

  def previewable?
    office_doc? && RedmineDmsf::Preview.office_available? && size <= Setting.file_max_size_displayed.to_i.kilobyte
  end

  # Deletes all previews
  def self.clear_previews
    Dir.glob(File.join(DmsfFile.previews_storage_path, '*.pdf')).each do |file|
      File.delete file
    end
  end

  def pdf_preview
    return '' unless previewable?

    target = File.join(DmsfFile.previews_storage_path, "#{last_revision.file.blob.key}.pdf")
    begin
      last_revision.file.open do |f|
        RedmineDmsf::Preview.generate f.path, target
      end
    rescue StandardError => e
      Rails.logger.error do
        %(An error occurred while generating preview for #{name} to #{target}\nException was: #{e.message})
      end
      ''
    end
  end

  def text_preview(limit)
    result = +'No preview available'
    if text?
      begin
        last_revision.file.open do |f|
          f.each_line do |line|
            case f.lineno
            when 1
              result = line
            when limit.to_i + 1
              break
            else
              result << line
            end
          end
        end
      rescue StandardError => e
        result = e.message
      end
    end
    result
  end

  def formatted_name(member)
    last_revision&.formatted_name(member)
  end

  def owner?(user)
    last_revision&.user == user
  end

  def involved?(user)
    dmsf_file_revisions.each do |file_revision|
      return true if file_revision.user == user
    end
    false
  end

  def assigned?(user)
    return false unless last_revision&.dmsf_workflow

    last_revision.dmsf_workflow.next_assignments(last_revision.id).each do |assignment|
      return true if assignment.user == user
    end
    false
  end

  def custom_value(custom_field)
    return nill unless last_revision

    last_revision.custom_field_values.each do |cv|
      return cv if cv.custom_field == custom_field
    end
    nil
  end

  def thumbnail(options = {})
    size = options[:size].to_i
    if size.positive?
      # Limit the number of thumbnails per image
      size = (size / 50) * 50
      # Maximum thumbnail size
      size = 800 if size > 800
    else
      size = Setting.thumbnails_size.to_i
    end
    size = 100 unless size.positive?
    target = File.join(Attachment.thumbnails_storage_path, "#{id}_#{last_revision.digest}_#{size}.thumb")
    begin
      Redmine::Thumbnail.generate last_revision.file.download, target, size, pdf?
    rescue StandardError => e
      Rails.logger.error do
        %(An error occured while generating thumbnail for #{last_revision.file&.blob&.filename} to #{target}\n
          Exception was: #{e.message})
      end
      nil
    end
  end

  def locked_title
    if locked_for_user?
      return l(:title_locked_by_user, user: lock.reverse[0].user) if lock.reverse[0].user

      return "#{l(:label_user)} #{l('activerecord.errors.messages.invalid')}"
    end
    l(:title_unlock_file)
  end

  def container
    return unless dmsf_folder&.system && dmsf_folder.title&.match(/(^\d+)/)

    id = Regexp.last_match(1).to_i
    case dmsf_folder.dmsf_folder&.title
    when '.Issues'
      Issue.visible.find_by id: id
    end
  end

  def to_s
    name
  end

  def delete_system_folder_before
    @parent_folder = dmsf_folder
  end

  def delete_system_folder_after
    return unless @parent_folder&.system && @parent_folder.dmsf_files.empty? && @parent_folder.dmsf_links.empty?

    @parent_folder&.destroy
  end
end
