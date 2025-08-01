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

# Redmine's PDF export patch to view DMS images

module RedmineDmsf
  module Patches
    # Puma
    module PumaPatch
      ##################################################################################################################
      # Overridden methods
      def self.included(base)
        base.class_eval do
          # WebDAV methods
          methods = Puma::Const::SUPPORTED_HTTP_METHODS |
                    %w[OPTIONS HEAD GET PUT POST DELETE PROPFIND PROPPATCH MKCOL COPY MOVE LOCK UNLOCK]
          remove_const :SUPPORTED_HTTP_METHODS
          const_set :SUPPORTED_HTTP_METHODS, methods.freeze
        end
      end
    end
  end
end

# Apply the patch
Puma::Const.include RedmineDmsf::Patches::PumaPatch if RedmineDmsf::Plugin.lib_available?('puma/const')
