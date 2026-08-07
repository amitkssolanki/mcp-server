# frozen_string_literal: true

# RFC 7591 — OAuth 2.0 Dynamic Client Registration Protocol.
#
# Without this, every MCP client that wants to connect needs a client_id
# handed to it out of band — someone visiting /oauth/applications, creating
# an application by hand, and pasting the id into the client's config. That
# doesn't scale past "one client I set up myself," and it's the opposite of
# what claude.ai's connector flow expects: point it at a URL and it
# self-registers.
#
# Deliberately open — no authentication on this endpoint. Registering a
# client is cheap and grants it nothing by itself; every token still requires
# an admin to authenticate and approve it on the consent screen at
# /oauth/authorize. That two-step (open registration, gated authorization) is
# the spec's intended trust model, not a shortcut.
class OauthClientRegistrationsController < ActionController::API
  def create
    redirect_uris = Array(params[:redirect_uris]).map(&:to_s)
    return invalid_metadata!("redirect_uris is required and must be non-empty") if redirect_uris.empty?

    public_client = params[:token_endpoint_auth_method].to_s == "none"

    application = Doorkeeper::Application.new(
      name: params[:client_name].presence || "Unnamed MCP client (#{Time.current.iso8601})",
      redirect_uri: redirect_uris.join(" "),
      confidential: !public_client
    )

    if application.save
      render(json: registration_response(application, redirect_uris), status: :created)
    else
      invalid_metadata!(application.errors.full_messages.join(", "))
    end
  end

  private

  def registration_response(application, redirect_uris)
    {
      client_id: application.uid,
      client_id_issued_at: application.created_at.to_i,
      redirect_uris: redirect_uris,
      grant_types: Array(params[:grant_types]).presence || ["authorization_code"],
      response_types: Array(params[:response_types]).presence || ["code"],
      token_endpoint_auth_method: application.confidential? ? "client_secret_basic" : "none",
      client_name: application.name
    }.tap do |body|
      # Only a confidential client gets a secret at all — see
      # Doorkeeper::Application#secret_required?, which we rely on here
      # rather than re-deciding it: nil for public/PKCE-only clients.
      if application.confidential?
        body[:client_secret] = application.plaintext_secret
        body[:client_secret_expires_at] = 0 # 0 = does not expire, per RFC 7591 §3.2.1
      end
    end
  end

  # RFC 7591 §3.2.2 error shape.
  def invalid_metadata!(description)
    render(json: { error: "invalid_client_metadata", error_description: description }, status: :bad_request)
  end
end
