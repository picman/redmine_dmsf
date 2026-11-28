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

# Probe Transport module
module ProbeTransport
  def convert(parameters)
    $probe_conversion = parameters
    { 'error' => 0, 'endConvert' => false }
  end

  def command(command, **_parameters)
    raise "Unexpected command #{command}" unless command == 'getForgotten'

    { 'error' => 0, 'url' => 'https://office.example.test/forgotten.pdf' }
  end

  def download_to_tempfile(url, **_parameters)
    raise 'Unexpected download' unless url == 'https://office.example.test/forgotten.pdf'

    io = Tempfile.new(['independent-forgotten-', '.pdf'])
    io.binmode
    io.write('%PDF-1.7 Filled personal data')
    io.rewind
    io
  end
end
RedmineDmsf::OnlyOffice.singleton_class.prepend(ProbeTransport)
