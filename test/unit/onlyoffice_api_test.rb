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

require File.expand_path('../test_helper', __dir__)

# ONLYOFFICE API tests
class OnlyOfficeApiTest < ActiveSupport::TestCase
  def setup
    RedmineDmsf.stubs(:onlyoffice_document_server_url).returns('https://office.example.test/docs')
    RedmineDmsf.stubs(:onlyoffice_document_server_internal_url).returns('http://office-internal/docs')
    RedmineDmsf.stubs(:onlyoffice_jwt_secret).returns('api-test-secret')
    RedmineDmsf.stubs(:onlyoffice_jwt_algorithm).returns('HS256')
    RedmineDmsf.stubs(:onlyoffice_jwt_header).returns('Authorization')
    RedmineDmsf.stubs(:onlyoffice_ssl_verification_disabled?).returns(false)
    RedmineDmsf.stubs(:onlyoffice_force_save_enabled?).returns(true)
  end

  test 'commands use their own purpose-bound JWT and internal endpoint' do
    http = mock_http('{"error":0,"key":"shared-session"}') do |request|
      payload = JSON.parse(request.body)
      token = payload.delete('token')
      signed = RedmineDmsf::OnlyOffice.jwt_decode(token, 'api-test-secret')
      assert_equal payload, signed
      assert_equal 'command', signed['operation']
      assert_equal 'forcesave', signed['c']
      assert_equal 'shared-session', signed['key']
      assert_equal "Bearer #{token}", request['Authorization']
      assert_equal '/docs/command', request.path
      assert_not signed.key?('document')
    end
    Net::HTTP.expects(:new).with('office-internal', 80).returns(http)
    assert_equal 0, RedmineDmsf::OnlyOffice.command('forcesave', key: 'shared-session')['error']
  end

  test 'conversion and builder requests cannot reuse an editor token' do
    %w[converter docbuilder].each do |operation|
      http = mock_http('{"error":0}') do |request|
        payload = JSON.parse(request.body)
        signed = RedmineDmsf::OnlyOffice.jwt_decode(payload.fetch('token'), 'api-test-secret')
        assert_equal operation, signed['operation']
        assert_equal "/docs/#{operation}", request.path
        assert_not signed.key?('document')
      end
      Net::HTTP.expects(:new).with('office-internal', 80).returns(http)
      if operation == 'converter'
        RedmineDmsf::OnlyOffice.convert(url: 'https://redmine.example.test/source', outputtype: 'pdf')
      else
        RedmineDmsf::OnlyOffice.build_document(url: 'https://redmine.example.test/script')
      end
    end
  end

  test 'callback tokens for another operation are rejected' do
    signed = RedmineDmsf::OnlyOffice.jwt_encode({ operation: 'command', key: 'document', status: 2 }, 'api-test-secret')
    request = Struct.new(:raw_post, :headers).new({ token: signed }.to_json, {})
    assert_raises(RedmineDmsf::OnlyOffice::InvalidToken) { RedmineDmsf::OnlyOffice.callback_payload(request) }
  end

  test 'unsigned body metadata is not trusted when header JWT omits it' do
    trusted = { key: 'document', status: 2, url: 'https://office.example.test/file.docx' }
    signed = RedmineDmsf::OnlyOffice.jwt_encode({ payload: trusted, operation: 'callback' }, 'api-test-secret')
    body = trusted.merge(history: { changes: [{ user: { name: 'Forged author' } }] })
    request = Struct.new(:raw_post, :headers).new(body.to_json, { 'Authorization' => "Bearer #{signed}" })
    assert_not RedmineDmsf::OnlyOffice.callback_payload(request).key?('history')
  end

  test 'review comment and form modes do not grant unrestricted editing' do
    user = Struct.new(:id, :name, :language).new(7, 'Reader', 'en')
    revision = Struct.new(:name).new('example.docx')
    %w[review comment fill].each do |mode|
      config = RedmineDmsf::OnlyOffice.editor_config(revision: revision, user: user, mode: mode,
                                                     key: 'same-collaborative-key',
                                                     download_url: 'https://redmine.test/file',
                                                     callback_url: 'https://redmine.test/callback', back_url: '/',
                                                     type: 'mobile')
      assert_equal false, config[:document][:permissions][:edit]
      assert_equal(mode == 'review', config[:document][:permissions][:review])
      assert_equal(mode == 'fill', config[:document][:permissions][:fillForms])
      assert_equal 'edit', config[:editorConfig][:mode]
      assert_equal 'mobile', config[:type]
      assert_equal 'same-collaborative-key', config[:document][:key]
    end
  end

  test 'independent Redmine installations cannot collide on a shared Document Server' do
    file = Struct.new(:id).new(5)
    revision = Struct.new(:id, :checksum).new(7, 'MD5:identical-content')
    RedmineDmsf::OnlyOffice.stubs(:storage_secret).returns('installation-one')
    first = RedmineDmsf::OnlyOffice.document_key(file, revision)
    assert_equal first, RedmineDmsf::OnlyOffice.document_key(file, revision)
    RedmineDmsf::OnlyOffice.stubs(:storage_secret).returns('installation-two')
    assert_not_equal first, RedmineDmsf::OnlyOffice.document_key(file, revision)
    assert_operator first.length, :<=, 128
  end

  test 'save-as downloads cannot fetch arbitrary network origins' do
    Net::HTTP.expects(:new).never
    assert_raises(RedmineDmsf::OnlyOffice::InvalidDownloadUrl) do
      RedmineDmsf::OnlyOffice.download_to_tempfile('http://unrelated-internal-service.example/secret')
    end
  end

  private

  def mock_http(body)
    http = mock('http')
    %i[use_ssl= verify_mode= open_timeout= read_timeout=].each { |setter| http.stubs(setter) }
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.stubs(:read_body).yields(body)
    http.expects(:request).with do |request|
      yield request
      true
    end.yields(response)
    http
  end
end
