# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'openssl'
require 'tempfile'
require 'uri'

module RedmineDmsf
  # ONLYOFFICE Docs integration for DMSF files and revisions.
  module OnlyOffice
    WORD_EXTENSIONS = %w[
      doc docm docx docxf dot dotm dotx epub fb2 fodt htm html mht mhtml odt oform ott rtf stw sxw txt wps wpt xml
    ].freeze
    CELL_EXTENSIONS = %w[
      csv et ett fods ods ots sxc xls xlsb xlsm xlsx xlt xltm xltx
    ].freeze
    SLIDE_EXTENSIONS = %w[
      dps dpt fodp odp otp pot potm potx pps ppsm ppsx ppt pptm pptx sxi
    ].freeze
    PDF_EXTENSIONS = %w[djvu oxps pdf pdfa xps].freeze
    VIEWABLE_EXTENSIONS = (WORD_EXTENSIONS + CELL_EXTENSIONS + SLIDE_EXTENSIONS + PDF_EXTENSIONS).uniq.freeze

    DEFAULT_EDITABLE_EXTENSIONS = %w[
      docx docm dotx dotm odt ott rtf txt html htm
      xlsx xlsm xltx xltm ods ots csv
      pptx pptm potx potm ppsx ppsm odp otp
      pdf docxf oform
    ].freeze

    JWT_DIGESTS = {
      'HS256' => 'SHA256',
      'HS384' => 'SHA384',
      'HS512' => 'SHA512'
    }.freeze

    class Error < StandardError; end
    class InvalidToken < Error; end
    class InvalidDownloadUrl < Error; end
    class FileTooLarge < Error; end

    class << self
      def enabled?
        url = RedmineDmsf.onlyoffice_document_server_url
        return false if url.blank?

        uri = URI.parse(url)
        %w[http https].include?(uri.scheme) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      def extension(filename)
        File.extname(filename.to_s).delete_prefix('.').downcase
      end

      def viewable?(filename)
        enabled? && VIEWABLE_EXTENSIONS.include?(extension(filename))
      end

      def editable?(filename)
        viewable?(filename) && RedmineDmsf.onlyoffice_editable_extensions.include?(extension(filename))
      end

      def document_type(filename)
        ext = extension(filename)
        return 'word' if WORD_EXTENSIONS.include?(ext)
        return 'cell' if CELL_EXTENSIONS.include?(ext)
        return 'slide' if SLIDE_EXTENSIONS.include?(ext)
        return 'pdf' if PDF_EXTENSIONS.include?(ext)

        'word'
      end

      def document_key(file, revision)
        digest = revision.checksum.presence || Digest::SHA256.hexdigest(
          [revision.id, revision.updated_at.to_i, revision.size].join(':')
        )
        "dmsf-#{file.id}-#{revision.id}-#{digest.to_s.gsub(/[^0-9A-Za-z_-]/, '')[0, 24]}"
      end

      def api_url
        join_url(RedmineDmsf.onlyoffice_document_server_url, 'web-apps/apps/api/documents/api.js')
      end

      def editor_config(revision:, user:, mode:, key:, download_url:, callback_url:, back_url:)
        editable = mode == 'edit'
        config = {
          type: 'desktop',
          documentType: document_type(revision.name),
          document: {
            fileType: extension(revision.name),
            key: key,
            title: revision.name,
            url: download_url,
            permissions: {
              edit: editable,
              download: true,
              print: true,
              review: editable,
              comment: editable,
              copy: true
            }
          },
          editorConfig: {
            mode: mode,
            lang: user.language.presence || I18n.locale.to_s,
            callbackUrl: callback_url,
            user: {
              id: user.id&.to_s || 'anonymous',
              name: user.name
            },
            customization: {
              forcesave: false,
              goback: {
                url: back_url
              }
            }
          }
        }

        secret = RedmineDmsf.onlyoffice_jwt_secret
        if secret.present?
          config[:token] = jwt_encode(config, secret, algorithm: RedmineDmsf.onlyoffice_jwt_algorithm)
        end
        config
      end

      def storage_token(file:, revision:, user:, purpose:, key: nil, mode: nil)
        claims = {
          purpose: purpose,
          file_id: file.id,
          revision_id: revision.id,
          user_id: user.id,
          anonymous: user.anonymous?,
          key: key || document_key(file, revision),
          exp: Time.now.to_i + RedmineDmsf.onlyoffice_token_ttl
        }
        claims[:mode] = mode if mode.present?
        jwt_encode(claims, storage_secret, algorithm: 'HS256')
      end

      def decode_storage_token(token, purpose:)
        claims = jwt_decode(token, storage_secret, algorithm: 'HS256')
        raise InvalidToken, 'Invalid token purpose' unless claims['purpose'] == purpose

        claims
      end

      # ONLYOFFICE signs POST callbacks in one of two forms:
      # * the JSON body has a `token` whose decoded payload is the callback body;
      # * the configured authorization header has a token with a `payload` object.
      def callback_payload(request)
        raw_body = JSON.parse(request.raw_post.presence || '{}')
        secret = RedmineDmsf.onlyoffice_jwt_secret
        return raw_body if secret.blank?

        algorithm = RedmineDmsf.onlyoffice_jwt_algorithm
        body_token = raw_body['token'].to_s
        if body_token.present?
          return jwt_decode(body_token, secret, algorithm: algorithm).deep_stringify_keys
        end

        header_name = RedmineDmsf.onlyoffice_jwt_header.presence || 'Authorization'
        header_token = request.headers[header_name].to_s.sub(/\ABearer\s+/i, '')
        if header_token.present?
          decoded = jwt_decode(header_token, secret, algorithm: algorithm)
          payload = decoded['payload']
          raise InvalidToken, 'Missing callback payload in ONLYOFFICE JWT header' unless payload.is_a?(Hash)

          return payload.deep_stringify_keys
        end

        raise InvalidToken, 'Missing ONLYOFFICE callback JWT' if body_token.blank?
      rescue JSON::ParserError => e
        raise InvalidToken, e.message
      end

      def jwt_encode(payload, secret, algorithm: 'HS256')
        digest = jwt_digest(algorithm)
        header = { alg: algorithm, typ: 'JWT' }
        segments = [base64url(header.to_json), base64url(payload.to_json)]
        signature = OpenSSL::HMAC.digest(digest, secret, segments.join('.'))
        (segments << base64url(signature)).join('.')
      end

      def jwt_decode(token, secret, algorithm: 'HS256')
        segments = token.to_s.split('.')
        raise InvalidToken, 'Malformed JWT' unless segments.size == 3

        header = JSON.parse(base64url_decode(segments[0]))
        raise InvalidToken, 'Unexpected JWT algorithm' unless header['alg'] == algorithm

        expected = OpenSSL::HMAC.digest(jwt_digest(algorithm), secret, segments[0, 2].join('.'))
        actual = base64url_decode(segments[2])
        unless actual.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(actual, expected)
          raise InvalidToken, 'Invalid JWT signature'
        end

        payload = JSON.parse(base64url_decode(segments[1]))
        now = Time.now.to_i
        raise InvalidToken, 'Expired JWT' if payload['exp'] && payload['exp'].to_i < now
        raise InvalidToken, 'JWT is not active yet' if payload['nbf'] && payload['nbf'].to_i > now

        payload
      rescue JSON::ParserError, ArgumentError => e
        raise InvalidToken, e.message
      end

      def internal_redmine_url(public_url)
        replacement = RedmineDmsf.onlyoffice_redmine_internal_url
        return public_url if replacement.blank?

        uri = URI.parse(public_url)
        root = Rails.application.config.relative_url_root.presence || '/'
        source_base = uri.dup
        source_base.path = root
        source_base.query = nil
        source_base.fragment = nil
        replace_base(public_url, source_base.to_s, replacement)
      rescue URI::InvalidURIError
        public_url
      end

      def internal_document_server_url(url)
        replace_base(
          url,
          RedmineDmsf.onlyoffice_document_server_url,
          RedmineDmsf.onlyoffice_document_server_internal_url
        )
      end

      def download_to_tempfile(url, max_bytes: nil)
        target = internal_document_server_url(url)
        validate_document_server_url!(target)
        tempfile = Tempfile.new(['dmsf-onlyoffice-', '.tmp'])
        tempfile.binmode
        fetch(target, tempfile, 0, max_bytes)
        tempfile.rewind
        tempfile
      rescue StandardError
        tempfile&.close!
        raise
      end

      def replace_base(url, source_base, replacement_base)
        return url if replacement_base.blank?

        original = URI.parse(url)
        source = URI.parse(normalize_base_url(source_base))
        replacement = URI.parse(normalize_base_url(replacement_base))
        return url unless same_origin?(original, source) || same_origin?(original, replacement)

        relative_path = original.path.to_s
        source_path = normalized_path(source.path)
        if same_origin?(original, source) && source_path != '/' &&
           (relative_path == source_path || relative_path.start_with?("#{source_path}/"))
          relative_path = relative_path.delete_prefix(source_path)
        end

        replacement_path = normalized_path(replacement.path)
        replacement.path = if replacement_path != '/' &&
                              (relative_path == replacement_path || relative_path.start_with?("#{replacement_path}/"))
                             normalized_path(relative_path)
                           else
                             join_paths(replacement_path, relative_path)
                           end
        replacement.query = original.query
        replacement.fragment = original.fragment
        replacement.to_s
      rescue URI::InvalidURIError
        url
      end

      def normalize_base_url(url)
        value = url.to_s.strip
        value.end_with?('/') ? value : "#{value}/"
      end

      def join_url(base, path)
        URI.join(normalize_base_url(base), path).to_s
      end

      private

      def base64url(value)
        Base64.urlsafe_encode64(value, padding: false)
      end

      def base64url_decode(value)
        Base64.urlsafe_decode64(value.to_s + ('=' * ((4 - value.to_s.length % 4) % 4)))
      end

      def jwt_digest(algorithm)
        JWT_DIGESTS.fetch(algorithm) { raise InvalidToken, "Unsupported JWT algorithm: #{algorithm}" }
      end

      def storage_secret
        @storage_secret ||= OpenSSL::HMAC.hexdigest(
          'SHA256', Rails.application.secret_key_base, 'redmine-dmsf-onlyoffice-storage-token'
        )
      end

      def normalized_path(path)
        value = path.to_s
        value = "/#{value}" unless value.start_with?('/')
        value = value.gsub(%r{/+}, '/')
        value.length > 1 ? value.delete_suffix('/') : value
      end

      def join_paths(base, suffix)
        return normalized_path(suffix) if base == '/'

        normalized_path("#{base}/#{suffix.to_s.delete_prefix('/')}")
      end

      def same_origin?(left, right)
        left.scheme == right.scheme && left.host == right.host && left.port == right.port
      end

      def validate_document_server_url!(url)
        uri = URI.parse(url)
        allowed = [
          RedmineDmsf.onlyoffice_document_server_url,
          RedmineDmsf.onlyoffice_document_server_internal_url
        ].filter_map do |base|
          next if base.blank?

          parsed = URI.parse(base)
          [parsed.scheme, parsed.host, parsed.port]
        rescue URI::InvalidURIError
          nil
        end
        unless %w[http https].include?(uri.scheme) && allowed.include?([uri.scheme, uri.host, uri.port])
          raise InvalidDownloadUrl, 'The callback download URL is not a configured ONLYOFFICE Document Server URL'
        end
      end

      def fetch(url, io, redirects, max_bytes)
        raise InvalidDownloadUrl, 'Too many redirects' if redirects > 3

        uri = URI.parse(url)
        validate_document_server_url!(url)
        request = Net::HTTP::Get.new(uri.request_uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.verify_mode = if RedmineDmsf.onlyoffice_ssl_verification_disabled?
                             OpenSSL::SSL::VERIFY_NONE
                           else
                             OpenSSL::SSL::VERIFY_PEER
                           end
        http.open_timeout = 15
        http.read_timeout = 120

        http.request(request) do |response|
          case response
          when Net::HTTPSuccess
            content_length = response['content-length'].to_i
            if max_bytes&.positive? && content_length.positive? && content_length > max_bytes
              raise FileTooLarge, 'The edited document exceeds Redmine attachment_max_size'
            end

            bytes = 0
            response.read_body do |chunk|
              bytes += chunk.bytesize
              if max_bytes&.positive? && bytes > max_bytes
                raise FileTooLarge, 'The edited document exceeds Redmine attachment_max_size'
              end
              io.write(chunk)
            end
          when Net::HTTPRedirection
            location = URI.join(url, response['location']).to_s
            fetch(internal_document_server_url(location), io, redirects + 1, max_bytes)
          else
            raise Error, "ONLYOFFICE download failed: #{response.code} #{response.message}"
          end
        end
      end
    end
  end
end
