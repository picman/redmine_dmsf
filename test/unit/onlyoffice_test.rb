# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class OnlyOfficeTest < ActiveSupport::TestCase
  test 'maps office extensions to ONLYOFFICE document types' do
    assert_equal 'word', RedmineDmsf::OnlyOffice.document_type('example.docx')
    assert_equal 'cell', RedmineDmsf::OnlyOffice.document_type('example.xlsx')
    assert_equal 'slide', RedmineDmsf::OnlyOffice.document_type('example.pptx')
    assert_equal 'pdf', RedmineDmsf::OnlyOffice.document_type('example.pdf')
  end

  test 'encodes and verifies HS256 JWT tokens' do
    token = RedmineDmsf::OnlyOffice.jwt_encode({ value: 'test', exp: 5.minutes.from_now.to_i }, 'secret')
    payload = RedmineDmsf::OnlyOffice.jwt_decode(token, 'secret')

    assert_equal 'test', payload['value']
  end

  test 'rejects JWT tokens signed with another secret' do
    token = RedmineDmsf::OnlyOffice.jwt_encode({ value: 'test' }, 'secret')

    assert_raises RedmineDmsf::OnlyOffice::InvalidToken do
      RedmineDmsf::OnlyOffice.jwt_decode(token, 'another-secret')
    end
  end

  test 'supports the HMAC algorithms exposed by ONLYOFFICE settings' do
    %w[HS256 HS384 HS512].each do |algorithm|
      token = RedmineDmsf::OnlyOffice.jwt_encode({ value: algorithm }, 'secret', algorithm: algorithm)
      payload = RedmineDmsf::OnlyOffice.jwt_decode(token, 'secret', algorithm: algorithm)

      assert_equal algorithm, payload['value']
    end
  end

  test 'uses the supplied session key in the editor configuration' do
    revision = Struct.new(:name).new('example.docx')
    user = Struct.new(:id, :name, :language).new(7, 'Editor', 'en')

    RedmineDmsf.stub(:onlyoffice_jwt_secret, '') do
      config = RedmineDmsf::OnlyOffice.editor_config(
        revision: revision,
        user: user,
        mode: 'view',
        key: 'separate-view-key',
        download_url: 'https://redmine.test/download',
        callback_url: 'https://redmine.test/callback',
        back_url: 'https://redmine.test/dmsf/file/1'
      )

      assert_equal 'separate-view-key', config[:document][:key]
      assert_equal false, config[:document][:permissions][:edit]
    end
  end

  test 'decodes a signed callback token from the request body' do
    payload = { 'key' => 'document-key', 'status' => 2 }
    token = RedmineDmsf::OnlyOffice.jwt_encode(payload, 'secret')
    request = Struct.new(:raw_post, :headers).new({ token: token }.to_json, {})

    RedmineDmsf.stub(:onlyoffice_jwt_secret, 'secret') do
      RedmineDmsf.stub(:onlyoffice_jwt_algorithm, 'HS256') do
        RedmineDmsf.stub(:onlyoffice_jwt_header, 'Authorization') do
          assert_equal payload, RedmineDmsf::OnlyOffice.callback_payload(request)
        end
      end
    end
  end

  test 'decodes a signed callback payload from the authorization header' do
    payload = { 'key' => 'document-key', 'status' => 4 }
    token = RedmineDmsf::OnlyOffice.jwt_encode({ payload: payload }, 'secret')
    request = Struct.new(:raw_post, :headers).new(payload.to_json, { 'Authorization' => "Bearer #{token}" })

    RedmineDmsf.stub(:onlyoffice_jwt_secret, 'secret') do
      RedmineDmsf.stub(:onlyoffice_jwt_algorithm, 'HS256') do
        RedmineDmsf.stub(:onlyoffice_jwt_header, 'Authorization') do
          assert_equal payload, RedmineDmsf::OnlyOffice.callback_payload(request)
        end
      end
    end
  end

  test 'rewrites reverse proxy base paths without duplicating them' do
    rewritten = RedmineDmsf::OnlyOffice.replace_base(
      'https://office.example.test/onlyoffice/cache/file.docx?token=1',
      'https://office.example.test/onlyoffice',
      'http://documentserver'
    )

    assert_equal 'http://documentserver/cache/file.docx?token=1', rewritten
  end
end
