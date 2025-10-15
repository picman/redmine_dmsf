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

# An asynchronous job to remove file from Xapian full-text search index
class RemoveFromIndexJob < ApplicationJob
  def self.schedule(key)
    perform_later key
  end

  def perform(key)
    url = File.join(key[0..1], key[2..3], key)
    stem_lang = RedmineDmsf.dmsf_stemming_lang
    db_path = File.join RedmineDmsf.dmsf_index_database, stem_lang
    db = Xapian::WritableDatabase.new(db_path, Xapian::DB_OPEN)
    found = false
    db.postlist('').each do |it|
      doc = db.document(it.docid)
      dochash = Hash[*doc.data.scan(%r{(url|sample|modtime|author|type|size)=/?([^\n\]]+)}).flatten]
      next unless url == dochash['url']

      db.delete_document it.docid
      found = true
      break
    end
    Rails.logger.warn "Document's URL '#{url}' not found in the index" unless found
  rescue StandardError => e
    Rails.logger.error e.message
  ensure
    db&.close
  end
end
