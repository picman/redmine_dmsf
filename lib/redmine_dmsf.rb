# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Vít Jonáš <vit.jonas@gmail.com>, Daniel Munn <dan.munn@munnster.co.uk>, Karel Pičman <karel.picman@kontron.com>
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

# Main module
module RedmineDmsf
  # Return true if the given gem is installed
  def self.lib_available?(path)
    require path
    true
  rescue LoadError => e
    Rails.logger.debug e.message
    false
  end

  # Return true if the given command is available
  def self.cmd_available?(cmd)
    _, _, status = Open3.capture3(cmd)
    status.success?
  rescue StandardError => _e
    false
  end

  mattr_accessor :xapian_available
  @@xapian_available = RedmineDmsf.lib_available?('xapian') && RedmineDmsf.cmd_available?('omindex -V')

  # Settings
  class << self
    def dmsf_max_file_download
      Setting.plugin_redmine_dmsf['dmsf_max_file_download'].to_i
    end

    def dmsf_max_email_filesize
      Setting.plugin_redmine_dmsf['dmsf_max_email_filesize'].to_i
    end

    def dmsf_index_database
      dir = if Setting.plugin_redmine_dmsf['dmsf_index_database'].present?
              Setting.plugin_redmine_dmsf['dmsf_index_database'].strip
            else
              File.expand_path('dmsf_index', Rails.root)
            end
      FileUtils.mkdir_p dir
    end

    def dmsf_stemming_lang
      if Setting.plugin_redmine_dmsf['dmsf_stemming_lang'].present?
        Setting.plugin_redmine_dmsf['dmsf_stemming_lang'].strip
      else
        'english'
      end
    end

    def dmsf_stemming_strategy
      if Setting.plugin_redmine_dmsf['dmsf_stemming_strategy'].present?
        Setting.plugin_redmine_dmsf['dmsf_stemming_strategy'].strip
      else
        'STEM_NONE'
      end
    end

    def dmsf_webdav_strategy
      if Setting.plugin_redmine_dmsf['dmsf_webdav_strategy'].present?
        Setting.plugin_redmine_dmsf['dmsf_webdav_strategy'].strip
      else
        'WEBDAV_READ_ONLY'
      end
    end

    def dmsf_webdav?
      value = Setting.plugin_redmine_dmsf['dmsf_webdav']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_display_notified_recipients?
      value = Setting.plugin_redmine_dmsf['dmsf_display_notified_recipients']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_global_title_format
      if Setting.plugin_redmine_dmsf['dmsf_global_title_format'].present?
        Setting.plugin_redmine_dmsf['dmsf_global_title_format'].strip
      else
        ''
      end
    end

    def dmsf_columns
      Setting.plugin_redmine_dmsf['dmsf_columns'].presence || DmsfFolder::DEFAULT_COLUMNS
    end

    def dmsf_webdav_ignore
      if Setting.plugin_redmine_dmsf['dmsf_webdav_ignore'].present?
        Setting.plugin_redmine_dmsf['dmsf_webdav_ignore'].strip
      else
        '^(\._|\.DS_Store$|Thumbs.db$)'
      end
    end

    def dmsf_webdav_disable_versioning
      if Setting.plugin_redmine_dmsf['dmsf_webdav_disable_versioning'].present?
        Setting.plugin_redmine_dmsf['dmsf_webdav_disable_versioning'].strip
      else
        '^\~\$|\.tmp$'
      end
    end

    def dmsf_keep_documents_locked?
      value = Setting.plugin_redmine_dmsf['dmsf_keep_documents_locked']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_act_as_attachable?
      value = Setting.plugin_redmine_dmsf['dmsf_act_as_attachable']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_documents_email_from
      if Setting.plugin_redmine_dmsf['dmsf_documents_email_from'].present?
        Setting.plugin_redmine_dmsf['dmsf_documents_email_from'].strip
      else
        "#{User.current.name} <#{User.current.mail}>"
      end
    end

    def dmsf_documents_email_reply_to
      if Setting.plugin_redmine_dmsf['dmsf_documents_email_reply_to'].present?
        Setting.plugin_redmine_dmsf['dmsf_documents_email_reply_to'].strip
      else
        ''
      end
    end

    def dmsf_documents_email_links_only?
      value = Setting.plugin_redmine_dmsf['dmsf_documents_email_links_only']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_enable_cjk_ngrams?
      value = Setting.plugin_redmine_dmsf['dmsf_enable_cjk_ngrams']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_webdav_use_project_names?
      value = Setting.plugin_redmine_dmsf['dmsf_webdav_use_project_names']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_webdav_ignore_1b_file_for_authentication?
      value = Setting.plugin_redmine_dmsf['dmsf_webdav_ignore_1b_file_for_authentication']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_projects_as_subfolders?
      value = Setting.plugin_redmine_dmsf['dmsf_projects_as_subfolders']
      value.to_i.positive? || value == 'true'
    end

    def only_approval_zero_minor_version?
      value = Setting.plugin_redmine_dmsf['only_approval_zero_minor_version']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_max_notification_receivers_info
      Setting.plugin_redmine_dmsf['dmsf_max_notification_receivers_info'].to_i
    end

    def office_bin
      if Setting.plugin_redmine_dmsf['office_bin'].present?
        Setting.plugin_redmine_dmsf['office_bin'].strip
      else
        ''
      end
    end

    def onlyoffice_official_settings
      return {} unless Redmine::Plugin.installed?('onlyoffice_redmine')

      Setting.plugin_onlyoffice_redmine || {}
    rescue NoMethodError
      {}
    end

    def onlyoffice_use_official_settings?
      value = Setting.plugin_redmine_dmsf['dmsf_onlyoffice_use_official_settings']
      enabled = value.to_i.positive? || value == 'true'
      enabled && onlyoffice_official_settings.present?
    end

    def onlyoffice_document_server_url
      onlyoffice_setting('dmsf_onlyoffice_document_server_url', 'oo_address')
    end

    def onlyoffice_document_server_internal_url
      onlyoffice_setting('dmsf_onlyoffice_document_server_internal_url', 'inner_editor')
    end

    def onlyoffice_redmine_internal_url
      onlyoffice_setting('dmsf_onlyoffice_redmine_internal_url', 'inner_server')
    end

    def onlyoffice_jwt_secret
      onlyoffice_setting('dmsf_onlyoffice_jwt_secret', 'jwtsecret')
    end

    def onlyoffice_jwt_algorithm
      value = onlyoffice_setting('dmsf_onlyoffice_jwt_algorithm', 'jwt_algorithm', 'HS256').upcase
      %w[HS256 HS384 HS512].include?(value) ? value : 'HS256'
    end

    def onlyoffice_jwt_header
      onlyoffice_setting('dmsf_onlyoffice_jwt_header', 'jwtheader', 'Authorization').presence || 'Authorization'
    end

    def onlyoffice_ssl_verification_disabled?
      if onlyoffice_use_official_settings?
        value = onlyoffice_official_settings['check_cert']
        ['on', true, 1, '1'].include?(value)
      else
        value = Setting.plugin_redmine_dmsf['dmsf_onlyoffice_disable_certificate_verification']
        value.to_i.positive? || value == 'true'
      end
    end

    def onlyoffice_editable_extensions
      if onlyoffice_use_official_settings?
        extensions = Array(onlyoffice_official_settings['formats_editable'])
                     .map { |extension| extension.to_s.delete_prefix('.').downcase }
                     .reject(&:blank?)
        return extensions.presence || RedmineDmsf::OnlyOffice::DEFAULT_EDITABLE_EXTENSIONS
      end

      value = Setting.plugin_redmine_dmsf['dmsf_onlyoffice_editable_extensions']
      extensions = value.to_s.split(/[\s,;]+/)
                        .map { |extension| extension.delete_prefix('.').downcase }
                        .reject(&:blank?)
      extensions.presence || RedmineDmsf::OnlyOffice::DEFAULT_EDITABLE_EXTENSIONS
    end

    def onlyoffice_version_type
      value = Setting.plugin_redmine_dmsf['dmsf_onlyoffice_version_type'].to_s
      %w[patch minor major].include?(value) ? value : 'minor'
    end

    def onlyoffice_version_constant
      case onlyoffice_version_type
      when 'patch' then DmsfFileRevision::PATCH_VERSION
      when 'major' then DmsfFileRevision::MAJOR_VERSION
      else DmsfFileRevision::MINOR_VERSION
      end
    end

    def onlyoffice_token_ttl
      value = Setting.plugin_redmine_dmsf['dmsf_onlyoffice_token_ttl'].to_i
      value = 86_400 if value <= 0
      value.clamp(300, 604_800)
    end

    def dmsf_global_menu_disabled?
      value = Setting.plugin_redmine_dmsf['dmsf_global_menu_disabled']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_default_query
      Setting.plugin_redmine_dmsf['dmsf_default_query'].to_i
    end

    def empty_minor_version_by_default?
      value = Setting.plugin_redmine_dmsf['empty_minor_version_by_default']
      value.to_i.positive? || value == 'true'
    end

    def physical_file_delete?
      value = Setting.plugin_redmine_dmsf['dmsf_really_delete_files']
      value.to_i.positive? || value == 'true'
    end

    def remove_original_documents_module?
      value = Setting.plugin_redmine_dmsf['remove_original_documents_module']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_webdav_authentication
      if Setting.plugin_redmine_dmsf['dmsf_webdav_authentication'].present?
        Setting.plugin_redmine_dmsf['dmsf_webdav_authentication'].strip
      else
        'Digest'
      end
    end

    def dmsf_default_notifications?
      value = Setting.plugin_redmine_dmsf['dmsf_default_notifications']
      value.to_i.positive? || value == 'true'
    end

    def dmsf_max_xapian_filesize
      if Setting.plugin_redmine_dmsf['dmsf_max_xapian_filesize'].present?
        Setting.plugin_redmine_dmsf['dmsf_max_xapian_filesize'].to_i
      else
        3
      end
    end

    private

    def onlyoffice_setting(local_key, official_key, default = '')
      value = if onlyoffice_use_official_settings?
                onlyoffice_official_settings[official_key]
              else
                Setting.plugin_redmine_dmsf[local_key]
              end
      value = default if value.blank?
      value.to_s.strip
    end
  end
end

# DMSF libraries

require "#{File.dirname(__FILE__)}/redmine_dmsf/only_office"

# Validators
require "#{File.dirname(__FILE__)}/../app/validators/dmsf_file_name_validator"
require "#{File.dirname(__FILE__)}/../app/validators/dmsf_max_file_size_validator"
require "#{File.dirname(__FILE__)}/../app/validators/dmsf_workflow_name_validator"
require "#{File.dirname(__FILE__)}/../app/validators/dmsf_url_validator"
require "#{File.dirname(__FILE__)}/../app/validators/dmsf_folder_parent_validator"

# Patches
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/formatting_helper_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/projects_helper_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/project_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/user_preference_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/user_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/issue_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/role_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/queries_controller_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/pdf_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/access_control_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/search_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/custom_field_patch"
require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/puma_patch"
# A workaround for obsolete 'alias_method' usage in RedmineUp's plugins
if RedmineDmsf::Plugin.an_obsolete_plugin_present?
  require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/notifiable_ru_patch"
else
  require "#{File.dirname(__FILE__)}/redmine_dmsf/patches/notifiable_patch"
end

# Load up classes that make up our WebDAV solution ontop of Dav4rack
require "#{File.dirname(__FILE__)}/dav4rack"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/custom_middleware"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/base_resource"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/dmsf_resource"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/index_resource"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/project_resource"
require "#{File.dirname(__FILE__)}/redmine_dmsf/webdav/resource_proxy"

# Hooks
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/controllers/account_controller_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/controllers/issues_controller_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/controllers/search_controller_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/view_projects_form_hook"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/base_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/custom_field_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/issue_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/mailer_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/my_account_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/views/search_view_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/helpers/issues_helper_hooks"
require "#{File.dirname(__FILE__)}/redmine_dmsf/hooks/helpers/project_helper_hooks"

# Macros
require "#{File.dirname(__FILE__)}/redmine_dmsf/macros"

# Field formats
require "#{File.dirname(__FILE__)}/redmine_dmsf/field_formats/dmsf_file_revision_format"
