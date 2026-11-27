# frozen_string_literal: true

require 'securerandom'

# A key identifies one collaborative editing session, not one browser or author.
class DmsfOnlyofficeSession < ApplicationRecord
  MODE_PERMISSIONS = {
    'edit' => :file_manipulation,
    'review' => :review_dmsf_files,
    'comment' => :comment_dmsf_files,
    'fill' => :fill_dmsf_forms
  }.freeze
  MODES = (['view'] + MODE_PERMISSIONS.keys).freeze
  STATES = %w[active snapshot saved recovery error closed submitted].freeze

  belongs_to :dmsf_file, optional: true
  belongs_to :source_revision, class_name: 'DmsfFileRevision', optional: true
  belongs_to :saved_revision, class_name: 'DmsfFileRevision', optional: true
  belongs_to :user, optional: true
  has_many :recoveries, class_name: 'DmsfOnlyofficeRecovery', dependent: :destroy,
                       inverse_of: :dmsf_onlyoffice_session

  serialize :participants, coder: JSON, type: Array
  serialize :connected_users, coder: JSON, type: Array

  validates :document_key, presence: true, length: { maximum: 128 }
  validates :mode, inclusion: { in: MODES }
  validates :state, inclusion: { in: STATES }
  validates :expires_at, presence: true

  scope :active, -> { where(state: %w[active snapshot], closed_at: nil).where('expires_at > ?', Time.current) }

  # The caller must hold the file lock until register! finishes. All editors of
  # the same live revision share a generation; completed keys are never reused.
  def self.key_for_editor(file:, revision:, user:, mode:)
    modes = %w[edit review comment].include?(mode) ? %w[edit review comment] : [mode]
    open_sessions = where(dmsf_file_id: file.id, source_revision_id: revision.id, mode: modes, closed_at: nil)
                    .where('expires_at > ?', Time.current).where.not(state: 'saved')
    open_sessions = open_sessions.where(user_id: user.id) if mode == 'fill'
    current = open_sessions.order(id: :desc).first
    return current.document_key if current

    base = RedmineDmsf::OnlyOffice.document_key(file, revision)
    base = "#{base}-view" if mode == 'view'
    base = "#{base}-fill-#{user.id}" if mode == 'fill'
    return base unless exists?(document_key: base)

    "#{base}-#{SecureRandom.hex(6)}"
  end

  def self.with_user(user)
    previous_user = User.current
    User.current = user
    yield
  ensure
    User.current = previous_user
  end

  def self.allowed_mode?(file:, user:, mode:)
    return false unless MODES.include?(mode.to_s) && file && user

    with_user(user) do
      next false unless (user.active? || user.anonymous?) && file.deleted == DmsfFile::STATUS_ACTIVE &&
                        file.project&.active? && file.project.module_enabled?(:dmsf) &&
                        user.allowed_to?(:view_dmsf_files, file.project) &&
                        folder_available?(file.dmsf_folder) &&
                        DmsfFolder.permissions?(file.dmsf_folder, allow_system: true, file: true)
      next true if mode.to_s == 'view'
      next false if user.anonymous?

      permission = MODE_PERMISSIONS.fetch(mode.to_s)
      user.allowed_to?(:file_manipulation, file.project) || user.allowed_to?(permission, file.project)
    end
  end

  def self.folder_available?(folder)
    return true unless folder
    return false unless folder.deleted == DmsfFolder::STATUS_ACTIVE

    folder_available?(folder.dmsf_folder)
  end

  def self.register!(file:, revision:, user:, mode:, document_key:, expires_at: nil)
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'The editor mode is not permitted' unless
      allowed_mode?(file: file, user: user, mode: mode)

    maximum_deadline = Time.current + RedmineDmsf.onlyoffice_session_ttl.seconds
    deadline = expires_at ? [expires_at, maximum_deadline].min : maximum_deadline
    session = nil
    # Registration and retention acquire locks in the same order: file, session.
    file.with_lock do
      unless allowed_mode?(file: file, user: user, mode: mode)
        raise RedmineDmsf::OnlyOffice::InvalidToken, 'The editor mode is no longer permitted'
      end
      revision.reload
      unless revision.dmsf_file_id == file.id && revision.visible? && revision.file.attached?
        raise ActiveRecord::RecordNotFound, 'The editor source is no longer available'
      end

      session = find_or_initialize_by(document_key: document_key)
      if session.new_record?
        session.assign_attributes(dmsf_file: file, source_revision: revision, user: user,
                                  mode: mode, state: 'active', expires_at: deadline, participants: [],
                                  source_filename: revision.name, source_content_type: revision.content_type)
        session.save!
      end
      session.with_lock do
        session.validate_identity!(file.id, revision.id)
        session.participants = (session.participants + [user.id.to_s]).uniq
        session.expires_at = [session.expires_at, deadline].compact.max
        session.source_filename ||= revision.name
        session.source_content_type ||= revision.content_type
        session.state = 'active' if session.state == 'closed'
        session.save!
      end
    end
    session
  rescue ActiveRecord::RecordNotUnique
    # The file lock normally serializes callers; retain a unique-key retry for
    # adapters whose row locking does not serialize initial record creation.
    retry
  end

  # Tokens issued before the session registry was installed remain usable until
  # their original expiry. A valid signed capability proves prior authorization;
  # current permissions are checked separately before publication.
  def self.from_claims!(claims)
    key = claims.fetch('key')
    mode = claims['mode'].presence || 'view'
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'Invalid editor mode' unless MODES.include?(mode)

    file = DmsfFile.find_by(id: claims.fetch('file_id'))
    unless file
      session = find_by!(document_key: key)
      session.with_lock do
        session.validate_identity!(claims.fetch('file_id').to_i, claims.fetch('revision_id').to_i)
        session.participants = (session.participants + [claims['user_id'].to_s]).uniq
        session.save!
      end
      raise RedmineDmsf::OnlyOffice::InvalidToken, 'The editor session has expired' if session.expired?

      return session
    end
    session = nil
    file.with_lock do
      session = find_or_initialize_by(document_key: key)
      if session.new_record?
        source = DmsfFileRevision.find(claims.fetch('revision_id'))
        raise ActiveRecord::RecordNotFound unless source.dmsf_file_id == file.id

        deadline = Time.at(claims.fetch('exp').to_i)
        session.assign_attributes(dmsf_file: file, source_revision: source, user_id: claims['user_id'],
                                  mode: mode, expires_at: deadline, state: 'active', participants: [],
                                  source_filename: source.name, source_content_type: source.content_type)
      end
      session.validate_identity!(file.id, claims.fetch('revision_id').to_i)
      session.participants = (session.participants + [claims['user_id'].to_s]).uniq
      session.save!
    end
    raise RedmineDmsf::OnlyOffice::InvalidToken, 'The editor session has expired' if session.expired?

    session
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def validate_identity!(file_id, revision_id)
    return if dmsf_file_id == file_id && source_revision_id == revision_id

    raise RedmineDmsf::OnlyOffice::InvalidToken, 'Document session identity mismatch'
  end

  def expired?
    expires_at <= Time.current
  end

  def participant?(candidate)
    candidate && participants.include?(candidate.id.to_s)
  end

  def permission_state(candidate = user, requested_mode = mode)
    return 'permission_revoked' unless self.class.allowed_mode?(file: dmsf_file, user: candidate, mode: requested_mode)

    self.class.with_user(candidate) { dmsf_file.locked_for_user? ? 'locked' : 'allowed' }
  end

  def record_callback!(next_state:, error: nil, connected_users: nil, closed: false, presence_only: false)
    with_lock do
      # A delayed force-save or close callback must not regress a published final
      # revision or a submitted form to an in-progress state. Presence is not a
      # successful save and cannot resolve a recovery warning or reopen a key.
      self.state = next_state unless %w[saved submitted].include?(state) || (presence_only && closed_at.present?)
      self.last_error = error unless presence_only
      self.last_callback_at = Time.current
      self.closed_at ||= Time.current if closed
      if connected_users.is_a?(Array)
        self.connected_users = connected_users.map(&:to_s).uniq
        self.last_presence_at = Time.current
      end
      save!
    end
  end
end
