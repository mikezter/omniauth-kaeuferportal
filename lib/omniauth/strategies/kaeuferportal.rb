require 'cgi'
require 'uri'
require 'oauth2'
require 'omniauth'
require 'timeout'
require 'securerandom'

module OAuth2
  class Client
    def get_token(params, access_token_opts={})
      opts = {:raise_errors => true, :parse => params.delete(:parse)}
      if options[:token_method] == :post
        opts[:body] = params
        opts[:headers] =  {'Content-Type' => 'application/x-www-form-urlencoded'}
      else
        opts[:params] = params
      end
      response = request(options[:token_method], token_url, opts)
      raise Error.new(response) unless response.body['access_token']
      opts = {
        :access_token => response.body.split("=")[1],
        :param_name => 'token'
      }
      AccessToken.from_hash(self, opts.merge(access_token_opts))
    end
  end
end

module OmniAuth
  module Strategies
    # Authentication strategy for connecting with APIs constructed using
    # the [OAuth 2.0 Specification](http://tools.ietf.org/html/draft-ietf-oauth-v2-10).
    # You must generally register your application with the provider and
    # utilize an application id and secret in order to authenticate using
    # OAuth 2.0.
    class Kaeuferportal
      include OmniAuth::Strategy

      args [:client_id, :client_secret]

      option :name, "kaeuferportal"
      option :client_id, nil
      option :client_secret, nil
      option :authorize_params, {}
      option :authorize_options, [:scope]
      option :token_params, {}
      option :token_options, []
      option :client_options, {
        :site => 'https://www.kaeuferportal.de',
        :authorize_url => '/oauth/authorize',
        :token_url => '/oauth/access_token'
      }


      attr_accessor :access_token

      def client
        ::OAuth2::Client.new(options.client_id, options.client_secret, deep_symbolize(options.client_options))
      end

      def callback_url
        full_host + script_name + callback_path
      end

      credentials do
        hash = {'token' => access_token.token}
        hash.merge!('refresh_token' => access_token.refresh_token) if access_token.expires? && access_token.refresh_token
        hash.merge!('expires_at' => access_token.expires_at) if access_token.expires?
        hash.merge!('expires' => access_token.expires?)
        hash
      end

      def request_phase
        redirect client.auth_code.authorize_url({:redirect_url => callback_url}.merge(authorize_params))
      end

      def authorize_params
        if options.authorize_params[:state].to_s.empty?
          options.authorize_params[:state] = SecureRandom.hex(24)
        end
        params = options.authorize_params.merge(options.authorize_options.inject({}){|h,k| h[k.to_sym] = options[k] if options[k]; h})
        if OmniAuth.config.test_mode
          @env ||= {}
          @env['rack.session'] ||= {}
        end
        session['omniauth.state'] = params[:state]
        params
      end

      def token_params
        options.token_params.merge(options.token_options.inject({}){|h,k| h[k.to_sym] = options[k] if options[k]; h})
      end

      def callback_phase
        if request.params['error'] || request.params['error_reason']
          raise CallbackError.new(request.params['error'], request.params['error_description'] || request.params['error_reason'], request.params['error_uri'])
        end
        if request.params['state'].to_s.empty? || request.params['state'] != session.delete('omniauth.state')
          raise CallbackError.new(nil, :csrf_detected)
        end

        self.access_token = build_access_token
        self.access_token = access_token.refresh! if access_token.expired?

        super
      rescue ::OAuth2::Error, CallbackError => e
        fail!(:invalid_credentials, e)
      rescue ::MultiJson::DecodeError => e
        fail!(:invalid_response, e)
      rescue ::Timeout::Error, ::Errno::ETIMEDOUT => e
        fail!(:timeout, e)
      rescue ::SocketError => e
        fail!(:failed_to_connect, e)
      end

      # These are called after authentication has succeeded. If
      # possible, you should try to set the UID without making
      # additional calls (if the user id is returned with the token
      # or as a URI parameter). This may not be possible with all
      # providers.
      uid { raw_info['uuid'] }

      info do
        {
          :name => @raw_info['email'].split("@")[0],
          :email => @raw_info['email']
        }
      end

      def raw_info
        access_token.options[:mode] = :query
        access_token.options[:param_name] = 'oauth_token'
        @raw_info ||= access_token.get('/oauth/user').parsed
      end

      protected

      def deep_symbolize(hash)
        hash.inject({}) do |h, (k,v)|
          h[k.to_sym] = v.is_a?(Hash) ? deep_symbolize(v) : v
          h
        end
      end

      def build_access_token
        verifier = request.params['code']
        client.auth_code.get_token(verifier, {:redirect_url => callback_url}.merge(token_params.to_hash(:symbolize_keys => true)))
      end

      # An error that is indicated in the OAuth 2.0 callback.
      # This could be a `redirect_uri_mismatch` or other
      class CallbackError < StandardError
        attr_accessor :error, :error_reason, :error_uri

        def initialize(error, error_reason=nil, error_uri=nil)
          self.error = error
          self.error_reason = error_reason
          self.error_uri = error_uri
        end
      end
    end
  end
end
OmniAuth.config.add_camelization 'kaeuferportal', 'Kaeuferportal'

