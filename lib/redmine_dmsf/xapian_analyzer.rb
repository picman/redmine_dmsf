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

module RedmineDmsf
  # ActiveRecord Analyzer for Xapian
  class XapianAnalyzer < ActiveStorage::Analyzer
    def self.accept?(blob)
      return false unless RedmineDmsf::Plugin.lib_available?('xapian') && blob.byte_size < 1_024 * 1_024 * 3 # 3MB

      @blob = blob
      true
    end

    def metadata
      index
      {}
    end

    private

    def index
      stem_lang = RedmineDmsf.dmsf_stemming_lang
      db_path = File.join RedmineDmsf.dmsf_index_database, stem_lang
      url = File.join(@blob.key[0..1], @blob.key[2..3])
      dir = File.join(Dir.tmpdir, @blob.key)
      FileUtils.mkdir dir
      @blob.open do |file|
        FileUtils.mv file.path, File.join(dir, @blob.key)
        system "omindex -s \"#{stem_lang}\" -D \"#{db_path}\" --url=/#{url} \"#{dir}\" -p", exception: true
      end
    rescue StandardError => e
      Rails.logger.error e.message
    ensure
      FileUtils.rm_f dir
    end
  end
end
