# frozen_string_literal: true

# Redmine plugin for Document Management System "Features"
#
# Karel Pičman <karel.picman@kontron.com>
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
  module Patches
    # TODO: This is just a workaround to fix alias_method usage in RedmineUp's plugins, which is in conflict with
    #   prepend and causes an infinite loop.
    module NotifiableRuPatch
      def self.included(base)
        base.extend ClassMethods
        base.class_eval do
          class << self
            alias_method :all_without_resources_dmsf, :all
            alias_method :all, :all_with_resources_dmsf
          end
        end
      end

      # Class methods
      module ClassMethods
        def all_with_resources_dmsf
          notifications = all_without_resources_dmsf
          notifications << Redmine::Notifiable.new('dmsf_workflow_plural')
          notifications << Redmine::Notifiable.new('dmsf_legacy_notifications')
          notifications
        end
      end
    end
  end
end

# Apply the patch
Redmine::Notifiable.include RedmineDmsf::Patches::NotifiableRuPatch if RedmineDmsf::Plugin.an_obsolete_plugin_present?
