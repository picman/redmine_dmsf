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

module RedmineDmsf
  module Test
    # Integration test
    class IntegrationTest < Redmine::IntegrationTest
      def initialize(name)
        super
        # Load all plugin's fixtures
        dir = File.join(File.dirname(__FILE__), 'fixtures')
        # We can't simply read the whole dir as we need to be active_storage_blobs read before
        # active_storage_attachments due to PG::ForeignKeyViolation
        ActiveRecord::FixtureSet.create_fixtures dir, 'active_storage_blobs'
        ActiveRecord::FixtureSet.create_fixtures dir, 'active_storage_attachments'
        ActiveRecord::FixtureSet.create_fixtures dir, 'custom_fields'
        ActiveRecord::FixtureSet.create_fixtures dir, 'custom_values'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_file_revisions'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_files'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_folder_permissions'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_folders'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_links'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_locks'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_public_urls'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_workflow_step_actions'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_workflow_step_assignments'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_workflow_steps'
        ActiveRecord::FixtureSet.create_fixtures dir, 'dmsf_workflows'
        ActiveRecord::FixtureSet.create_fixtures dir, 'queries'
      end

      def setup
        @admin = credentials('admin', 'admin')
        @admin_user = User.find_by(login: 'admin')
        @jsmith = credentials('jsmith', 'jsmith')
        @jsmith_user = User.find_by(login: 'jsmith')
        @someone = credentials('someone', 'foo')
        @anonymous = credentials('')
        @project1 = Project.find 1
        @project2 = Project.find 2
        @project5 = Project.find 5
        [@project1, @project2, @project5].each do |project|
          project.enable_module! :dmsf
        end
        @file1 = DmsfFile.find 1
        @file2 = DmsfFile.find 2
        @file9 = DmsfFile.find 9
        @file10 = DmsfFile.find 10
        @file12 = DmsfFile.find 12
        @folder1 = DmsfFolder.find 1
        @folder2 = DmsfFolder.find 2
        @folder3 = DmsfFolder.find 3
        @folder6 = DmsfFolder.find 6
        @folder7 = DmsfFolder.find 7
        @folder10 = DmsfFolder.find 10
        @folder_link1 = DmsfLink.find 1
        @role = Role.find_by(name: 'Manager')
        @role.add_permission! :view_dmsf_folders
        @role.add_permission! :folder_manipulation
        @role.add_permission! :view_dmsf_files
        @role.add_permission! :file_manipulation
        @role.add_permission! :file_delete
        Setting.plugin_redmine_dmsf['dmsf_webdav'] = '1'
        Setting.plugin_redmine_dmsf['dmsf_webdav_strategy'] = 'WEBDAV_READ_WRITE'
        Setting.plugin_redmine_dmsf['dmsf_webdav_use_project_names'] = '0'
        Setting.plugin_redmine_dmsf['dmsf_projects_as_subfolders'] = '0'
        Setting.plugin_redmine_dmsf['dmsf_storage_directory'] = File.join('files', ['dmsf'])
        Setting.plugin_redmine_dmsf['dmsf_webdav_authentication'] = 'Basic'
        FileUtils.cp_r File.join(File.expand_path('../fixtures/files', __FILE__), '.'), DmsfFile.storage_path
        User.current = nil
      end

      def teardown
        # Delete our tmp folder
        FileUtils.rm_rf DmsfFile.storage_path
      rescue StandardError => e
        Rails.logger.error e.message
      end

      protected

      def check_headers_exist
        assert_not response.headers.blank?, 'Head returned without headers' # Headers exist?
        values = {}
        values[:etag] = { optional: true, content: response.headers['Etag'] }
        values[:content_type] = response.headers['Content-Type']
        values[:last_modified] = { optional: true, content: response.headers['Last-Modified'] }
        single_optional = false
        values.each do |key, val|
          if val.is_a?(Hash)
            if val[:optional].nil? || !val[:optional]
              assert_not val[:content].blank?, "Expected header #{key} was empty." if single_optional
            else
              single_optional = true
            end
          else
            assert_not val.blank?, "Expected header #{key} was empty."
          end
        end
      end

      def check_headers_dont_exist
        assert_not response.headers.blank?, 'Head returned without headers' # Headers exist?
        values = {}
        values[:etag] = response.headers['Etag']
        values[:last_modified] = response.headers['Last-Modified']
        values.each do |key, val|
          assert val.blank?, "Expected header #{key} should be empty."
        end
      end

      def encode_credentials(options)
        options.reverse_merge!(nc: '00000001', cnonce: '0a4f113b', password_is_ha1: false)
        # Perform unauthenticated request to retrieve digest parameters to use on subsequent request
        target = options.delete(:target) || :index
        get target
        assert_response :unauthorized
        # Credentials
        credentials = {
          uri: target,
          realm: RedmineDmsf::Webdav::AUTHENTICATION_REALM,
          username: options[:username],
          nonce: ActionController::HttpAuthentication::Digest.nonce(Rails.configuration.secret_key_base),
          opaque: ActionController::HttpAuthentication::Digest.opaque(Rails.configuration.secret_key_base)
        }
        credentials.merge!(options)
        path_info = @request.env['PATH_INFO'].to_s
        uri = options[:uri] || path_info
        credentials[uri] = uri
        @request.env['ORIGINAL_FULLPATH'] = path_info
        ha2 = ActiveSupport::Digest.hexdigest("GET:#{target}")
        nonce = ActionController::HttpAuthentication::Digest.nonce(Rails.configuration.secret_key_base)
        ha1 = options.delete(:digest)
        credentials[:response] = ActiveSupport::Digest.hexdigest("#{ha1}:#{nonce}:#{ha2}")
        "Digest #{credentials.sort_by { |x| x[0].to_s }.map { |v| "#{v[0]}=#{v[1]}" }.join(',')}"
      end
    end
  end
end
